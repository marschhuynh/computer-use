import ApplicationServices
import CoreGraphics
import Foundation

public final class NativeService {
    public init() {}

    public func execute(_ request: WireRequest) -> WireReply {
        if request.command == .doctor { return doctor() }
        return .failure(command: request.command, code: "UNSUPPORTED_ACTION", message: "This command is not implemented by this helper version")
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
