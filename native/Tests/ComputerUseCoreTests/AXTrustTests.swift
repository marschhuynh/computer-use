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
