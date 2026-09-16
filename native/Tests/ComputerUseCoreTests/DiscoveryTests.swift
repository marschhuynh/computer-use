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

    // MARK: - windows

    func testWindowsListPreservesEveryCandidateWithReason() async throws {
        // One on-screen eligible window + one minimized + one off-screen.
        let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
        let windows = [
            TargetWindow(
                ax: AXWindowMetadata(role: "AXWindow", title: "Visible", bounds: bounds, minimized: false),
                cg: CGWindowMetadata(id: 7, title: "Visible", bounds: bounds, onScreen: true, minimized: false)
            ),
            TargetWindow(
                ax: AXWindowMetadata(role: "AXWindow", title: "Minimized", bounds: bounds, minimized: true),
                cg: CGWindowMetadata(id: 8, title: "Minimized", bounds: bounds, onScreen: true, minimized: true)
            ),
            TargetWindow(
                ax: AXWindowMetadata(role: "AXWindow", title: "Offscreen", bounds: bounds, minimized: false),
                cg: CGWindowMetadata(id: 9, title: "Offscreen", bounds: bounds, onScreen: false, minimized: false)
            ),
        ]
        let service = NativeService(
            targetResolver: TargetResolver(provider: TargetResolverProvider(
                listApplications: { [ProcessMetadata(name: "Editor", pid: 42, launchDate: nil, bundleId: nil)] },
                windowsForPID: { _, _ in windows }
            ))
        )
        let reply = await service.execute(windowsRequest(pid: 42), context: discoveryContext())
        XCTAssertTrue(reply.ok, "expected success, got \(String(describing: reply.error))")
        guard case let .array(listed) = reply.data?["windows"] else {
            return XCTFail("expected windows array, got \(String(describing: reply.data))")
        }
        XCTAssertEqual(listed.count, 3, "no candidate may be dropped")
        let eligible = listed.filter { value in
            guard case let .object(w) = value, case let .bool(e) = w["eligible"] else { return false }
            return e
        }
        XCTAssertEqual(eligible.count, 1)
        // ineligible candidates carry a non-null reason
        let reasons = listed.compactMap { value -> JSONValue? in
            guard case let .object(w) = value else { return nil }
            return w["reason"]
        }
        XCTAssertEqual(reasons.count, 3)
        let nonNullReasons = reasons.filter { $0 != .null }
        XCTAssertEqual(nonNullReasons.count, 2)
    }

    func testWindowsSelectsSingleApplicationWithoutRequiringUniquenessOfWindows() async throws {
        let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
        let windows = (0..<3).map { id in
            TargetWindow(
                ax: AXWindowMetadata(role: "AXWindow", title: "W\(id)", bounds: bounds, minimized: false),
                cg: CGWindowMetadata(id: id + 1, title: "W\(id)", bounds: bounds, onScreen: true, minimized: false)
            )
        }
        let service = NativeService(
            targetResolver: TargetResolver(provider: TargetResolverProvider(
                listApplications: { [ProcessMetadata(name: "Editor", pid: 42, launchDate: nil, bundleId: nil)] },
                windowsForPID: { _, _ in windows }
            ))
        )
        // Multiple eligible windows is fine for listing — it is not AMBIGUOUS.
        let reply = await service.execute(windowsRequest(pid: 42), context: discoveryContext())
        XCTAssertTrue(reply.ok)
    }

    func testWindowsFailsWhenAppSelectionNotUnique() async throws {
        let service = NativeService(
            targetResolver: TargetResolver(provider: TargetResolverProvider(
                listApplications: {
                    [
                        ProcessMetadata(name: "Editor", pid: 42, launchDate: nil, bundleId: nil),
                        ProcessMetadata(name: "Editor", pid: 43, launchDate: nil, bundleId: nil),
                    ]
                },
                windowsForPID: { _, _ in [] }
            ))
        )
        let reply = await service.execute(windowsRequest(app: "Editor"), context: discoveryContext())
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "AMBIGUOUS_TARGET")
    }

    func testWindowsFailsWhenAppNotFound() async throws {
        let service = NativeService(
            targetResolver: TargetResolver(provider: TargetResolverProvider(
                listApplications: { [] },
                windowsForPID: { _, _ in [] }
            ))
        )
        let reply = await service.execute(windowsRequest(pid: 42), context: discoveryContext())
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error?.code, "TARGET_NOT_FOUND")
    }

    // MARK: - helpers

    private func appsRequest() -> WireRequest {
        WireRequest(command: .apps, object: [
            "schemaVersion": 1,
            "command": "apps",
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ])
    }

    private func windowsRequest(pid: Int) -> WireRequest {
        WireRequest(command: .windows, object: [
            "schemaVersion": 1,
            "command": "windows",
            "target": ["pid": pid],
            "options": ["timeoutMs": 1_000, "cursor": "off"],
        ])
    }

    private func windowsRequest(app: String) -> WireRequest {
        WireRequest(command: .windows, object: [
            "schemaVersion": 1,
            "command": "windows",
            "target": ["app": app],
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
