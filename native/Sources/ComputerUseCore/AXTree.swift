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

enum AXReadResult<Value> {
    case value(Value)
    case unavailable
    case failure
}

extension AXReadResult: Equatable where Value: Equatable {}

struct AXTreeReader<Element> {
    let string: (Element, String) -> AXReadResult<String>
    let bool: (Element, String) -> AXReadResult<Bool>
    let children: (Element) -> AXReadResult<[Element]>
    let actions: (Element) -> AXReadResult<[String]>
    let bounds: (Element) -> AXReadResult<WindowBounds>
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

    static func readSnapshot<Element>(
        target: ResolvedTarget,
        options: TreeOptions,
        root: Element,
        reader: AXTreeReader<Element>
    ) throws -> (snapshot: AXTreeSnapshot, elementsByRef: [Int: Element]) {
        var visited = 0
        var elementsByPath: [[Int]: Element] = [:]
        let input = try readNode(
            root,
            path: [],
            depth: 0,
            options: options,
            reader: reader,
            visited: &visited,
            elementsByPath: &elementsByPath
        )
        let snapshot = snapshot(target: target, options: options, root: input)
        var elementsByRef: [Int: Element] = [:]
        for ref in snapshot.evidence.refs {
            guard let element = elementsByPath[ref.path] else { throw observationFailure() }
            elementsByRef[ref.ref] = element
        }
        return (snapshot, elementsByRef)
    }

    private static func readNode<Element>(
        _ element: Element,
        path: [Int],
        depth: Int,
        options: TreeOptions,
        reader: AXTreeReader<Element>,
        visited: inout Int,
        elementsByPath: inout [[Int]: Element]
    ) throws -> AXTreeInputNode {
        visited += 1
        elementsByPath[path] = element

        let role = try required(reader.string(element, kAXRoleAttribute))
        let subrole = try optional(reader.string(element, kAXSubroleAttribute))
        let identifier = try optional(reader.string(element, kAXIdentifierAttribute))
        let title = try optional(reader.string(element, kAXTitleAttribute))
        let label = try optional(reader.string(element, kAXDescriptionAttribute))
        let value = try optional(reader.string(element, kAXValueAttribute))
        let enabled = try optional(reader.bool(element, kAXEnabledAttribute))
        let focused = try optional(reader.bool(element, kAXFocusedAttribute))
        let selected = try optional(reader.bool(element, kAXSelectedAttribute))
        let rawChildren = try collection(reader.children(element))
        let actions = try collection(reader.actions(element))
        let bounds = try optional(reader.bounds(element))

        var children: [AXTreeInputNode] = []
        if depth < options.maxDepth {
            for (index, child) in rawChildren.enumerated() {
                guard visited < options.maxElements else { break }
                children.append(try readNode(
                    child,
                    path: path + [index],
                    depth: depth + 1,
                    options: options,
                    reader: reader,
                    visited: &visited,
                    elementsByPath: &elementsByPath
                ))
            }
        }

        return AXTreeInputNode(
            role: role,
            subrole: subrole,
            identifier: identifier,
            title: title,
            label: label,
            value: value,
            enabled: enabled,
            focused: focused,
            selected: selected,
            actions: actions,
            bounds: bounds,
            children: children,
            totalChildCount: rawChildren.count
        )
    }

    private static func required<Value>(_ result: AXReadResult<Value>) throws -> Value {
        guard case let .value(value) = result else { throw observationFailure() }
        return value
    }

    private static func optional<Value>(_ result: AXReadResult<Value>) throws -> Value? {
        switch result {
        case let .value(value): return value
        case .unavailable: return nil
        case .failure: throw observationFailure()
        }
    }

    private static func collection<Value>(_ result: AXReadResult<[Value]>) throws -> [Value] {
        switch result {
        case let .value(values): return values
        case .unavailable: return []
        case .failure: throw observationFailure()
        }
    }

    private static func observationFailure() -> NativeFailure {
        NativeFailure("STALE_SNAPSHOT", "Accessibility observation could not be trusted")
    }

