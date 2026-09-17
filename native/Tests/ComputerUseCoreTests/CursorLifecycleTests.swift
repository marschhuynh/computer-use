import CoreGraphics
import XCTest
@testable import ComputerUseCore

final class CursorLifecycleTests: XCTestCase {

    private func context() -> CommandContext { discoveryContext() }

    private final class FakeRenderer: CursorRenderer, InputMarking {
        var calls: [String] = []
        var prepareFails = false
        func markInput() { calls.append("input") }
        func prepare() throws {
            if prepareFails { throw NativeFailure("NATIVE_FAILURE", "overlay init failed") }
            calls.append("prepare")
        }
        func approach(_ point: CGPoint, context: CommandContext) async throws {
            calls.append("approach")
        }
        func pulse() async throws {
            calls.append("pulse")
        }
        func dragAlong(_ points: [CGPoint], context: CommandContext) async throws {
            calls.append("dragAlong")
        }
        func hide() async throws {
            calls.append("hide")
        }
        func teardown() async throws {
            calls.append("teardown")
        }
    }

    func testClickTimelineOrdersPrepareApproachPulseInputHideTeardown() async throws {
        let renderer = FakeRenderer()
        var inputDispatched = false
        let timeline = ActionTimeline(renderer: renderer)
        try await timeline.spatialAction(
            at: CGPoint(x: 10, y: 20), kind: .click, context: context()
        ) { _ in inputDispatched = true }
        XCTAssertTrue(inputDispatched)
        XCTAssertEqual(renderer.calls, ["prepare", "approach", "pulse", "input", "hide", "teardown"])
    }

    func testPreparationFailurePreventsInput() async throws {
        let renderer = FakeRenderer()
        renderer.prepareFails = true
        var inputDispatched = false
        let timeline = ActionTimeline(renderer: renderer)
        await XCTAssertThrowsErrorAsync({
            try await timeline.spatialAction(at: .zero, kind: .click, context: context()) { _ in
                inputDispatched = true
            }
        })
        XCTAssertFalse(inputDispatched, "input must not dispatch if cursor prep fails")
        XCTAssertEqual(renderer.calls.last, "teardown", "teardown still runs on prep failure")
    }

    func testTeardownRunsOnInputFailure() async throws {
        let renderer = FakeRenderer()
        let timeline = ActionTimeline(renderer: renderer)
        await XCTAssertThrowsErrorAsync({
            try await timeline.spatialAction(at: .zero, kind: .click, context: context()) { _ in
                throw NativeFailure("NATIVE_FAILURE", "input failed")
            }
        })
        XCTAssertEqual(renderer.calls.last, "teardown")
        XCTAssertTrue(renderer.calls.contains("hide"))
    }

    func testElementActionWithoutGeometryReportsNoVisualization() async throws {
        let renderer = FakeRenderer()
        let timeline = ActionTimeline(renderer: renderer)
        // press on a validated element that has no geometry: feedback is skipped,
        // but the action still runs (no coordinate fallback is fabricated).
        var inputDispatched = false
        let viz = try await timeline.elementAction(
            at: nil, context: context()
        ) { _ in inputDispatched = true }
        XCTAssertTrue(inputDispatched)
        XCTAssertEqual(viz, .none)
    }

    func testElementActionWithGeometryShowsApproach() async throws {
        let renderer = FakeRenderer()
        let timeline = ActionTimeline(renderer: renderer)
        let viz = try await timeline.elementAction(
            at: CGPoint(x: 5, y: 5), context: context()
        ) { _ in }
        XCTAssertEqual(viz, .approach)
        XCTAssertTrue(renderer.calls.contains("approach"))
    }
}
