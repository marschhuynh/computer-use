import XCTest
@testable import ComputerUseCore

final class ForegroundExecutionTests: XCTestCase {

    private func context() -> CommandContext { discoveryContext() }

    private final class Recorder {
        var actions: [String] = []
        var texts: [String] = []
        var keys: [String] = []
        var scrolls: [(String, Int)] = []
    }

    private final class RecordingDriver: NativeInputDriver {
        let r: Recorder
        init(_ r: Recorder) { self.r = r }
        func performAXAction(_ action: String, on element: LiveAXElement, context: CommandContext) throws {
            r.actions.append(action)
        }
        func postKey(_ chord: String, to pid: Int, context: CommandContext) throws {
            r.keys.append(chord)
        }
        func postText(_ text: String, to pid: Int, context: CommandContext) throws {
            r.texts.append(text)
        }
        func scroll(_ direction: String, amount: Int, at element: LiveAXElement?, context: CommandContext) throws {
            r.scrolls.append((direction, amount))
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
        try await input.key("cmd+s", to: 42, context: context())
        XCTAssertEqual(recorder.keys, ["cmd+s"])
    }

    func testKeyRejectsUnknownKey() async throws {
        let input = NativeInput(driver: RecordingDriver(Recorder()))
        await XCTAssertThrowsErrorAsync({
            try await input.key("cmd+notakey", to: 42, context: context())
        }) { XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_ARGUMENT") }
    }

    func testScrollDirectionalDispatch() async throws {
        let recorder = Recorder()
        let input = NativeInput(driver: RecordingDriver(recorder))
        try await input.scroll(direction: "down", amount: 3, at: nil, context: context())
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
}
