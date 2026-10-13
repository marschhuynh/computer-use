import ApplicationServices
import Foundation

public struct SnapshotResult {
    public let record: SnapshotRecord
    public let snapshot: AXTreeSnapshot

    var wireData: [String: JSONValue] {
        [
            "snapshotId": .string(record.id),
            "target": snapshot.target.jsonValue,
            "tree": SnapshotPresentation(snapshot: snapshot).tree,
            "truncated": .bool(snapshot.truncated),
            "createdAt": .string(record.createdAt),
            "expiresAt": .string(record.expiresAt)
        ]
    }
}

public final class SnapshotService {
    public typealias Resolve = (TargetSelector, CommandContext) async throws -> ResolvedTarget
    public typealias Observe = (ResolvedTarget, TreeOptions, CommandContext) async throws -> AXTreeObservation
    public typealias ValidateTarget = (TargetIdentity, CommandContext) async throws -> ResolvedTarget
    public typealias PrepareForeground = (ResolvedTarget, LiveAXElement, CommandContext) async throws -> Void
    public typealias PrepareElement = (LiveAXElement, CommandContext) async throws -> Void
    public typealias Preflight<Prepared> = (LiveAXElement, ResolvedTarget, CommandContext) async throws -> Prepared
    public typealias Dispatch<Prepared, Result> = (Prepared, LiveAXElement, CommandContext) async throws -> Result

    private let lock: DesktopLock
    private let store: StateStore
    private let resolve: Resolve
    private let observe: Observe
    private let validateTarget: ValidateTarget
    private let sameLiveElement: AXElementIdentity
    private let prepareForeground: PrepareForeground
    private let prepareElement: PrepareElement

    public init(
        lock: DesktopLock = DesktopLock(),
        store: StateStore = StateStore(),
        resolve: @escaping Resolve = { selector, context in
            try await TargetResolver().resolve(selector, context: context)
        },
        observe: @escaping Observe = { target, options, context in
            try AXTree.capture(target: target, options: options, context: context)
        },
        validateTarget: @escaping ValidateTarget = { identity, context in
            try await TargetResolver().validate(identity, context: context)
        },
        sameLiveElement: AXElementIdentity? = nil,
        prepareForeground: @escaping PrepareForeground = { _, _, _ in },
        prepareElement: PrepareElement? = nil
    ) {
        self.lock = lock
        self.store = store
        self.resolve = resolve
        self.observe = observe
        self.validateTarget = validateTarget
        self.sameLiveElement = sameLiveElement ?? liveAXElementsAreIdentical
        self.prepareForeground = prepareForeground
        self.prepareElement = prepareElement ?? { element, context in
            try prepareLiveAXElementMessaging(element, context: context)
        }
    }

    public func snapshot(
        selector: TargetSelector,
        options: TreeOptions,
        context: CommandContext
    ) async throws -> SnapshotResult {
        try context.check()
        return try await lock.withLock(context: context) {
            try context.check()
            try store.sweep(context: context)
            let target = try await resolve(selector, context)
            try context.check()
            let observation = try await observe(target, options, context)
            try context.check()
            let refreshed = try await validateTarget(
                observation.snapshot.target.identity,
                context
            )
            try context.check()
            guard refreshed == target,
                  observation.snapshot.target == refreshed,
                  observation.snapshot.treeOptions == options else {
                throw NativeFailure(
                    "STALE_SNAPSHOT",
                    "Target or traversal evidence changed during snapshot"
                )
            }
            let created = context.wallNow
            let record = SnapshotRecord(
                id: UUID().uuidString.lowercased(),
                createdAt: timestamp(created),
                expiresAt: timestamp(created.addingTimeInterval(snapshotLifetime)),
                target: refreshed,
                treeOptions: options,
                evidence: observation.snapshot.evidence
            )
            try store.writeSnapshot(record, context: context)
            // Durable publication committed; do not check or roll back after return.
            return SnapshotResult(record: record, snapshot: observation.snapshot)
        }
    }

    func withValidatedSnapshotAction<Prepared, Result>(
        snapshotID: String,
        ref: Int,
        context: CommandContext,
        stateChanging: Bool,
        preflight: @escaping Preflight<Prepared>,
        dispatch: @escaping Dispatch<Prepared, Result>
    ) async throws -> Result {
        var dispatchEntered = false
        do {
            try context.check()
            return try await lock.withLock(context: context) {
                try context.check()
                try store.sweep(context: context)
                let record = try store.readSnapshot(id: snapshotID, context: context)
                let recorded = AXTreeSnapshot(
                    target: record.target,
                    treeOptions: record.treeOptions,
                    evidence: record.evidence
                )

                let target = try await validateTarget(record.target.identity, context)
                try context.check()
                guard target == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                let live = try await observe(target, record.treeOptions, context)
                try context.check()
                _ = try Self.validateEvidence(recorded, live: live.snapshot, ref: ref)
                guard let element = live.liveElements[ref] else {
                    throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
                }
                let identityAfterObservation = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityAfterObservation == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }

                try await prepareElement(element, context)
                _ = try await preflight(element, target, context)
                try context.check()
                let identityAfterPreflight = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityAfterPreflight == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }

                if stateChanging {
                    try store.invalidateRecords(
                        for: record.target.identity,
                        context: context
                    )
                }
                try context.check()

                try await prepareForeground(target, element, context)
                try context.check()

                let freshTarget = try await validateTarget(record.target.identity, context)
                try context.check()
                guard freshTarget == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                let freshLive = try await observe(
                    freshTarget,
                    record.treeOptions,
                    context
                )
                try context.check()
                _ = try Self.validateEvidence(
                    recorded,
                    live: freshLive.snapshot,
                    ref: ref
                )
                guard let freshElement = freshLive.liveElements[ref] else {
                    throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
                }
                let identityAfterFreshObservation = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityAfterFreshObservation == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                guard sameLiveElement(element, freshElement) else {
                    throw NativeFailure("STALE_SNAPSHOT", "Live accessibility element was replaced")
                }

                try await prepareElement(freshElement, context)
                let freshlyPrepared = try await preflight(
                    freshElement,
                    freshTarget,
                    context
                )
                try context.check()
                let identityBeforeDispatch = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityBeforeDispatch == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                try await prepareElement(freshElement, context)
                try context.check()

                dispatchEntered = true
                let result = try await dispatch(freshlyPrepared, freshElement, context)
                // Successful dispatch is the action commit; no post-commit check.
                return result
            }
        } catch {
            throw Self.attachingMutationStatus(
                to: error,
                status: dispatchEntered ? .potentiallyApplied : .notStarted
            )
        }
    }

    static func validateEvidence(
        _ recorded: AXTreeSnapshot,
        live: AXTreeSnapshot,
        ref: Int
    ) throws -> AXRefEvidence {
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
            throw NativeFailure(
                "STALE_SNAPSHOT",
                "Snapshot evidence no longer matches the selected window"
            )
        }
        return liveRef
    }

    private static func attachingMutationStatus(
        to error: Error,
        status: MutationStatus
    ) -> NativeFailure {
        let failure = error as? NativeFailure
            ?? NativeFailure("NATIVE_FAILURE", "Native command failed")
        var details = failure.details ?? [:]
        details["mutationStatus"] = .string(status.rawValue)
        return NativeFailure(failure.code, failure.message, details: details)
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
