import ApplicationServices

// Only static labels and actual status codes enter diagnostics, never AX payloads or errors.
enum AXDiagnosticPhase: String {
    case resolution, preparation, observation
}

enum AXDiagnosticOperation: String {
    case setMessagingTimeout, copyAttribute, setAttribute, copyMultipleAttributes, copyActionNames
}

enum AXDiagnosticScope: String {
    case direct, batchTopLevel, batchEntry
}

enum AXDiagnosticReason: String {
    case statusFailure, missingValue, unexpectedType, invalidArrayElement
    case batchLengthMismatch, invalidBoundsRepresentation, decodeFailure
}

struct AXDiagnosticContext {
    let phase: AXDiagnosticPhase
    let operation: AXDiagnosticOperation
    var attribute: String? = nil
    var scope: AXDiagnosticScope = .direct

    private static let attributes: Set<String> = [
        "AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue",
        "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize", "AXChildren",
        "AXWindows", "AXManualAccessibility", "AXEnhancedUserInterface"
    ]

    func details(status: AXError?, reason: AXDiagnosticReason) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "phase": .string(phase.rawValue), "operation": .string(operation.rawValue),
            "statusScope": .string(scope.rawValue), "reason": .string(reason.rawValue)
        ]
        if let attribute, Self.attributes.contains(attribute),
           operation != .setMessagingTimeout, operation != .copyActionNames, scope != .batchTopLevel {
            fields["attribute"] = .string(attribute)
        }
        if let status {
            fields["statusCode"] = .number(Double(status.rawValue))
            fields["statusName"] = .string(axStatusName(status))
        }
        return ["ax": .object(fields)]
    }
}

func axStatusName(_ status: AXError) -> String {
    switch status {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    default: return "unknown"
    }
}
