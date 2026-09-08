import Foundation
import XCTest
@testable import ComputerUseCore

final class HostLifecycleTests: XCTestCase {
    func testBoundedLineReaderAcceptsOnlyTerminatedInputWithinLimit() {
        var reader = BoundedLineReader(maximumBytes: 5)

        XCTAssertEqual(reader.consume(Data("hello".utf8)), .awaitingInput)
        XCTAssertEqual(reader.consume(Data("\nignored".utf8)), .line(Data("hello".utf8)))
    }

    func testBoundedLineReaderRejectsOverflowWithoutBufferingIt() {
        var reader = BoundedLineReader(maximumBytes: 5)

        XCTAssertEqual(reader.consume(Data("123456".utf8)), .invalid)
        XCTAssertLessThanOrEqual(reader.bufferedByteCount, 5)
    }

    func testBoundedLineReaderRejectsUnterminatedInputAtEOF() {
        var reader = BoundedLineReader(maximumBytes: 5)

        XCTAssertEqual(reader.consume(Data("hello".utf8), endOfFile: true), .invalid)
    }

    func testHostSessionStaysActiveUntilWorkCompletesWithoutWaitingForEOF() throws {
        var finish: ((WireReply) -> Void)?
        var replies = 0
        var shutdowns = 0
        let session = HostSession(
            work: { _, completion in finish = completion },
            onReply: { _ in replies += 1 },
            onShutdown: { shutdowns += 1 }
        )

        session.start()
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(shutdowns, 0)

        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "staged"))
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(shutdowns, 1)
    }

    func testHostSessionCancelsAndShutsDownWhenParentClosesDuringWork() {
        var cancellation: HostCancellation?
        var workCancelled = false
        var replies = 0
        var shutdowns = 0
        let session = HostSession(
            work: { token, _ in
                cancellation = token
                token.onCancel { workCancelled = true }
            },
            onReply: { _ in replies += 1 },
            onShutdown: { shutdowns += 1 }
        )

        session.start()
        session.parentDidClose()

        XCTAssertEqual(cancellation?.isCancelled, true)
        XCTAssertTrue(workCancelled)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(shutdowns, 1)
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
