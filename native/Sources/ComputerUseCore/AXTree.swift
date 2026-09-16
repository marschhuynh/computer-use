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

internal enum AXEvidencePolicy {
    static func deriveRefs(
        nodes: [AXNodeEvidence],
        boundaries: [AXTraversalBoundary],
        mode: HintMode
    ) -> [AXRefEvidence] {
        let count = nodes.count
        guard count > 0 else { return [] }

        var parent = [Int](repeating: -1, count: count)
        var children = [[Int]](repeating: [], count: count)
        var stack: [Int] = []
        for index in 0..<count {
            let depth = nodes[index].path.count
            while stack.count > depth {
                stack.removeLast()
            }
            if depth > 0, stack.count == depth {
                let parentIndex = stack[depth - 1]
                parent[index] = parentIndex
                children[parentIndex].append(index)
            }
            stack.append(index)
        }

        var isBoundary = [Bool](repeating: false, count: count)
        for boundary in boundaries {
            var index = 0
            var resolved = true
            for component in boundary.path {
                let kids = children[index]
                guard component >= 0, component < kids.count,
                      nodes[kids[component]].path.last == component else {
                    resolved = false
                    break
                }
                index = kids[component]
            }
            if resolved {
                isBoundary[index] = true
            }
        }

        var atOrBelowBoundary = [Bool](repeating: false, count: count)
        var isBoundaryAncestor = [Bool](repeating: false, count: count)
        var isActionableAncestor = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let parentIndex = parent[index]
            atOrBelowBoundary[index] = isBoundary[index]
                || (parentIndex >= 0 && atOrBelowBoundary[parentIndex])
        }
        for index in stride(from: count - 1, through: 0, by: -1) {
            let parentIndex = parent[index]
            guard parentIndex >= 0 else { continue }
            if isBoundary[index] || isBoundaryAncestor[index] {
                isBoundaryAncestor[parentIndex] = true
            }
            if !nodes[index].actions.isEmpty || isActionableAncestor[index] {
                isActionableAncestor[parentIndex] = true
            }
        }

        var selected: [AXNodeEvidence] = []
        selected.reserveCapacity(count)
        for index in 0..<count {
            guard !atOrBelowBoundary[index] else { continue }
            let node = nodes[index]
            switch mode {
            case .full:
                selected.append(node)
            case .leafOnly, .leafCompact:
                guard !isBoundaryAncestor[index] else { continue }
                let editable = node.role == "AXTextArea" || node.role == "AXWebArea"
                if editable || (!node.actions.isEmpty && !isActionableAncestor[index]) {
                    selected.append(node)
                }
            }
        }

        return selected.enumerated().map {
            AXRefEvidence(ref: $0.offset + 1, path: $0.element.path, node: $0.element)
        }
    }

    static func validate(_ evidence: AXTreeEvidence, options: TreeOptions) throws {
        guard options.maxDepth > 0,
              options.maxDepth <= maximumSafeInteger,
              options.maxElements > 0,
              options.maxElements <= maximumSafeInteger,
              !evidence.nodes.isEmpty,
              evidence.nodes.count <= options.maxElements,
              evidence.nodes[0].path.isEmpty else { throw invalidEvidence() }

        var nodesByPath: [[Int]: AXNodeEvidence] = [:]
        var directChildIndexes: [[Int]: [Int]] = [:]
        var previousPath: [Int]?

        for node in evidence.nodes {
            guard !node.role.isEmpty,
                  node.path.allSatisfy({ $0 >= 0 }),
                  node.path.count <= options.maxDepth,
                  node.childCount >= 0,
                  valid(node.bounds),
                  node.actions == Array(Set(node.actions)).sorted(),
                  nodesByPath[node.path] == nil else { throw invalidEvidence() }
            if let previousPath,
               !previousPath.lexicographicallyPrecedes(node.path) {
                throw invalidEvidence()
            }
            if !node.path.isEmpty {
                let parentPath = Array(node.path.dropLast())
                guard let parent = nodesByPath[parentPath],
                      let childIndex = node.path.last,
                      childIndex < parent.childCount else { throw invalidEvidence() }
                directChildIndexes[parentPath, default: []].append(childIndex)
            }
            nodesByPath[node.path] = node
            previousPath = node.path
        }

        let finalPath = evidence.nodes[evidence.nodes.count - 1].path
        var depthBoundaries: [AXTraversalBoundary] = []
        var elementBoundaries: [AXTraversalBoundary] = []

        for node in evidence.nodes {
            let indexes = directChildIndexes[node.path, default: []]
            guard indexes == Array(0..<indexes.count),
                  indexes.count <= node.childCount else { throw invalidEvidence() }
            guard indexes.count < node.childCount else { continue }

            if node.path.count == options.maxDepth {
                guard indexes.isEmpty else { throw invalidEvidence() }
                depthBoundaries.append(AXTraversalBoundary(
                    path: node.path,
                    reason: .maxDepth,
                    observedChildren: 0,
                    totalChildren: node.childCount
                ))
            } else {
                guard evidence.nodes.count == options.maxElements,
                      finalPath.starts(with: node.path) else { throw invalidEvidence() }
                elementBoundaries.append(AXTraversalBoundary(
                    path: node.path,
                    reason: .maxElements,
                    observedChildren: indexes.count,
                    totalChildren: node.childCount
                ))
            }
        }

        elementBoundaries.sort {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.path.lexicographicallyPrecedes($1.path)
        }
        let expectedBoundaries = depthBoundaries + elementBoundaries
        guard evidence.truncation == expectedBoundaries else { throw invalidEvidence() }

        let expectedRefs = deriveRefs(
            nodes: evidence.nodes,
            boundaries: expectedBoundaries,
            mode: options.hintMode
        )
        guard evidence.refs == expectedRefs else { throw invalidEvidence() }
    }

    private static func valid(_ bounds: WindowBounds?) -> Bool {
        guard let bounds else { return true }
        return bounds.x.isFinite
            && bounds.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && bounds.width >= 0
            && bounds.height >= 0
    }

    private static func invalidEvidence() -> NativeFailure {
        NativeFailure("STALE_SNAPSHOT", "Accessibility evidence is malformed or incomplete")
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

public typealias AXElementIdentity = (LiveAXElement, LiveAXElement) -> Bool

func liveAXElementsAreIdentical(
    _ lhs: LiveAXElement,
    _ rhs: LiveAXElement
) -> Bool {
    guard let left = lhs.rawValue, let right = rhs.rawValue else { return false }
    return CFEqual(left, right)
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
        let refs = AXEvidencePolicy.deriveRefs(
            nodes: nodes,
            boundaries: boundaries,
            mode: options.hintMode
        )
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
            actions: Array(Set(input.actions)).sorted(),
            bounds: input.bounds,
            childCount: input.totalChildCount
        )
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

func liveAXAttribute(
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
