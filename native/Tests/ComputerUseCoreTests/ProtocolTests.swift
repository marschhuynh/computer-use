import XCTest
@testable import ComputerUseCore

final class ProtocolTests: XCTestCase {
    func testSharedProtocolFixturesHaveExpectedValidity() throws {
        for fixture in try protocolFixtures() {
            XCTAssertEqual(WireRequest.decode(fixture.request) != nil, fixture.valid, fixture.name)
        }
    }

    func testUnsupportedValidRequestStagesUntilItsTask() throws {
        let request = try XCTUnwrap(WireRequest.decode([
            "schemaVersion": 1,
            "command": "apps",
            "options": ["timeoutMs": 1, "cursor": "on"]
        ]))
        let reply = NativeService().execute(request)
        XCTAssertEqual(reply.error?.code, "UNSUPPORTED_ACTION")
    }

    func testEveryCommandFormRejectsAnUnexpectedTopLevelKey() {
        for original in validRequestsForEveryCommandForm() {
            XCTAssertNotNil(WireRequest.decode(original), String(describing: original["command"]))
            var request = original
            request["unexpected"] = true
            XCTAssertNil(WireRequest.decode(request), String(describing: original["command"]))
        }
    }

    func testWireFlagsRequireJSONBooleans() throws {
        let options: [String: Any] = ["timeoutMs": 15_000, "cursor": "on"]
        let target: [String: Any] = ["pid": 42]
        let tree: [String: Any] = ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"]
        let cases: [[String: Any]] = [
            ["schemaVersion": 1, "command": "type", "options": options,
             "target": target, "text": "sample", "allowClipboardReplace": 1],
            ["schemaVersion": 1, "command": "screenshot", "options": options,
             "target": target, "output": "/tmp/requested.png", "tree": tree,
             "overwrite": 0, "annotated": false],
            ["schemaVersion": 1, "command": "screenshot", "options": options,
             "target": target, "output": "/tmp/requested.png", "tree": tree,
             "overwrite": false, "annotated": 1]
        ]
        for request in cases {
            XCTAssertNil(WireRequest.decode(data: try JSONSerialization.data(withJSONObject: request)))
        }
    }

    func testWireRequiredKeyAndOutputCannotBeEmpty() throws {
        let options: [String: Any] = ["timeoutMs": 15_000, "cursor": "on"]
        let target: [String: Any] = ["pid": 42]
        let tree: [String: Any] = ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"]
        let cases: [[String: Any]] = [
            ["schemaVersion": 1, "command": "key", "options": options, "target": target, "key": ""],
            ["schemaVersion": 1, "command": "screenshot", "options": options,
             "target": target, "output": "", "tree": tree, "overwrite": false, "annotated": false]
        ]
        for request in cases {
            XCTAssertNil(WireRequest.decode(data: try JSONSerialization.data(withJSONObject: request)))
        }
    }
}

private func validRequestsForEveryCommandForm() -> [[String: Any]] {
    let options: [String: Any] = ["timeoutMs": 1, "cursor": "on"]
    let target: [String: Any] = ["pid": 42]
    let tree: [String: Any] = ["maxDepth": 8, "maxElements": 500, "hintMode": "full"]
    let snapshotID = "123e4567-e89b-42d3-a456-426614174000"
    let captureID = "123e4567-e89b-42d3-a456-426614174001"
    return [
        ["schemaVersion": 1, "command": "doctor", "options": options],
        ["schemaVersion": 1, "command": "apps", "options": options],
        ["schemaVersion": 1, "command": "windows", "target": target, "options": options],
        ["schemaVersion": 1, "command": "snapshot", "target": target, "tree": tree, "options": options],
        ["schemaVersion": 1, "command": "press", "snapshotId": snapshotID, "ref": 1, "options": options],
        ["schemaVersion": 1, "command": "set-value", "snapshotId": snapshotID, "ref": 1, "text": "", "options": options],
        ["schemaVersion": 1, "command": "type", "target": target, "text": "", "allowClipboardReplace": false, "options": options],
        ["schemaVersion": 1, "command": "key", "target": target, "key": "cmd+s", "options": options],
        ["schemaVersion": 1, "command": "scroll", "snapshotId": snapshotID, "ref": 1, "options": options],
        ["schemaVersion": 1, "command": "scroll", "target": target, "direction": "down", "amount": 3, "options": options],
        ["schemaVersion": 1, "command": "screenshot", "target": target, "output": "image.png", "overwrite": false, "annotated": false, "tree": tree, "options": options],
        ["schemaVersion": 1, "command": "click", "captureId": captureID, "point": ["x": 1, "y": 2], "button": "left", "count": 1, "options": options],
        ["schemaVersion": 1, "command": "move", "captureId": captureID, "point": ["x": 1, "y": 2], "options": options],
        ["schemaVersion": 1, "command": "drag", "captureId": captureID, "from": ["x": 1, "y": 2], "to": ["x": 3, "y": 4], "options": options]
    ]
}

private struct ProtocolFixture {
    let name: String
    let valid: Bool
    let request: [String: Any]
}

private func protocolFixtures() throws -> [ProtocolFixture] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contracts/fixtures/native-protocol.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return (object["cases"] as! [[String: Any]]).map {
        ProtocolFixture(name: $0["name"] as! String, valid: $0["valid"] as! Bool, request: $0["request"] as! [String: Any])
    }
}
