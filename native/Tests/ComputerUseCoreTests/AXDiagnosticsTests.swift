import ApplicationServices
import XCTest
@testable import ComputerUseCore

// Inert handles only; every exercised IPC callback is injected.
final class AXDiagnosticsTests: XCTestCase {
    func testStaticStatusNamesAndFlatBoundedAllowlistedDetails() throws {
        for raw in [Int32(0)] + Array(Int32(-25214)...Int32(-25200)) + [-99999] {
            let status = try XCTUnwrap(AXError(rawValue: raw))
            XCTAssertEqual(axStatusName(status), testAXName(status))
            let failure = liveAXFailure(for: status, diagnostic: AXDiagnosticContext(
                phase: .observation, operation: .copyAttribute, attribute: "AXTitle"))
            assertAXDiagnostic(failure, operation: "copyAttribute", attribute: "AXTitle", status: status, name: testAXName(status))
            guard case let .object(fields)? = failure.details?["ax"] else { return XCTFail("missing ax") }
            XCTAssertEqual(fields.count, 7)
            for (key, value) in fields {
                XCTAssertTrue(key.utf8.allSatisfy { $0 < 128 })
                switch value {
                case let .string(text):
                    XCTAssertLessThanOrEqual(text.utf8.count, 64)
                    XCTAssertTrue(text.utf8.allSatisfy { $0 < 128 })
                case .number: XCTAssertEqual(key, "statusCode")
                default: XCTFail("diagnostics must contain only strings and numeric status")
                }
            }
        }
        let allowed = ["AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue",
            "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize", "AXChildren", "AXWindows",
            "AXManualAccessibility", "AXEnhancedUserInterface"]
        for attribute in allowed + ["PRIVATE-title-identifier-URL", String(repeating: "x", count: 200), "秘密"] {
            let details = AXDiagnosticContext(phase: .preparation, operation: .copyAttribute, attribute: attribute)
                .details(status: nil, reason: .decodeFailure)
            guard case let .object(fields)? = details["ax"] else { return XCTFail("missing ax") }
            XCTAssertNil(fields["statusCode"])
            XCTAssertNil(fields["statusName"])
            XCTAssertEqual(fields["attribute"], allowed.contains(attribute) ? .string(attribute) : nil)
            XCTAssertLessThanOrEqual(fields.count, 5)
        }
        for context in [AXDiagnosticContext(phase: .resolution, operation: .setMessagingTimeout, attribute: "AXTitle"),
                        AXDiagnosticContext(phase: .observation, operation: .copyActionNames, attribute: "AXTitle"),
                        AXDiagnosticContext(phase: .observation, operation: .copyMultipleAttributes, attribute: "AXTitle", scope: .batchTopLevel)] {
            guard case let .object(fields)? = context.details(status: .cannotComplete, reason: .statusFailure)["ax"] else {
                return XCTFail("missing ax")
            }
            XCTAssertNil(fields["attribute"])
            XCTAssertEqual(fields.count, 6)
        }
    }

