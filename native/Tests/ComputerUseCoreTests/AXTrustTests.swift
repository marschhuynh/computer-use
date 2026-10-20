import ApplicationServices
import XCTest
@testable import ComputerUseCore

final class AXTrustTests: XCTestCase {
    func testMissingOptionalValuesAndUnsupportedLeafCollectionsRemainTrustworthy() throws {
        let reader = AXTreeReader<Int>(
            string: { element, attribute in
                if attribute == kAXRoleAttribute { return .value(element == 0 ? "AXWindow" : "AXButton") }
                return .unavailable
            },
            bool: { _, _ in .unavailable },
            children: { element in element == 0 ? .value([1]) : .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )

        let result = try AXTree.readSnapshot(
            target: trustTarget(),
            options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
            root: 0,
            reader: reader
        )

        XCTAssertEqual(result.snapshot.evidence.nodes.map(\.role), ["AXWindow", "AXButton"])
        XCTAssertNil(result.snapshot.evidence.nodes[0].title)
        XCTAssertEqual(result.snapshot.evidence.nodes[1].childCount, 0)
        XCTAssertEqual(result.snapshot.evidence.nodes[1].actions, [])
        XCTAssertEqual(result.elementsByRef.keys.sorted(), [1, 2])
        XCTAssertEqual(result.elementsByRef[1], 0)
        XCTAssertEqual(result.elementsByRef[2], 1)
    }

    func testEveryPersistedReadFailureRejectsObservationInsteadOfSerializingFallbackEvidence() {
        for failingRead in axFailureCases {
            XCTAssertThrowsError(
                try AXTree.readSnapshot(
                    target: trustTarget(),
                    options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                    root: 0,
                    reader: failingReader(failingRead)
                ),
                failingRead
            ) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testUnavailableRoleRejectsObservation() {
        let reader = AXTreeReader<Int>(
            string: { _, _ in .unavailable },
            bool: { _, _ in .unavailable },
            children: { _ in .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )

        XCTAssertThrowsError(
            try AXTree.readSnapshot(
                target: trustTarget(),
                options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                root: 0,
                reader: reader
            )
        ) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testCannotCompleteIsFailureWhileMissingAndUnsupportedAreUnavailable() {
        XCTAssertEqual(axReadDisposition(for: .success), .value)
        XCTAssertEqual(axReadDisposition(for: .cannotComplete), .failure)
        XCTAssertEqual(axReadDisposition(for: .failure), .failure)
        XCTAssertEqual(axReadDisposition(for: .invalidUIElement), .failure)
        XCTAssertEqual(axReadDisposition(for: .apiDisabled), .failure)
        XCTAssertEqual(axReadDisposition(for: .noValue), .unavailable)
        XCTAssertEqual(axReadDisposition(for: .attributeUnsupported), .unavailable)
    }

    // Notes and Calendar return kAXErrorFailure from
    // AXUIElementCopyActionNames for elements that simply expose no actions
    // (verified live: AXSplitter/AXStaticText/AXGroup inside the Notes
    // window). An unreadable *action list* is not grounds to abort a whole
    // snapshot — the element is still observable, it just advertises no
    // actions — so the live adapter must degrade it to `.unavailable`.
    func testUnreadableActionListDegradesToNoActionsInsteadOfFailing() {
        XCTAssertEqual(axActionNamesReadResult(status: .failure, names: nil), .unavailable)
    }

    // Permission and liveness problems must still surface: degrading them
    // would hide PERMISSION_DENIED and dead-element errors behind an empty
    // action list.
    func testActionListPermissionAndLivenessErrorsStayFailures() {
        XCTAssertEqual(axActionNamesReadResult(status: .apiDisabled, names: nil), .failure)
        XCTAssertEqual(axActionNamesReadResult(status: .invalidUIElement, names: nil), .failure)
        XCTAssertEqual(axActionNamesReadResult(status: .cannotComplete, names: nil), .failure)
    }

    func testActionListSuccessAndAbsenceKeepExistingSemantics() {
        let names = ["AXPress", "AXShowMenu"] as CFArray
        XCTAssertEqual(axActionNamesReadResult(status: .success, names: names), .value(["AXPress", "AXShowMenu"]))
        XCTAssertEqual(axActionNamesReadResult(status: .noValue, names: nil), .unavailable)
        XCTAssertEqual(axActionNamesReadResult(status: .attributeUnsupported, names: nil), .unavailable)
        // `.success` with no payload at all is a contract violation, not a
        // degenerate element: AX claimed it wrote a value and did not. That
        // stays a failure (see testSuccessfulWrongCFTypeAndMissingValueAreFailures).
        XCTAssertEqual(axActionNamesReadResult(status: .success, names: nil), .failure)
    }

    // Same root cause as the action-list case, on a different attribute:
    // Notes and Calendar answer kAXErrorFailure for an *absent* AXSubrole on
    // AXGroup/AXButton elements (verified live) where AppKit answers
    // .noValue. AXSubrole is optional and non-identifying, so an unreadable
    // one must not abort the snapshot.
    func testUnreadableOptionalScalarAttributeDegradesToAbsent() {
        for attribute in [
            kAXSubroleAttribute,
            kAXIdentifierAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute
        ] {
            XCTAssertFalse(axAttributeIsIdentifying(attribute), attribute)
        }
    }

    // AXRole is the one scalar the snapshot cannot do without: it is read via
    // `required()` and every downstream ref/evidence decision keys off it.
    // An unreadable role must stay a hard failure rather than silently
    // producing a roleless node.
    func testUnreadableRoleRemainsIdentifyingAndFatal() {
        XCTAssertTrue(axAttributeIsIdentifying(kAXRoleAttribute))
    }

    func testSuccessfulWrongCFTypeAndMissingValueAreFailures() {
        let number: CFTypeRef = NSNumber(value: 7)
        let wrongType: AXReadResult<String> = axReadResult(
            status: .success,
            value: number,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )
        let missing: AXReadResult<String> = axReadResult(
            status: .success,
            value: nil,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )

        XCTAssertEqual(wrongType, .failure)
        XCTAssertEqual(missing, .failure)
    }

    func testMalformedArrayMemberIsAReadFailure() {
        let values: [AnyObject] = [NSString(string: "AXPress"), NSNumber(value: 7)]
        let decoded: [String]? = decodeAXArray(
            values,
            expectedElementTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )

        XCTAssertNil(decoded)
    }

    func testCancellationDuringBlockedReadStopsBeforeChildTraversal() async {
        let context = axTestContext()
        let entered = expectation(description: "AX read entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedInt()
        let reader = AXTreeReader<Int>(
            string: { element, attribute in
                if attribute == kAXRoleAttribute {
                    let call = calls.increment()
                    if call == 1 {
                        entered.fulfill()
                        _ = release.wait(timeout: .now() + 1)
                    }
                    return .value(element == 0 ? "AXWindow" : "AXButton")
                }
                return .unavailable
            },
            bool: { _, _ in .unavailable },
            children: { element in element == 0 ? .value([1]) : .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )
        let work = Task.detached { () -> NativeFailure? in
            do {
                _ = try AXTree.readSnapshot(
                    target: trustTarget(),
                    options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                    root: 0,
                    reader: reader,
                    checkpoint: { try context.check() }
                )
                return nil
            } catch let failure as NativeFailure {
                return failure
            } catch {
                return NativeFailure("NATIVE_FAILURE", "unexpected test failure")
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        context.cancel()
        release.signal()
        let failure = await work.value
        XCTAssertEqual(failure?.code, "INTERRUPTED")
        XCTAssertEqual(calls.value, 1)
    }

    func testMainQueueSentinelRunsWhileDetachedAXWorkIsBlocked() async {
        let entered = expectation(description: "detached AX entered")
        let sentinel = expectation(description: "main sentinel")
        let finished = expectation(description: "detached AX finished")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = AXTreeReader<Int>(
            string: { _, attribute in
                if attribute == kAXRoleAttribute {
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 1)
                    return .value("AXWindow")
                }
                return .unavailable
            },
            bool: { _, _ in .unavailable },
            children: { _ in .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )
        let work = Task.detached {
            _ = try? AXTree.readSnapshot(
                target: trustTarget(),
                options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                root: 0,
                reader: reader
            )
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        DispatchQueue.main.async { sentinel.fulfill() }
        await fulfillment(of: [sentinel], timeout: 1)
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
        await work.value
    }

    func testAXTimeoutIsPositiveAndClampedToRemainingBudget() throws {
        var now: UInt64 = 0
        let context = CommandContext(
            timeoutMilliseconds: 3_000,
            clock: NativeClock(
                monotonicNow: { now },
                wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { _ in }
            )
        )
        XCTAssertEqual(try axMessagingTimeout(context: context), Float(2.0))
        now = 2_750_000_000
        XCTAssertEqual(try axMessagingTimeout(context: context), Float(0.25))
        now = context.deadline
        XCTAssertThrowsError(try axMessagingTimeout(context: context)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
        }
    }

    func testLiveAXFailureMappingKeepsPermissionDistinctFromHardFailures() {
        XCTAssertEqual(liveAXFailure(for: .apiDisabled).code, "PERMISSION_DENIED")
        for status in [AXError.cannotComplete, .invalidUIElement, .failure, .success] {
            XCTAssertEqual(liveAXFailure(for: status).code, "NATIVE_FAILURE")
        }
    }

    func testProductionBatchHardTopLevelStatusesNeverCallSuccessfulSingleReader() {
        for status in [AXError.apiDisabled, .invalidUIElement, .cannotComplete, .failure,
                       .noValue, .illegalArgument, .notImplemented, AXError(rawValue: -99999)!] {
            var batches = 0
            var singles = 0
            let element = AXUIElementCreateApplication(42)
            let cache = LiveAXBatchCache(multipleRead: { _, attributes in
                batches += 1
                XCTAssertEqual(attributes, [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
                    kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXEnabledAttribute,
                    kAXFocusedAttribute, kAXSelectedAttribute, kAXPositionAttribute, kAXSizeAttribute])
                return (status, nil)
            }, singleRead: { _, _ in singles += 1; return (.success, "would hide failure" as CFString) })
            let code = status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE"
            let ax = expectedAXDiagnostic(operation: "copyMultipleAttributes", status: status,
                name: testAXName(status), scope: "batchTopLevel")
            let reader = liveAXTreeReader(cache: cache)
            assertBatchFailure(code, ax: ax) { _ = try cache.attribute(element, kAXRoleAttribute) }
            // Optional title .failure must not be degraded after a top-level failure.
            assertBatchFailure(code, ax: ax) { _ = try reader.string(element, kAXTitleAttribute) }
            assertBatchFailure(code, ax: ax) { _ = try reader.bool(element, kAXEnabledAttribute) }
            assertBatchFailure(code, ax: ax) { _ = try reader.bounds(element) }
            XCTAssertEqual(batches, 1)
            XCTAssertEqual(singles, 0, "hard batch \(status) was erased")
            assertBatchFailure(code, ax: ax) { _ = try reader.string(AXUIElementCreateApplication(43), kAXTitleAttribute) }
            XCTAssertEqual(batches, 2, "switching handles must obtain a fresh batch")
            XCTAssertEqual(singles, 0)
        }
    }

    func testProductionBatchMalformedSuccessNeverFallsBack() {
        for values in [nil, ["AXWindow" as CFString] as CFArray,
                       Array(repeating: "extra" as CFString, count: 12) as CFArray] as [CFArray?] {
            var batches = 0
            var singles = 0
            let cache = LiveAXBatchCache(multipleRead: { _, _ in batches += 1; return (.success, values) },
                singleRead: { _, _ in singles += 1; return (.success, "AXWindow" as CFString) })
            let element = AXUIElementCreateApplication(42)
            for _ in 0..<2 {
                assertBatchFailure("NATIVE_FAILURE", ax: expectedAXDiagnostic(operation: "copyMultipleAttributes",
                    status: .success, name: "success", scope: "batchTopLevel",
                    reason: values == nil ? "missingValue" : "batchLengthMismatch")) { _ = try liveAXTreeReader(cache: cache).string(element, kAXRoleAttribute) }
            }
            XCTAssertEqual(batches, 1)
            XCTAssertEqual(singles, 0)
        }
    }

    func testOnlyUnsupportedBatchUsesSinglesAndCachesTheDecisionPerElement() throws {
        var batches = 0
        var singles: [String] = []
        let cache = LiveAXBatchCache(multipleRead: { _, _ in batches += 1; return (.attributeUnsupported, nil) },
            singleRead: { _, name in
                singles.append(name)
                return name == kAXEnabledAttribute ? (.success, kCFBooleanTrue) : (.success, "AXButton" as CFString)
            })
        let reader = liveAXTreeReader(cache: cache)
        let first = AXUIElementCreateApplication(42)
        XCTAssertEqual(try reader.string(first, kAXRoleAttribute), .value("AXButton"))
        XCTAssertEqual(try reader.string(first, kAXTitleAttribute), .value("AXButton"))
        XCTAssertEqual(try reader.bool(first, kAXEnabledAttribute), .value(true))
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(singles, [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute])
        XCTAssertEqual(try reader.string(AXUIElementCreateApplication(43), kAXRoleAttribute), .value("AXButton"))
        XCTAssertEqual(batches, 2)
        XCTAssertEqual(singles.count, 4)
    }

    func testCompleteProductionBatchPreservesPayloadsAndScalarAdapters() throws {
        var batches = 0
        var singles = 0
        let values = try batchFixtureValues()
        let cache = LiveAXBatchCache(multipleRead: { _, _ in batches += 1; return (.success, values) },
            singleRead: { _, _ in singles += 1; return (.failure, nil) })
        let reader = liveAXTreeReader(cache: cache)
        let element = AXUIElementCreateApplication(42)
        XCTAssertEqual(try reader.string(element, kAXRoleAttribute), .value("AXWindow"))
        XCTAssertEqual(try reader.string(element, kAXTitleAttribute), .value("Fixture"))
        XCTAssertEqual(try reader.string(element, kAXSubroleAttribute), .unavailable)
        XCTAssertEqual(try reader.bool(element, kAXEnabledAttribute), .value(true))
        XCTAssertEqual(try reader.bool(element, kAXFocusedAttribute), .value(false))
        XCTAssertEqual(try reader.bool(element, kAXSelectedAttribute), .unavailable)
        XCTAssertEqual(try reader.bounds(element), .value(WindowBounds(x: 12, y: 34, width: 56, height: 78)))
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(singles, 0)
        // Requesting an absent entry is not a compatibility fallback from a successful batch.
        assertBatchFailure("NATIVE_FAILURE") { _ = try cache.attribute(element, "not-in-batch") }
        XCTAssertEqual(singles, 0)
    }

    func testValidPerEntryAndUnsupportedSingleScalarPoliciesRemainLocal() throws {
        for useBatch in [true, false] {
            for status in [AXError.noValue, .attributeUnsupported, .failure, .apiDisabled,
                           .invalidUIElement, .cannotComplete, .illegalArgument, .notImplemented, AXError(rawValue: -99999)!] {
                var singles = 0
                var encoded = status
                let error = try XCTUnwrap(AXValueCreate(.axError, &encoded))
                let values = try batchFixtureValues(title: error)
                let cache = LiveAXBatchCache(multipleRead: { _, _ in
                    useBatch ? (.success, values) : (.attributeUnsupported, nil)
                }, singleRead: { _, _ in singles += 1; return (status, nil) })
                let reader = liveAXTreeReader(cache: cache)
                let element = AXUIElementCreateApplication(42)
                if [.noValue, .attributeUnsupported, .failure].contains(status) {
                    XCTAssertEqual(try reader.string(element, kAXTitleAttribute), .unavailable)
                } else {
                    assertBatchFailure(status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE",
                        ax: expectedAXDiagnostic(operation: useBatch ? "copyMultipleAttributes" : "copyAttribute",
                            attribute: "AXTitle", status: status, name: testAXName(status),
                            scope: useBatch ? "batchEntry" : "direct")) {
                        _ = try reader.string(element, kAXTitleAttribute)
                    }
                }
                XCTAssertEqual(try cache.attribute(element, kAXTitleAttribute).status, status)
                XCTAssertEqual(singles, useBatch ? 0 : 2)
            }
        }
        var failure = AXError.failure
        let values = try batchFixtureValues(role: XCTUnwrap(AXValueCreate(.axError, &failure)))
        let cache = LiveAXBatchCache(multipleRead: { _, _ in (.success, values) },
                                    singleRead: { _, _ in XCTFail("no single"); return (.success, "AXWindow" as CFString) })
        assertBatchFailure("NATIVE_FAILURE", ax: expectedAXDiagnostic(operation: "copyMultipleAttributes",
            attribute: "AXRole", status: .failure, name: "failure", scope: "batchEntry")) {
            _ = try liveAXTreeReader(cache: cache).string(AXUIElementCreateApplication(42), kAXRoleAttribute)
        }
        // Malformed descriptive scalar compatibility is unchanged, but Boolean preparation isn't a scalar read.
        let malformed = LiveAXBatchCache(multipleRead: { _, _ in
            (.success, try! batchFixtureValues(title: kCFBooleanTrue))
        })
        XCTAssertEqual(try liveAXTreeReader(cache: malformed).string(AXUIElementCreateApplication(42), kAXTitleAttribute), .unavailable)
    }

    func testProductionBoundsDiagnosticsRetainReadOrderAndUnavailableControls() throws {
        let element = AXUIElementCreateApplication(42)
        var point = CGPoint(x: 12, y: 34)
        var size = CGSize(width: 56, height: 78)
        let position = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let dimensions = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        for useBatch in [false, true] {
            for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
                let cases: [(AXError, CFTypeRef?, String)] = [(.cannotComplete, nil, "statusFailure"),
                    (.apiDisabled, nil, "statusFailure"), (.failure, nil, "statusFailure"),
                    (.success, nil, "missingValue"), (.success, "PRIVATE-URL" as CFString, "unexpectedType"),
                    (.success, attribute == kAXPositionAttribute ? dimensions : position, "invalidBoundsRepresentation")]
                for (status, value, reason) in cases {
                    var names: [String] = []
                    let cache = LiveAXBatchCache(multipleRead: { _, attributes in
                        if !useBatch { return (.attributeUnsupported, nil) }
                        var raw = status
                        let replacement = value ?? AXValueCreate(.axError, &raw)!
                        return (.success, attributes.map { name -> CFTypeRef in
                            if name == attribute { return replacement }
                            if name == kAXPositionAttribute { return position }
                            if name == kAXSizeAttribute { return dimensions }
                            return kCFNull
                        } as CFArray)
                    }, singleRead: { _, name in
                        names.append(name)
                        if name == attribute { return (status, value) }
                        return (.success, name == kAXPositionAttribute ? position : dimensions)
                    })
                    XCTAssertThrowsError(try liveAXTreeReader(cache: cache).bounds(element)) {
                        assertAXDiagnostic($0, operation: useBatch ? "copyMultipleAttributes" : "copyAttribute",
                            attribute: attribute, status: status, name: testAXName(status),
                            scope: useBatch ? "batchEntry" : "direct", reason: reason)
                    }
                    XCTAssertEqual(names, useBatch ? [] : [kAXPositionAttribute, kAXSizeAttribute])
                }
                for status in [AXError.noValue, .attributeUnsupported] {
                    let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.attributeUnsupported, nil) },
                        singleRead: { _, name in name == attribute ? (status, nil) : (.success, name == kAXPositionAttribute ? position : dimensions) }))
                    XCTAssertEqual(try reader.bounds(element), .unavailable)
                }
            }
        }
        // Both raw reads happen before classification; position failure retains precedence.
        let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.attributeUnsupported, nil) },
            singleRead: { _, name in (name == kAXPositionAttribute ? .cannotComplete : .apiDisabled, nil) }))
        XCTAssertThrowsError(try reader.bounds(element)) {
            assertAXDiagnostic($0, operation: "copyAttribute", attribute: "AXPosition", status: .cannotComplete, name: "cannotComplete")
        }
    }

    func testPureDecodersReportActualSuccessRatherThanCompatibilityFailure() throws {
        var point = CGPoint.zero
        var size = CGSize.zero
        let position = LiveAXAttributeRead(status: .success, value: try XCTUnwrap(AXValueCreate(.cgPoint, &point)), actualStatus: .success)
        let dimensions = LiveAXAttributeRead(status: .success, value: try XCTUnwrap(AXValueCreate(.cgSize, &size)), actualStatus: .success)
        for failPoint in [true, false] {
            XCTAssertThrowsError(try decodeLiveAXBounds(positionRead: position, sizeRead: dimensions,
                decodePoint: { _ in failPoint ? nil : .zero }, decodeSize: { _ in nil })) {
                assertAXDiagnostic($0, operation: "copyAttribute", attribute: failPoint ? "AXPosition" : "AXSize",
                                   status: .success, name: "success", reason: "decodeFailure")
            }
        }
        var raw = AXError.cannotComplete
        let entries = try XCTUnwrap(unpackMultipleAXAttributes(attributes: [kAXRoleAttribute, kAXTitleAttribute], status: .success,
            values: [try XCTUnwrap(AXValueCreate(.axError, &raw)), kCFNull!] as CFArray, decodeError: { _ in nil }))
        let read = try XCTUnwrap(entries[kAXRoleAttribute])
        XCTAssertEqual(read.status, .failure) // compatibility policy, NOT the actual AX status
        XCTAssertEqual(read.actualStatus, .success)
        XCTAssertEqual(entries[kAXTitleAttribute]?.actualStatus, .success) // CFNull isn't an AX noValue result
        let result: AXReadResult<String> = axScalarReadResult(attribute: kAXRoleAttribute, status: read.status,
            value: read.value, expectedTypeID: CFStringGetTypeID(), decode: { _ in nil })
        XCTAssertThrowsError(try classifyLiveAXResult(status: read.actualStatus, result: result,
            diagnostic: read.diagnostic(kAXRoleAttribute), reason: read.reason(expectedTypeID: CFStringGetTypeID()))) {
            assertAXDiagnostic($0, operation: "copyMultipleAttributes", attribute: "AXRole", status: .success,
                               name: "success", scope: "batchEntry", reason: "decodeFailure")
        }
        let optional: AXReadResult<String> = axScalarReadResult(attribute: kAXTitleAttribute, status: read.status,
            value: read.value, expectedTypeID: CFStringGetTypeID(), decode: { _ in nil })
        XCTAssertEqual(optional, .unavailable, "undecodable entry retains descriptive failure degradation")
        let scalar: AXReadResult<String> = axScalarReadResult(attribute: kAXRoleAttribute, status: .success,
            value: "PRIVATE-title" as CFString, expectedTypeID: CFStringGetTypeID(), decode: { _ in nil })
        XCTAssertThrowsError(try classifyLiveAXResult(status: .success, result: scalar,
            diagnostic: AXDiagnosticContext(phase: .observation, operation: .copyAttribute, attribute: kAXRoleAttribute),
            reason: axReadFailureReason(status: .success, value: "PRIVATE-title" as CFString, expectedTypeID: CFStringGetTypeID()))) {
            assertAXDiagnostic($0, operation: "copyAttribute", attribute: kAXRoleAttribute, status: .success,
                               name: "success", reason: "decodeFailure")
        }
        let diagnostic = AXDiagnosticContext(phase: .observation, operation: .copyActionNames)
        XCTAssertThrowsError(try classifyLiveAXArrayResult(status: .success, value: ["PRIVATE-value"] as CFArray,
            expectedElementTypeID: CFStringGetTypeID(), diagnostic: diagnostic, decode: { _ -> String? in nil })) {
            assertAXDiagnostic($0, operation: "copyActionNames", status: .success, name: "success", reason: "decodeFailure")
        }
    }

    func testArrayDecoderPreservesFirstConcreteValidationFailure() {
        XCTAssertThrowsError(try classifyLiveAXArrayResult(status: .success,
            value: ["PRIVATE-value" as CFString, NSNumber(value: 2)] as CFArray,
            expectedElementTypeID: CFStringGetTypeID(),
            diagnostic: AXDiagnosticContext(phase: .observation, operation: .copyActionNames),
            decode: { _ -> String? in nil })) {
            assertAXDiagnostic($0, operation: "copyActionNames", status: .success, name: "success", reason: "decodeFailure")
        }
    }

    func testProductionChildrenAndActionsDiagnoseOnlyExistingHardFailures() throws {
        let element = AXUIElementCreateApplication(42)
        for actions in [false, true] {
            for status in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .illegalArgument,
                           AXError(rawValue: -99999)!, .success, .failure, .noValue, .attributeUnsupported] {
                let reader = collectionReader(children: { _, _ in (status, nil) }, actions: { _ in (status, nil) })
                if [.noValue, .attributeUnsupported].contains(status) || (actions && status == .failure) {
                    if actions { XCTAssertEqual(try reader.actions(element), .unavailable) }
                    else { XCTAssertEqual(try reader.children(element), .unavailable) }
                } else {
                    XCTAssertThrowsError(try {
                        if actions { _ = try reader.actions(element) } else { _ = try reader.children(element) }
                    }()) {
                        assertAXDiagnostic($0, operation: actions ? "copyActionNames" : "copyAttribute",
                            attribute: actions ? nil : "AXChildren", status: status, name: testAXName(status),
                            reason: status == .success ? "missingValue" : "statusFailure")
                    }
                }
            }
            let array = actions ? ["PRIVATE-title" as CFString, NSNumber(value: 4)] as CFArray
                                : [element, "PRIVATE-identifier" as CFString] as CFArray
            let reader = collectionReader(children: { _, _ in (.success, array) }, actions: { _ in (.success, array) })
            XCTAssertThrowsError(try {
                if actions { _ = try reader.actions(element) } else { _ = try reader.children(element) }
            }()) {
                assertAXDiagnostic($0, operation: actions ? "copyActionNames" : "copyAttribute",
                    attribute: actions ? nil : "AXChildren", status: .success, name: "success", reason: "invalidArrayElement")
            }
        }
        let wrongChildren = collectionReader(children: { _, _ in (.success, "PRIVATE-url" as CFString) },
                                             actions: { _ in (.success, ["AXPress"] as CFArray) })
        XCTAssertEqual(try wrongChildren.children(element), .unavailable)
        XCTAssertEqual(try wrongChildren.actions(element), .value(["AXPress"]))
        let valid = collectionReader(children: { _, _ in (.success, [element] as CFArray) }, actions: { _ in (.success, [] as CFArray) })
        guard case let .value(children) = try valid.children(element) else { return XCTFail("missing children") }
        XCTAssertEqual(children.count, 1)
        XCTAssertTrue(CFEqual(children[0], element))
        XCTAssertEqual(try valid.actions(element), .value([]))
    }

