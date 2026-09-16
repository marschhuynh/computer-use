import XCTest
@testable import ComputerUseCore

final class DiscoveryTests: XCTestCase {

    // MARK: - apps

    func testAppsListReturnsAllAppsWithoutResolving() async throws {
        let apps = [
            ProcessMetadata(name: "Editor", pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor"),
            ProcessMetadata(name: "Editor", pid: 43, launchDate: nil, bundleId: "com.example.Editor"),
            ProcessMetadata(name: "NoBundle", pid: 44, launchDate: nil, bundleId: nil),
        ]
        let service = NativeService(
            targetResolver: TargetResolver(provider: TargetResolverProvider(
                listApplications: { apps },
                windowsForPID: { _, _ in [] }
            ))
        )
        let reply = await service.execute(appsRequest(), context: discoveryContext())
        XCTAssertTrue(reply.ok, "expected success, got \(String(describing: reply.error))")
        guard case let .array(listed) = reply.data?["apps"] else {
            return XCTFail("expected apps array, got \(String(describing: reply.data))")
        }
        XCTAssertEqual(listed.count, 3)
        // apps does not resolve a unique target and does not require launch identity:
        // duplicate names and nil launchDate/bundleId are all still listed.
        let names = listed.compactMap { value -> String? in
            guard case let .object(app) = value, case let .string(name) = app["name"] else { return nil }
            return name
        }
        XCTAssertEqual(names, ["Editor", "Editor", "NoBundle"])
        for case let .object(app) in listed {
            XCTAssertNotNil(app["name"])
            XCTAssertNotNil(app["pid"])
            XCTAssertNotNil(app["bundleId"])
        }
    }

    func testAppsDoesNotResolveUniqueTarget() async throws {
        // Two same-named apps must NOT trigger AMBIGUOUS_TARGET — listing enumerates.
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [
                    ProcessMetadata(name: "Editor", pid: 42, launchDate: nil, bundleId: nil),
                    ProcessMetadata(name: "Editor", pid: 43, launchDate: nil, bundleId: nil),
                ]
            },
            windowsForPID: { _, _ in [] }
        ))
        let listed = try await resolver.listApplications(context: discoveryContext())
        XCTAssertEqual(listed.count, 2)
    }

    // MARK: - helpers

    private func appsRequest() -> WireRequest {
        WireRequest(command: .apps, object: [
            "schemaVersion": 1,
            "command": "apps",
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ])
    }
}

func discoveryContext(timeoutMilliseconds: Int = 1_000) -> CommandContext {
    CommandContext(
        timeoutMilliseconds: timeoutMilliseconds,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
}
