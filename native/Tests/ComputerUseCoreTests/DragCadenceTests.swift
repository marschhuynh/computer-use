import CoreGraphics
import XCTest
@testable import ComputerUseCore

/// Runs the shipping synchronous algorithm, but never posts input or sleeps.
/// Shared with CaptureTests so route proof does not substitute a fake algorithm.
final class DragFixture {
    struct Post: Equatable {
        let type: CGEventType
        let point: CGPoint
        let button: Int64
        let time: UInt64
    }
    struct Wait {
        let duration: UInt64
        let time: UInt64
        let previousPostReturn: UInt64
    }
    var now: UInt64 = 0
    var posts: [Post] = []
    var postReturns: [UInt64] = []
    var constructions: [CGEventType] = []
    var waits: [Wait] = []
    var onMake: ((CGEventType, CGPoint) -> Bool)?
    var onPost: ((Post) -> Void)?
    var onWait: ((UInt64) throws -> Void)?
    var onClock: (() -> Void)?
    var forbidClockReads = false
    var clockReads = 0
    var wall = ISO8601DateFormatter().date(from: "2026-09-08T10:00:01Z")!

    var clock: NativeClock {
        NativeClock(monotonicNow: {
            XCTAssertFalse(self.forbidClockReads, "cleanup must not read/check the context")
            self.clockReads += 1
            self.onClock?()
            return self.now
        }, wallNow: { self.wall }, sleepNanoseconds: { _ in
            XCTFail("drag must not use async sleep")
            throw NativeFailure("NATIVE_FAILURE", "unexpected async sleep")
        })
    }

    func context(milliseconds: Int = 2_000) -> CommandContext {
        CommandContext(timeoutMilliseconds: milliseconds, clock: clock)
    }

    var driver: LiveInputDriver {
        LiveInputDriver(dragOperations: DragEventOperations(makeEvent: { type, point in
            self.constructions.append(type)
            if self.onMake?(type, point) == false { return nil }
            // Inert allocation only. Production post/wait closures are never used.
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: point, mouseButton: .left)
            XCTAssertNotNil(event)
            return event
        }, post: { event in
            // Copy fields immediately: the prepared up's location is mutable.
            let post = Post(type: event.type, point: event.location,
                            button: event.getIntegerValueField(.mouseEventButtonNumber), time: self.now)
            self.posts.append(post)
            self.onPost?(post)
            self.postReturns.append(self.now)
        }, waitNanoseconds: { duration in
            self.waits.append(Wait(duration: duration, time: self.now,
                                   previousPostReturn: self.postReturns.last ?? self.now))
            if let onWait = self.onWait { try onWait(duration) }
            else { self.now += duration }
        }))
    }
}

final class DragCadenceTests: XCTestCase {
    func testGeometryAndNominalCadence() throws {
        let origin = CGPoint(x: -30.25, y: 71.125)
        let pairs: [(CGPoint, CGPoint)] = [
            (origin, CGPoint(x: 190.1, y: origin.y)),
            (CGPoint(x: 190.1, y: origin.y), origin),
            (origin, CGPoint(x: origin.x, y: 170.3)),
            (CGPoint(x: origin.x, y: 170.3), origin),
            (origin, CGPoint(x: 190.1, y: -90.7)),
            (CGPoint(x: 190.1, y: -90.7), origin),
            (origin, origin),
        ]
        for (start, end) in pairs {
            let f = DragFixture()
            let context = f.context()
            try f.driver.drag(from: start, to: end, context: context)
            XCTAssertEqual(f.posts.count, 22)
            XCTAssertEqual(f.posts.map(\.type), [.leftMouseDown] + Array(repeating: .leftMouseDragged, count: 20) + [.leftMouseUp])
            XCTAssertTrue(f.posts.allSatisfy { $0.button == 0 })
            XCTAssertEqual(f.posts.first?.point, start)
            for (i, post) in f.posts.dropFirst().prefix(20).enumerated() {
                let t = CGFloat(i + 1) / 20
                XCTAssertEqual(post.point.x, start.x + (end.x - start.x) * t, accuracy: 0.000_000_001)
                XCTAssertEqual(post.point.y, start.y + (end.y - start.y) * t, accuracy: 0.000_000_001)
            }
            XCTAssertEqual(f.posts.dropLast().last?.point, end)
            XCTAssertEqual(f.posts.last?.point, end)
            XCTAssertEqual(f.posts.map(\.time), (0...21).map { UInt64($0) * 15_000_000 })
            XCTAssertEqual(f.now, 315_000_000)
            XCTAssertEqual(f.waits.map(\.duration), Array(repeating: 5_000_000, count: 63))
        }
    }
}

extension DragCadenceTests {
    private var start: CGPoint { CGPoint(x: 10, y: 20) }
    private var end: CGPoint { CGPoint(x: 210, y: 120) }