    func testProductionScalarDiagnosticsAndWrongTypeUnavailablePolicy() throws {
        let element = AXUIElementCreateApplication(42)
        for attribute in [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute] {
            for status in [AXError.cannotComplete, .apiDisabled, .success] {
                let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.attributeUnsupported, nil) },
                    singleRead: { _, _ in (status, nil) }))
                XCTAssertThrowsError(try {
                    if attribute == kAXEnabledAttribute { _ = try reader.bool(element, attribute) }
                    else { _ = try reader.string(element, attribute) }
                }()) {
                    assertAXDiagnostic($0, operation: "copyAttribute", attribute: attribute,
                        status: status, name: testAXName(status), reason: status == .success ? "missingValue" : "statusFailure")
                }
            }
            let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.attributeUnsupported, nil) },
                singleRead: { _, _ in (.success, ["PRIVATE-object"] as CFArray) }))
            if attribute == kAXEnabledAttribute { XCTAssertEqual(try reader.bool(element, attribute), .unavailable) }
            else { XCTAssertEqual(try reader.string(element, attribute), .unavailable) }
        }
        // Encoded success without a value is a malformed batch entry, not an invented failure code.
        var status = AXError.success
        let values = try batchFixtureValues(role: XCTUnwrap(AXValueCreate(.axError, &status)))
        let reader = liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in (.success, values) },
            singleRead: { _, _ in XCTFail("no fallback"); return (.failure, nil) }))
        XCTAssertThrowsError(try reader.string(element, kAXRoleAttribute)) {
            assertAXDiagnostic($0, operation: "copyMultipleAttributes", attribute: "AXRole", status: .success,
                               name: "success", scope: "batchEntry", reason: "missingValue")
        }
    }

    func testUnpackMultipleAXAttributesUnpacksValuesErrorsAndCFNull() throws {
        let attributes = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXIdentifierAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXEnabledAttribute,
            kAXFocusedAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute
        ]

        var noValueError = AXError.noValue
        let noValueAX = try XCTUnwrap(AXValueCreate(.axError, &noValueError))
        var unsupportedError = AXError.attributeUnsupported
        let unsupportedAX = try XCTUnwrap(AXValueCreate(.axError, &unsupportedError))
        var cannotCompleteError = AXError.cannotComplete
        let cannotCompleteAX = try XCTUnwrap(AXValueCreate(.axError, &cannotCompleteError))
        var point = CGPoint(x: 12, y: 34)
        let pointAX = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        var size = CGSize(width: 56, height: 78)
        let sizeAX = try XCTUnwrap(AXValueCreate(.cgSize, &size))

        let values: [AnyObject] = [
            "AXButton" as CFString,
            noValueAX,
            unsupportedAX,
            cannotCompleteAX,
            kCFNull,
            kCFBooleanTrue,
            kCFBooleanFalse,
            pointAX,
            sizeAX
        ]

        let unpacked = try XCTUnwrap(unpackMultipleAXAttributes(
            attributes: attributes,
            status: .success,
            values: values as CFArray
        ))

        XCTAssertEqual(unpacked[kAXRoleAttribute]?.status, .success)
        XCTAssertEqual(unpacked[kAXRoleAttribute]?.value as? String, "AXButton")

        XCTAssertEqual(unpacked[kAXSubroleAttribute]?.status, .noValue)
        XCTAssertNil(unpacked[kAXSubroleAttribute]?.value)

        XCTAssertEqual(unpacked[kAXIdentifierAttribute]?.status, .attributeUnsupported)
        XCTAssertNil(unpacked[kAXIdentifierAttribute]?.value)

        XCTAssertEqual(unpacked[kAXTitleAttribute]?.status, .cannotComplete)
        XCTAssertNil(unpacked[kAXTitleAttribute]?.value)

        XCTAssertEqual(unpacked[kAXDescriptionAttribute]?.status, .noValue)
        XCTAssertNil(unpacked[kAXDescriptionAttribute]?.value)

        XCTAssertEqual(unpacked[kAXEnabledAttribute]?.status, .success)
        XCTAssertEqual(unpacked[kAXEnabledAttribute]?.value as? Bool, true)

        XCTAssertEqual(unpacked[kAXFocusedAttribute]?.status, .success)
        XCTAssertEqual(unpacked[kAXFocusedAttribute]?.value as? Bool, false)

        XCTAssertEqual(unpacked[kAXPositionAttribute]?.status, .success)
        XCTAssertEqual(CFGetTypeID(try XCTUnwrap(unpacked[kAXPositionAttribute]?.value)), AXValueGetTypeID())

        XCTAssertEqual(unpacked[kAXSizeAttribute]?.status, .success)
        XCTAssertEqual(CFGetTypeID(try XCTUnwrap(unpacked[kAXSizeAttribute]?.value)), AXValueGetTypeID())
    }

    func testUnpackMultipleAXAttributesReturnsNilOnTopLevelErrorOrCountMismatch() {
        let attributes = [kAXRoleAttribute, kAXTitleAttribute]
        let validValues = ["AXWindow" as CFString, "Doc" as CFString] as CFArray

        for status in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            XCTAssertNil(unpackMultipleAXAttributes(
                attributes: attributes,
                status: status,
                values: validValues
            ))
        }
        XCTAssertNil(unpackMultipleAXAttributes(
            attributes: attributes,
            status: .success,
            values: nil
        ))
        XCTAssertNil(unpackMultipleAXAttributes(
            attributes: attributes,
            status: .success,
            values: ["AXWindow" as CFString] as CFArray
        ))
    }

    func testUnpackedScalarReadResultsPreserveFailureAndUnavailableSemantics() throws {
        let attributes = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute
        ]

        var failureError = AXError.failure
        let failureAX = try XCTUnwrap(AXValueCreate(.axError, &failureError))
        var cannotCompleteError = AXError.cannotComplete
        let cannotCompleteAX = try XCTUnwrap(AXValueCreate(.axError, &cannotCompleteError))
        var apiDisabledError = AXError.apiDisabled
        let apiDisabledAX = try XCTUnwrap(AXValueCreate(.axError, &apiDisabledError))
        var invalidElementError = AXError.invalidUIElement
        let invalidElementAX = try XCTUnwrap(AXValueCreate(.axError, &invalidElementError))

        let values: [AnyObject] = [
            failureAX,
            failureAX,
            cannotCompleteAX,
            apiDisabledAX,
            invalidElementAX
        ]

        let unpacked = try XCTUnwrap(unpackMultipleAXAttributes(
            attributes: attributes,
            status: .success,
            values: values as CFArray
        ))

        func classifyString(_ attr: String) throws -> AXReadResult<String> {
            let read = try XCTUnwrap(unpacked[attr])
            return axScalarReadResult(
                attribute: attr,
                status: read.status,
                value: read.value,
                expectedTypeID: CFStringGetTypeID(),
                decode: { $0 as? String }
            )
        }

        XCTAssertEqual(try classifyString(kAXRoleAttribute), .failure)
        XCTAssertEqual(try classifyString(kAXSubroleAttribute), .unavailable)
        XCTAssertEqual(try classifyString(kAXTitleAttribute), .failure)
        XCTAssertEqual(try classifyString(kAXDescriptionAttribute), .failure)
        XCTAssertEqual(try classifyString(kAXValueAttribute), .failure)
    }
}

