import Foundation
import XCTest
@testable import ComputerUseCore

private final class LockedHostEvents {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

final class HostLifecycleTests: XCTestCase {
    func testBoundedLineReaderAcceptsOnlyTerminatedInputWithinLimit() {
        var reader = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(reader.consume(Data("hello".utf8)), .awaitingInput)
        XCTAssertEqual(
            reader.consume(Data("\nignored".utf8)),
            .line(Data("hello".utf8))
        )
    }

    func testBoundedLineReaderRejectsOverflowWithoutBufferingIt() {
        var reader = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(reader.consume(Data("123456".utf8)), .invalid)
        XCTAssertLessThanOrEqual(reader.bufferedByteCount, 5)
    }

    func testEmptyEOFIsDistinctFromPartialUnterminatedEOF() {
        var empty = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(empty.consume(Data(), endOfFile: true), .emptyEndOfFile)

        var partial = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(
            partial.consume(Data("hello".utf8), endOfFile: true),
            .invalid
        )

        var line = BoundedLineReader(maximumBytes: 16)
        XCTAssertEqual(
            line.consume(Data("hello\n".utf8), endOfFile: true),
            .line(Data("hello".utf8))
        )
    }

    func testNormalCompletionEmitsOneReplyThenShutsDown() throws {
        var finish: ((WireReply) -> Void)?
        var events: [String] = []
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, completion in
                finish = completion
                return Task.detached {}
            },
            onReply: { _ in events.append("reply") },
            onShutdown: { events.append("shutdown") }
        )
        session.start()
        XCTAssertEqual(events, [])
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "first"))
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "duplicate"))
        session.start()
        XCTAssertEqual(events, ["reply", "shutdown"])
    }

    func testParentEOFDuringWorkCancelsAndWaitsForCleanupWithoutReply() throws {
        var finish: ((WireReply) -> Void)?
        var replies = 0
        var events: [String] = []
        let context = CommandContext(timeoutMilliseconds: 1_000)
        context.onCancel { events.append("cancelled") }
        let session = HostSession(
            context: context,
            work: { _, completion in
                events.append("work-start")
                finish = completion
                return Task.detached {}
            },
            onReply: { _ in replies += 1; events.append("reply") },
            onShutdown: { events.append("shutdown") }
        )
        session.start()
        session.parentDidClose()
        session.parentDidClose() // duplicate EOF while cancelling is ignored
        XCTAssertTrue(context.isCancelled)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(events, ["work-start", "cancelled"])

        events.append("lock-released")
        try XCTUnwrap(finish)(.failure(code: "INTERRUPTED", message: "Interrupted"))
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(events, ["work-start", "cancelled", "lock-released", "shutdown"])
    }

    func testReadyParentEOFDoesNotStartWorkOrReply() {
        var workStarts = 0
        var replies = 0
        var shutdowns = 0
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, _ in
                workStarts += 1
                return Task.detached {}
            },
            onReply: { _ in replies += 1 },
            onShutdown: { shutdowns += 1 }
        )
        session.parentDidClose()
        session.start()
        XCTAssertEqual(workStarts, 0)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(shutdowns, 1)
    }

    func testCancellationBeforeReturnedTaskIsOwnedStillCompletesAndShutsDown() async {
        let workEntered = expectation(description: "work factory entered")
        let taskCancelled = expectation(description: "returned task cancelled")
        let operationEntered = expectation(description: "command operation entered")
        let shutdown = expectation(description: "shutdown after completion")
        let allowWorkReturn = DispatchSemaphore(value: 0)
        let allowOperationCompletion = DispatchSemaphore(value: 0)
        defer {
            allowWorkReturn.signal()
            allowOperationCompletion.signal()
        }
        let events = LockedHostEvents()
        var replies = 0
        let context = CommandContext(timeoutMilliseconds: 1_000)
        let session = HostSession(
            context: context,
            work: { context, completion in
                workEntered.fulfill()
                _ = allowWorkReturn.wait(timeout: .now() + 1)
                return Task.detached {
                    await withTaskCancellationHandler(operation: {
                        operationEntered.fulfill()
                        _ = allowOperationCompletion.wait(timeout: .now() + 1)
                        XCTAssertTrue(Task.isCancelled)
                        events.append("operation-finished")
                        completion(.failure(code: "INTERRUPTED", message: "Interrupted"))
                    }, onCancel: {
                        context.cancel()
                        taskCancelled.fulfill()
                    })
                }
            },
            onReply: { _ in replies += 1 },
            onShutdown: {
                events.append("shutdown")
                shutdown.fulfill()
            }
        )

        let starter = Task.detached { session.start() }
        await fulfillment(of: [workEntered], timeout: 1)
        session.parentDidClose()
        XCTAssertTrue(context.isCancelled)
        XCTAssertEqual(events.values, [])

        allowWorkReturn.signal()
        await fulfillment(of: [taskCancelled, operationEntered], timeout: 1)
        allowOperationCompletion.signal()
        await fulfillment(of: [shutdown], timeout: 1)
        await starter.value

        XCTAssertEqual(replies, 0)
        XCTAssertEqual(events.values, ["operation-finished", "shutdown"])
    }

    func testLateParentEOFAndDuplicateCompletionAreIgnored() throws {
        var finish: ((WireReply) -> Void)?
        var replies = 0
        var shutdowns = 0
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, completion in
                finish = completion
                return Task.detached {}
            },
            onReply: { _ in replies += 1 },
            onShutdown: { shutdowns += 1 }
        )
        session.start()
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "done"))
        session.parentDidClose()
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "late"))
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(shutdowns, 1)
    }

    func testMainQueueSentinelRunsWhileSessionWorkerIsActive() async {
        let workerEntered = expectation(description: "worker entered")
        let sentinel = expectation(description: "main sentinel")
        let shutdown = expectation(description: "shutdown")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, completion in
                Task.detached {
                    workerEntered.fulfill()
                    _ = release.wait(timeout: .now() + 1)
                    completion(.failure(code: "UNSUPPORTED_ACTION", message: "done"))
                }
            },
            onReply: { _ in },
            onShutdown: { shutdown.fulfill() }
        )
        session.start()
        await fulfillment(of: [workerEntered], timeout: 1)
        DispatchQueue.main.async { sentinel.fulfill() }
        await fulfillment(of: [sentinel], timeout: 1)
        release.signal()
        await fulfillment(of: [shutdown], timeout: 1)
    }

    func testParentEOFObserverIgnoresDataAndReportsClosure() {
        let pipe = Pipe()
        let closed = expectation(description: "parent closure observed")
        let observer = ParentEOFObserver(fileHandle: pipe.fileHandleForReading) {
            closed.fulfill()
        }
        observer.start()
        pipe.fileHandleForWriting.write(Data("still-open".utf8))
        pipe.fileHandleForWriting.closeFile()
        wait(for: [closed], timeout: 1)
        observer.stop()
    }
}
