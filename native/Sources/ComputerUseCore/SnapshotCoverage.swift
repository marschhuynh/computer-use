import Foundation

/// Coverage describes the original observation, never the projected tree's paths.
struct SnapshotCoverage {
    static let maxEmittedBoundaries = 32

    static func json(snapshot: AXTreeSnapshot, emittedNodes: Int) -> JSONValue {
        let evidence = snapshot.evidence
        let emittedBoundaries: [AXTraversalBoundary]
        let omittedCount: Int
        if evidence.truncation.count > maxEmittedBoundaries {
            let maxElementsBoundaries = evidence.truncation.filter { $0.reason == .maxElements }
            let maxDepthBudget = max(0, maxEmittedBoundaries - maxElementsBoundaries.count)
            let maxDepthBoundaries = evidence.truncation.filter { $0.reason == .maxDepth }.prefix(maxDepthBudget)
            emittedBoundaries = Array(maxDepthBoundaries) + maxElementsBoundaries
            omittedCount = evidence.truncation.count - emittedBoundaries.count
        } else {
            emittedBoundaries = evidence.truncation
            omittedCount = 0
        }
        var value: [String: JSONValue] = [
            "scope": .string("selectedWindow"), "absenceIsConclusive": .bool(false),
            "observedNodes": .number(Double(evidence.nodes.count)),
            "emittedNodes": .number(Double(emittedNodes)),
            "refCount": .number(Double(evidence.refs.count)),
            "limits": .object([
                "maxDepth": .number(Double(snapshot.treeOptions.maxDepth)),
                "maxElements": .number(Double(snapshot.treeOptions.maxElements))
            ]),
            "boundaries": .array(emittedBoundaries.map { boundary in
                .object([
                    "path": .array(boundary.path.map { .number(Double($0)) }),
                    "reason": .string(boundary.reason.rawValue),
                    "observedChildren": .number(Double(boundary.observedChildren)),
                    "totalChildren": .number(Double(boundary.totalChildren))
                ])
            })
        ]
        if omittedCount > 0 {
            value["omittedBoundaries"] = .number(Double(omittedCount))
        }
        if evidence.refs.isEmpty {
            value["noRefReason"] = .string(evidence.truncation.isEmpty ? "noEligibleRefs" : "traversalLimited")
        }
        return .object(value)
    }
}
