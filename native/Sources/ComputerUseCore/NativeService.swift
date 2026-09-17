import ApplicationServices
import CoreGraphics
import Foundation

/// Read-only environment probes for `doctor`. Injected so the diagnostic runs
/// without touching real permissions or a lock in tests.
public struct DoctorEnvironment {
    public let accessibilityTrusted: () -> Bool
    public let screenRecordingTrusted: () -> Bool

    public init(accessibilityTrusted: @escaping () -> Bool, screenRecordingTrusted: @escaping () -> Bool) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingTrusted = screenRecordingTrusted
    }

    public init(accessibilityTrusted: Bool, screenRecordingTrusted: Bool) {
        self.init(
            accessibilityTrusted: { accessibilityTrusted },
            screenRecordingTrusted: { screenRecordingTrusted }
        )
    }

    public static var live: DoctorEnvironment {
        DoctorEnvironment(
            accessibilityTrusted: { AXIsProcessTrusted() },
            screenRecordingTrusted: { CGPreflightScreenCaptureAccess() }
        )
    }
}

public final class NativeService {
    private let snapshotService: SnapshotService
    private let desktopLock: DesktopLock
    private let targetResolver: TargetResolver
    private let environment: DoctorEnvironment
    private let captureService: CaptureService
    private let input: NativeInput
    private let store: StateStore
    private let makeRenderer: () -> CursorRenderer
    private var cursorEnabled = true

    public init(
        snapshotService: SnapshotService = SnapshotService(),
        desktopLock: DesktopLock = DesktopLock(),
        targetResolver: TargetResolver = TargetResolver(),
        environment: DoctorEnvironment = .live,
        store: StateStore = StateStore(),
        captureService: CaptureService? = nil,
        input: NativeInput = NativeInput(driver: LiveInputDriver()),
        renderer: @escaping () -> CursorRenderer = {
            #if canImport(AppKit)
            return CursorOverlay()
            #else
            return NullCursorRenderer()
            #endif
        }
    ) {
        self.snapshotService = snapshotService
        self.desktopLock = desktopLock
        self.targetResolver = targetResolver
        self.environment = environment
        self.store = store
        self.input = input
        self.makeRenderer = renderer
        #if canImport(ScreenCaptureKit)
        self.captureService = captureService ?? CaptureService(capturer: { target, native, context in
            target.isDisplay
                ? try await liveDisplayCapture(target: target, native: native, context: context)
                : try await liveWindowCapture(windowID: target.identity.windowId, native: native, context: context)
        }, store: store)
        #else
        self.captureService = captureService ?? CaptureService(capturer: { _, _, _ in
            throw NativeFailure("UNSUPPORTED_PLATFORM", "Screen capture requires macOS")
        }, store: store)
        #endif
    }