private let axFailureCases = [
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXIdentifierAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXValueAttribute,
    kAXEnabledAttribute,
    kAXFocusedAttribute,
    kAXSelectedAttribute,
    "children",
    "actions",
    "bounds"
]

private func failingReader(_ failingRead: String) -> AXTreeReader<Int> {
    AXTreeReader(
        string: { _, attribute in
            if failingRead == attribute { return .failure }
            if attribute == kAXRoleAttribute { return .value("AXWindow") }
            return .unavailable
        },
        bool: { _, attribute in failingRead == attribute ? .failure : .unavailable },
        children: { _ in failingRead == "children" ? .failure : .unavailable },
        actions: { _ in failingRead == "actions" ? .failure : .unavailable },
        bounds: { _ in failingRead == "bounds" ? .failure : .unavailable }
    )
}

private final class LockedInt {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() -> Int {
        lock.lock()
        storage += 1
        let result = storage
        lock.unlock()
        return result
    }
}

private func axTestContext() -> CommandContext {
    CommandContext(
        timeoutMilliseconds: 1_000,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
}

private func trustTarget() -> ResolvedTarget {
    ResolvedTarget(
        identity: TargetIdentity(
            pid: 42,
            launchDate: "2026-09-08T10:00:00Z",
            bundleId: "com.example.Editor",
            windowId: 7
        ),
        title: "Document",
        bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400)
    )
}