    private func run(_ f: DragFixture, context: CommandContext, wrapped: Bool = false) throws {
        let driver = f.driver
        if wrapped { try NativeInput(driver: driver).drag(from: start, to: end, context: context) }
        else { try driver.drag(from: start, to: end, context: context) }
    }

    private func assertRelease(_ f: DragFixture, samples: Int, at time: UInt64,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.posts.map(\.type), [.leftMouseDown] + Array(repeating: .leftMouseDragged, count: samples) + [.leftMouseUp], file: file, line: line)
        XCTAssertEqual(f.posts.last?.point, f.posts.dropLast().last?.point, file: file, line: line)
        XCTAssertEqual(f.posts.last?.time, time, file: file, line: line)
    }

    func testPreparationFailuresNeverPostDown() {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let f = DragFixture()
            let context = f.context()
            f.onMake = { made, _ in made != type }
            XCTAssertThrowsError(try run(f, context: context)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "NATIVE_FAILURE")
            }
            XCTAssertEqual(f.constructions, type == .leftMouseDown ? [.leftMouseDown] : [.leftMouseDown, .leftMouseUp])
            XCTAssertTrue(f.posts.isEmpty)
            XCTAssertTrue(f.waits.isEmpty)
        }
    }

    func testMovementConstructionFailureStopsAndReleasesWithoutAllocationOrWait() {
        for wrapped in [false, true] {
            for failedSample in [1, 10, 20] {
                let f = DragFixture()
                let context = f.context()
                var sample = 0
                var fault: (allocations: Int, waits: Int, time: UInt64)?
                f.onMake = { type, _ in
                    if type == .leftMouseDragged { sample += 1 }
                    if type == .leftMouseDragged && sample == failedSample {
                        fault = (f.constructions.count, f.waits.count, f.now)
                        f.forbidClockReads = true
                        return false
                    }
                    return true
                }
                XCTAssertThrowsError(try run(f, context: context, wrapped: wrapped)) {
                    XCTAssertEqual(($0 as? NativeFailure)?.code, "NATIVE_FAILURE")
                }
                XCTAssertEqual(f.constructions.count, fault?.allocations)
                XCTAssertEqual(f.waits.count, fault?.waits)
                assertRelease(f, samples: failedSample - 1, at: fault?.time ?? UInt64.max)
                XCTAssertEqual(f.constructions.filter { $0 == .leftMouseUp }.count, 1)
            }
        }
    }

    private final class WaitFault: Error {}

    func testWaitFailurePreservesPrimaryErrorAndReleasesOnceWithoutContextOrAllocation() {
        for wrapped in [false, true] {
            let f = DragFixture()
            let context = f.context()
            let error = WaitFault()
            var allocations = 0
            var waits = 0
            var faultTime: UInt64 = 0
            f.onWait = { duration in
                if f.posts.count == 11 {
                    allocations = f.constructions.count
                    waits = f.waits.count
                    faultTime = f.now
                    f.forbidClockReads = true
                    throw error
                }
                f.now += duration
            }
            XCTAssertThrowsError(try run(f, context: context, wrapped: wrapped)) {
                XCTAssertTrue(($0 as? WaitFault) === error)
            }
            assertRelease(f, samples: 10, at: faultTime)
            XCTAssertEqual(f.constructions.count, allocations)
            XCTAssertEqual(f.waits.count, waits)
        }
    }
}

