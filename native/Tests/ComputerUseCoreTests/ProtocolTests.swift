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
