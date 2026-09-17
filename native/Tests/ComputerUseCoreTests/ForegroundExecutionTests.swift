import XCTest
@testable import ComputerUseCore

final class ForegroundExecutionTests: XCTestCase {

    private func context() -> CommandContext { discoveryContext() }

    private final class Recorder {
        var actions: [String] = []
        var texts: [String] = []
        var pidKeys: [String] = []
        var tapKeys: [String] = []
        var globalKeys: [String] = []
        var usedHIDTap = false
        var scrolls: [(String, Int)] = []
        var failOnDrag = false
        final class Mouse {
            struct Click { let button: String; let count: Int; let point: CGPoint }
            var clicks: [Click] = []
            var moves: [CGPoint] = []
            var events: [String] = []
        }
        var mouse = Mouse()
    }

    private final class RecordingDriver: NativeInputDriver {
        let r: Recorder
        init(_ r: Recorder) { self.r = r }
        func performAXAction(_ action: String, on element: LiveAXElement, context: CommandContext) throws {
            r.actions.append(action)
        }
        func postKey(_ chord: String, to pid: Int, context: CommandContext) throws {
            r.pidKeys.append(chord)
        }
        func postGlobalKey(_ chord: String, context: CommandContext) throws {
            r.globalKeys.append(chord)
            r.usedHIDTap = true
        }
        func postFocusedKey(_ chord: String, context: CommandContext) throws {
            r.tapKeys.append(chord)
            r.usedHIDTap = true
        }
        func postText(_ text: String, to pid: Int, context: CommandContext) throws {
            r.texts.append(text)
        }
        func scroll(_ direction: String, amount: Int, at element: LiveAXElement?, point: CGPoint?, context: CommandContext) throws {
            r.scrolls.append((direction, amount))
        }
        func click(at point: CGPoint, button: String, count: Int, context: CommandContext) throws {
            r.mouse.clicks.append(.init(button: button, count: count, point: point))
        }
        func move(to point: CGPoint, context: CommandContext) throws {
            r.mouse.moves.append(point)
        }
        func drag(from start: CGPoint, to end: CGPoint, context: CommandContext) throws {
            r.mouse.events.append("down")
            if r.failOnDrag {
                r.mouse.events.append("up") // cleanup still releases the button
                throw NativeFailure("NATIVE_FAILURE", "injected drag failure")
            }
            r.mouse.events.append("move")
            r.mouse.events.append("up")
        }
        func releaseHeldInputs() throws {}
    }

