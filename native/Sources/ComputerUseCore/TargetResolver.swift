import AppKit
import ApplicationServices
import Foundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

public enum TargetSelector {
    case app(String, windowId: Int?)
    case pid(Int, windowId: Int?)
    case display(index: Int?)
    case global
}

extension TargetSelector {
    static func decode(_ value: Any?) -> TargetSelector? {
        guard let target = value as? [String: Any] else { return nil }
        let windowID = targetInteger(target["windowId"])
        if let app = target["app"] as? String { return .app(app, windowId: windowID) }
        if let pid = targetInteger(target["pid"]) { return .pid(pid, windowId: windowID) }
        if let display = targetInteger(target["display"]) { return .display(index: display) }
        return nil
    }
}

public struct TargetIdentity: Codable, Equatable {
    public let pid: Int
    public let launchDate: String
    public let bundleId: String?
    public let windowId: Int
}

public struct ResolvedTarget: Codable, Equatable {
    public let identity: TargetIdentity
    public let title: String
    public let bounds: WindowBounds
    /// True for display targets, which carry a synthetic identity (windowId =
    /// displayID, pid = the host's own). Decode defaults to false so capture
    /// records persisted before this field existed still load.
    public let isDisplay: Bool

    public init(identity: TargetIdentity, title: String, bounds: WindowBounds, isDisplay: Bool = false) {
        self.identity = identity
        self.title = title
        self.bounds = bounds
        self.isDisplay = isDisplay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(TargetIdentity.self, forKey: .identity)
        title = try container.decode(String.self, forKey: .title)
        bounds = try container.decode(WindowBounds.self, forKey: .bounds)
        isDisplay = try container.decodeIfPresent(Bool.self, forKey: .isDisplay) ?? false
    }
}

public struct WindowBounds: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct AXWindowMetadata: Codable, Equatable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let bounds: WindowBounds?
    public let minimized: Bool?

    public init(role: String?, title: String?, bounds: WindowBounds?, minimized: Bool?, subrole: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.bounds = bounds
        self.minimized = minimized
    }
}

public struct CGWindowMetadata: Codable, Equatable {
    public let id: Int
    public let title: String?
    public let bounds: WindowBounds
    public let onScreen: Bool
    public let minimized: Bool
}

public struct TargetWindow: Codable, Equatable {
    public let ax: AXWindowMetadata
    public let cg: CGWindowMetadata

    public var isEligible: Bool {
        ineligibilityReason == nil
    }

    public var ineligibilityReason: String? {
        if ax.minimized == true || cg.minimized {
            return "minimized"
        }
        if !cg.onScreen {
            return "offscreen"
        }
        if ax.subrole == "AXUnknown" {
            return "nonStandardWindow"
        }
        return nil
    }
}

public struct TargetApplication: Codable, Equatable {
    public let name: String
    public let pid: Int
    public let launchDate: String?
    public let bundleId: String?
    public let windows: [TargetWindow]
}

public struct TargetInventory: Codable, Equatable {
    public let apps: [TargetApplication]
}

public struct ProcessMetadata: Equatable, Sendable {
    public let name: String
    public let pid: Int
    public let launchDate: String?
    public let bundleId: String?
    public let isRegularApp: Bool

    public init(name: String, pid: Int, launchDate: String?, bundleId: String?, isRegularApp: Bool = true) {
        self.name = name
        self.pid = pid
        self.launchDate = launchDate
        self.bundleId = bundleId
        self.isRegularApp = isRegularApp
    }

    init(
        name: String, pid: Int, appKitLaunchDate: Date?, bundleId: String?,
        isRegularApp: Bool = true, kernelStartLookup: (Int) -> Date?
    ) {
        self.init(
            name: name, pid: pid,
            launchDate: (appKitLaunchDate ?? kernelStartLookup(pid)).map(ProcessLaunchDate.format),
            bundleId: bundleId, isRegularApp: isRegularApp
        )
    }

    init(application: TargetApplication) {
        name = application.name
        pid = application.pid
        launchDate = application.launchDate
        bundleId = application.bundleId
        isRegularApp = true
    }
}

/// SCK-free view of a display for the resolver/test layer. `frame` is in
/// screen points; `width`/`height` are the display's backing pixels.
public struct DisplayMetadata: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let frame: WindowBounds
    public let width: Int
    public let height: Int

    public init(displayID: UInt32, frame: WindowBounds, width: Int, height: Int) {
        self.displayID = displayID
        self.frame = frame
        self.width = width
        self.height = height
    }
}

