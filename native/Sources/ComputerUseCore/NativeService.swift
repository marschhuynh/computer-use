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

    public init(
        snapshotService: SnapshotService = SnapshotService(),
        desktopLock: DesktopLock = DesktopLock(),
        targetResolver: TargetResolver = TargetResolver(),
        environment: DoctorEnvironment = .live,
        captureService: CaptureService? = nil,
        input: NativeInput = NativeInput(driver: LiveInputDriver())
    ) {
        self.snapshotService = snapshotService
        self.desktopLock = desktopLock
        self.targetResolver = targetResolver
        self.environment = environment
        self.input = input
        #if canImport(ScreenCaptureKit)
        self.captureService = captureService ?? CaptureService(capturer: liveWindowCapture)
        #else
        self.captureService = captureService ?? CaptureService(capturer: { _, _ in
            throw NativeFailure("UNSUPPORTED_PLATFORM", "Screen capture requires macOS")
        })
        #endif
    }

    public func execute(_ request: WireRequest, context: CommandContext) async -> WireReply {
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
                guard let selector = TargetSelector.decode(request.object["target"]),
                      let tree = decodeTreeOptions(request.object["tree"]),
                      let output = request.object["output"] as? String,
                      let overwrite = boolean(request.object["overwrite"]),
                      let annotated = boolean(request.object["annotated"]) else {
                    return .failure(
                        command: request.command,
                        code: "PROTOCOL_ERROR",
                        message: "Invalid screenshot request"
                    )
                }
                let resolved = try await targetResolver.resolve(selector, context: context)
                let captureData = try await captureService.screenshot(
                    target: resolved, output: output, overwrite: overwrite, context: context
                )
                var data = captureData
                if annotated {
                    // Consistent capture+snapshot pair (Stage E4): the AX
                    // traversal must observe the same target identity as the
                    // capture, else fail rather than ship mismatched metadata.
                    let snap = try await snapshotService.snapshot(
                        selector: selector, options: tree, context: context
                    )
                    guard snap.record.target.identity == resolved.identity else {
                        throw NativeFailure("NATIVE_FAILURE", "Capture and snapshot targets diverged")
                    }
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
                        try self.input.scroll(direction: "", amount: 0, at: element, context: context)
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
                    try self.input.scroll(direction: direction, amount: amount, at: nil, context: context)
                    return mutationResult(method: "cg-event", verification: "verified")
                }
            case .key:
                guard let selector = TargetSelector.decode(request.object["target"]),
                      let key = request.object["key"] as? String else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid key request")
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
            default:
                return .failure(
                    command: request.command,
                    code: "UNSUPPORTED_ACTION",
                    message: "This command is not implemented by this helper version"
                )
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
