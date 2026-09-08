import ApplicationServices
import Foundation

public enum HintMode: String, Codable, Equatable {
    case full, leafOnly, leafCompact
}

public struct TreeOptions: Codable, Equatable {
    public let maxDepth: Int
    public let maxElements: Int
    public let hintMode: HintMode

    public init(maxDepth: Int, maxElements: Int, hintMode: HintMode) {
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.hintMode = hintMode
    }
}

public struct AXTreeInputNode: Equatable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let label: String?
    public let value: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    public let actions: [String]
    public let bounds: WindowBounds?
    public let children: [AXTreeInputNode]
    public let totalChildCount: Int

    public init(
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        label: String? = nil,
        value: String? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        selected: Bool? = nil,
        actions: [String] = [],
        bounds: WindowBounds? = nil,
        children: [AXTreeInputNode] = [],
        totalChildCount: Int? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.actions = actions
        self.bounds = bounds
        self.children = children
        self.totalChildCount = totalChildCount ?? children.count
    }
}

public struct AXNodeEvidence: Codable, Equatable {
    public let path: [Int]
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let label: String?
    public let value: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let selected: Bool?
    public let actions: [String]
    public let bounds: WindowBounds?
    public let childCount: Int
}

public enum AXTraversalLimit: String, Codable, Equatable {
    case maxDepth, maxElements
}

public struct AXTraversalBoundary: Codable, Equatable {
    public let path: [Int]
    public let reason: AXTraversalLimit
    public let observedChildren: Int
    public let totalChildren: Int

    public init(path: [Int], reason: AXTraversalLimit, observedChildren: Int, totalChildren: Int) {
        self.path = path
        self.reason = reason
        self.observedChildren = observedChildren
        self.totalChildren = totalChildren
    }
}

public struct AXRefEvidence: Codable, Equatable {
    public let ref: Int
    public let path: [Int]
    public let node: AXNodeEvidence
}

public struct AXTreeEvidence: Codable, Equatable {
    public let nodes: [AXNodeEvidence]
    public let truncation: [AXTraversalBoundary]
    public let refs: [AXRefEvidence]

    public init(nodes: [AXNodeEvidence], truncation: [AXTraversalBoundary], refs: [AXRefEvidence]) {
        self.nodes = nodes
        self.truncation = truncation
        self.refs = refs
    }
}

public struct AXTreeSnapshot: Codable, Equatable {
    public let target: ResolvedTarget
    public let treeOptions: TreeOptions
    public let evidence: AXTreeEvidence

    public var truncated: Bool { !evidence.truncation.isEmpty }
}

public struct LiveAXElement {
    let rawValue: AXUIElement?

    public init() { rawValue = nil }
    init(_ rawValue: AXUIElement) { self.rawValue = rawValue }
}

public struct AXTreeObservation {
    public let snapshot: AXTreeSnapshot
    let liveElements: [Int: LiveAXElement]

    public init(snapshot: AXTreeSnapshot, liveElements: [Int: LiveAXElement]) {
        self.snapshot = snapshot
        self.liveElements = liveElements
    }
}

public enum AXTree {
    public static func snapshot(target: ResolvedTarget, options: TreeOptions, root: AXTreeInputNode) -> AXTreeSnapshot {
        var nodes: [AXNodeEvidence] = []
        var boundaries: [AXTraversalBoundary] = []
        walk(root, path: [], depth: 0, options: options, nodes: &nodes, boundaries: &boundaries)
        let refs = buildRefs(nodes: nodes, boundaries: boundaries, mode: options.hintMode)
        return AXTreeSnapshot(target: target, treeOptions: options, evidence: AXTreeEvidence(nodes: nodes, truncation: boundaries, refs: refs))
    }

    public static func capture(target: ResolvedTarget, options: TreeOptions) throws -> AXTreeObservation {
        let app = AXUIElementCreateApplication(pid_t(target.identity.pid))
        AXUIElementSetMessagingTimeout(app, 2)
        let windows = axChildren(app, attribute: kAXWindowsAttribute)
        let matches = windows.filter { window in
            axString(window, kAXRoleAttribute) == "AXWindow"
                && (axString(window, kAXTitleAttribute) ?? "") == target.title
                && axBounds(window) == target.bounds
        }
        guard matches.count == 1 else { throw NativeFailure("STALE_SNAPSHOT", "Selected window identity is no longer unique") }

        var visited = 0
        var elementsByPath: [[Int]: AXUIElement] = [:]
        let root = captureNode(matches[0], path: [], depth: 0, options: options, visited: &visited, elements: &elementsByPath)
        let result = snapshot(target: target, options: options, root: root)
        var liveElements: [Int: LiveAXElement] = [:]
        for ref in result.evidence.refs {
            if let element = elementsByPath[ref.path] { liveElements[ref.ref] = LiveAXElement(element) }
        }
        return AXTreeObservation(snapshot: result, liveElements: liveElements)
    }