    func testPressPerformsAXPress() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.press(LiveAXElement(), context: context())
        XCTAssertEqual(recorder.actions, ["AXPress"])
    }

    func testKeyParsesChordAndPosts() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.key("cmd+s", to: 42, delivery: .process, context: context())
        XCTAssertEqual(recorder.pidKeys, ["cmd+s"])
    }

    func testKeyRejectsUnknownKey() async throws {
        let input = NativeInput(driver: RecordingDriver(Recorder()))
        await XCTAssertThrowsErrorAsync({
            try await input.key("cmd+notakey", to: 42, context: context())
        }) { XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_ARGUMENT") }
    }

    func testKeyFocusedDeliveryPostsToHIDTap() throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try input.key("cmd+s", to: 42, delivery: .focused, context: context())
        XCTAssertEqual(recorder.tapKeys, ["cmd+s"])
        XCTAssertEqual(recorder.pidKeys, [])
    }

    func testGlobalKeyPostsViaHIDTapNotPid() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try input.globalKey("cmd+space", context: context())
        XCTAssertEqual(recorder.globalKeys, ["cmd+space"])
        XCTAssertTrue(recorder.usedHIDTap)   // global path, not postToPid
        XCTAssertTrue(recorder.pidKeys.isEmpty) // pid-scoped path untouched
    }

    func testGlobalKeyRejectsUnknownKey() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        await XCTAssertThrowsErrorAsync({
            try await input.globalKey("cmd+notakey", context: context())
        }) { XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_ARGUMENT") }
        XCTAssertTrue(recorder.globalKeys.isEmpty)
    }

    func testKeyWithoutTargetPostsGlobally() async throws {
        let recorder = Recorder()
        let service = NativeService(
            desktopLock: DesktopLock(rootURL: temporaryStateRoot()),
            input: NativeInput(driver: RecordingDriver(recorder))
        )
        let request = WireRequest(command: .key, object: [
            "schemaVersion": 1,
            "command": "key",
            "key": "cmd+space",
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ])
        let reply = await service.execute(request, context: context())
        XCTAssertTrue(reply.ok, "expected success, got \(String(describing: reply.error))")
        XCTAssertEqual(recorder.globalKeys, ["cmd+space"])
        XCTAssertTrue(recorder.usedHIDTap)
        XCTAssertTrue(recorder.pidKeys.isEmpty, "no target means nothing is posted to a pid")
        guard case let .object(target) = reply.data?["target"],
              case let .string(scope) = target["scope"] else {
            return XCTFail("expected target scope, got \(String(describing: reply.data))")
        }
        XCTAssertEqual(scope, "global")
        XCTAssertEqual(reply.data?["method"], .string("cg-event"))
        XCTAssertEqual(reply.data?["verification"], .string("verified"))
    }

    func testScrollDirectionalDispatch() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.scroll(direction: "down", amount: 3, at: nil, point: nil, context: context())
        XCTAssertEqual(recorder.scrolls.count, 1)
        XCTAssertEqual(recorder.scrolls.first?.0, "down")
        XCTAssertEqual(recorder.scrolls.first?.1, 3)
    }

    func testTypePostsText() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.type("hello", to: 42, context: context())
        XCTAssertEqual(recorder.texts, ["hello"])
    }

    // MARK: - mouse routes (Stage G)

    func testClickEmitsValidatedButtonAndCount() async throws {
        let recorder = Recorder()
        recorder.mouse = .init()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.click(at: CGPoint(x: 10, y: 20), button: "left", count: 1, context: context())
        XCTAssertEqual(recorder.mouse.clicks.count, 1)
        XCTAssertEqual(recorder.mouse.clicks.first?.button, "left")
    }

    func testClickRejectsUnsupportedCombinationBeforeInput() async throws {
        let recorder = Recorder()
        recorder.mouse = .init()
        let input = NativeInput(driver: RecordingDriver(recorder))
        // right button only supports count 1; middle only count 1
        await XCTAssertThrowsErrorAsync({
            try await input.click(at: .zero, button: "right", count: 2, context: context())
        }) { XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_ARGUMENT") }
        await XCTAssertThrowsErrorAsync({
            try await input.click(at: .zero, button: "middle", count: 3, context: context())
        }) { XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_ARGUMENT") }
        XCTAssertTrue(recorder.mouse.clicks.isEmpty, "no input emitted for rejected combos")
    }

    func testMoveEmitsMoveEvent() async throws {
        let recorder = Recorder()
        recorder.mouse = .init()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.move(to: CGPoint(x: 5, y: 6), context: context())
        XCTAssertEqual(recorder.mouse.moves.first?.x, 5)
        XCTAssertEqual(recorder.mouse.moves.first?.y, 6)
    }

    func testDragEmitsDownMoveUpSequence() async throws {
        let recorder = Recorder()
        recorder.mouse = .init()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100), context: context())
        XCTAssertEqual(recorder.mouse.events.first, "down")
        XCTAssertEqual(recorder.mouse.events.last, "up")
    }

    func testDragReleasesButtonOnCancellation() async throws {
        let recorder = Recorder()
        recorder.mouse = .init()
        recorder.failOnDrag = true
        let input = NativeInput(driver: RecordingDriver(recorder))
        await XCTAssertThrowsErrorAsync({
            try await input.drag(from: .zero, to: CGPoint(x: 10, y: 10), context: context())
        })
        // button must be released even though dispatch failed mid-drag
        XCTAssertEqual(recorder.mouse.events.last, "up")
    }
}
