import ApplicationServices
import Darwin
import Foundation

/// Resolves an AX window element to its `CGWindowID`.
///
/// ## Why a private symbol
///
/// AX and CG are two separate window registries. AX owns semantics (refs,
/// actions, the element tree) but its handles are opaque, per-process and
/// unprintable — they cannot survive this CLI's one-process-per-command
/// lifetime. CG owns identity (`CGWindowID`), on-screen truth and pixels:
/// ScreenCaptureKit addresses windows *only* by `CGWindowID`, and `--window
/// 51583` has to be a number a later invocation can pass back.
///
/// Apple exposes no public mapping between the two. `AXUIElementGetPid` is the
/// only public identity extractor; `AXWindowNumber`, `_AXWindowNumber` and
/// `AXWindowID` all answer `kAXErrorAttributeUnsupported`, and `AXIdentifier`
/// returns developer strings (`"_NS:6"`, `"FinderWindow"`) that are not unique
/// per window. `SCWindow` is in the same id space as CG but carries no
/// AX-correlatable key.
///
/// So the only correlation available was *guessing* by title and bounds — and
/// that guess is what broke: Chrome appends an audio glyph to `kCGWindowName`
/// while `AXTitle` carries an app/profile suffix, so neither string is a
/// prefix of the other and a visible, playing window matched nothing.
/// Measured on a live desktop, title+bounds correlation was correct for only
/// 18 of 22 windows, was ambiguous for 5, and once produced an outright
/// *wrong* id.
///
/// `_AXUIElementGetWindow` answers directly. Its signature has been stable
/// since Mac OS X 10.5 and it is the unanimous choice of every major macOS
/// window manager (yabai, AeroSpace, Rectangle, Amethyst/Silica, Hammerspoon,
/// Loop). Private-API constraints do not bind here: App Store review does not
/// apply (this ships via npm), notarization does not scan for private symbols,
/// and the Accessibility permission this tool already requires is
/// unobtainable inside a sandbox anyway.
///
/// ## Why `dlsym` rather than `@_silgen_name`
///
/// Link-time binding to a missing symbol kills the process *at load*. For a
/// tool distributed to unknown macOS versions that turns a future symbol
/// removal into "the CLI does not start" instead of "the CLI degrades". The
/// pointer is therefore resolved at runtime, once, and kept optional so the
/// caller can fall back.
public struct WindowIDResolver {
    /// Resolves the window id for an AX element, or nil when the element has
    /// no window (or resolution is unavailable).
    private let resolve: ((AXUIElement) -> CGWindowID?)?

    /// Whether the underlying symbol resolved. When false the caller must
    /// fall back to correlation and treat ambiguity as failure.
    public var isAvailable: Bool { resolve != nil }

    init(resolve: ((AXUIElement) -> CGWindowID?)?) {
        self.resolve = resolve
    }

    public static let live = WindowIDResolver(resolve: liveWindowIDFunction())

    /// Returns the element's `CGWindowID`.
    ///
    /// A non-success status or a zero id means "this element is not a window"
    /// — Finder's desktop `AXScrollArea` answers `kAXErrorIllegalArgument`
    /// (-25201) by design — so callers filter such elements rather than
    /// treating them as errors.
    public func windowID(for element: AXUIElement) -> Int? {
        guard let resolve, let id = resolve(element), id != 0 else { return nil }
        return Int(id)
    }
}

private typealias AXUIElementGetWindowFunction =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Resolves `_AXUIElementGetWindow` out of ApplicationServices at runtime.
/// An explicit `dlopen` of the framework is used rather than `RTLD_DEFAULT`
/// so resolution does not depend on load order elsewhere in the process.
private func liveWindowIDFunction() -> ((AXUIElement) -> CGWindowID?)? {
    let paths = [
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
    ]
    for path in paths {
        guard let handle = dlopen(path, RTLD_LAZY) else { continue }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { continue }
        let function = unsafeBitCast(symbol, to: AXUIElementGetWindowFunction.self)
        return { element in
            var id: CGWindowID = 0
            guard function(element, &id) == .success else { return nil }
            return id
        }
    }
    return nil
}

