import AppKit
import ApplicationServices
import Foundation

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
}

public struct WindowBounds: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct AXWindowMetadata: Codable, Equatable {
    public let role: String?
    public let title: String?
    public let bounds: WindowBounds?
    public let minimized: Bool?
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

    public init(name: String, pid: Int, launchDate: String?, bundleId: String?) {
        self.name = name
        self.pid = pid
        self.launchDate = launchDate
        self.bundleId = bundleId
    }

    init(application: TargetApplication) {
        name = application.name
        pid = application.pid
        launchDate = application.launchDate
        bundleId = application.bundleId
    }
}

public struct TargetResolverProvider {
    public let listApplications: () async throws -> [ProcessMetadata]
    public let windowsForPID: (Int, CommandContext) throws -> [TargetWindow]

    public init(
        listApplications: @escaping () async throws -> [ProcessMetadata],
        windowsForPID: @escaping (Int, CommandContext) throws -> [TargetWindow]
    ) {
        self.listApplications = listApplications
        self.windowsForPID = windowsForPID
    }

    public static var live: TargetResolverProvider {
        TargetResolverProvider(
            listApplications: {
                await MainActor.run { liveProcessMetadata() }
            },
            windowsForPID: { pid, context in
                try liveWindows(for: pid, context: context)
            }
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
            }
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
        let selected: [ProcessMetadata]
        switch selector {
        case let .app(name, _):
            selected = applications.filter { $0.name == name || $0.bundleId == name }
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

        let selected: [ProcessMetadata]
        switch selector {
        case let .app(name, _):
            selected = applications.filter { $0.name == name || $0.bundleId == name }
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
        let application = selected[0]
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
        let eligible = candidates.filter { $0.cg.onScreen && !$0.cg.minimized }
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
}

enum ProcessLaunchDate {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

@MainActor
private func liveProcessMetadata() -> [ProcessMetadata] {
    NSWorkspace.shared.runningApplications.map { application in
        ProcessMetadata(
            name: application.localizedName ?? "",
            pid: Int(application.processIdentifier),
            launchDate: application.launchDate.map(ProcessLaunchDate.format),
            bundleId: application.bundleIdentifier
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
    try prepareLiveAXMessaging(application, context: context)
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

    var axWindows: [AXWindowMetadata] = []
    for element in windowElements {
        try context.check()
        try prepareLiveAXMessaging(element, context: context)
        axWindows.append(AXWindowMetadata(
            role: try resolverString(element, kAXRoleAttribute),
            title: try resolverString(element, kAXTitleAttribute),
            bounds: try resolverBounds(element),
            minimized: try resolverBool(element, kAXMinimizedAttribute)
        ))
    }
    let cgWindows = try liveCGWindows(for: pid, context: context)
    var matched: [TargetWindow] = []
    for ax in axWindows {
        try context.check()
        for cg in cgWindows {
            try context.check()
            guard matches(ax: ax, cg: cg) else { continue }
            matched.append(TargetWindow(
                ax: ax,
                cg: CGWindowMetadata(
                    id: cg.id,
                    title: cg.title,
                    bounds: cg.bounds,
                    onScreen: cg.onScreen,
                    minimized: ax.minimized == true
                )
            ))
        }
    }
    return matched
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

private func matches(ax: AXWindowMetadata, cg: CGWindowMetadata) -> Bool {
    guard ax.role == "AXWindow", windowTitlesMatch(ax.title, cg.title), let bounds = ax.bounds else {
        return false
    }
    return bounds == cg.bounds
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