    private static func walk(
        _ input: AXTreeInputNode,
        path: [Int],
        depth: Int,
        options: TreeOptions,
        nodes: inout [AXNodeEvidence],
        boundaries: inout [AXTraversalBoundary]
    ) {
        guard nodes.count < options.maxElements else { return }
        nodes.append(evidence(input, path: path))
        guard input.totalChildCount > 0 else { return }
        if depth >= options.maxDepth {
            boundaries.append(.init(path: path, reason: .maxDepth, observedChildren: 0, totalChildren: input.totalChildCount))
            return
        }

        var observedChildren = 0
        for (index, child) in input.children.enumerated() {
            guard nodes.count < options.maxElements else { break }
            walk(child, path: path + [index], depth: depth + 1, options: options, nodes: &nodes, boundaries: &boundaries)
            observedChildren += 1
        }
        if observedChildren < input.totalChildCount {
            boundaries.append(.init(path: path, reason: .maxElements, observedChildren: observedChildren, totalChildren: input.totalChildCount))
        }
    }

    private static func evidence(_ input: AXTreeInputNode, path: [Int]) -> AXNodeEvidence {
        AXNodeEvidence(
            path: path,
            role: input.role,
            subrole: input.subrole,
            identifier: input.identifier,
            title: input.title,
            label: input.label,
            value: input.value,
            enabled: input.enabled,
            focused: input.focused,
            selected: input.selected,
            actions: input.actions.sorted(),
            bounds: input.bounds,
            childCount: input.totalChildCount
        )
    }

    private static func buildRefs(nodes: [AXNodeEvidence], boundaries: [AXTraversalBoundary], mode: HintMode) -> [AXRefEvidence] {
        let selected: [AXNodeEvidence]
        switch mode {
        case .full:
            selected = nodes
        case .leafOnly, .leafCompact:
            selected = nodes.filter { node in
                let hasObservedActionableDescendant = nodes.contains {
                    $0.path.count > node.path.count && $0.path.starts(with: node.path) && !$0.actions.isEmpty
                }
                let hasUnobservedDescendant = boundaries.contains { $0.path.starts(with: node.path) || node.path.starts(with: $0.path) }
                let editable = ["AXTextArea", "AXWebArea"].contains(node.role)
                return !hasUnobservedDescendant && (editable || (!node.actions.isEmpty && !hasObservedActionableDescendant))
            }
        }
        return selected.enumerated().map { AXRefEvidence(ref: $0.offset + 1, path: $0.element.path, node: $0.element) }
    }

    private static func captureNode(
        _ element: AXUIElement,
        path: [Int],
        depth: Int,
        options: TreeOptions,
        visited: inout Int,
        elements: inout [[Int]: AXUIElement]
    ) -> AXTreeInputNode {
        visited += 1
        elements[path] = element
        let rawChildren = axChildren(element, attribute: kAXChildrenAttribute)
        var children: [AXTreeInputNode] = []
        if depth < options.maxDepth {
            for (index, child) in rawChildren.enumerated() {
                guard visited < options.maxElements else { break }
                children.append(captureNode(child, path: path + [index], depth: depth + 1, options: options, visited: &visited, elements: &elements))
            }
        }
        return AXTreeInputNode(
            role: axString(element, kAXRoleAttribute) ?? "AXUnknown",
            subrole: axString(element, kAXSubroleAttribute),
            identifier: axString(element, kAXIdentifierAttribute),
            title: axString(element, kAXTitleAttribute),
            label: axString(element, kAXDescriptionAttribute),
            value: axString(element, kAXValueAttribute),
            enabled: axBool(element, kAXEnabledAttribute),
            focused: axBool(element, kAXFocusedAttribute),
            selected: axBool(element, kAXSelectedAttribute),
            actions: axActions(element),
            bounds: axBounds(element),
            children: children,
            totalChildCount: rawChildren.count
        )
    }
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func axTypedValue<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type) -> T? {
    axValue(element, attribute) as? T
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axValue(element, attribute) as? String
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axValue(element, attribute) as? Bool
}

private func axChildren(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    guard let array: CFArray = axTypedValue(element, attribute, as: CFArray.self) else { return [] }
    return (array as [AnyObject]).map { unsafeBitCast($0, to: AXUIElement.self) }
}

private func axActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
    return (names as [AnyObject]).compactMap { value in
        let raw = value as? String
        guard let raw else { return nil }
        if raw.hasPrefix("Name:") { return String(raw.dropFirst(5).split(separator: "\n", maxSplits: 1)[0]) }
        return raw
    }.sorted()
}

private func axBounds(_ element: AXUIElement) -> WindowBounds? {
    guard let position: AXValue = axTypedValue(element, kAXPositionAttribute, as: AXValue.self),
          let size: AXValue = axTypedValue(element, kAXSizeAttribute, as: AXValue.self) else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
    return WindowBounds(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
}
