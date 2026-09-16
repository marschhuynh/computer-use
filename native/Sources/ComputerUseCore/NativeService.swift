import ApplicationServices
import CoreGraphics
import Foundation

public final class NativeService {
    private let snapshotService: SnapshotService
    private let desktopLock: DesktopLock

    public init(snapshotService: SnapshotService = SnapshotService(), desktopLock: DesktopLock = DesktopLock()) {
        self.snapshotService = snapshotService
        self.desktopLock = desktopLock
    }

    public func execute(_ request: WireRequest, context: CommandContext) async -> WireReply {
        do {
            try context.check()
            switch request.command {
            case .doctor:
                return try await desktopLock.withLock(context: context) {
                    let result = doctor()
                    try context.check()
                    return result
                }
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
        let accessibility: JSONValue = AXIsProcessTrusted() ? .object([
            "name": .string("accessibility"), "status": .string("ok"), "message": .string("Accessibility access is available to this helper")
        ]) : .object([
            "name": .string("accessibility"), "status": .string("unknown"), "message": .string("Accessibility attribution cannot be determined without prompting")
        ])
        let screenRecording: JSONValue = CGPreflightScreenCaptureAccess() ? .object([
            "name": .string("screen-recording"), "status": .string("ok"), "message": .string("Screen Recording access is available to this helper")
        ]) : .object([
            "name": .string("screen-recording"), "status": .string("unknown"), "message": .string("Screen Recording attribution cannot be determined without prompting")
        ])
        let protocolCheck: JSONValue = .object([
            "name": .string("helper-protocol"), "status": .string("ok"), "message": .string("Protocol version \(protocolVersion)")
        ])
        let dependencies: JSONValue = .object([
            "name": .string("native-dependencies"), "status": .string("ok"), "message": .string("No external helper dependency is required by this host version")
        ])
        return .success(command: .doctor, data: ["ready": .bool(false), "checks": .array([protocolCheck, dependencies, accessibility, screenRecording])])
    }
}

private func decodeTreeOptions(_ value: Any?) -> TreeOptions? {
    guard let tree = value as? [String: Any],
          let maxDepth = integer(tree["maxDepth"]),
          let maxElements = integer(tree["maxElements"]),
          let rawMode = tree["hintMode"] as? String,
          let hintMode = HintMode(rawValue: rawMode) else { return nil }
    return TreeOptions(maxDepth: maxDepth, maxElements: maxElements, hintMode: hintMode)
}
