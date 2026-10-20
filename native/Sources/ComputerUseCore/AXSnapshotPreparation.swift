import ApplicationServices
import Foundation

struct AXPreparationDriver {
    let isTrusted: () -> Bool
    // Only an attribute write returns an AX status. Setup failures must throw,
    // so unsupported timeout setup cannot be mistaken for capability negotiation.
    let write: (Int, String, Float, CommandContext) throws -> AXError
    let readBool: (Int, String, Float, CommandContext) throws -> Bool?

    init(
        isTrusted: @escaping () -> Bool,
        write: @escaping (Int, String, Float, CommandContext) throws -> AXError,
        readBool: @escaping (Int, String, Float, CommandContext) throws -> Bool? = { _, _, _, _ in nil }
    ) {
        self.isTrusted = isTrusted
        self.write = write
        self.readBool = readBool
    }
}

/// Raw AX operations shared by the shipping driver and deterministic fixture tests.
struct AXPreparationAPI {
    let isTrusted: () -> Bool
    let createApplication: (pid_t) throws -> AXUIElement
    let setMessagingTimeout: (AXUIElement, Float) throws -> AXError
    let copyAttribute: (AXUIElement, String) throws -> (status: AXError, value: CFTypeRef?)
    let setAttribute: (AXUIElement, String, CFTypeRef) throws -> AXError

    static var live: AXPreparationAPI {
        AXPreparationAPI(
            isTrusted: { AXIsProcessTrusted() },
            createApplication: { AXUIElementCreateApplication($0) },
            setMessagingTimeout: { AXUIElementSetMessagingTimeout($0, $1) },
            copyAttribute: { element, name in
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                return (status, value)
            },
            setAttribute: { AXUIElementSetAttributeValue($0, $1 as CFString, $2) }
        )
    }
}

enum AXPreparationOutcome: Equatable {
    case requestedManual, requestedEnhanced, unsupported
}

public enum AXSnapshotPreparation {
    public static func prepare(
        target: ResolvedTarget,
        context: CommandContext
    ) async throws {
        try await prepare(pid: target.identity.pid, context: context, driver: liveDriver)
    }

    static func prepare(
        pid: Int,
        context: CommandContext,
        driver: AXPreparationDriver
    ) async throws {
        try validate(pid: pid, context: context, driver: driver)
        let remaining = Double(context.remainingNanoseconds) / 1_000_000_000
        guard remaining > 0 else {
            try context.check()
            throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
        }
        let wasAlreadyManual = try driver.readBool(
            pid,
            "AXManualAccessibility",
            Float(min(0.25, remaining)),
            context
        )
        try context.check()
        let outcome = try request(pid: pid, context: context, driver: driver)
        try context.check()
        if outcome == .requestedManual && wasAlreadyManual != true && context.remainingNanoseconds > 500_000_000 {
            try await context.sleep(nanoseconds: 250_000_000)
        }
        try context.check()
    }

    private static let liveDriver = makeDriver(api: .live)

    static func makeDriver(api: AXPreparationAPI) -> AXPreparationDriver {
        AXPreparationDriver(
            isTrusted: api.isTrusted,
            write: { pid, name, requestedTimeout, context in
                let application = try preparedApplication(
                    pid: pid, requestedTimeout: requestedTimeout, context: context, api: api
                )
                try context.check()
                let status = try api.setAttribute(application, name, kCFBooleanTrue)
                try context.check()
                return status // Only this actual write status can negotiate capability.
            },
            readBool: { pid, name, requestedTimeout, context in
                let application = try preparedApplication(
                    pid: pid, requestedTimeout: requestedTimeout, context: context, api: api
                )
                try context.check()
                let read = try api.copyAttribute(application, name)
                try context.check()
                switch axReadResult(status: read.status, value: read.value,
                                    expectedTypeID: CFBooleanGetTypeID(), decode: { $0 as? Bool }) {
                case let .value(value): return value
                case .unavailable: return nil
                case .failure:
                    throw liveAXFailure(for: read.status,
                        diagnostic: AXDiagnosticContext(phase: .preparation, operation: .copyAttribute, attribute: name),
                        reason: axReadFailureReason(status: read.status, value: read.value, expectedTypeID: CFBooleanGetTypeID()))
                }
            }
        )
    }

    private static func preparedApplication(
        pid: Int, requestedTimeout: Float, context: CommandContext, api: AXPreparationAPI
    ) throws -> AXUIElement {
        try context.check()
        guard let nativePID = pid_t(exactly: pid), nativePID > 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Invalid accessibility process")
        }
        let application = try api.createApplication(nativePID)
        try context.check()
        // Creation consumes the same budget. This cap is not forced IPC cancellation.
        let remaining = Double(context.remainingNanoseconds) / 1_000_000_000
        guard remaining > 0 else {
            try context.check()
            throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
        }
        let timeout = min(requestedTimeout, Float(min(0.25, remaining)))
        try context.check()
        let status = try api.setMessagingTimeout(application, timeout)
        try context.check()
        guard status == .success else {
            throw liveAXFailure(for: status,
                diagnostic: AXDiagnosticContext(phase: .preparation, operation: .setMessagingTimeout))
        }
        return application
    }

    private static func validate(
        pid: Int, context: CommandContext, driver: AXPreparationDriver
    ) throws {
        try context.check()
        let trusted = driver.isTrusted()
        try context.check()
        guard trusted else {
            throw NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
        }
        guard let nativePID = pid_t(exactly: pid), nativePID > 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Invalid accessibility process")
        }
    }

    static func request(
        pid: Int,
        context: CommandContext,
        driver: AXPreparationDriver
    ) throws -> AXPreparationOutcome {
        try validate(pid: pid, context: context, driver: driver)
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
            switch status {
            case .attributeUnsupported, .failure, .illegalArgument: continue
            default: throw liveAXFailure(for: status,
                diagnostic: AXDiagnosticContext(phase: .preparation, operation: .setAttribute, attribute: name))
            }
        }
        return .unsupported
    }
}
