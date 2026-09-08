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

    public func execute(_ request: WireRequest) -> WireReply {
        do {
            switch request.command {
            case .doctor:
                return try withDesktopLock(request) { doctor() }
            case .snapshot:
                guard let selector = TargetSelector.decode(request.object["target"]),
                      let tree = decodeTreeOptions(request.object["tree"]),
                      let timeout = wireInteger((request.object["options"] as? [String: Any])?["timeoutMs"]) else {
                    return .failure(command: request.command, code: "PROTOCOL_ERROR", message: "Invalid snapshot request")
                }
                let result = try snapshotService.snapshot(selector: selector, options: tree, timeoutMilliseconds: timeout)
                return .success(command: .snapshot, data: result.wireData)
            default:
                return .failure(command: request.command, code: "UNSUPPORTED_ACTION", message: "This command is not implemented by this helper version")
            }
        } catch let failure as NativeFailure {
            return .failure(
                command: request.command,
                code: failure.code,
                message: failure.message,
                details: failure.details
            )
        } catch {
            return .failure(command: request.command, code: "NATIVE_FAILURE", message: "Native command failed")
        }
    }

    private func withDesktopLock(_ request: WireRequest, body: () -> WireReply) throws -> WireReply {
        guard let timeout = wireInteger((request.object["options"] as? [String: Any])?["timeoutMs"]) else {
            throw NativeFailure("PROTOCOL_ERROR", "Invalid command options")
        }
        return try desktopLock.withLock(timeoutMilliseconds: timeout, body)
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
          let maxDepth = wireInteger(tree["maxDepth"]),
          let maxElements = wireInteger(tree["maxElements"]),
          let rawMode = tree["hintMode"] as? String,
          let hintMode = HintMode(rawValue: rawMode) else { return nil }
    return TreeOptions(maxDepth: maxDepth, maxElements: maxElements, hintMode: hintMode)
}

private func wireInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value.rounded() == value, value > 0, value <= Double(maximumSafeInteger) else { return nil }
    return Int(value)
}