    public static func capture(target: ResolvedTarget, options: TreeOptions) throws -> AXTreeObservation {
        let app = AXUIElementCreateApplication(pid_t(target.identity.pid))
        AXUIElementSetMessagingTimeout(app, 2)
        let reader = liveAXTreeReader()

        guard case let .value(windows) = liveAXChildren(app, attribute: kAXWindowsAttribute) else {
            throw observationFailure()
        }

        var matches: [AXUIElement] = []
        for window in windows {
            guard case let .value(role) = reader.string(window, kAXRoleAttribute),
                  case let .value(title) = reader.string(window, kAXTitleAttribute),
                  case let .value(bounds) = reader.bounds(window) else {
                throw observationFailure()
            }
            if role == "AXWindow" && title == target.title && bounds == target.bounds {
                matches.append(window)
            }
        }
        guard matches.count == 1 else {
            throw NativeFailure("STALE_SNAPSHOT", "Selected window identity is no longer unique")
        }

        let result = try readSnapshot(
            target: target,
            options: options,
            root: matches[0],
            reader: reader
        )
        return AXTreeObservation(
            snapshot: result.snapshot,
            liveElements: result.elementsByRef.mapValues(LiveAXElement.init)
        )
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
}

enum AXReadDisposition: Equatable {
    case value
    case unavailable
    case failure
}

func axReadDisposition(for error: AXError) -> AXReadDisposition {
    switch error {
    case .success:
        return .value
    case .noValue, .attributeUnsupported:
        return .unavailable
    default:
        return .failure
    }
}

func axReadResult<Value>(
    status: AXError,
    value: CFTypeRef?,
    expectedTypeID: CFTypeID,
    decode: (CFTypeRef) -> Value?
) -> AXReadResult<Value> {
    switch axReadDisposition(for: status) {
    case .unavailable:
        return .unavailable
    case .failure:
        return .failure
    case .value:
        guard let value,
              CFGetTypeID(value) == expectedTypeID,
              let decoded = decode(value) else { return .failure }
        return .value(decoded)
    }
}

func decodeAXArray<Value>(
    _ values: [AnyObject],
    expectedElementTypeID: CFTypeID,
    decode: (AnyObject) -> Value?
) -> [Value]? {
    var decoded: [Value] = []
    decoded.reserveCapacity(values.count)
    for value in values {
        guard CFGetTypeID(value) == expectedElementTypeID,
              let item = decode(value) else { return nil }
        decoded.append(item)
    }
    return decoded
}

private func liveAXTreeReader() -> AXTreeReader<AXUIElement> {
    AXTreeReader(
        string: liveAXString,
        bool: liveAXBool,
        children: { liveAXChildren($0, attribute: kAXChildrenAttribute) },
        actions: liveAXActions,
        bounds: liveAXBounds
    )
}

private func liveAXAttribute(
    _ element: AXUIElement,
    _ attribute: String
) -> (status: AXError, value: CFTypeRef?) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (status, value)
}

private func liveAXString(_ element: AXUIElement, _ attribute: String) -> AXReadResult<String> {
    let read = liveAXAttribute(element, attribute)
    return axReadResult(
        status: read.status,
        value: read.value,
        expectedTypeID: CFStringGetTypeID(),
        decode: { $0 as? String }
    )
}

private func liveAXBool(_ element: AXUIElement, _ attribute: String) -> AXReadResult<Bool> {
    let read = liveAXAttribute(element, attribute)
    return axReadResult(
        status: read.status,
        value: read.value,
        expectedTypeID: CFBooleanGetTypeID(),
        decode: { $0 as? Bool }
    )
}

private func liveAXChildren(_ element: AXUIElement, attribute: String) -> AXReadResult<[AXUIElement]> {
    let read = liveAXAttribute(element, attribute)
    return axReadResult(
        status: read.status,
        value: read.value,
        expectedTypeID: CFArrayGetTypeID(),
        decode: { value in
            // axReadResult has already verified CFArrayGetTypeID().
            let array = value as! CFArray
            return decodeAXArray(
                array as [AnyObject],
                expectedElementTypeID: AXUIElementGetTypeID(),
                decode: { raw in unsafeBitCast(raw, to: AXUIElement.self) }
            )
        }
    )
}

private func liveAXActions(_ element: AXUIElement) -> AXReadResult<[String]> {
    var names: CFArray?
    let status = AXUIElementCopyActionNames(element, &names)
    return axReadResult(
        status: status,
        value: names,
        expectedTypeID: CFArrayGetTypeID(),
        decode: { value in
            // axReadResult has already verified CFArrayGetTypeID().
            let array = value as! CFArray
            guard let actions: [String] = decodeAXArray(
                    array as [AnyObject],
                    expectedElementTypeID: CFStringGetTypeID(),
                    decode: { $0 as? String }
                  ) else { return nil }
            return actions
        }
    )
}

private func liveAXBounds(_ element: AXUIElement) -> AXReadResult<WindowBounds> {
    let positionRead = liveAXAttribute(element, kAXPositionAttribute)
    let sizeRead = liveAXAttribute(element, kAXSizeAttribute)
    let position: AXReadResult<AXValue> = axReadResult(
        status: positionRead.status,
        value: positionRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { ($0 as! AXValue) } // guarded by AXValueGetTypeID above
    )
    let size: AXReadResult<AXValue> = axReadResult(
        status: sizeRead.status,
        value: sizeRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { ($0 as! AXValue) } // guarded by AXValueGetTypeID above
    )

    switch (position, size) {
    case (.failure, _), (_, .failure):
        return .failure
    case (.unavailable, _), (_, .unavailable):
        return .unavailable
    case let (.value(position), .value(size)):
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize else { return .failure }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return .failure }
        return .value(WindowBounds(
            x: point.x,
            y: point.y,
            width: dimensions.width,
            height: dimensions.height
        ))
    }
}
