import XCTest
@testable import ComputerUseCore

final class TargetResolverTests: XCTestCase {
    func testDisplayAndGlobalSelectorsDecode() throws {
        XCTAssertNil(TargetSelector.decode(nil)) // absent target -> caller picks .global/.display
        guard case .display(let idx) = TargetSelector.decode(["display": 2]) else {
            return XCTFail("expected .display")
        }
        XCTAssertEqual(idx, 2)
        // A bare dict with no app/pid/display is not a valid selector.
        XCTAssertNil(TargetSelector.decode(["unexpected": true]))
    }

    func testResolveDisplayProducesSyntheticTarget() async throws {
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: { [] },
            windowsForPID: { _, _ in [] },
            listDisplays: {
                [
                    DisplayMetadata(
                        displayID: 77,
                        frame: WindowBounds(x: 0, y: 0, width: 2056, height: 1329),
                        width: 2056,
                        height: 1329
                    )
                ]
            }
        ))
        let target = try await resolver.resolveDisplay(nil, context: resolverContext())
        XCTAssertTrue(target.isDisplay)
        XCTAssertEqual(target.identity.windowId, 77)
        XCTAssertGreaterThan(target.identity.pid, 0)
        XCTAssertNil(target.identity.bundleId)
        XCTAssertFalse(target.identity.launchDate.isEmpty)
        XCTAssertEqual(target.title, "Display 77")
        XCTAssertEqual(target.bounds, WindowBounds(x: 0, y: 0, width: 2056, height: 1329))
        // geometry: pixel == point at 1x over display bounds
        let geo = CaptureGeometry(
            windowBounds: target.bounds,
            imageSize: CGSize(width: 2056, height: 1329),
            scale: 1
        )
        let point = try geo.imageToScreen(CGPoint(x: 100, y: 50))
        XCTAssertEqual(point, CGPoint(x: 100, y: 50))
    }

    func testResolveDisplayIndexSelectsAndOutOfRangeFails() async throws {
        let displays = {
            [
                DisplayMetadata(
                    displayID: 1,
                    frame: WindowBounds(x: 0, y: 0, width: 100, height: 100),
                    width: 100,
                    height: 100
                ),
                DisplayMetadata(
                    displayID: 2,
                    frame: WindowBounds(x: 100, y: 0, width: 200, height: 100),
                    width: 200,
                    height: 100
                ),
            ]
        }
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: { [] },
            windowsForPID: { _, _ in [] },
            listDisplays: displays
        ))
        // --display is 1-based: 1 selects the first display, 2 the second.
        let second = try await resolver.resolveDisplay(2, context: resolverContext())
        XCTAssertEqual(second.identity.windowId, 2)
        XCTAssertEqual(second.bounds.width, 200)
        await assertResolverFailure("INVALID_ARGUMENT") {
            try await resolver.resolveDisplay(3, context: resolverContext())
        }
        await assertResolverFailure("TARGET_NOT_FOUND") {
            try await TargetResolver(provider: TargetResolverProvider(
                listApplications: { [] },
                windowsForPID: { _, _ in [] },
                listDisplays: { [] }
            )).resolveDisplay(nil, context: resolverContext())
        }
    }

    func testDuplicateAppNamesAreNotSelected() async {
        let resolver = TargetResolver(inventory: .fixture("duplicate-apps"))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.app("Editor", windowId: nil), context: resolverContext())
        }
    }

    func testPidReuseFailsIdentityValidation() async {
        let resolver = TargetResolver(inventory: .fixture("pid-reused"))
        await assertResolverFailure("STALE_SNAPSHOT") {
            try await resolver.validate(
                .init(pid: 42, launchDate: "old", bundleId: "com.example.Editor", windowId: 7),
                context: resolverContext()
            )
        }
    }

    func testMissingWindowRequiresExactlyOneEligibleWindow() async {
        let zero = TargetResolver(inventory: .fixture("zero-eligible-windows"))
        await assertResolverFailure("INELIGIBLE_TARGET") {
            try await zero.resolve(.pid(42, windowId: nil), context: resolverContext())
        }
        let multiple = TargetResolver(inventory: .fixture("multiple-eligible-windows"))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await multiple.resolve(.pid(42, windowId: nil), context: resolverContext())
        }
    }

    func testDuplicateAXToCGCandidatesAreRejected() async {
        let resolver = TargetResolver(inventory: .fixture("duplicate-ax-cg"))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.pid(42, windowId: 7), context: resolverContext())
        }
    }

    func testMinimizedAndOffSpaceWindowsAreIneligible() async {
        for fixture in ["minimized-window", "off-space-window"] {
            let resolver = TargetResolver(inventory: .fixture(fixture))
            await assertResolverFailure("INELIGIBLE_TARGET", message: fixture) {
                try await resolver.resolve(.pid(42, windowId: 7), context: resolverContext())
            }
        }
    }

    func testAmbiguousApplicationDoesNotQueryAXWindows() async {
        let queries = LockedValues<Int>()
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [
                    ProcessMetadata(name: "Editor", pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor"),
                    ProcessMetadata(name: "Editor", pid: 43, launchDate: "2026-09-08T10:00:00.001Z", bundleId: "com.example.Editor")
                ]
            },
            windowsForPID: { pid, _ in
                queries.append(pid)
                XCTFail("window provider must not run for an ambiguous app")
                return []
            },
            listDisplays: { [] }
        ))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.app("Editor", windowId: nil), context: resolverContext())
        }
        XCTAssertEqual(queries.values, [])
    }

    func testExplicitPIDQueriesExactlyThatPID() async throws {
        let queries = LockedValues<Int>()
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [
                    ProcessMetadata(name: "Editor", pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor"),
                    ProcessMetadata(name: "Other", pid: 99, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Other")
                ]
            },
            windowsForPID: { pid, _ in
                queries.append(pid)
                return [resolverWindow(id: 7)]
            },
            listDisplays: { [] }
        ))
        let target = try await resolver.resolve(
            .pid(42, windowId: 7),
            context: resolverContext()
        )
        XCTAssertEqual(queries.values, [42])
        XCTAssertEqual(target.identity.pid, 42)
        XCTAssertEqual(target.identity.windowId, 7)
    }

    func testMillisecondSeparatedSameSecondLaunchesHaveDifferentIdentity() async {
        let first = ProcessLaunchDate.format(Date(timeIntervalSince1970: 1_788_861_900.000))
        let second = ProcessLaunchDate.format(Date(timeIntervalSince1970: 1_788_861_900.001))
        XCTAssertTrue(first.hasSuffix(".000Z"), first)
        XCTAssertTrue(second.hasSuffix(".001Z"), second)
        XCTAssertNotEqual(first, second)

        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [ProcessMetadata(name: "Editor", pid: 42, launchDate: second, bundleId: "com.example.Editor")]
            },
            windowsForPID: { _, _ in [resolverWindow(id: 7)] },
            listDisplays: { [] }
        ))
        await assertResolverFailure("STALE_SNAPSHOT") {
            try await resolver.validate(
                TargetIdentity(pid: 42, launchDate: first, bundleId: "com.example.Editor", windowId: 7),
                context: resolverContext()
            )
        }
    }

    func testMissingLaunchDateRemainsMetadataButCannotBeTargeted() async {
        let queries = LockedValues<Int>()
        let metadata = ProcessMetadata(name: "Editor", pid: 42, launchDate: nil, bundleId: "com.example.Editor")
        XCTAssertNil(metadata.launchDate)
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: { [metadata] },
            windowsForPID: { pid, _ in queries.append(pid); return [] },
            listDisplays: { [] }
        ))
        await assertResolverFailure("TARGET_NOT_FOUND") {
            try await resolver.resolve(.pid(42, windowId: nil), context: resolverContext())
        }
        XCTAssertEqual(queries.values, [])
    }

    func testPersistedMissingWindowIsStaleButPermissionAndNativeFailuresSurvive() async {
        let identity = TargetIdentity(
            pid: 42,
            launchDate: "2026-09-08T10:00:00.000Z",
            bundleId: "com.example.Editor",
            windowId: 7
        )
        let applications = {
            [ProcessMetadata(name: "Editor", pid: 42, launchDate: identity.launchDate, bundleId: identity.bundleId)]
        }
        let missing = TargetResolver(provider: TargetResolverProvider(
            listApplications: applications,
            windowsForPID: { _, _ in [] },
            listDisplays: { [] }
        ))
        await assertResolverFailure("TARGET_NOT_FOUND") {
            try await missing.resolve(.pid(42, windowId: 7), context: resolverContext())
        }
        await assertResolverFailure("STALE_SNAPSHOT") {
            try await missing.validate(identity, context: resolverContext())
        }

        for code in ["PERMISSION_DENIED", "NATIVE_FAILURE"] {
            let resolver = TargetResolver(provider: TargetResolverProvider(
                listApplications: applications,
                windowsForPID: { _, _ in throw NativeFailure(code, "classified provider failure") },
                listDisplays: { [] }
            ))
            await assertResolverFailure(code) {
                try await resolver.validate(identity, context: resolverContext())
            }
        }
    }

    func testResolverUnavailableReadsRemainOptionalButHardFailuresStayClassified() throws {
        let unavailable: AXReadResult<String> = .unavailable
        XCTAssertNil(try resolverOptionalRead(status: .noValue, result: unavailable))

        for (status, code) in [
            (AXError.apiDisabled, "PERMISSION_DENIED"),
            (.cannotComplete, "NATIVE_FAILURE"),
            (.success, "NATIVE_FAILURE")
        ] {
            let failure: AXReadResult<String> = .failure
            XCTAssertThrowsError(try resolverOptionalRead(status: status, result: failure)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, code)
            }
        }
    }

    func testUnavailableAXMetadataCanCoexistWithValidSelectedWindow() async throws {
        let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
        let unsupported = TargetWindow(
            ax: AXWindowMetadata(
                role: nil,
                title: nil,
                bounds: nil,
                minimized: nil
            ),
            cg: CGWindowMetadata(
                id: 8,
                title: nil,
                bounds: bounds,
                onScreen: true,
                minimized: false
            )
        )
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [ProcessMetadata(
                    name: "Editor",
                    pid: 42,
                    launchDate: "2026-09-08T10:00:00.000Z",
                    bundleId: "com.example.Editor"
                )]
            },
            windowsForPID: { _, _ in [unsupported, resolverWindow(id: 7)] },
            listDisplays: { [] }
        ))

        let target = try await resolver.resolve(
            .pid(42, windowId: 7),
            context: resolverContext()
        )
        XCTAssertEqual(target.identity.windowId, 7)
    }


    func testWindowTitlesMatchToleratesCGSuffixStripping() {
        // Chrome-style: CGWindowList strips the app/profile suffix that the app
        // appends to AXTitle. The CG name is a strict prefix of the AX title.
        XCTAssertTrue(windowTitlesMatch(
            "Example Domain - Google Chrome - Test-MCP",
            "Example Domain"
        ))
        XCTAssertTrue(windowTitlesMatch(
            "Example Domain",
            "Example Domain - Google Chrome - Test-MCP"
        ))
        XCTAssertTrue(windowTitlesMatch("Draft", "Draft"))
        XCTAssertTrue(windowTitlesMatch(nil, nil))

        // Unrelated titles must never match — bounds alone cannot rescue a
        // genuinely different window.
        XCTAssertFalse(windowTitlesMatch("Example Domain", "Untitled"))
        XCTAssertFalse(windowTitlesMatch("Doc A", "Doc B"))
        XCTAssertFalse(windowTitlesMatch("", "Non-empty"))
        XCTAssertFalse(windowTitlesMatch("Title", nil))
        XCTAssertFalse(windowTitlesMatch(nil, "Title"))
    }

    func testEmptyFixtureHandlesAreNotProductionEqual() {
        XCTAssertFalse(liveAXElementsAreIdentical(LiveAXElement(), LiveAXElement()))
    }
}

extension TargetInventory {
    static func fixture(_ name: String) -> TargetInventory {
        let url = Bundle.module.url(forResource: "inventories", withExtension: "json")!
        let fixtures = try! JSONDecoder().decode(
            [String: TargetInventory].self,
            from: Data(contentsOf: url)
        )
        return fixtures[name]!
    }
}

private final class LockedValues<Value> {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func resolverContext() -> CommandContext {
    CommandContext(
        timeoutMilliseconds: 1_000,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
}

private func resolverWindow(id: Int) -> TargetWindow {
    let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
    return TargetWindow(
        ax: AXWindowMetadata(role: "AXWindow", title: "Draft", bounds: bounds, minimized: false),
        cg: CGWindowMetadata(id: id, title: "Draft", bounds: bounds, onScreen: true, minimized: false)
    )
}

private func assertResolverFailure<T>(
    _ code: String,
    message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: () async throws -> T
) async {
    do {
        _ = try await work()
        XCTFail(message.isEmpty ? "expected \(code)" : message, file: file, line: line)
    } catch let failure as NativeFailure {
        XCTAssertEqual(failure.code, code, message, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