    func testNativeFailureSerializationNeverIncludesRawScalarOrCollectionPayloads() throws {
        let sentinels = ["PRIVATE-title-836", "PRIVATE-value-937", "https://private.invalid/738", "PRIVATE-identifier-639"]
        let element = AXUIElementCreateApplication(42)
        for (attribute, text) in zip([kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute], sentinels) {
            for payload in [text as CFString, ["private-object": text] as CFDictionary] as [CFTypeRef] {
                let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.attributeUnsupported, nil) },
                    singleRead: { _, _ in (.cannotComplete, payload) }),
                    readChildrenAttribute: { _, _ in (.success, [element, payload] as CFArray) },
                    copyActionNames: { _ in (.success, [text as CFString, payload, NSNumber(value: 1)] as CFArray) })
                let operations: [() throws -> Void] = [
                    { _ = try reader.string(element, attribute) },
                    { _ = try reader.children(element) }, { _ = try reader.actions(element) }
                ]
                for operation in operations {
                    do { try operation(); XCTFail("expected diagnosed failure") }
                    catch let failure as NativeFailure {
                        let data = try JSONEncoder().encode(WireReply.failure(command: .snapshot, code: failure.code,
                            message: failure.message, details: failure.details))
                        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
                        XCTAssertNotNil(failure.details?["ax"])
                        for sentinel in sentinels + ["private-object"] { XCTAssertFalse(json.contains(sentinel)) }
                    }
                }
            }
        }
        let unknown = "PRIVATE-unknown-秘密-" + String(repeating: "x", count: 100)
        let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.attributeUnsupported, nil) },
            singleRead: { _, _ in (.cannotComplete, unknown as CFString) }))
        XCTAssertThrowsError(try reader.string(element, unknown)) {
            assertAXDiagnostic($0, operation: "copyAttribute", status: .cannotComplete, name: "cannotComplete")
        }
    }

    func testSharedTimeoutLabelsActualStatusWithoutAttribute() throws {
        for phase in [AXDiagnosticPhase.resolution, .observation] {
            for (status, name) in [(AXError.cannotComplete, "cannotComplete"), (.apiDisabled, "apiDisabled"),
                                   (AXError(rawValue: -99999)!, "unknown")] {
                var calls = 0
                XCTAssertThrowsError(try prepareLiveAXMessaging(AXUIElementCreateApplication(42),
                    context: diagnosticContext(), phase: phase, setMessagingTimeout: { _, timeout in
                        calls += 1
                        XCTAssertEqual(timeout, 1)
                        return status
                    })) {
                    assertAXDiagnostic($0, phase: phase.rawValue, operation: "setMessagingTimeout",
                                       status: status, name: name)
                }
                XCTAssertEqual(calls, 1)
            }
            try prepareLiveAXMessaging(AXUIElementCreateApplication(42), context: diagnosticContext(),
                phase: phase, setMessagingTimeout: { _, _ in .success })
        }
    }

    func testSharedTimeoutContextPrecedenceAndUnrelatedDefaultRemainUnlabelled() {
        for cancelled in [false, true] {
            let context = diagnosticContext(timeout: 0)
            if cancelled { context.cancel() }
            XCTAssertThrowsError(try prepareLiveAXMessaging(AXUIElementCreateApplication(42),
                context: context, phase: .resolution, setMessagingTimeout: { _, _ in
                    XCTFail("expired context must not call AX"); return .apiDisabled
                })) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, cancelled ? "INTERRUPTED" : "TIMEOUT")
                XCTAssertNil(($0 as? NativeFailure)?.details)
            }
        }
        XCTAssertThrowsError(try prepareLiveAXMessaging(AXUIElementCreateApplication(42),
            context: diagnosticContext(), setMessagingTimeout: { _, _ in .cannotComplete })) {
            XCTAssertNil(($0 as? NativeFailure)?.details)
        }
    }
}

func diagnosticContext(timeout: Int = 1_000) -> CommandContext {
    CommandContext(timeoutMilliseconds: timeout, clock: NativeClock(monotonicNow: { 0 },
        wallNow: { Date(timeIntervalSince1970: 0) }, sleepNanoseconds: { _ in }))
}

func expectedAXDiagnostic(phase: String = "observation", operation: String,
                          attribute: String? = nil, status: AXError, name: String,
                          scope: String = "direct", reason: String = "statusFailure") -> JSONValue {
    var fields: [String: JSONValue] = ["phase": .string(phase), "operation": .string(operation),
        "statusCode": .number(Double(status.rawValue)), "statusName": .string(name),
        "statusScope": .string(scope), "reason": .string(reason)]
    if let attribute { fields["attribute"] = .string(attribute) }
    return .object(fields)
}

func assertAXDiagnostic(_ error: Error, phase: String = "observation", operation: String,
                        attribute: String? = nil, status: AXError, name: String,
                        scope: String = "direct", reason: String = "statusFailure",
                        file: StaticString = #filePath, line: UInt = #line) {
    guard let failure = error as? NativeFailure else { return XCTFail("not NativeFailure", file: file, line: line) }
    XCTAssertEqual(failure.code, status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE", file: file, line: line)
    XCTAssertEqual(failure.message, status == .apiDisabled ? "Accessibility access is unavailable" :
        "Accessibility data could not be read reliably", file: file, line: line)
    XCTAssertEqual(failure.details, ["ax": expectedAXDiagnostic(phase: phase, operation: operation,
        attribute: attribute, status: status, name: name, scope: scope, reason: reason)], file: file, line: line)
}

func testAXName(_ status: AXError) -> String {
    let names = ["failure", "illegalArgument", "invalidUIElement", "invalidUIElementObserver",
        "cannotComplete", "attributeUnsupported", "actionUnsupported", "notificationUnsupported",
        "notImplemented", "notificationAlreadyRegistered", "notificationNotRegistered", "apiDisabled",
        "noValue", "parameterizedAttributeUnsupported", "notEnoughPrecision"]
    if status == .success { return "success" }
    let index = -25200 - Int(status.rawValue)
    return names.indices.contains(index) ? names[index] : "unknown"
}
