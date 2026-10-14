import Darwin
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

    func testComposedMetadataPreservesExplicitRegularFlagAcrossStartSources() {
        let date = Date(timeIntervalSince1970: 1_788_861_900.088618)
        for regular in [false, true] {
            for source in ["appkit", "kernel", "missing"] {
                let calls = LockedValues<Int>()
                let metadata = ProcessMetadata(name: "Editor", pid: 42,
                    appKitLaunchDate: source == "appkit" ? date : nil,
                    bundleId: "com.example.Editor", isRegularApp: regular, kernelStartLookup: { pid in
                        calls.append(pid)
                        return source == "missing" ? nil : KernelProcessStart.lookup(pid: pid, query: kernelQuery())
                    })
                XCTAssertEqual(metadata.isRegularApp, regular, source)
                XCTAssertEqual(calls.values, source == "appkit" ? [] : [42])
                XCTAssertEqual(metadata.launchDate, source == "missing" ? nil : ProcessLaunchDate.format(date))
            }
        }
    }

    func testKernelBackedNameCollisionKeepsHelpersOutOfRegularTieBreak() async throws {
        for includeRegular in [true, false] {
            let apps = [42, 43, 99].filter { includeRegular || $0 != 99 }.map { pid in
                ProcessMetadata(name: "Editor", pid: pid, appKitLaunchDate: nil,
                    bundleId: "com.example.\(pid)", isRegularApp: pid == 99,
                    kernelStartLookup: { requested in
                        KernelProcessStart.lookup(pid: requested, query: kernelQuery(returnedPID: pid_t(requested)))
                    })
            }
            let queries = LockedValues<Int>()
            let resolver = TargetResolver(provider: TargetResolverProvider(
                listApplications: { apps },
                windowsForPID: { pid, _ in queries.append(pid); return [resolverWindow(id: 7)] }, listDisplays: { [] }))
            if includeRegular {
                let target = try await resolver.resolve(.app("Editor", windowId: nil), context: resolverContext())
                let application = try await resolver.windowsApplication(.app("Editor", windowId: nil), context: resolverContext())
                XCTAssertEqual(target.identity.pid, 99)
                XCTAssertEqual(application.pid, 99)
                XCTAssertEqual(queries.values, [99])
            } else {
                await assertResolverFailure("AMBIGUOUS_TARGET") {
                    try await resolver.resolve(.app("Editor", windowId: nil), context: resolverContext())
                }
                XCTAssertEqual(queries.values, [])
            }
        }
    }

    func testLiveKernelMetadataCallerRetainsActivationPolicy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ComputerUseCore/TargetResolver.swift"), encoding: .utf8)
        let caller = try XCTUnwrap(source.range(of: "private func liveProcessMetadata()"))
        let body = source[caller.lowerBound...]
        XCTAssertTrue(body.contains("appKitLaunchDate: application.launchDate"))
        XCTAssertTrue(body.contains("isRegularApp: application.activationPolicy == .regular"))
        XCTAssertTrue(body.contains("kernelStartLookup: { KernelProcessStart.lookup(pid: $0) }"))
    }

    func testKernelStartSuccessAndMicrosecondBoundaries() throws {
        for microseconds in [88_618, 0, 999_999] {
            let queries = LockedValues<Int>()
            let query: KernelProcessStart.Query = { pid, process, size in
                queries.append(Int(pid))
                XCTAssertEqual(size, MemoryLayout<kinfo_proc>.size)
                return kernelQuery(microseconds: microseconds)(pid, &process, &size)
            }
            let expected = Date(timeIntervalSince1970: 1_788_861_900 + Double(microseconds) / 1_000_000)
            let first = try XCTUnwrap(KernelProcessStart.lookup(pid: 42, query: query))
            XCTAssertEqual(first.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
            XCTAssertEqual(ProcessLaunchDate.format(first), ProcessLaunchDate.format(expected))
            XCTAssertEqual(KernelProcessStart.lookup(pid: 42, query: query).map(ProcessLaunchDate.format), ProcessLaunchDate.format(first))
            XCTAssertEqual(queries.values, [42, 42])
        }
    }

    func testKernelStartRejectsMalformedRecordsAndInvalidRequests() {
        for (label, query) in invalidKernelQueries() {
            XCTAssertNil(KernelProcessStart.lookup(pid: 42, query: query), label)
        }
        let calls = LockedValues<Int>()
        for pid in [0, -1, Int.max] {
            XCTAssertNil(KernelProcessStart.lookup(pid: pid, query: { pid, _, _ in
                calls.append(Int(pid))
                return 0
            }))
        }
        XCTAssertEqual(calls.values, [])
    }

    func testMetadataPrefersAppKitAndFallsBackThroughRawQuery() {
        let date = Date(timeIntervalSince1970: 1_788_861_900.088618)
        let calls = LockedValues<Int>()
        let preferred = ProcessMetadata(name: "Editor", pid: 42, appKitLaunchDate: date,
                                        bundleId: "com.example.Editor", kernelStartLookup: {
            calls.append($0)
            return date.addingTimeInterval(1)
        })
        XCTAssertEqual(preferred, ProcessMetadata(name: "Editor", pid: 42,
                                                 launchDate: ProcessLaunchDate.format(date), bundleId: "com.example.Editor"))
        XCTAssertEqual(calls.values, [])
        let fallback = fallbackMetadata(query: { pid, process, size in
            calls.append(Int(pid))
            return kernelQuery()(pid, &process, &size)
        })
        XCTAssertEqual(fallback, preferred)
        XCTAssertEqual(calls.values, [42])
        XCTAssertNil(fallbackMetadata(query: kernelQuery(status: -1)).launchDate)
    }

    func testKernelBackedResolutionAndExactPersistedIdentity() async throws {
        let calls = LockedValues<Int>()
        let resolver = fallbackResolver(windowCalls: calls)
        let expected = TargetIdentity(pid: 42,
                                      launchDate: ProcessLaunchDate.format(Date(timeIntervalSince1970: 1_788_861_900.088618)),
                                      bundleId: "com.example.Editor", windowId: 7)
        for selector in [TargetSelector.app("Editor", windowId: nil), .pid(42, windowId: 7), .app("Editor", windowId: nil)] {
            let target = try await resolver.resolve(selector, context: resolverContext())
            XCTAssertEqual(target.identity, expected)
        }
        XCTAssertEqual(calls.values, [42, 42, 42])
        let validated = try await fallbackResolver().validate(expected, context: resolverContext())
        XCTAssertEqual(validated.identity, expected)
        for replacement in [
            fallbackResolver(query: kernelQuery(microseconds: 89_618)),
            fallbackResolver(bundleId: "com.example.Other"),
            fallbackResolver(windows: []),
            fallbackResolver(windows: [resolverWindow(id: 8)])
        ] {
            await assertResolverFailure("STALE_SNAPSHOT") {
                try await replacement.validate(expected, context: resolverContext())
            }
        }
    }

    func testMalformedFallbackFailsBeforeWindowsButInventorySurvives() async throws {
        for (label, query) in invalidKernelQueries() {
            let calls = LockedValues<Int>()
            let metadata = fallbackMetadata(query: query)
            XCTAssertNil(metadata.launchDate, label)
            let resolver = fallbackResolver(query: query, windowCalls: calls)
            for selector in [TargetSelector.pid(42, windowId: 7), .app("Editor", windowId: nil)] {
                do {
                    _ = try await resolver.resolve(selector, context: resolverContext())
                    XCTFail("expected missing start: \(label)")
                } catch let failure as NativeFailure {
                    XCTAssertEqual(failure.code, "TARGET_NOT_FOUND", label)
                    XCTAssertEqual(failure.message, "Process start identity is unavailable", label)
                }
            }
            XCTAssertEqual(calls.values, [], label)
            let applications = try await resolver.listApplications(context: resolverContext())
            XCTAssertEqual(applications, [metadata])
            let application = try await resolver.windowsApplication(.pid(42, windowId: nil), context: resolverContext())
            XCTAssertEqual(application, metadata)
            XCTAssertEqual(try resolver.listWindows(for: 42, context: resolverContext()), [resolverWindow(id: 7)])
            XCTAssertEqual(calls.values, [42])
        }
    }

    func testSourceTransitionsRequireExactlyEqualCompleteIdentities() async throws {
        let date = Date(timeIntervalSince1970: 1_788_861_900.088618)
        for initialAppKit in [true, false] {
            let initial = fallbackResolver(appKitDate: initialAppKit ? date : nil)
            let identity = try await initial.resolve(.pid(42, windowId: 7), context: resolverContext()).identity
            let equal = fallbackResolver(appKitDate: initialAppKit ? nil : date)
            let validated = try await equal.validate(identity, context: resolverContext())
            XCTAssertEqual(validated.identity, identity)
            let different = fallbackResolver(appKitDate: initialAppKit ? nil : date.addingTimeInterval(0.001),
                                             query: kernelQuery(microseconds: 89_618))
            await assertResolverFailure("STALE_SNAPSHOT") {
                try await different.validate(identity, context: resolverContext())
            }
            let calls = LockedValues<Int>()
            let unavailable = fallbackResolver(query: kernelQuery(status: -1), windowCalls: calls)
            await assertResolverFailure("STALE_SNAPSHOT") {
                try await unavailable.validate(identity, context: resolverContext())
            }
            XCTAssertEqual(calls.values, [])
        }
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

    func testApplicationSelectionConfinesBothAPIsToExactBundleDomain() async throws {
        let selector = "com.example.Editor"
        func app(_ pid: Int, _ name: String, _ bundle: String, _ regular: Bool) -> ProcessMetadata {
            ProcessMetadata(name: name, pid: pid, launchDate: "2026-09-08T10:00:00.000Z",
                            bundleId: bundle, isRegularApp: regular)
        }
        let helper42 = app(42, "Helper A", selector, false)
        let helper43 = app(43, "Helper B", selector, false)
        let regular42 = app(42, "Editor", selector, true)
        let regular43 = app(43, "Editor", selector, true)
        let outsider = app(99, selector, "com.other.Regular", true)
        let rows: [([ProcessMetadata], Int?, String)] = [
            ([helper42, helper43, outsider], nil, "AMBIGUOUS_TARGET"),
            ([regular42, helper43, outsider], 42, ""),
            ([helper42, outsider], 42, ""),
            ([regular42, regular43, outsider], nil, "AMBIGUOUS_TARGET"),
            ([app(42, selector, "helper.a", false), app(43, selector, "helper.b", false), outsider], 99, ""),
            ([app(42, selector, "other.a", true), outsider], nil, "AMBIGUOUS_TARGET"),
            ([app(42, "Other", "other.a", true)], nil, "TARGET_NOT_FOUND")
        ]
        for (apps, expectedPID, code) in rows {
            let queries = LockedValues<Int>()
            let resolver = TargetResolver(provider: TargetResolverProvider(listApplications: { apps },
                windowsForPID: { pid, _ in queries.append(pid); return [resolverWindow(id: 7)] }, listDisplays: { [] }))
            if let expectedPID {
                let target = try await resolver.resolve(.app(selector, windowId: nil), context: resolverContext())
                let application = try await resolver.windowsApplication(.app(selector, windowId: nil), context: resolverContext())
                XCTAssertEqual(target.identity.pid, expectedPID)
                XCTAssertEqual(application.pid, expectedPID)
                XCTAssertEqual(target.identity.bundleId, apps.first { $0.pid == expectedPID }?.bundleId)
                XCTAssertEqual(application.bundleId, target.identity.bundleId)
                XCTAssertEqual(queries.values, [expectedPID])
            } else {
                await assertResolverFailure(code) {
                    try await resolver.resolve(.app(selector, windowId: nil), context: resolverContext())
                }
                await assertResolverFailure(code) {
                    try await resolver.windowsApplication(.app(selector, windowId: nil), context: resolverContext())
                }
                XCTAssertEqual(queries.values, [], "wrong-bundle windows must not be queried")
            }
        }
        let resolver = TargetResolver(provider: TargetResolverProvider(listApplications: { [helper42, helper43, outsider] },
            windowsForPID: { pid, _ in XCTAssertEqual(pid, 42); return [resolverWindow(id: 7)] }, listDisplays: { [] }))
        let exactPID = try await resolver.resolve(.pid(42, windowId: nil), context: resolverContext())
        let exactApplication = try await resolver.windowsApplication(.pid(42, windowId: nil), context: resolverContext())
        XCTAssertEqual(exactPID.identity.pid, 42)
        XCTAssertEqual(exactApplication, helper42)
    }

    func testRegularAppDisambiguatesHelperProcessesSharingName() async throws {
        let apps = [
            ProcessMetadata(
                name: "Arc",
                pid: 100,
                launchDate: "2026-09-08T10:00:00.000Z",
                bundleId: "company.thebrowser.Browser",
                isRegularApp: true
            ),
            ProcessMetadata(
                name: "Arc",
                pid: 101,
                launchDate: "2026-09-08T10:00:00.001Z",
                bundleId: "company.thebrowser.browser.helper",
                isRegularApp: false
            ),
            ProcessMetadata(
                name: "Arc",
                pid: 102,
                launchDate: "2026-09-08T10:00:00.002Z",
                bundleId: "company.thebrowser.browser.helper.renderer",
                isRegularApp: false
            ),
        ]
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: { apps },
            windowsForPID: { pid, _ in
                XCTAssertEqual(pid, 100)
                return [resolverWindow(id: 7)]
            },
            listDisplays: { [] }
        ))

        let resolved = try await resolver.resolve(.app("Arc", windowId: nil), context: resolverContext())
        XCTAssertEqual(resolved.identity.pid, 100)
        XCTAssertEqual(resolved.identity.windowId, 7)

        let windowsApp = try await resolver.windowsApplication(.app("Arc", windowId: nil), context: resolverContext())
        XCTAssertEqual(windowsApp.pid, 100)
    }

    func testTwoRegularAppsSharingNameStillThrowAmbiguousTarget() async {
        let apps = [
            ProcessMetadata(
                name: "Arc",
                pid: 100,
                launchDate: "2026-09-08T10:00:00.000Z",
                bundleId: "company.thebrowser.Browser",
                isRegularApp: true
            ),
            ProcessMetadata(
                name: "Arc",
                pid: 101,
                launchDate: "2026-09-08T10:00:00.001Z",
                bundleId: "company.thebrowser.BrowserBeta",
                isRegularApp: true
            ),
        ]
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: { apps },
            windowsForPID: { _, _ in [resolverWindow(id: 7)] },
            listDisplays: { [] }
        ))

        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.app("Arc", windowId: nil), context: resolverContext())
        }
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.windowsApplication(.app("Arc", windowId: nil), context: resolverContext())
        }
    }

    func testAXUnknownWindowIsIneligibleAndIgnoredDuringResolution() async throws {
        let bounds = WindowBounds(x: 0, y: 0, width: 800, height: 600)
        let phantomWindow = TargetWindow(
            ax: AXWindowMetadata(
                role: "AXWindow",
                title: "",
                bounds: bounds,
                minimized: false,
                subrole: "AXUnknown"
            ),
            cg: CGWindowMetadata(
                id: 11,
                title: "",
                bounds: bounds,
                onScreen: true,
                minimized: false
            )
        )
        let standardWindow = TargetWindow(
            ax: AXWindowMetadata(
                role: "AXWindow",
                title: "Main Tab — Arc",
                bounds: bounds,
                minimized: false,
                subrole: "AXStandardWindow"
            ),
            cg: CGWindowMetadata(
                id: 12,
                title: "Main Tab — Arc",
                bounds: bounds,
                onScreen: true,
                minimized: false
            )
        )

        XCTAssertFalse(phantomWindow.isEligible)
        XCTAssertEqual(phantomWindow.ineligibilityReason, "nonStandardWindow")
        XCTAssertTrue(standardWindow.isEligible)
        XCTAssertNil(standardWindow.ineligibilityReason)

        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [
                    ProcessMetadata(
                        name: "Arc",
                        pid: 100,
                        launchDate: "2026-09-08T10:00:00.000Z",
                        bundleId: "company.thebrowser.Browser"
                    )
                ]
            },
            windowsForPID: { _, _ in [phantomWindow, standardWindow] },
            listDisplays: { [] }
        ))

        let resolved = try await resolver.resolve(.app("Arc", windowId: nil), context: resolverContext())
        XCTAssertEqual(resolved.identity.windowId, 12)
        XCTAssertEqual(resolved.title, "Main Tab — Arc")
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

