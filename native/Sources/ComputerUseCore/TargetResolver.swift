import AppKit
import ApplicationServices
import Foundation

public enum TargetSelector {
    case app(String, windowId: Int?)
    case pid(Int, windowId: Int?)
}

public struct TargetIdentity: Codable, Equatable {
    public let pid: Int
    public let launchDate: String
    public let bundleId: String?
    public let windowId: Int
}

public struct ResolvedTarget: Equatable {
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

    public static func live() -> TargetInventory {
        let apps = NSWorkspace.shared.runningApplications.compactMap { application -> TargetApplication? in
            guard let launchDate = application.launchDate else { return nil }
            let pid = Int(application.processIdentifier)
            let axWindows = axWindows(for: application.processIdentifier)
            let cgWindows = cgWindows(for: pid)
            let windows = axWindows.flatMap { ax in
                cgWindows.filter { cg in matches(ax: ax, cg: cg) }.map {
                    TargetWindow(ax: ax, cg: CGWindowMetadata(id: $0.id, title: $0.title, bounds: $0.bounds, onScreen: $0.onScreen, minimized: ax.minimized == true))
                }
            }
            return TargetApplication(name: application.localizedName ?? "", pid: pid, launchDate: ISO8601DateFormatter().string(from: launchDate), bundleId: application.bundleIdentifier, windows: windows)
        }
        return TargetInventory(apps: apps)
    }
}

public final class TargetResolver {
    private let inventory: TargetInventory

    public init(inventory: TargetInventory = .live()) { self.inventory = inventory }

    public func resolve(_ selector: TargetSelector) throws -> ResolvedTarget {
        let app: TargetApplication
        switch selector {
        case let .app(name, _):
            let matches = inventory.apps.filter { $0.name == name || $0.bundleId == name }
            guard matches.count == 1 else { throw NativeFailure(matches.isEmpty ? "TARGET_NOT_FOUND" : "AMBIGUOUS_TARGET", "Application selection is not unique") }
            app = matches[0]
        case let .pid(pid, _):
            guard let match = inventory.apps.first(where: { $0.pid == pid }) else { throw NativeFailure("TARGET_NOT_FOUND", "Process was not found") }
            app = match
        }
        guard let launchDate = app.launchDate else { throw NativeFailure("TARGET_NOT_FOUND", "Process start identity is unavailable") }
        let windowID: Int?
        switch selector { case let .app(_, id), let .pid(_, id): windowID = id }
        let candidates = app.windows.filter { windowID == nil || $0.cg.id == windowID }
        guard !candidates.isEmpty else { throw NativeFailure("TARGET_NOT_FOUND", "Window was not found") }
        let eligible = candidates.filter { $0.cg.onScreen && !$0.cg.minimized }
        if eligible.isEmpty { throw NativeFailure("INELIGIBLE_TARGET", "No eligible window is available") }
        guard eligible.count == 1 else { throw NativeFailure("AMBIGUOUS_TARGET", "Window selection is not unique") }
        let window = eligible[0]
        return ResolvedTarget(identity: TargetIdentity(pid: app.pid, launchDate: launchDate, bundleId: app.bundleId, windowId: window.cg.id), title: window.cg.title ?? "", bounds: window.cg.bounds)
    }

    public func validate(_ identity: TargetIdentity) throws -> ResolvedTarget {
        guard let app = inventory.apps.first(where: { $0.pid == identity.pid }), app.launchDate == identity.launchDate, app.bundleId == identity.bundleId else {
            throw NativeFailure("STALE_SNAPSHOT", "Process identity changed")
        }
        return try resolve(.pid(app.pid, windowId: identity.windowId))
    }
}

private func axAttribute<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

private func axBounds(_ element: AXUIElement) -> WindowBounds? {
    guard let position: AXValue = axAttribute(element, kAXPositionAttribute, as: AXValue.self),
          let size: AXValue = axAttribute(element, kAXSizeAttribute, as: AXValue.self) else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
    return WindowBounds(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
}

private func axWindows(for pid: pid_t) -> [AXWindowMetadata] {
    let app = AXUIElementCreateApplication(pid)
    guard let values: CFArray = axAttribute(app, kAXWindowsAttribute, as: CFArray.self) else { return [] }
    return (values as [AnyObject]).compactMap { value in
        let element = unsafeBitCast(value, to: AXUIElement.self)
        return AXWindowMetadata(role: axAttribute(element, kAXRoleAttribute, as: String.self), title: axAttribute(element, kAXTitleAttribute, as: String.self), bounds: axBounds(element), minimized: axAttribute(element, kAXMinimizedAttribute, as: Bool.self))
    }
}

private func cgWindows(for pid: Int) -> [CGWindowMetadata] {
    guard let values = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return values.compactMap { value in
        guard value[kCGWindowOwnerPID as String] as? Int == pid,
              let id = value[kCGWindowNumber as String] as? Int,
              let dictionary = value[kCGWindowBounds as String] as? [String: CGFloat],
              let x = dictionary["X"], let y = dictionary["Y"], let width = dictionary["Width"], let height = dictionary["Height"] else { return nil }
        return CGWindowMetadata(id: id, title: value[kCGWindowName as String] as? String, bounds: WindowBounds(x: x, y: y, width: width, height: height), onScreen: value[kCGWindowIsOnscreen as String] as? Bool ?? false, minimized: false)
    }
}

private func matches(ax: AXWindowMetadata, cg: CGWindowMetadata) -> Bool {
    guard ax.role == "AXWindow", ax.title == cg.title, let bounds = ax.bounds else { return false }
    return bounds == cg.bounds
}