private func batchFixtureValues(
    role: CFTypeRef = "AXWindow" as CFString, title: CFTypeRef = "Fixture" as CFString
) throws -> CFArray {
    var point = CGPoint(x: 12, y: 34)
    var size = CGSize(width: 56, height: 78)
    return [role, kCFNull!, kCFNull!, title, kCFNull!, kCFNull!, kCFBooleanTrue!,
            kCFBooleanFalse!, kCFNull!, try XCTUnwrap(AXValueCreate(.cgPoint, &point)),
            try XCTUnwrap(AXValueCreate(.cgSize, &size))] as CFArray
}

private func assertBatchFailure(
    _ code: String, ax: JSONValue? = nil, file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> Void
) {
    do { try body(); XCTFail("expected " + code, file: file, line: line) }
    catch let failure as NativeFailure {
        XCTAssertEqual(failure.code, code, file: file, line: line)
        if let ax { XCTAssertEqual(failure.details, ["ax": ax], file: file, line: line) }
    }
    catch { XCTFail("unexpected \(error)", file: file, line: line) }
}

private func collectionReader(children: @escaping LiveAXBatchCache.SingleRead,
                              actions: @escaping (AXUIElement) -> (status: AXError, names: CFArray?)) -> AXTreeReader<AXUIElement> {
    liveAXTreeReader(cache: LiveAXBatchCache(multipleRead: { _, _ in XCTFail("no batch"); return (.failure, nil) },
        singleRead: { _, _ in XCTFail("no scalar"); return (.failure, nil) }),
        readChildrenAttribute: children, copyActionNames: actions)
}
