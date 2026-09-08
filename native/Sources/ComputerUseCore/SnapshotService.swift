import ApplicationServices
import Foundation

public struct SnapshotResult {
    public let record: SnapshotRecord
    public let snapshot: AXTreeSnapshot

    var wireData: [String: JSONValue] {
        [
            "snapshotId": .string(record.id),
            "target": snapshot.target.jsonValue,
            "tree": snapshot.treeJSON,
            "truncated": .bool(snapshot.truncated),
            "createdAt": .string(record.createdAt),
            "expiresAt": .string(record.expiresAt)
        ]
    }
}

public final class SnapshotService {
    public typealias Resolve = (TargetSelector) throws -> ResolvedTarget
    public typealias Observe = (ResolvedTarget, TreeOptions) throws -> AXTreeObservation

    public typealias ValidateTarget = (TargetIdentity) throws -> ResolvedTarget
    private let lock: DesktopLock
    private let store: StateStore
    private let resolve: Resolve
    private let observe: Observe
    private let currentDate: () -> Date
    private let validateTarget: ValidateTarget

    public init(
        lock: DesktopLock = DesktopLock(),
        store: StateStore = StateStore(),
        resolve: @escaping Resolve = { try TargetResolver().resolve($0) },
        observe: @escaping Observe = AXTree.capture,
        validateTarget: @escaping ValidateTarget = { try TargetResolver().validate($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.lock = lock
        self.store = store
        self.resolve = resolve
        self.observe = observe
        self.validateTarget = validateTarget
        currentDate = now
    }

    public func snapshot(selector: TargetSelector, options: TreeOptions, timeoutMilliseconds: Int) throws -> SnapshotResult {
        let deadline = deadline(after: timeoutMilliseconds)
        return try lock.withLock(deadline: deadline) {
            try requireTime(deadline)
            try store.sweep()
            let target = try resolve(selector)
            try requireTime(deadline)
            let observation = try observe(target, options)
            guard observation.snapshot.target == target, observation.snapshot.treeOptions == options else {
                throw NativeFailure("STALE_SNAPSHOT", "Target or traversal evidence changed during snapshot")
            }
            try requireTime(deadline)
            let created = currentDate()
            let record = SnapshotRecord(
                id: UUID().uuidString.lowercased(),
                createdAt: timestamp(created),
                expiresAt: timestamp(created.addingTimeInterval(snapshotLifetime)),
                target: target,
                treeOptions: options,
                evidence: observation.snapshot.evidence
            )
            try store.writeSnapshot(record)
            return SnapshotResult(record: record, snapshot: observation.snapshot)
        }
    }

    func withValidatedSnapshotAction<Prepared, Result>(
        snapshotID: String,
        ref: Int,
        timeoutMilliseconds: Int,
        stateChanging: Bool,
        preflight: (LiveAXElement, ResolvedTarget) throws -> Prepared,
        dispatch: (Prepared) throws -> Result
    ) throws -> Result {
        let deadline = deadline(after: timeoutMilliseconds)
        return try lock.withLock(deadline: deadline) {
            try requireTime(deadline)
            try store.sweep()
            let record = try store.readSnapshot(id: snapshotID)
            let target = try validateTarget(record.target.identity)
            guard target == record.target else { throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed") }
            let live = try observe(target, record.treeOptions)
            let recorded = AXTreeSnapshot(target: record.target, treeOptions: record.treeOptions, evidence: record.evidence)
            _ = try Self.validateEvidence(recorded, live: live.snapshot, ref: ref)
            guard let element = live.liveElements[ref] else { throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable") }
            let prepared = try preflight(element, target)
            try requireTime(deadline)
            if stateChanging {
                try store.invalidateRecords(for: record.target.identity)
            }
            return try dispatch(prepared)
        }
    }

    static func validateEvidence(_ recorded: AXTreeSnapshot, live: AXTreeSnapshot, ref: Int) throws -> AXRefEvidence {
        try AXEvidencePolicy.validate(recorded.evidence, options: recorded.treeOptions)
        try AXEvidencePolicy.validate(live.evidence, options: live.treeOptions)
        guard recorded.target == live.target,
              recorded.treeOptions == live.treeOptions,
              recorded.evidence.nodes == live.evidence.nodes,
              recorded.evidence.truncation == live.evidence.truncation,
              recorded.evidence.refs == live.evidence.refs,
              let recordedRef = recorded.evidence.refs.first(where: { $0.ref == ref }),
              let liveRef = live.evidence.refs.first(where: { $0.ref == ref }),
              recordedRef == liveRef else {
            throw NativeFailure("STALE_SNAPSHOT", "Snapshot evidence no longer matches the selected window")
        }
        return liveRef
    }

    private func deadline(after milliseconds: Int) -> UInt64 {
        let increment = UInt64(max(0, milliseconds)) * 1_000_000
        let now = lock.now()
        return now > UInt64.max - increment ? UInt64.max : now + increment
    }

    private func requireTime(_ deadline: UInt64) throws {
        guard lock.now() < deadline else { throw NativeFailure("TIMEOUT", "Desktop operation deadline expired") }
    }
}

private func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private extension ResolvedTarget {
    var jsonValue: JSONValue {
        .object([
            "pid": .number(Double(identity.pid)),
            "launchDate": .string(identity.launchDate),
            "bundleId": identity.bundleId.map(JSONValue.string) ?? .null,
            "windowId": .number(Double(identity.windowId)),
            "title": .string(title),
            "bounds": bounds.jsonValue
        ])
    }
}

private extension WindowBounds {
    var jsonValue: JSONValue {
        .object(["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)])
    }
}

private extension AXTreeSnapshot {
    var treeJSON: JSONValue {
        let refs = Dictionary(uniqueKeysWithValues: evidence.refs.map { ($0.path, $0.ref) })
        let includedPaths: Set<[Int]>
        if treeOptions.hintMode == .leafCompact {
            var paths = Set<[Int]>()
            for ref in evidence.refs {
                for count in 0...ref.path.count { paths.insert(Array(ref.path.prefix(count))) }
            }
            includedPaths = paths
        } else {
            includedPaths = Set(evidence.nodes.map(\.path))
        }

        func render(_ node: AXNodeEvidence) -> JSONValue {
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
            if let bounds = node.bounds { value["bounds"] = bounds.jsonValue }
            let children = evidence.nodes.filter {
                $0.path.count == node.path.count + 1 && Array($0.path.dropLast()) == node.path && includedPaths.contains($0.path)
            }.map(render)
            if !children.isEmpty { value["children"] = .array(children) }
            return .object(value)
        }

        let roots = evidence.nodes.filter { $0.path.isEmpty && includedPaths.contains($0.path) }.map(render)
        return .object(["elements": .array(roots)])
    }
}
