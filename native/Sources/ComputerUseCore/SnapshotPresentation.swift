import Foundation

/// A pure wire projection; the observed evidence remains the action-safety authority.
struct SnapshotPresentation {
    let tree: JSONValue
    let emittedNodes: Int

    init(snapshot: AXTreeSnapshot) {
        let evidence = snapshot.evidence
        let treeOptions = snapshot.treeOptions
        var emitted = 0
        let refs = Dictionary(uniqueKeysWithValues: evidence.refs.map { ($0.path, $0.ref) })
        let boundaryPaths = Set(evidence.truncation.map(\.path))
        let includedPaths: Set<[Int]>
        if treeOptions.hintMode == .leafCompact {
            var paths: Set<[Int]> = [[]]
            // Seed observed states conservatively. Neutral wrapper states disappear only
            // when the complete single-retained-child collapse predicate below succeeds.
            for node in evidence.nodes where refs[node.path] != nil
                || boundaryPaths.contains(node.path) || hasDescription(node) || !node.actions.isEmpty
                || node.enabled == false || node.focused != nil || node.selected != nil {
                for count in 0...node.path.count { paths.insert(Array(node.path.prefix(count))) }
            }
            includedPaths = paths
        } else {
            includedPaths = Set(evidence.nodes.map(\.path))
        }

        var directChildren: [[Int]: [AXNodeEvidence]] = [:]
        for node in evidence.nodes where !node.path.isEmpty {
            directChildren[Array(node.path.dropLast()), default: []].append(node)
        }

        func hasDescription(_ node: AXNodeEvidence) -> Bool {
            [node.subrole, node.identifier, node.title, node.label, node.value].contains {
                guard let text = $0 else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        func render(_ node: AXNodeEvidence) -> JSONValue {
            let observedChildren = directChildren[node.path, default: []]
            // Render children first in evidence DFS order. Promotion returns the real
            // child's already-counted JSON, never a fabricated or re-numbered node.
            let children = observedChildren.filter { includedPaths.contains($0.path) }.map(render)
            if treeOptions.hintMode == .leafCompact,
               !node.path.isEmpty, refs[node.path] == nil, !boundaryPaths.contains(node.path),
               node.role == "AXGroup" || node.role == "AXScrollArea",
               observedChildren.count == 1, children.count == 1,
               !hasDescription(node), node.actions.isEmpty,
               node.enabled != false, node.focused != true, node.selected != true {
                return children[0]
            }
            emitted += 1
            var value: [String: JSONValue] = ["role": .string(node.role)]
            if let ref = refs[node.path] { value["ref"] = .number(Double(ref)) }
            if let subrole = node.subrole { value["subrole"] = .string(subrole) }
            if let identifier = node.identifier { value["identifier"] = .string(identifier) }
            if let title = node.title { value["title"] = .string(title) }
            if let label = node.label { value["label"] = .string(label) }
            if let text = node.value { value["value"] = .string(text) }
            if !node.actions.isEmpty { value["actions"] = .array(node.actions.map(JSONValue.string)) }
            if let enabled = node.enabled { value["enabled"] = .bool(enabled) }
            if let focused = node.focused { value["focused"] = .bool(focused) }
            if let selected = node.selected { value["selected"] = .bool(selected) }
            if let bounds = node.bounds, treeOptions.hintMode != .leafCompact || refs[node.path] != nil {
                value["bounds"] = bounds.jsonValue
            }
            if !children.isEmpty { value["children"] = .array(children) }
            return .object(value)
        }

        let roots = evidence.nodes.filter { $0.path.isEmpty && includedPaths.contains($0.path) }.map(render)
        tree = .object(["elements": .array(roots)])
        emittedNodes = emitted
    }
}

private extension WindowBounds {
    var jsonValue: JSONValue {
        .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)])
    }
}
