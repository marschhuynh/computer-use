import XCTest
@testable import ComputerUseCore

final class CommandContextTests: XCTestCase {
    func testDeadlineUsesExclusiveUpperBound() throws {
        var now: UInt64 = 1_000
        let context = CommandContext(timeoutMilliseconds: 1, clock: frozenClock { now })
        XCTAssertEqual(context.deadline, 1_001_000)
        XCTAssertNoThrow(try context.check())
        now = 1_001_000
        XCTAssertThrowsError(try context.check()) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
            XCTAssertEqual(($0 as? NativeFailure)?.message, "Desktop operation deadline expired")
        }
    }

    func testExplicitCancellationWinsAtExpiredDeadline() {
        var now: UInt64 = 0
        let cancellation = CommandCancellation()
        let context = CommandContext(
            timeoutMilliseconds: 1,
            clock: frozenClock { now },
            cancellation: cancellation
        )
        cancellation.cancel()
        now = context.deadline
        XCTAssertThrowsError(try context.check()) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
            XCTAssertEqual(($0 as? NativeFailure)?.message, "Interrupted")
        }
    }

    func testWallClockIsIndependentOfMonotonicDeadline() {
        var monotonic: UInt64 = 5
        var wall = Date(timeIntervalSince1970: 100)
        let context = CommandContext(
            timeoutMilliseconds: 1,
            clock: NativeClock(
                monotonicNow: { monotonic },
                wallNow: { wall },
                sleepNanoseconds: { _ in }
            )
        )
        monotonic = 50
        wall = Date(timeIntervalSince1970: 999)
        XCTAssertEqual(context.deadline, 1_000_005)
        XCTAssertEqual(context.wallNow.timeIntervalSince1970, 999)
        XCTAssertEqual(context.remainingNanoseconds, 999_955)
    }

    func testDeadlineArithmeticSaturatesOnOverflow() {
        XCTAssertEqual(CommandContext.deadlineNanoseconds(now: 10, timeoutMilliseconds: Int.max), UInt64.max)
        XCTAssertEqual(
            CommandContext.deadlineNanoseconds(now: UInt64.max - 999_999, timeoutMilliseconds: 1),
            UInt64.max
        )
        XCTAssertEqual(
            CommandContext.deadlineNanoseconds(now: UInt64.max - 1_000_000, timeoutMilliseconds: 1),
            UInt64.max
        )
        XCTAssertEqual(CommandContext.deadlineNanoseconds(now: 7, timeoutMilliseconds: 0), 7)
        XCTAssertEqual(CommandContext.deadlineNanoseconds(now: 7, timeoutMilliseconds: -5), 7)
    }

    func testSleepClampsToRemainingBudget() async throws {
        var slept: UInt64 = 0
        let context = CommandContext(
            timeoutMilliseconds: 5,
            clock: NativeClock(
                monotonicNow: { 100 },
                wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { slept = $0 }
            )
        )
        try await context.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(slept, 5_000_000)
    }

    func testSleepMapsTaskCancellationToSharedInterruption() async {
        let cancellation = CommandCancellation()
        let context = CommandContext(
            timeoutMilliseconds: 5_000,
            clock: NativeClock(
                monotonicNow: { 0 },
                wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { _ in throw CancellationError() }
            ),
            cancellation: cancellation
        )
        await XCTAssertThrowsErrorAsyncLocal({
            try await context.sleep(nanoseconds: 1_000)
        }) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
        }
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testTaskCancellationBridgesIntoSharedToken() async throws {
        let context = CommandContext(timeoutMilliseconds: 5_000, clock: frozenClock { 0 })
        let entered = expectation(description: "cancelled task entered")
        let task = Task.detached {
            entered.fulfill()
            while !Task.isCancelled { await Task.yield() }
            XCTAssertThrowsError(try context.check()) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
            }
            XCTAssertTrue(context.isCancelled)
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        try await task.value
    }

    func testLockWaitUsesBusyOnlyAfterObservedContention() {
        var now: UInt64 = 0
        let context = CommandContext(timeoutMilliseconds: 1, clock: frozenClock { now })
        now = context.deadline
        XCTAssertThrowsError(try context.checkLockWait(observedContention: false)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
        }
        XCTAssertThrowsError(try context.checkLockWait(observedContention: true)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
        }
        context.cancel()
        XCTAssertThrowsError(try context.checkLockWait(observedContention: true)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
        }
    }
}

private func frozenClock(_ monotonicNow: @escaping () -> UInt64) -> NativeClock {
    NativeClock(
        monotonicNow: monotonicNow,
        wallNow: { Date(timeIntervalSince1970: 0) },
        sleepNanoseconds: { _ in }
    )
}

private func XCTAssertThrowsErrorAsyncLocal<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Asynchronous expression did not throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