public struct TargetResolverProvider {
    public let listApplications: () async throws -> [ProcessMetadata]
    public let windowsForPID: (Int, CommandContext) throws -> [TargetWindow]
    public let listDisplays: () async throws -> [DisplayMetadata]

    public init(
        listApplications: @escaping () async throws -> [ProcessMetadata],
        windowsForPID: @escaping (Int, CommandContext) throws -> [TargetWindow],
        listDisplays: @escaping () async throws -> [DisplayMetadata]
    ) {
        self.listApplications = listApplications
        self.windowsForPID = windowsForPID
        self.listDisplays = listDisplays
    }

    public static var live: TargetResolverProvider {
        TargetResolverProvider(
            listApplications: {
                await MainActor.run { liveProcessMetadata() }
            },
            windowsForPID: { pid, context in
                try liveWindows(for: pid, context: context)
            },
            listDisplays: liveDisplays
        )
    }
}

public final class TargetResolver {
    private let provider: TargetResolverProvider

    public init() {
        provider = .live
    }

    public init(inventory: TargetInventory) {
        provider = TargetResolverProvider(
            listApplications: { inventory.apps.map(ProcessMetadata.init(application:)) },
            windowsForPID: { pid, _ in
                inventory.apps.first(where: { $0.pid == pid })?.windows ?? []
            },
            listDisplays: { [] }
        )
    }

    init(provider: TargetResolverProvider) {
        self.provider = provider
    }

    /// Enumerates running applications for the `apps` command. Unlike `resolve`,
    /// this never selects a unique target, never requires launch identity, and
    /// never filters by eligibility — it returns the inventory as observed.
    public func listApplications(context: CommandContext) async throws -> [ProcessMetadata] {
        try context.check()
        let applications = try await provider.listApplications()
        try context.check()
        return applications
    }

    /// Resolves only the *application* for `windows`, then enumerates its windows.
    /// Unlike `resolve`, this does not require launch identity, does not require a
    /// unique/eligible window, and does not select one — it returns every
    /// candidate so the caller can report eligibility per window.
    public func windowsApplication(_ selector: TargetSelector, context: CommandContext) async throws -> ProcessMetadata {
        try context.check()
        let applications = try await provider.listApplications()
        try context.check()
        return try selectApplication(selector, from: applications)
    }

    private func selectApplication(
        _ selector: TargetSelector,
        from applications: [ProcessMetadata]
    ) throws -> ProcessMetadata {
        let selected: [ProcessMetadata]
        switch selector {
        case let .app(name, _):
            let exactBundleMatches = applications.filter { $0.bundleId == name }
            // An exact bundle match fixes the entire tie-break domain. A name
            // collision from another bundle must never redirect this selector.
            let matches = exactBundleMatches.isEmpty
                ? applications.filter { $0.name == name }
                : exactBundleMatches
            if matches.count > 1 {
                let regularMatches = matches.filter(\.isRegularApp)
                if regularMatches.count == 1 { return regularMatches[0] }
            }
            selected = matches
        case let .pid(pid, _):
            selected = applications.filter { $0.pid == pid }
        case .display, .global:
            throw NativeFailure("INVALID_ARGUMENT", "This target is not a window")
        }
        guard selected.count == 1 else {
            throw NativeFailure(
                selected.isEmpty ? "TARGET_NOT_FOUND" : "AMBIGUOUS_TARGET",
                "Application selection is not unique"
            )
        }
        return selected[0]
    }

    /// Enumerates window candidates for a pid for the `windows` command. Returns
    /// every matched window — eligible or not — so callers can report reasons.
    public func listWindows(for pid: Int, context: CommandContext) throws -> [TargetWindow] {
        try context.check()
        let windows = try provider.windowsForPID(pid, context)
        try context.check()
        return windows
    }