/// An AX window element paired with the id it resolved to. `resolvedWindowID`
/// is nil when the element is not a window, or when id resolution is
/// unavailable and correlation must be used instead.
public struct AXWindowCandidate: Equatable {
    public let resolvedWindowID: Int?
    public let metadata: AXWindowMetadata

    public init(resolvedWindowID: Int?, metadata: AXWindowMetadata) {
        self.resolvedWindowID = resolvedWindowID
        self.metadata = metadata
    }
}

/// Joins AX window candidates to CG window records.
///
/// Preferred path: match on the resolved `CGWindowID`. Titles and bounds stop
/// being identity, so per-side decoration (CG's audio/recording glyphs, AX's
/// app/profile suffixes) can no longer veto a match.
///
/// Fallback path (`idResolutionAvailable == false`): correlate on role, title
/// and exact bounds as before, but a candidate matching several CG windows is
/// reported as `AMBIGUOUS_TARGET` rather than resolved to a guess — measured
/// correlation produced a wrong id, and a wrong id silently drives input at
/// the wrong window.
///
/// `strictJoin` additionally reports `NATIVE_FAILURE` when AX advertises
/// windows but none of them join, distinguishing "correlation collapsed" from
/// "this application genuinely has no windows". Those two were previously
/// indistinguishable: both surfaced as `ok:true, windows:[]`.
func joinWindows(
    axWindows: [AXWindowCandidate],
    cgWindows: [CGWindowMetadata],
    idResolutionAvailable: Bool = true,
    strictJoin: Bool = false
) throws -> [TargetWindow] {
    let windowsByID = Dictionary(
        cgWindows.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    var joined: [TargetWindow] = []
    var sawWindowElement = false

    for candidate in axWindows {
        let metadata = candidate.metadata
        guard metadata.role == "AXWindow" else { continue }
        sawWindowElement = true

        if idResolutionAvailable {
            // A window element with no id is not addressable; a resolved id
            // with no CG entry is off-screen or filtered out.
            guard let id = candidate.resolvedWindowID, let cg = windowsByID[id] else { continue }
            joined.append(targetWindow(ax: metadata, cg: cg))
            continue
        }

        let matches = cgWindows.filter { correlates(ax: metadata, cg: $0) }
        guard matches.count <= 1 else {
            throw NativeFailure(
                "AMBIGUOUS_TARGET",
                "Window identity could not be resolved unambiguously"
            )
        }
        guard let cg = matches.first else { continue }
        joined.append(targetWindow(ax: metadata, cg: cg))
    }

    if strictJoin, joined.isEmpty, sawWindowElement {
        throw NativeFailure(
            "NATIVE_FAILURE",
            "Window identity could not be resolved for any reported window"
        )
    }
    return joined
}

/// Selects which AX window a snapshot should walk, by resolved `CGWindowID`.
///
/// The previous approach compared the target's title — which is CG's, and so
/// carries CG's decoration — against each window's `AXTitle`, so a window
/// whose two titles differ (any Chrome tab playing audio) could never be
/// re-found and failed as `STALE_SNAPSHOT`. Ids do not have that problem.
///
/// Returns the index of the matching candidate.
func selectTargetWindow(
    candidates: [(id: Int?, metadata: AXWindowMetadata)],
    targetWindowID: Int
) throws -> Int {
    let matches = candidates.indices.filter { index in
        candidates[index].metadata.role == "AXWindow" && candidates[index].id == targetWindowID
    }
    guard matches.count == 1 else {
        throw NativeFailure("STALE_SNAPSHOT", "Selected window identity is no longer unique")
    }
    return matches[0]
}

private func targetWindow(ax: AXWindowMetadata, cg: CGWindowMetadata) -> TargetWindow {
    TargetWindow(
        ax: ax,
        cg: CGWindowMetadata(
            id: cg.id,
            title: cg.title,
            bounds: cg.bounds,
            onScreen: cg.onScreen,
            minimized: ax.minimized == true
        )
    )
}

/// Legacy correlation, retained only for the fallback path.
private func correlates(ax: AXWindowMetadata, cg: CGWindowMetadata) -> Bool {
    guard ax.role == "AXWindow", windowTitlesMatch(ax.title, cg.title), let bounds = ax.bounds else {
        return false
    }
    return bounds == cg.bounds
}
