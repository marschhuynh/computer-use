import ApplicationServices
import Foundation

struct AXPreparationDriver {
    let isTrusted: () -> Bool
    // Only an attribute write returns an AX status. Setup failures must throw,
    // so unsupported timeout setup cannot be mistaken for capability negotiation.
    let write: (Int, String, Float, CommandContext) throws -> AXError
}

enum AXPreparationOutcome: Equatable {
    case requestedManual, requestedEnhanced, unsupported
}

/// Isolated experiment; not invoked by snapshot observation or action validation.
enum AXSnapshotPreparation {
    // Deliberately unwired. Identity checks belong to the separately gated
    // snapshot integration; a successful write only means requested, not ready.
    static func prepare(target: ResolvedTarget, context: CommandContext) async throws {
        _ = try request(pid: target.identity.pid, context: context, driver: liveDriver)
    }

    private static let liveDriver = AXPreparationDriver(
        isTrusted: { AXIsProcessTrusted() },
        write: { pid, name, requestedTimeout, context in
            // request validates the exact positive pid_t conversion first.
            try context.check()
            let application = AXUIElementCreateApplication(pid_t(pid))
            try context.check()

            // Application creation also consumes the existing command deadline.
            // This is a requested IPC cap, not forced native-call cancellation.
            let remaining = Double(context.remainingNanoseconds) / 1_000_000_000
            guard remaining > 0 else {
                try context.check()
                throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
            }
            let timeout = min(requestedTimeout, Float(min(0.25, remaining)))
            let timeoutStatus = AXUIElementSetMessagingTimeout(application, timeout)
            try context.check()
            guard timeoutStatus == .success else {
                throw liveAXFailure(for: timeoutStatus)
            }

            try context.check()
            let status = AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue)
            try context.check()
            return status
        }
    )

    static func request(
        pid: Int,
        context: CommandContext,
        driver: AXPreparationDriver
    ) throws -> AXPreparationOutcome {
        try context.check()
        let trusted = driver.isTrusted()
        try context.check()
        guard trusted else {
            throw NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
        }
        guard let nativePID = pid_t(exactly: pid), nativePID > 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Invalid accessibility process")
        }
        for (name, outcome) in [
            ("AXManualAccessibility", AXPreparationOutcome.requestedManual),
            ("AXEnhancedUserInterface", AXPreparationOutcome.requestedEnhanced)
        ] {
            try context.check()
            let remaining = Double(context.remainingNanoseconds) / 1_000_000_000
            guard remaining > 0 else {
                try context.check()
                throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
            }
            let status = try driver.write(pid, name, Float(min(0.25, remaining)), context)
            try context.check()
            if status == .success { return outcome }
            if status != .attributeUnsupported { throw liveAXFailure(for: status) }
        }
        return .unsupported
    }
}