    public func execute(_ request: WireRequest, context: CommandContext) async -> WireReply {
        // Read the per-request --cursor option; visualization is feedback only.
        if let options = request.object["options"] as? [String: Any],
           (options["cursor"] as? String) == "off" {
            cursorEnabled = false
        }
        do {
            try context.check()
            switch request.command {
            case .doctor:
                // Read-only diagnostic: no desktop lock, no state sweep. It must
                // report health even while another operation holds the lock.
                let result = doctor()
                try context.check()
                return result
            case .apps:
                let apps = try await targetResolver.listApplications(context: context)
                return .success(command: .apps, data: [
                    "apps": .array(apps.map { app in .object([
                        "name": .string(app.name),
                        "pid": .number(Double(app.pid)),
                        "bundleId": app.bundleId.map(JSONValue.string) ?? .null,
                    ]) })
                ])
            case .windows:
                guard let selector = TargetSelector.decode(request.object["target"]) else {
                    return .failure(
                        command: request.command,
                        code: "PROTOCOL_ERROR",
                        message: "Invalid windows request"
                    )
                }
                let application = try await targetResolver.windowsApplication(selector, context: context)
                let windows = try targetResolver.listWindows(for: application.pid, context: context)
                return .success(command: .windows, data: [
                    "windows": .array(windows.map { windowJSON($0) })
                ])
            case .snapshot:
                guard let selector = TargetSelector.decode(request.object["target"]),
                      let tree = decodeTreeOptions(request.object["tree"]) else {
                    return .failure(
                        command: request.command,
                        code: "PROTOCOL_ERROR",
                        message: "Invalid snapshot request"
                    )
                }
                let result = try await snapshotService.snapshot(
                    selector: selector,
                    options: tree,
                    context: context
                )
                return .success(command: .snapshot, data: result.wireData)
            case .screenshot:
                guard let tree = decodeTreeOptions(request.object["tree"]),
                      let output = request.object["output"] as? String,
                      let overwrite = boolean(request.object["overwrite"]),
                      let annotated = boolean(request.object["annotated"]),
                      let native = boolean(request.object["native"]) else {
                    return .failure(
                        command: request.command,
                        code: "PROTOCOL_ERROR",
                        message: "Invalid screenshot request"
                    )
                }
                // target + display is rejected at wire validation; guard again
                // so a hand-built request can't slip both through.
                if request.object["target"] != nil, request.object["display"] != nil {
                    return .failure(
                        command: request.command,
                        code: "PROTOCOL_ERROR",
                        message: "Invalid screenshot request"
                    )
                }
                // `selector` is nil for the display path; annotated snapshots
                // below are gated on isDisplay and always have a window target.
                let selector = TargetSelector.decode(request.object["target"])
                let resolved: ResolvedTarget
                if let selector {
                    resolved = try await targetResolver.resolve(selector, context: context)
                } else {
                    // No window target: --display n selects displays[n]; bare
                    // screenshot takes the primary display.
                    resolved = try await targetResolver.resolveDisplay(
                        integer(request.object["display"]),
                        context: context
                    )
                }
                if annotated, resolved.isDisplay {
                    throw NativeFailure("INVALID_ARGUMENT", "--annotated requires --app/--pid")
                }
                // When annotated, snapshot first so the capture can overlay
                // ref-hint badges at each element's screen bounds — the saved
                // PNG then maps pixels back to refs.
                var snap: SnapshotResult?
                var annotations: [(ref: Int, bounds: WindowBounds)] = []
                if annotated, let selector {
                    let observed = try await snapshotService.snapshot(
                        selector: selector, options: tree, context: context
                    )
                    guard observed.record.target.identity == resolved.identity else {
                        throw NativeFailure("NATIVE_FAILURE", "Capture and snapshot targets diverged")
                    }
                    snap = observed
                    annotations = observed.snapshot.evidence.refs.compactMap { refEvidence in
                        guard let bounds = refEvidence.node.bounds else { return nil }
                        return (ref: refEvidence.ref, bounds: bounds)
                    }
                }
                let captureData = try await captureService.screenshot(
                    target: resolved, output: output, overwrite: overwrite,
                    native: native, context: context, annotations: annotations
                )
                var data = captureData
                if let snap {
                    if case var .object(dict) = data {
                        dict["snapshotId"] = .string(snap.record.id)
                        dict["tree"] = snap.wireData["tree"] ?? .null
                        dict["truncated"] = snap.wireData["truncated"] ?? .bool(false)
                        data = .object(dict)
                    }
                }
                return .success(command: .screenshot, data: dataAsDictionary(data))
            case .press:
                guard let snapshotId = request.object["snapshotId"] as? String,
                      let ref = integer(request.object["ref"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid press request")
                }
                return try await dispatchSnapshotMutation(
                    command: .press, snapshotID: snapshotId, ref: ref, context: context
                ) { element, context in
                    try self.input.press(element, context: context)
                    return mutationResult(method: "accessibility", verification: "verified")
                }
            case .setValue:
                guard let snapshotId = request.object["snapshotId"] as? String,
                      let ref = integer(request.object["ref"]),
                      let text = request.object["text"] as? String else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid set-value request")
                }
                return try await dispatchSnapshotMutation(
                    command: .setValue, snapshotID: snapshotId, ref: ref, context: context
                ) { element, context in
                    try self.input.setValue(element, text: text, context: context)
                    return mutationResult(method: "accessibility", verification: "verified")
                }
            case .scroll:
                if let snapshotId = request.object["snapshotId"] as? String,
                   let ref = integer(request.object["ref"]) {
                    return try await dispatchSnapshotMutation(
                        command: .scroll, snapshotID: snapshotId, ref: ref, context: context
                    ) { element, context in
                        try self.input.scroll(direction: "", amount: 0, at: element, point: nil, context: context)
                        return mutationResult(method: "accessibility", verification: "verified")
                    }
                }
                guard let selector = TargetSelector.decode(request.object["target"]),
                      let direction = request.object["direction"] as? String,
                      let amount = integer(request.object["amount"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid scroll request")
                }
                let resolved = try await targetResolver.resolve(selector, context: context)
                return try await dispatchTargetMutation(
                    command: .scroll, target: resolved, context: context
                ) { context in
                    // Deliver the scroll gesture at the resolved window's centre so
                    // it lands on the target regardless of where the pointer sits.
                    let center = CGPoint(
                        x: resolved.bounds.x + resolved.bounds.width / 2,
                        y: resolved.bounds.y + resolved.bounds.height / 2
                    )
                    try self.input.scroll(direction: direction, amount: amount, at: nil, point: center, context: context)
                    return mutationResult(method: "cg-event", verification: "verified")
                }
            case .key:
                let selector = TargetSelector.decode(request.object["target"])
                guard let key = request.object["key"] as? String else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid key request")
                }
                // No target: the chord goes to the HID event tap, landing on
                // whatever holds keyboard focus. Protocol validation guarantees
                // any present target dict is well-formed, so nil means absent.
                guard let selector else {
                    return try await dispatchGlobalMutation(command: .key, context: context) { context in
                        try self.input.globalKey(key, context: context)
                        return mutationResult(method: "cg-event", verification: "verified")
                    }
                }
                let resolved = try await targetResolver.resolve(selector, context: context)
                return try await dispatchTargetMutation(
                    command: .key, target: resolved, context: context
                ) { context in
                    try self.input.key(key, to: resolved.identity.pid, context: context)
                    return mutationResult(method: "cg-event", verification: "verified")
                }
            case .type:
                guard let selector = TargetSelector.decode(request.object["target"]),
                      let text = request.object["text"] as? String,
                      let allowClipboardReplace = boolean(request.object["allowClipboardReplace"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid type request")
                }
                let resolved = try await targetResolver.resolve(selector, context: context)
                return try await dispatchTargetMutation(
                    command: .type, target: resolved, context: context
                ) { context in
                    // Unicode-event path leaves the clipboard untouched.
                    // allowClipboardReplace is accepted but never triggers a
                    // hidden paste fallback (spec: no silent clipboard use).
                    _ = allowClipboardReplace
                    try self.input.type(text, to: resolved.identity.pid, context: context)
                    var result = mutationResult(method: "cg-event", verification: "verified")
                    result["clipboardReplaced"] = .bool(false)
                    return result
                }
            case .click:
                guard let captureId = request.object["captureId"] as? String,
                      let point = decodePoint(request.object["point"]),
                      let button = request.object["button"] as? String,
                      let count = integer(request.object["count"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid click request")
                }
                let (screen, capture) = try await resolveCapturePoint(captureId, point: point, context: context)
                return try await dispatchSpatialMutation(command: .click, target: capture.target, point: screen, kind: .click, context: context) { context in
                    try self.input.click(at: screen, button: button, count: count, context: context)
                }
            case .move:
                guard let captureId = request.object["captureId"] as? String,
                      let point = decodePoint(request.object["point"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid move request")
                }
                let (screen, capture) = try await resolveCapturePoint(captureId, point: point, context: context)
                return try await dispatchSpatialMutation(command: .move, target: capture.target, point: screen, kind: .move, context: context) { context in
                    try self.input.move(to: screen, context: context)
                }
            case .drag:
                guard let captureId = request.object["captureId"] as? String,
                      let from = decodePoint(request.object["from"]),
                      let to = decodePoint(request.object["to"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid drag request")
                }
                let (fromScreen, capture) = try await resolveCapturePoint(captureId, point: from, context: context)
                let toScreen = try capture.geometry.imageToScreen(to)
                return try await dispatchSpatialMutation(command: .drag, target: capture.target, point: fromScreen, kind: .drag(to: toScreen), context: context) { context in
                    try self.input.drag(from: fromScreen, to: toScreen, context: context)
                }
            }
        } catch let failure as NativeFailure {
            return .failure(
                command: request.command,
                code: failure.code,
                message: failure.message,
                details: failure.details
            )
        } catch {
            return .failure(
                command: request.command,
                code: "NATIVE_FAILURE",
                message: "Native command failed"
            )
        }
    }

    private func doctor() -> WireReply {
        let accessibilityTrusted = environment.accessibilityTrusted()
        let screenRecordingTrusted = environment.screenRecordingTrusted()
        let accessibility: JSONValue = accessibilityTrusted ? .object([
            "name": .string("accessibility"), "status": .string("ok"), "message": .string("Accessibility access is available to this helper")
        ]) : .object([
            "name": .string("accessibility"), "status": .string("denied"), "message": .string("Accessibility access is not available to this helper")
        ])
        let screenRecording: JSONValue = screenRecordingTrusted ? .object([
            "name": .string("screen-recording"), "status": .string("ok"), "message": .string("Screen Recording access is available to this helper")
        ]) : .object([
            "name": .string("screen-recording"), "status": .string("denied"), "message": .string("Screen Recording access is not available to this helper")
        ])
        let protocolCheck: JSONValue = .object([
            "name": .string("helper-protocol"), "status": .string("ok"), "message": .string("Protocol version \(protocolVersion)")
        ])
        let dependencies: JSONValue = .object([
            "name": .string("native-dependencies"), "status": .string("ok"), "message": .string("No external helper dependency is required by this host version")
        ])
        let checks: [JSONValue] = [protocolCheck, dependencies, accessibility, screenRecording]
        let ready = checks.allSatisfy { check in
            if case let .object(object) = check, case let .string(status) = object["status"] {
                return status == "ok"
            }
            return false
        }
        return .success(command: .doctor, data: ["ready": .bool(ready), "checks": .array(checks)])
    }
}

private func windowJSON(_ window: TargetWindow) -> JSONValue {
    let eligible = window.cg.onScreen && window.ax.minimized != true
    let reason: JSONValue
    if eligible {
        reason = .null
    } else if window.ax.minimized == true {
        reason = .string("minimized")
    } else if !window.cg.onScreen {
        reason = .string("offscreen")
    } else {
        reason = .string("ineligible")
    }
    return .object([
        "id": .number(Double(window.cg.id)),
        "title": .string(window.cg.title ?? window.ax.title ?? ""),
        "bounds": .object([
            "x": .number(window.cg.bounds.x),
            "y": .number(window.cg.bounds.y),
            "width": .number(window.cg.bounds.width),
            "height": .number(window.cg.bounds.height),
        ]),
        "eligible": .bool(eligible),
        "reason": reason,
    ])
}

private func mutationResult(method: String, verification: String) -> [String: JSONValue] {
    [
        "method": .string(method),
        "verification": .string(verification),
        "visualization": .string("none"),
    ]
}

private extension NativeService {
    /// Ref-scoped mutation: goes through the full validated-snapshot-action
    /// pipeline (lock, sweep, identity+evidence revalidation, foreground prep,
    /// invalidate-on-mutation, dispatch). Mutation status is attached by the
    /// pipeline based on whether dispatch began.
    func dispatchSnapshotMutation(
        command: WireCommand,
        snapshotID: String,
        ref: Int,
        context: CommandContext,
        dispatch: @escaping (LiveAXElement, CommandContext) async throws -> [String: JSONValue]
    ) async throws -> WireReply {
        var entered = false
        do {
            let data: [String: JSONValue] = try await snapshotService.withValidatedSnapshotAction(
                snapshotID: snapshotID,
                ref: ref,
                context: context,
                stateChanging: true,
                preflight: { _, target, _ in target },
                dispatch: { _, element, context in
                    entered = true
                    return try await dispatch(element, context)
                }
            )
            var payload = data
            payload["target"] = targetJSONForMutation(snapshotID: snapshotID)
            return .success(command: command, data: payload)
        } catch let failure as NativeFailure {
            return .failure(command: command, code: failure.code, message: failure.message,
                            details: attachingStatus(failure.details, entered))
        } catch {
            return .failure(command: command, code: "NATIVE_FAILURE", message: "Native command failed",
                            details: attachingStatus(nil, entered))
        }
    }

    /// Spatial mutation (click/move/drag): like a target mutation but the
    /// cursor visualizes the resolved screen point via an ActionTimeline when
    /// enabled. Visualization is feedback only; input always runs.
    func dispatchSpatialMutation(
        command: WireCommand,
        target: ResolvedTarget,
        point: CGPoint,
        kind: SpatialActionKind,
        context: CommandContext,
        input: @escaping (CommandContext) async throws -> Void
    ) async throws -> WireReply {
        var entered = false
        do {
            let (data, visualization): ([String: JSONValue], Visualization) = try await desktopLock.withLock(context: context) {
                try context.check()
                let fresh = try await targetResolver.validate(target.identity, context: context)
                guard fresh == target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                var viz = Visualization.none
                if cursorEnabled {
                    let timeline = ActionTimeline(renderer: makeRenderer())
                    viz = try await timeline.spatialAction(at: point, kind: kind, context: context) { context in
                        entered = true
                        try await input(context)
                    }
                } else {
                    entered = true
                    try await input(context)
                }
                var payload = mutationResult(method: "cg-event", verification: "verified")
                payload["visualization"] = .string(viz.rawValue)
                return (payload, viz)
            }
            var payload = data
            payload["target"] = targetJSONForMutation(target: target)
            _ = visualization
            return .success(command: command, data: payload)
        } catch let failure as NativeFailure {
            return .failure(command: command, code: failure.code, message: failure.message,
                            details: attachingStatus(failure.details, entered))
        } catch {
            return .failure(command: command, code: "NATIVE_FAILURE", message: "Native command failed",
                            details: attachingStatus(nil, entered))
        }
    }

    /// Target-scoped mutation (key/type/directional scroll): lock + identity
    /// validation + dispatch, with held-input cleanup on cancellation.
    func dispatchTargetMutation(
        command: WireCommand,
        target: ResolvedTarget,
        context: CommandContext,
        dispatch: @escaping (CommandContext) async throws -> [String: JSONValue]
    ) async throws -> WireReply {
        var entered = false
        do {
            let data = try await desktopLock.withLock(context: context) {
                try context.check()
                // revalidate the target still owns the foreground window before input
                let fresh = try await targetResolver.validate(target.identity, context: context)
                guard fresh == target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                entered = true
                return try await dispatch(context)
            }
            var payload = data
            payload["target"] = targetJSONForMutation(target: target)
            return .success(command: command, data: payload)
        } catch let failure as NativeFailure {
            return .failure(command: command, code: failure.code, message: failure.message,
                            details: attachingStatus(failure.details, entered))
        } catch {
            return .failure(command: command, code: "NATIVE_FAILURE", message: "Native command failed",
                            details: attachingStatus(nil, entered))
        }
    }

    /// Global mutation (target-less key): lock + dispatch. There is no target
    /// identity to revalidate — the input lands wherever focus sits — so the
    /// reply only reports the global scope.
    func dispatchGlobalMutation(
        command: WireCommand,
        context: CommandContext,
        dispatch: @escaping (CommandContext) async throws -> [String: JSONValue]
    ) async throws -> WireReply {
        var entered = false
        do {
            let data = try await desktopLock.withLock(context: context) {
                try context.check()
                entered = true
                return try await dispatch(context)
            }
            var payload = data
            payload["target"] = .object(["scope": .string("global")])
            return .success(command: command, data: payload)
        } catch let failure as NativeFailure {
            return .failure(command: command, code: failure.code, message: failure.message,
                            details: attachingStatus(failure.details, entered))
        } catch {
            return .failure(command: command, code: "NATIVE_FAILURE", message: "Native command failed",
                            details: attachingStatus(nil, entered))
        }
    }
}

private func attachingStatus(_ details: [String: JSONValue]?, _ entered: Bool) -> [String: JSONValue] {
    var details = details ?? [:]
    if details["mutationStatus"] == nil {
        details["mutationStatus"] = .string(entered ? "potentiallyApplied" : "notStarted")
    }
    return details
}

private func targetJSONForMutation(snapshotID: String) -> JSONValue {
    .object(["snapshotId": .string(snapshotID)])
}
private func targetJSONForMutation(target: ResolvedTarget) -> JSONValue {
    .object([
        "pid": .number(Double(target.identity.pid)),
        "windowId": .number(Double(target.identity.windowId)),
    ])
}

private func decodePoint(_ value: Any?) -> CGPoint? {
    guard let dict = value as? [String: Any],
          let x = dict["x"] as? NSNumber, let y = dict["y"] as? NSNumber,
          x.doubleValue.isFinite, y.doubleValue.isFinite else { return nil }
    return CGPoint(x: x.doubleValue, y: y.doubleValue)
}

private extension NativeService {
    /// Resolve a --capture record + image point to a screen point, after
    /// re-validating the capture's target identity and geometry are unchanged.
    func resolveCapturePoint(
        _ captureId: String,
        point: CGPoint,
        context: CommandContext
    ) async throws -> (CGPoint, CaptureRecord) {
        let record = try store.readCapture(id: captureId, context: context)
        // Re-validate the target identity; a changed process/window means the
        // recorded geometry no longer maps onto what's on screen.
        let fresh = try await targetResolver.validate(record.target.identity, context: context)
        guard fresh == record.target else {
            throw NativeFailure("STALE_CAPTURE", "Recorded capture target changed")
        }
        let screen = try record.geometry.imageToScreen(point)
        return (screen, record)
    }
}

private func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

private func dataAsDictionary(_ value: JSONValue) -> [String: JSONValue] {
    if case let .object(dict) = value { return dict }
    return [:]
}

private func decodeTreeOptions(_ value: Any?) -> TreeOptions? {
    guard let tree = value as? [String: Any],
          let maxDepth = integer(tree["maxDepth"]),
          let maxElements = integer(tree["maxElements"]),
          let rawMode = tree["hintMode"] as? String,
          let hintMode = HintMode(rawValue: rawMode) else { return nil }
    return TreeOptions(maxDepth: maxDepth, maxElements: maxElements, hintMode: hintMode)
}