extension DragCadenceTests {
    private func assertFailure(_ code: String, _ operation: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, code, file: file, line: line)
            XCTAssertEqual(($0 as? NativeFailure)?.message,
                           code == "INTERRUPTED" ? "Interrupted" : "Desktop operation deadline expired",
                           file: file, line: line)
        }
    }

    func testInitiallyInvalidContextsHaveNoEffectsAndCancellationWins() {
        for (cancelled, expired) in [(true, false), (false, true), (true, true)] {
            let f = DragFixture()
            let context = f.context(milliseconds: expired ? 0 : 2_000)
            if cancelled { context.cancel() }
            assertFailure(cancelled ? "INTERRUPTED" : "TIMEOUT") { try run(f, context: context) }
            XCTAssertTrue(f.constructions.isEmpty)
            XCTAssertTrue(f.posts.isEmpty)
            XCTAssertTrue(f.waits.isEmpty)
        }
    }

    func testInterruptionDuringConstructionCannotSlipANormalPostThrough() {
        for cancelled in [true, false] {
            for construction in [1, 2, 3, 12, 22] { // down, prepared up, samples 1/10/20
                let f = DragFixture()
                let context = f.context()
                f.onMake = { _, _ in
                    if f.constructions.count == construction {
                        if cancelled { context.cancel() } else { f.now = context.deadline }
                    }
                    return true
                }
                assertFailure(cancelled ? "INTERRUPTED" : "TIMEOUT") { try run(f, context: context) }
                if construction <= 2 {
                    XCTAssertTrue(f.posts.isEmpty)
                    XCTAssertTrue(f.waits.isEmpty)
                } else {
                    assertRelease(f, samples: construction - 3, at: f.now)
                    XCTAssertEqual(f.constructions.count, construction)
                }
            }
        }
    }

    func testInterruptionDuringInitialMiddleAndFinalDwellReleasesImmediately() {
        for cancelled in [true, false] {
            for samples in [0, 10, 20] {
                let f = DragFixture()
                let context = f.context()
                var faultWaits = 0
                var faultAllocations = 0
                f.onWait = { duration in
                    f.now += duration
                    if f.posts.count == samples + 1 {
                        faultWaits = f.waits.count
                        faultAllocations = f.constructions.count
                        if cancelled { context.cancel() } else { f.now = context.deadline }
                    }
                }
                assertFailure(cancelled ? "INTERRUPTED" : "TIMEOUT") { try run(f, context: context) }
                assertRelease(f, samples: samples, at: f.now)
                XCTAssertEqual(f.waits.count, faultWaits)
                XCTAssertEqual(f.constructions.count, faultAllocations)
            }
        }
    }

    func testFinalUpPrecheckRejectsCancellationAndClockTriggeredExpiry() {
        for cancelled in [true, false] {
            let f = DragFixture()
            let context = f.context()
            var finalReads = 0
            f.onClock = {
                if f.now == 315_000_000 && f.posts.count == 21 {
                    finalReads += 1
                    // Cancel on the gap measurement, or expire at the final check itself.
                    if cancelled && finalReads == 3 { context.cancel() }
                    if !cancelled && finalReads == 4 { f.now = context.deadline }
                }
            }
            assertFailure(cancelled ? "INTERRUPTED" : "TIMEOUT") { try run(f, context: context) }
            assertRelease(f, samples: 20, at: f.now)
            XCTAssertEqual(f.constructions.count, 22)
            XCTAssertEqual(f.waits.count, 63)
        }
    }

    func testBudgetShorterThanSliceIsNotCompressed() {
        let f = DragFixture()
        let context = f.context(milliseconds: 2)
        assertFailure("TIMEOUT") { try run(f, context: context) }
        XCTAssertEqual(f.waits.map(\.duration), [2_000_000])
        assertRelease(f, samples: 0, at: 2_000_000)
        XCTAssertEqual(f.constructions, [.leftMouseDown, .leftMouseUp])
    }

    func testEarlyReturningWaitsRecomputeGapAndNeverUseAsyncSleep() throws {
        let f = DragFixture()
        let context = f.context()
        f.onWait = { duration in
            if f.waits.count > 1 { f.now += max(1, duration / 2) }
        }
        try run(f, context: context)
        XCTAssertEqual(f.posts.map(\.time), (0...21).map { UInt64($0) * 15_000_000 })
        XCTAssertGreaterThan(f.waits.count, 63)
        XCTAssertEqual(f.waits.prefix(2).map(\.time), [0, 0])
        assertWaitBounds(f, deadline: context.deadline)
    }

    func testLateWaitDoesNotCauseCatchUpBurst() throws {
        let f = DragFixture()
        let context = f.context()
        f.onWait = { duration in f.now += f.waits.count == 1 ? 40_000_000 : duration }
        try run(f, context: context)
        XCTAssertEqual(f.posts.map(\.time), [0] + (0...20).map { 40_000_000 + UInt64($0) * 15_000_000 })
        assertWaitBounds(f, deadline: context.deadline)
    }

    func testConstructionAndPostingOverheadAreNotChargedToNextGap() throws {
        let f = DragFixture()
        let context = f.context()
        f.onMake = { _, _ in f.now += 2_000_000; return true }
        f.onPost = { _ in f.now += 3_000_000 }
        try run(f, context: context)
        XCTAssertEqual(f.posts.count, 22)
        for i in 1..<f.posts.count {
            XCTAssertGreaterThanOrEqual(f.posts[i].time - f.postReturns[i - 1], 15_000_000)
        }
        assertWaitBounds(f, deadline: context.deadline)
    }

    func testNearMaximumMonotonicTimeUsesElapsedArithmetic() {
        let f = DragFixture()
        f.now = UInt64.max - 2_000_000
        let context = f.context()
        assertFailure("TIMEOUT") { try run(f, context: context) }
        XCTAssertEqual(f.waits.map(\.duration), [2_000_000])
        assertRelease(f, samples: 0, at: UInt64.max)
    }

    private func assertWaitBounds(_ f: DragFixture, deadline: UInt64,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for wait in f.waits {
            XCTAssertGreaterThan(wait.duration, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(wait.duration, 5_000_000, file: file, line: line)
            XCTAssertLessThanOrEqual(wait.duration, 15_000_000 - (wait.time - wait.previousPostReturn), file: file, line: line)
            XCTAssertLessThanOrEqual(wait.duration, deadline - wait.time, file: file, line: line)
        }
    }
}