    public func resolve(
        _ selector: TargetSelector,
        context: CommandContext
    ) async throws -> ResolvedTarget {
        try context.check()
        let applications = try await provider.listApplications()
        try context.check()

        let application = try selectApplication(selector, from: applications)
        guard let launchDate = application.launchDate, !launchDate.isEmpty else {
            throw NativeFailure("TARGET_NOT_FOUND", "Process start identity is unavailable")
        }

        try context.check()
        let windows = try provider.windowsForPID(application.pid, context)
        try context.check()
        let requestedWindow: Int?
        switch selector {
        case let .app(_, windowID), let .pid(_, windowID):
            requestedWindow = windowID
        case .display, .global:
            throw NativeFailure("INVALID_ARGUMENT", "This target is not a window")
        }
        let candidates = windows.filter {
            requestedWindow == nil || $0.cg.id == requestedWindow
        }
        guard !candidates.isEmpty else {
            throw NativeFailure("TARGET_NOT_FOUND", "Window was not found")
        }
        let eligible = candidates.filter(\.isEligible)
        guard !eligible.isEmpty else {
            throw NativeFailure("INELIGIBLE_TARGET", "No eligible window is available")
        }
        guard eligible.count == 1 else {
            throw NativeFailure("AMBIGUOUS_TARGET", "Window selection is not unique")
        }
        let window = eligible[0]
        try context.check()
        return ResolvedTarget(
            identity: TargetIdentity(
                pid: application.pid,
                launchDate: launchDate,
                bundleId: application.bundleId,
                windowId: window.cg.id
            ),
            title: window.cg.title ?? "",
            bounds: window.cg.bounds
        )
    }

    /// Resolves a display for the bare/`--display` screenshot path into a
    /// synthetic `ResolvedTarget`. There is no real window or app, so the
    /// identity borrows the host's own pid/launch identity — capture records
    /// require positive ids — and `isDisplay` marks the kind for the capturer.
    /// `index` selects into `SCShareableContent.displays` order; nil picks the
    /// first (primary) display.
    public func resolveDisplay(_ index: Int?, context: CommandContext) async throws -> ResolvedTarget {
        try context.check()
        let displays = try await provider.listDisplays()
        try context.check()
        guard !displays.isEmpty else {
            throw NativeFailure("TARGET_NOT_FOUND", "No display is available")
        }
        let display: DisplayMetadata
        if let index {
            // --display is 1-based (wire validation requires a positive
            // integer): display 1 is the first SCShareableContent display.
            guard index > 0, index <= displays.count else {
                throw NativeFailure("INVALID_ARGUMENT", "Display index is out of range")
            }
            display = displays[index - 1]
        } else {
            display = displays[0]
        }
        try context.check()
        return ResolvedTarget(
            identity: TargetIdentity(
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                launchDate: ProcessLaunchDate.format(ProcessInfo.processInfo.hostLaunchDate),
                bundleId: nil,
                windowId: Int(display.displayID)
            ),
            title: "Display \(display.displayID)",
            bounds: display.frame,
            isDisplay: true
        )
    }

    public func validate(
        _ identity: TargetIdentity,
        context: CommandContext
    ) async throws -> ResolvedTarget {
        do {
            let target = try await resolve(
                .pid(identity.pid, windowId: identity.windowId),
                context: context
            )
            guard target.identity == identity else {
                throw NativeFailure("STALE_SNAPSHOT", "Process or window identity changed")
            }
            return target
        } catch let failure as NativeFailure {
            throw mapPersistedSelectionFailure(failure)
        }
    }

    /// Re-validates a display target for a persisted capture. Unlike `validate`,
    /// this does not walk the window path: the synthetic identity carries the
    /// host's pid/launch identity, which is a *new* process for every command
    /// (the host is one-request-per-process), so pid equality is meaningless
    /// across requests. What must be stable for the recorded geometry to still
    /// map is the display itself — its `displayID` (in `windowId`) and its
    /// `frame`. A display that disappeared or moved/resized is stale.
    public func validateDisplay(
        _ target: ResolvedTarget,
        context: CommandContext
    ) async throws -> ResolvedTarget {
        try context.check()
        let displays = try await provider.listDisplays()
        try context.check()
        let displayID = UInt32(clamping: target.identity.windowId)
        guard let display = displays.first(where: { $0.displayID == displayID }),
              display.frame == target.bounds else {
            throw NativeFailure("STALE_CAPTURE", "Recorded capture target changed")
        }
        return ResolvedTarget(
            identity: target.identity,
            title: target.title,
            bounds: display.frame,
            isDisplay: true
        )
    }
}

enum KernelProcessStart {
    typealias Query = (pid_t, inout kinfo_proc, inout size_t) -> Int32

    static func liveQuery(_ pid: pid_t, _ process: inout kinfo_proc, _ size: inout size_t) -> Int32 {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        return sysctl(&mib, u_int(mib.count), &process, &size, nil, 0)
    }

