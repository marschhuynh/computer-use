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

    public init(
        snapshotService: SnapshotService = SnapshotService(),
        desktopLock: DesktopLock = DesktopLock(),
        targetResolver: TargetResolver = TargetResolver(),
        environment: DoctorEnvironment = .live,
        captureService: CaptureService? = nil
    ) {
        self.snapshotService = snapshotService
        self.desktopLock = desktopLock
        self.targetResolver = targetResolver
        self.environment = environment
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
