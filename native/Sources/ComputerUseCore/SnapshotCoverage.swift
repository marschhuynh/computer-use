import Foundation

/// Coverage describes the original observation, never the projected tree's paths.
struct SnapshotCoverage {
    static func json(snapshot: AXTreeSnapshot, emittedNodes: Int) -> JSONValue {
        let evidence = snapshot.evidence
        var value: [String: JSONValue] = [
            "scope": .string("selectedWindow"), "absenceIsConclusive": .bool(false),
            "observedNodes": .number(Double(evidence.nodes.count)),
            "emittedNodes": .number(Double(emittedNodes)),
            "refCount": .number(Double(evidence.refs.count)),
            "limits": .object([
                "maxDepth": .number(Double(snapshot.treeOptions.maxDepth)),
                "maxElements": .number(Double(snapshot.treeOptions.maxElements))
            ]),
            "boundaries": .array(evidence.truncation.map { boundary in
                .object([
                    "path": .array(boundary.path.map { .number(Double($0)) }),
                    "reason": .string(boundary.reason.rawValue),
                    "observedChildren": .number(Double(boundary.observedChildren)),
                    "totalChildren": .number(Double(boundary.totalChildren))
                ])
            })
        ]
        if evidence.refs.isEmpty {
            value["noRefReason"] = .string(evidence.truncation.isEmpty ? "noEligibleRefs" : "traversalLimited")
        }
        return .object(value)
    }
}