private func kernelQuery(
    status: Int32 = 0, length: Int = MemoryLayout<kinfo_proc>.size,
    returnedPID: pid_t = 42, seconds: Int = 1_788_861_900, microseconds: Int = 88_618
) -> KernelProcessStart.Query {
    { _, process, size in
        process = kinfo_proc()
        process.kp_proc.p_pid = returnedPID
        process.kp_proc.p_starttime.tv_sec = seconds
        process.kp_proc.p_starttime.tv_usec = Int32(microseconds)
        size = length
        return status
    }
}

private func invalidKernelQueries() -> [(String, KernelProcessStart.Query)] {
    let size = MemoryLayout<kinfo_proc>.size
    return [
        ("syscall failure", kernelQuery(status: -1)),
        ("empty", kernelQuery(length: 0)),
        ("partial", kernelQuery(length: size - 1)),
        ("oversized", kernelQuery(length: size + 1)),
        ("wrong PID", kernelQuery(returnedPID: 43)),
        ("zero seconds", kernelQuery(seconds: 0)),
        ("negative seconds", kernelQuery(seconds: -1)),
        ("negative microseconds", kernelQuery(microseconds: -1)),
        ("overflow microseconds", kernelQuery(microseconds: 1_000_000))
    ]
}

private func fallbackMetadata(
    appKitDate: Date? = nil, query: KernelProcessStart.Query = kernelQuery(),
    bundleId: String? = "com.example.Editor"
) -> ProcessMetadata {
    ProcessMetadata(name: "Editor", pid: 42, appKitLaunchDate: appKitDate, bundleId: bundleId,
                    kernelStartLookup: { KernelProcessStart.lookup(pid: $0, query: query) })
}

private func fallbackResolver(
    appKitDate: Date? = nil, query: @escaping KernelProcessStart.Query = kernelQuery(),
    bundleId: String? = "com.example.Editor", windows: [TargetWindow] = [resolverWindow(id: 7)],
    windowCalls: LockedValues<Int> = LockedValues<Int>()
) -> TargetResolver {
    TargetResolver(provider: TargetResolverProvider(
        listApplications: { [fallbackMetadata(appKitDate: appKitDate, query: query, bundleId: bundleId)] },
        windowsForPID: { pid, _ in windowCalls.append(pid); return windows },
        listDisplays: { [] }
    ))
}
