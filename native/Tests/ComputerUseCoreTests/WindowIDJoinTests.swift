import ApplicationServices
import XCTest
@testable import ComputerUseCore

/// The AX↔CG join. AX owns semantics (refs, actions, tree); CG owns identity
/// (`CGWindowID`), visibility and pixels. Correlating them by title+bounds is
/// lossy: Chrome appends an audio glyph to `kCGWindowName` while `AXTitle`
/// carries an app/profile suffix, so a playing tab silently matched nothing
/// and `windows` reported an empty list for a visible window. Resolving each
/// AX window's own `CGWindowID` removes the guess.
final class WindowIDJoinTests: XCTestCase {

    // MARK: direct id join

    func testWindowsJoinByResolvedIDIgnoringDecoratedTitles() throws {
        // Verified live on Chrome playing audio: AX and CG disagree on title,
        // bounds agree exactly, and the resolved id is authoritative.
        let joined = try joinWindows(
            axWindows: [
                axCandidate(
                    id: 51732,
                    role: "AXWindow",
                    title: "untitled - Paint - Google Chrome - Test-MCP",
                    bounds: chromeBounds
                )
            ],
            cgWindows: [
                cgWindow(id: 51732, title: "untitled - Paint 🔊", bounds: chromeBounds, onScreen: true)
            ]
        )

        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].cg.id, 51732)
        // The user-visible title is CG's: it is what is drawn on screen.
        XCTAssertEqual(joined[0].cg.title, "untitled - Paint 🔊")
    }

    func testResolvedIDDisambiguatesWindowsSharingExactBounds() throws {
        // Stacked same-size windows are indistinguishable geometrically; the
        // measured title+bounds join produced a 5-way ambiguity here.
        let bounds = WindowBounds(x: 100, y: 100, width: 800, height: 600)
        let joined = try joinWindows(
            axWindows: [
                axCandidate(id: 20, role: "AXWindow", title: "Doc", bounds: bounds),
                axCandidate(id: 21, role: "AXWindow", title: "Doc", bounds: bounds),
            ],
            cgWindows: [
                cgWindow(id: 20, title: "Doc", bounds: bounds, onScreen: true),
                cgWindow(id: 21, title: "Doc", bounds: bounds, onScreen: true),
            ]
        )

        XCTAssertEqual(joined.map(\.cg.id).sorted(), [20, 21])
    }

    func testNonWindowElementsAreFilteredRatherThanFailing() throws {
        // Finder's desktop AXScrollArea legitimately has no window id
        // (kAXErrorIllegalArgument, -25201): it is not a window, not an error.
        let joined = try joinWindows(
            axWindows: [
                axCandidate(id: 480, role: "AXWindow", title: "Quick Look", bounds: chromeBounds),
                AXWindowCandidate(
                    resolvedWindowID: nil,
                    metadata: AXWindowMetadata(role: "AXScrollArea", title: nil, bounds: nil, minimized: nil)
                ),
            ],
            cgWindows: [
                cgWindow(id: 480, title: "Quick Look", bounds: chromeBounds, onScreen: true)
            ]
        )

        XCTAssertEqual(joined.map(\.cg.id), [480])
    }

    func testResolvedIDWithNoMatchingCGEntryIsDropped() throws {
        // An AX window whose id has no CG entry (e.g. on another Space and
        // filtered out) is simply not a candidate here.
        let joined = try joinWindows(
            axWindows: [axCandidate(id: 999, role: "AXWindow", title: "Elsewhere", bounds: chromeBounds)],
            cgWindows: [cgWindow(id: 51732, title: "Here", bounds: chromeBounds, onScreen: true)]
        )

        XCTAssertEqual(joined.count, 0)
    }

    // MARK: fallback when the private symbol is unavailable

    func testFallbackMatchesOnTitleAndBoundsWhenIDIsUnavailable() throws {
        let joined = try joinWindows(
            axWindows: [
                AXWindowCandidate(
                    resolvedWindowID: nil,
                    metadata: AXWindowMetadata(role: "AXWindow", title: "Draft", bounds: chromeBounds, minimized: false)
                )
            ],
            cgWindows: [cgWindow(id: 7, title: "Draft", bounds: chromeBounds, onScreen: true)],
            idResolutionAvailable: false
        )

        XCTAssertEqual(joined.map(\.cg.id), [7])
    }

    func testAmbiguousFallbackMatchFailsRatherThanGuessing() {
        // Measured: pid+bounds correlation returned a *wrong* window id once
        // and was ambiguous 5 times. Guessing is worse than reporting.
        let bounds = WindowBounds(x: 0, y: 0, width: 500, height: 500)
        assertFailure("AMBIGUOUS_TARGET") {
            try joinWindows(
                axWindows: [
                    AXWindowCandidate(
                        resolvedWindowID: nil,
                        metadata: AXWindowMetadata(role: "AXWindow", title: "Doc", bounds: bounds, minimized: false)
                    )
                ],
                cgWindows: [
                    cgWindow(id: 11, title: "Doc", bounds: bounds, onScreen: true),
                    cgWindow(id: 12, title: "Doc", bounds: bounds, onScreen: true),
                ],
                idResolutionAvailable: false
            )
        }
    }

    // MARK: honesty when the join collapses

    func testAXWindowsPresentButNothingJoinedIsReportedNotSilentlyEmpty() {
        // The defect that made this bug expensive to find: `ok:true,
        // windows:[]` is indistinguishable from "this app has no windows".
        assertFailure("NATIVE_FAILURE") {
            try joinWindows(
                axWindows: [
                    axCandidate(id: 51732, role: "AXWindow", title: "Playing", bounds: chromeBounds)
                ],
                cgWindows: [
                    cgWindow(id: 999, title: "Unrelated", bounds: chromeBounds, onScreen: true)
                ],
                strictJoin: true
            )
        }
    }

    func testAnAppWithGenuinelyNoAXWindowsStaysAnEmptyList() throws {
        let joined = try joinWindows(axWindows: [], cgWindows: [], strictJoin: true)
        XCTAssertEqual(joined.count, 0)
    }

    // MARK: re-finding the target window for a snapshot

    // `AXTree.capture` re-finds the window to walk. Selecting it by title
    // compared the *CG* title carried on the target against the window's
    // *AX* title, which for Chrome can never match, so a resolvable window
    // failed as STALE_SNAPSHOT. The resolved id selects it directly.
    func testTargetWindowIsSelectedByResolvedIDNotTitle() throws {
        let selected = try selectTargetWindow(
            candidates: [
                (id: 51732, metadata: AXWindowMetadata(
                    role: "AXWindow",
                    title: "untitled - Paint - Google Chrome - Test-MCP",
                    bounds: chromeBounds,
                    minimized: false
                )),
                (id: 51736, metadata: AXWindowMetadata(
                    role: "AXWindow",
                    title: "other",
                    bounds: chromeBounds,
                    minimized: false
                )),
            ],
            targetWindowID: 51732
        )

        XCTAssertEqual(selected, 0)
    }

    func testMissingTargetWindowIsStale() {
        assertFailure("STALE_SNAPSHOT") {
            try selectTargetWindow(
                candidates: [
                    (id: 4242, metadata: AXWindowMetadata(
                        role: "AXWindow", title: "Draft", bounds: chromeBounds, minimized: false
                    ))
                ],
                targetWindowID: 51732
            )
        }
    }
}

// MARK: - helpers

private let chromeBounds = WindowBounds(x: 0, y: 39, width: 2056, height: 1290)

private func axCandidate(
    id: Int,
    role: String,
    title: String?,
    bounds: WindowBounds
) -> AXWindowCandidate {
    AXWindowCandidate(
        resolvedWindowID: id,
        metadata: AXWindowMetadata(role: role, title: title, bounds: bounds, minimized: false)
    )
}

private func cgWindow(
    id: Int,
    title: String?,
    bounds: WindowBounds,
    onScreen: Bool
) -> CGWindowMetadata {
    CGWindowMetadata(id: id, title: title, bounds: bounds, onScreen: onScreen, minimized: false)
}

private func assertFailure(
    _ code: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: () throws -> Any
) {
    do {
        _ = try work()
        XCTFail("expected \(code)", file: file, line: line)
    } catch let failure as NativeFailure {
        XCTAssertEqual(failure.code, code, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