    static func lookup(pid: Int, query: Query = liveQuery) -> Date? {
        guard let requestedPID = pid_t(exactly: pid), requestedPID > 0 else { return nil }
        var process = kinfo_proc()
        var size = size_t(MemoryLayout<kinfo_proc>.size)
        guard query(requestedPID, &process, &size) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        let start = process.kp_proc.p_starttime
        guard process.kp_proc.p_pid == requestedPID,
              start.tv_sec > 0, (0...999_999).contains(start.tv_usec) else { return nil }
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

enum ProcessLaunchDate {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension ProcessInfo {
    /// Wall-clock instant this host process launched. `processIdentifier` is
    /// reused across reboots, so the synthetic display identity pairs it with
    /// the process start time — unique within a boot and stable for the
    /// host's lifetime.
    var hostLaunchDate: Date {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &process, &size, nil, 0) == 0,
              size > 0 else {
            return Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)
        }
        let start = process.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

#if canImport(ScreenCaptureKit)
private func liveDisplays() async throws -> [DisplayMetadata] {
    guard CGPreflightScreenCaptureAccess() else {
        throw NativeFailure("PERMISSION_DENIED", "Screen Recording access is unavailable")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )
    return content.displays.map { display in
        DisplayMetadata(
            displayID: display.displayID,
            frame: WindowBounds(
                x: display.frame.origin.x,
                y: display.frame.origin.y,
                width: display.frame.width,
                height: display.frame.height
            ),
            width: display.width,
            height: display.height
        )
    }
}
#else
private func liveDisplays() async throws -> [DisplayMetadata] {
    throw NativeFailure("UNSUPPORTED_PLATFORM", "Screen capture requires macOS")
}
#endif

@MainActor
private func liveProcessMetadata() -> [ProcessMetadata] {
    NSWorkspace.shared.runningApplications.map { application in
        ProcessMetadata(
            name: application.localizedName ?? "",
            pid: Int(application.processIdentifier),
            appKitLaunchDate: application.launchDate,
            bundleId: application.bundleIdentifier,
            isRegularApp: application.activationPolicy == .regular,
            kernelStartLookup: { KernelProcessStart.lookup(pid: $0) }
        )
    }
}

private func mapPersistedSelectionFailure(_ failure: NativeFailure) -> NativeFailure {
    switch failure.code {
    case "TARGET_NOT_FOUND", "AMBIGUOUS_TARGET", "INELIGIBLE_TARGET":
        return NativeFailure(
            "STALE_SNAPSHOT",
            "Recorded target is no longer eligible or unique"
        )
    default:
        return failure
    }
}

private func resolverReadFailure(_ status: AXError) -> NativeFailure {
    if status == .apiDisabled {
        return NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    return NativeFailure(
        "NATIVE_FAILURE",
        "Window identity could not be observed reliably"
    )
}

func resolverOptionalRead<Value>(
    status: AXError,
    result: AXReadResult<Value>
) throws -> Value? {
    switch result {
    case let .value(value):
        return value
    case .unavailable:
        return nil
    case .failure:
        throw resolverReadFailure(status)
    }
}

private func resolverString(
    _ element: AXUIElement,
    _ attribute: String
) throws -> String? {
    let read = liveAXAttribute(element, attribute)
    return try resolverOptionalRead(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )
    )
}

private func resolverBool(
    _ element: AXUIElement,
    _ attribute: String
) throws -> Bool? {
    let read = liveAXAttribute(element, attribute)
    return try resolverOptionalRead(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFBooleanGetTypeID(),
            decode: { $0 as? Bool }
        )
    )
}

private func resolverBounds(_ element: AXUIElement) throws -> WindowBounds? {
    let positionRead = liveAXAttribute(element, kAXPositionAttribute)
    let sizeRead = liveAXAttribute(element, kAXSizeAttribute)
    let position: AXReadResult<AXValue> = axReadResult(
        status: positionRead.status,
        value: positionRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { $0 as! AXValue }
    )
    let size: AXReadResult<AXValue> = axReadResult(
        status: sizeRead.status,
        value: sizeRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { $0 as! AXValue }
    )
    guard let positionValue = try resolverOptionalRead(
        status: positionRead.status,
        result: position
    ), let sizeValue = try resolverOptionalRead(
        status: sizeRead.status,
        result: size
    ) else {
        return nil
    }
    guard AXValueGetType(positionValue) == .cgPoint,
          AXValueGetType(sizeValue) == .cgSize else {
        throw NativeFailure("NATIVE_FAILURE", "Window identity could not be observed reliably")
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &point),
          AXValueGetValue(sizeValue, .cgSize, &dimensions) else {
        throw NativeFailure("NATIVE_FAILURE", "Window identity could not be observed reliably")
    }
    return WindowBounds(
        x: point.x,
        y: point.y,
        width: dimensions.width,
        height: dimensions.height
    )
}

private func liveWindows(for pid: Int, context: CommandContext) throws -> [TargetWindow] {
    try context.check()
    guard AXIsProcessTrusted() else {
        throw NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    guard let nativePID = pid_t(exactly: pid), nativePID > 0 else {
        throw NativeFailure("TARGET_NOT_FOUND", "Process was not found")
    }
    let application = AXUIElementCreateApplication(nativePID)
    try prepareLiveAXMessaging(application, context: context, phase: .resolution)
    var rawWindows: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute as CFString,
        &rawWindows
    )
    let windowsResult: AXReadResult<[AXUIElement]> = axReadResult(
        status: status,
        value: rawWindows,
        expectedTypeID: CFArrayGetTypeID(),
        decode: { value in
            let array = value as! CFArray
            return decodeAXArray(
                array as [AnyObject],
                expectedElementTypeID: AXUIElementGetTypeID(),
                decode: { unsafeBitCast($0, to: AXUIElement.self) }
            )
        }
    )
    let windowElements: [AXUIElement]
    switch windowsResult {
    case let .value(values): windowElements = values
    case .unavailable: windowElements = []
    case .failure: throw resolverReadFailure(status)
    }

    let resolver = WindowIDResolver.live
    var candidates: [AXWindowCandidate] = []
    for element in windowElements {
        try context.check()
        try prepareLiveAXMessaging(element, context: context, phase: .resolution)
        let metadata = AXWindowMetadata(
            role: try resolverString(element, kAXRoleAttribute),
            title: try resolverString(element, kAXTitleAttribute),
            bounds: try resolverBounds(element),
            minimized: try resolverBool(element, kAXMinimizedAttribute),
            subrole: try resolverString(element, kAXSubroleAttribute)
        )
        candidates.append(AXWindowCandidate(
            resolvedWindowID: resolver.windowID(for: element),
            metadata: metadata
        ))
    }
    let cgWindows = try liveCGWindows(for: pid, context: context)
    try context.check()
    // Strict only when ids are available: with resolution working, AX
    // advertising a window that joins to nothing means the correlation
    // collapsed and the caller must hear about it rather than receive an
    // empty list. On the fallback path an unmatched window is expected
    // (that path is already lossy), so it stays non-fatal.
    return try joinWindows(
        axWindows: candidates,
        cgWindows: cgWindows,
        idResolutionAvailable: resolver.isAvailable,
        strictJoin: resolver.isAvailable
    )
}

private func liveCGWindows(
    for pid: Int,
    context: CommandContext
) throws -> [CGWindowMetadata] {
    try context.check()
    guard let values = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        throw NativeFailure("NATIVE_FAILURE", "Window inventory could not be read")
    }
    try context.check()
    var windows: [CGWindowMetadata] = []
    for value in values {
        try context.check()
        guard value[kCGWindowOwnerPID as String] as? Int == pid else { continue }
        guard let id = value[kCGWindowNumber as String] as? Int, id > 0,
              let dictionary = value[kCGWindowBounds as String] as? [String: CGFloat],
              let x = dictionary["X"],
              let y = dictionary["Y"],
              let width = dictionary["Width"],
              let height = dictionary["Height"],
              x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              width >= 0,
              height >= 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Window inventory contained invalid metadata")
        }
        windows.append(CGWindowMetadata(
            id: id,
            title: value[kCGWindowName as String] as? String,
            bounds: WindowBounds(x: x, y: y, width: width, height: height),
            onScreen: value[kCGWindowIsOnscreen as String] as? Bool ?? false,
            minimized: false
        ))
    }
    return windows
}

/// CGWindowList strips the application/profile suffix that many apps append to
/// `AXTitle` (e.g. Chrome reports `AXTitle` "Example Domain - Google Chrome -
/// Test-MCP" while `kCGWindowName` is just "Example Domain"). Exact equality
/// therefore never matches and the window is dropped. Accept a prefix
/// relationship in either direction; identical bounds still disambiguate.
/// Shared by TargetResolver (CG↔AX join) and AXTree.capture (re-find by
/// ResolvedTarget.title) so both match sites tolerate the same suffix.
func windowTitlesMatch(_ first: String?, _ second: String?) -> Bool {
    switch (first, second) {
    case let (a?, b?):
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        guard !shorter.isEmpty else { return false }
        return longer.hasPrefix(shorter)
    case (nil, nil):
        return true
    default:
        return false
    }
}

private func targetInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value.rounded() == value, value > 0, value <= Double(maximumSafeInteger) else { return nil }
    return Int(value)
}
