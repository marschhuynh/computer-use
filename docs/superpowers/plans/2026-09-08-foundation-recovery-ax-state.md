# AX and State Foundation Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the current standalone CLI foundation without discarding useful unfinished work or adding live desktop behavior.

**Architecture:** Preserve the TypeScript CLI/Swift helper split. This volume supplies small reviewed changes under the approved recovery design; the recovery index owns execution order and cross-volume interface amendments.

**Tech Stack:** Node.js 22+, TypeScript, Vitest 3, Swift 5.9+ in Swift v5 mode, macOS 14+, Foundation/AppKit/ApplicationServices, XCTest.

## Global Constraints

- Approved recovery design: `../specs/2026-09-08-foundation-recovery-design.md`; public product spec: `../specs/2026-09-08-standalone-cli-design.md`.
- Execute only in `/Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli`, based on `9b3a6d5` plus the preserved seven unfinished implementation paths.
- Follow `2026-09-08-foundation-recovery.md` for exact inter-volume order. A volume is not permission to skip prerequisites.
- Foreground automation first, macOS only; no daemon, MCP, model execution, private APIs, or implicit target.
- Default deadline is 15 seconds; integer timeout range is 1–120,000 ms inclusive. Cancellation cleanup has a separate 2-second grace period.
- Records expire after 10 minutes. State root is `~/Library/Application Support/nuvin-computer-use/`; directories 0700, files 0600.
- No live apps/windows/doctor/snapshot success, permission prompts, captures, activation, or input during recovery verification. Pure fixtures and injected providers only.
- Do not delete original restored source, discard inherited edits, use `git clean`/`git reset`, or blanket-stage changes. New recovery code may replace obsolete new-CLI internals when the task names them.
- Planning itself makes no implementation edits or commits. During execution, retain the user's prior authorization for baseline/task commits, but inspect only task-owned hunks before each commit; never push, merge, publish, or delete originals implicitly.
- Every reviewable task records RED evidence, focused GREEN evidence, changed files, known limitations, and review verdict. Do not relabel stale binary tests as current-source verification.

---

## Recovery ordering and review boundaries

Execute in this order:

1. **A1a — Pure generic AX read seam and compile recovery**
2. **A1b — Error-aware live AX adapter**
3. **A2 — Shared deterministic AX evidence policy**
4. **A3 — Efficient exact StateStore semantics and timestamps**
5. **A4 — Descriptor-safe filesystem and fail-closed I/O adoption**

A1 is split because restoring the missing pure seam is independently reviewable from replacing live Core Foundation decoding. Do not delete or exclude `AXTrustTests.swift` to obtain a green build.

All commands below run from:

```sh
cd /Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli
```

The worktree begins with inherited edits in `AXTree.swift`, `DesktopLock.swift`, `SnapshotService.swift`, `StateStore.swift`, `SnapshotTests.swift`, and `StateStoreTests.swift`, plus untracked `AXTrustTests.swift`. Never use `git reset`, `git clean`, `git add -A`, `git add .`, or a blanket commit. At each boundary, inspect and stage only the reviewed hunks if commit authorization is separately granted.

---

## Task A1a: Restore compilation with the pure generic AX read seam

**Concern:** Define and test one pure, generic traversal seam. Do not change the live AX adapter in this task.

**Files:**

- Modify `native/Sources/ComputerUseCore/AXTree.swift`
  - anchor: immediately after `TreeOptions`
  - anchor: `public enum AXTree`, immediately after `snapshot(target:options:root:)`
- Complete `native/Tests/ComputerUseCoreTests/AXTrustTests.swift`
  - replace the unfinished file in full; do not delete it

**Consumes:** Existing `TreeOptions`, `AXTreeInputNode`, `AXTree.snapshot`, `AXTreeSnapshot`, `ResolvedTarget`, and `NativeFailure`.

**Produces:**

```swift
enum AXReadResult<Value> {
    case value(Value)
    case unavailable
    case failure
}

struct AXTreeReader<Element> {
    let string: (Element, String) -> AXReadResult<String>
    let bool: (Element, String) -> AXReadResult<Bool>
    let children: (Element) -> AXReadResult<[Element]>
    let actions: (Element) -> AXReadResult<[String]>
    let bounds: (Element) -> AXReadResult<WindowBounds>
}

static func readSnapshot<Element>(
    target: ResolvedTarget,
    options: TreeOptions,
    root: Element,
    reader: AXTreeReader<Element>
) throws -> (snapshot: AXTreeSnapshot, elementsByRef: [Int: Element])
```

The tri-state semantics are fixed:

- `.value(value)` is observed, correctly typed evidence.
- `.unavailable` is accepted only where the caller has already classified a documented absence/unsupported status. Optional scalar evidence becomes `nil`; unavailable child/action collections become empty collections.
- `.failure` always aborts the observation with `STALE_SNAPSHOT`.
- Role is required even when the reader reports `.unavailable`; all other persisted scalar fields remain optional.

### A1a executable steps

- [ ] **2–5 min — Replace the unfinished AX trust test file with complete pure-seam coverage.** Replace all of `native/Tests/ComputerUseCoreTests/AXTrustTests.swift` with:

```swift
import ApplicationServices
import XCTest
@testable import ComputerUseCore

final class AXTrustTests: XCTestCase {
    func testMissingOptionalValuesAndUnsupportedLeafCollectionsRemainTrustworthy() throws {
        let reader = AXTreeReader<Int>(
            string: { element, attribute in
                if attribute == kAXRoleAttribute { return .value(element == 0 ? "AXWindow" : "AXButton") }
                return .unavailable
            },
            bool: { _, _ in .unavailable },
            children: { element in element == 0 ? .value([1]) : .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )

        let result = try AXTree.readSnapshot(
            target: trustTarget(),
            options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
            root: 0,
            reader: reader
        )

        XCTAssertEqual(result.snapshot.evidence.nodes.map(\.role), ["AXWindow", "AXButton"])
        XCTAssertNil(result.snapshot.evidence.nodes[0].title)
        XCTAssertEqual(result.snapshot.evidence.nodes[1].childCount, 0)
        XCTAssertEqual(result.snapshot.evidence.nodes[1].actions, [])
        XCTAssertEqual(result.elementsByRef.keys.sorted(), [1, 2])
        XCTAssertEqual(result.elementsByRef[1], 0)
        XCTAssertEqual(result.elementsByRef[2], 1)
    }

    func testEveryPersistedReadFailureRejectsObservationInsteadOfSerializingFallbackEvidence() {
        for failingRead in axFailureCases {
            XCTAssertThrowsError(
                try AXTree.readSnapshot(
                    target: trustTarget(),
                    options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                    root: 0,
                    reader: failingReader(failingRead)
                ),
                failingRead
            ) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testUnavailableRoleRejectsObservation() {
        let reader = AXTreeReader<Int>(
            string: { _, _ in .unavailable },
            bool: { _, _ in .unavailable },
            children: { _ in .unavailable },
            actions: { _ in .unavailable },
            bounds: { _ in .unavailable }
        )

        XCTAssertThrowsError(
            try AXTree.readSnapshot(
                target: trustTarget(),
                options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                root: 0,
                reader: reader
            )
        ) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }
}

private let axFailureCases = [
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXIdentifierAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXValueAttribute,
    kAXEnabledAttribute,
    kAXFocusedAttribute,
    kAXSelectedAttribute,
    "children",
    "actions",
    "bounds"
]

private func failingReader(_ failingRead: String) -> AXTreeReader<Int> {
    AXTreeReader(
        string: { _, attribute in
            if failingRead == attribute { return .failure }
            if attribute == kAXRoleAttribute { return .value("AXWindow") }
            return .unavailable
        },
        bool: { _, attribute in failingRead == attribute ? .failure : .unavailable },
        children: { _ in failingRead == "children" ? .failure : .unavailable },
        actions: { _ in failingRead == "actions" ? .failure : .unavailable },
        bounds: { _ in failingRead == "bounds" ? .failure : .unavailable }
    )
}

private func trustTarget() -> ResolvedTarget {
    ResolvedTarget(
        identity: TargetIdentity(
            pid: 42,
            launchDate: "2026-09-08T10:00:00Z",
            bundleId: "com.example.Editor",
            windowId: 7
        ),
        title: "Document",
        bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400)
    )
}
```

- [ ] **2–5 min — Run the RED compile check.**

```sh
swift test --package-path native --filter AXTrustTests
```

Expected RED reason: `AXTreeReader` and `AXTree.readSnapshot` are not in scope. This is the known recovery blocker; do not remove `AXTrustTests.swift`.

- [ ] **2–5 min — Add the generic read-result and reader declarations.** In `AXTree.swift`, insert immediately after the closing brace of `TreeOptions`:

```swift
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
```

- [ ] **2–5 min — Add the pure traversal and live-element-by-ref projection.** In `AXTree`, insert immediately after the existing `snapshot(target:options:root:)` function and before `capture(target:options:)`:

```swift
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
```

- [ ] **2–5 min — Run the focused GREEN check.**

```sh
swift test --package-path native --filter AXTrustTests
```

Expected GREEN: all pure seam tests pass. The production `AXTree.capture` is intentionally still on the old adapter until A1b.

- [ ] **2–5 min — Review only this concern.**

```sh
git diff --check
git diff -- native/Sources/ComputerUseCore/AXTree.swift native/Tests/ComputerUseCoreTests/AXTrustTests.swift
git status --short
```

Confirm that `AXTrustTests.swift` remains present and that no live Core Foundation helper was changed in this boundary.

- [ ] **2–5 min — Optional authorized checkpoint only.** If and only if commit authorization is provided, interactively stage only A1a hunks and inspect them before committing:

```sh
git add -p native/Sources/ComputerUseCore/AXTree.swift
git add native/Tests/ComputerUseCoreTests/AXTrustTests.swift
git diff --cached --check
git diff --cached
git commit -m "test: restore pure AX read seam"
```

---

## Task A1b: Route live AX reads through the error-aware adapter

**Concern:** Replace all failure-erasing live reads in `AXTree.capture` with one classified public-AX adapter. Do not alter resolver discovery, process identity, action lifecycle, or add read checkpoints here.

**Files:**

- Modify `native/Sources/ComputerUseCore/AXTree.swift`
  - anchor: `AXTree.capture(target:options:)`
  - anchor: replace `captureNode` and the old file-private `axValue` / `axTypedValue` / `axString` / `axBool` / `axChildren` / `axActions` / `axBounds` block
- Modify `native/Tests/ComputerUseCoreTests/AXTrustTests.swift`
  - anchor: inside `AXTrustTests`, after `testUnavailableRoleRejectsObservation`

**Consumes:** A1a `AXReadResult`, `AXTreeReader`, and `AXTree.readSnapshot`.

**Produces:**

```swift
enum AXReadDisposition: Equatable {
    case value
    case unavailable
    case failure
}

func axReadDisposition(for error: AXError) -> AXReadDisposition
```

Only `.noValue` and `.attributeUnsupported` map to `.unavailable`; `.success` maps to `.value`; every other `AXError` maps to `.failure`. Successful values with a missing value, wrong CF type, malformed array member, wrong `AXValue` subtype, or failed `AXValueGetValue` map to `.failure`.

### A1b executable steps

- [ ] **2–5 min — Add pure tests for status and CF-type classification.** Insert these methods inside `AXTrustTests`, immediately before its closing brace:

```swift
    func testCannotCompleteIsFailureWhileMissingAndUnsupportedAreUnavailable() {
        XCTAssertEqual(axReadDisposition(for: .success), .value)
        XCTAssertEqual(axReadDisposition(for: .cannotComplete), .failure)
        XCTAssertEqual(axReadDisposition(for: .failure), .failure)
        XCTAssertEqual(axReadDisposition(for: .invalidUIElement), .failure)
        XCTAssertEqual(axReadDisposition(for: .apiDisabled), .failure)
        XCTAssertEqual(axReadDisposition(for: .noValue), .unavailable)
        XCTAssertEqual(axReadDisposition(for: .attributeUnsupported), .unavailable)
    }

    func testSuccessfulWrongCFTypeAndMissingValueAreFailures() {
        let number: CFTypeRef = NSNumber(value: 7)
        let wrongType: AXReadResult<String> = axReadResult(
            status: .success,
            value: number,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )
        let missing: AXReadResult<String> = axReadResult(
            status: .success,
            value: nil,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )

        XCTAssertEqual(wrongType, .failure)
        XCTAssertEqual(missing, .failure)
    }

    func testMalformedArrayMemberIsAReadFailure() {
        let values: [AnyObject] = [NSString(string: "AXPress"), NSNumber(value: 7)]
        let decoded: [String]? = decodeAXArray(
            values,
            expectedElementTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )

        XCTAssertNil(decoded)
    }
```

- [ ] **2–5 min — Run the RED adapter check.**

```sh
swift test --package-path native --filter AXTrustTests
```

Expected RED reason: `AXReadDisposition`, `axReadDisposition`, `axReadResult`, and `decodeAXArray` are not defined.

- [ ] **2–5 min — Replace `AXTree.capture` with the generic live-reader path.** Replace only the existing `capture(target:options:)` function with:

```swift
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
```

This intentionally requires observed role, title, and bounds for every candidate AX window used to establish uniqueness. An unreadable candidate makes uniqueness unprovable and fails closed.

- [ ] **2–5 min — Replace the obsolete live capture helper block with the complete classified adapter.** Delete `captureNode` from `AXTree` and delete the old file-private helpers beginning at `private func axValue` through the end of `axBounds`. In their place, after the closing brace of `AXTree`, add:

```swift
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
```

- [ ] **2–5 min — Run focused GREEN checks.**

```sh
swift test --package-path native --filter AXTrustTests
swift test --package-path native --filter SnapshotTests
```

Expected GREEN: the trust tests prove status/type failures are rejected without invoking a desktop; snapshot fixture tests still pass.

- [ ] **2–5 min — Review adapter scope and forbidden regressions.**

```sh
git diff --check
git diff -- native/Sources/ComputerUseCore/AXTree.swift native/Tests/ComputerUseCoreTests/AXTrustTests.swift
git grep -n 'AXUIElementCopyAttributeValue\|AXUIElementCopyActionNames' -- native/Sources/ComputerUseCore/AXTree.swift
git status --short
```

Confirm there is one classified attribute path, one classified action path, no `compactMap` that drops malformed actions, and no unchecked array-element cast before `AXUIElementGetTypeID` validation. Do not add resolver changes or lifecycle/checkpoint parameters.

- [ ] **2–5 min — Optional authorized checkpoint only.**

```sh
git add -p native/Sources/ComputerUseCore/AXTree.swift
git add native/Tests/ComputerUseCoreTests/AXTrustTests.swift
git diff --cached --check
git diff --cached
git commit -m "fix: reject untrustworthy live AX reads"
```

---

## Task A2: Introduce the shared deterministic AX evidence policy

**Concern:** Make one internal policy own canonical refs and structural/truncation validation, including leaf-mode safety when descendants are unobserved.

**Files:**

- Modify `native/Sources/ComputerUseCore/AXTree.swift`
  - anchor: immediately after `AXTreeEvidence`
  - anchor: `AXTree.snapshot(target:options:root:)`
  - anchor: `AXTree.evidence(_:path:)`
  - anchor: remove `AXTree.buildRefs(nodes:boundaries:mode:)`
- Modify `native/Sources/ComputerUseCore/SnapshotService.swift`
  - anchor: `SnapshotService.validateEvidence(_:live:ref:)`
- Modify `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`
  - anchor: after `testTraversalPreservesCustomDepthLimitAndObservedBoundaries`
  - anchor: file-private helpers after `testDirectoryNames`

**Consumes:** A1 trustworthy ordered node production, existing DFS path format, `TreeOptions`, `AXTraversalBoundary`, and `AXRefEvidence`.

**Produces exactly:**

```swift
internal enum AXEvidencePolicy {
    static func deriveRefs(
        nodes: [AXNodeEvidence],
        boundaries: [AXTraversalBoundary],
        mode: HintMode
    ) -> [AXRefEvidence]

    static func validate(_ evidence: AXTreeEvidence, options: TreeOptions) throws
}
```

Policy invariants:

- Refs are dense, ordered, and exactly equal to `deriveRefs` output.
- Every full-mode candidate at or below a truncation boundary is excluded.
- `leafOnly` and `leafCompact` additionally exclude any ancestor of an unobserved subtree, because leaf-most semantics cannot be proven there.
- A fully observed sibling remains eligible.
- Paths are canonical DFS preorder, rooted at `[]`, nonnegative, unique, parent-connected, depth-bounded, and child-index dense.
- Boundaries are exactly the canonical producer boundaries, in producer order. Duplicate, missing, extra, reordered, or field-mismatched boundaries are rejected.
- Work is linear in node count times path depth; there is no complete node-array rescan per node.

### A2 executable steps

- [ ] **2–5 min — Add direct producer and policy tests.** Insert these methods in `SnapshotTests` immediately after `testTraversalPreservesCustomDepthLimitAndObservedBoundaries`:

```swift
    func testProducerRefsRespectDepthBoundaryInEveryHintMode() throws {
        let target = try treeFixture("save-cancel").target
        let input = truncationPolicyInput()
        let expected: [HintMode: [[Int]]] = [
            .full: [[], [1]],
            .leafOnly: [[1]],
            .leafCompact: [[1]]
        ]

        for mode in [HintMode.full, .leafOnly, .leafCompact] {
            let options = TreeOptions(maxDepth: 1, maxElements: 20, hintMode: mode)
            let snapshot = AXTree.snapshot(target: target, options: options, root: input)

            XCTAssertEqual(snapshot.evidence.truncation, [
                AXTraversalBoundary(
                    path: [0],
                    reason: .maxDepth,
                    observedChildren: 0,
                    totalChildren: 1
                )
            ], mode.rawValue)
            XCTAssertEqual(snapshot.evidence.refs.map(\.path), expected[mode], mode.rawValue)
            XCTAssertNoThrow(try AXEvidencePolicy.validate(snapshot.evidence, options: options), mode.rawValue)
        }
    }

    func testRootMaxElementsBoundaryProducesNoRefsInEveryHintMode() throws {
        let target = try treeFixture("save-cancel").target
        let input = truncationPolicyInput()

        for mode in [HintMode.full, .leafOnly, .leafCompact] {
            let options = TreeOptions(maxDepth: 8, maxElements: 2, hintMode: mode)
            let snapshot = AXTree.snapshot(target: target, options: options, root: input)

            XCTAssertEqual(snapshot.evidence.truncation, [
                AXTraversalBoundary(
                    path: [0],
                    reason: .maxElements,
                    observedChildren: 0,
                    totalChildren: 1
                ),
                AXTraversalBoundary(
                    path: [],
                    reason: .maxElements,
                    observedChildren: 1,
                    totalChildren: 2
                )
            ], mode.rawValue)
            XCTAssertEqual(snapshot.evidence.refs, [], mode.rawValue)
            XCTAssertNoThrow(try AXEvidencePolicy.validate(snapshot.evidence, options: options), mode.rawValue)
        }
    }

    func testEvidencePolicyRejectsDuplicateBoundariesAndModeIncoherentRefs() throws {
        let target = try treeFixture("save-cancel").target
        let truncatedOptions = TreeOptions(maxDepth: 8, maxElements: 2, hintMode: .full)
        let truncated = AXTree.snapshot(target: target, options: truncatedOptions, root: truncationPolicyInput())
        let firstBoundary = try XCTUnwrap(truncated.evidence.truncation.first)
        let duplicateBoundaryEvidence = AXTreeEvidence(
            nodes: truncated.evidence.nodes,
            truncation: [firstBoundary, firstBoundary],
            refs: truncated.evidence.refs
        )

        XCTAssertThrowsError(try AXEvidencePolicy.validate(duplicateBoundaryEvidence, options: truncatedOptions)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }

        let completeOptions = TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full)
        let complete = AXTree.snapshot(
            target: target,
            options: completeOptions,
            root: AXTreeInputNode(role: "AXWindow")
        )
        let missingRefEvidence = AXTreeEvidence(
            nodes: complete.evidence.nodes,
            truncation: complete.evidence.truncation,
            refs: []
        )

        XCTAssertThrowsError(try AXEvidencePolicy.validate(missingRefEvidence, options: completeOptions)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }
```

Then append this complete helper after the existing `testDirectoryNames` helper:

```swift
private func truncationPolicyInput() -> AXTreeInputNode {
    AXTreeInputNode(
        role: "AXWindow",
        actions: ["AXRaise"],
        children: [
            AXTreeInputNode(
                role: "AXGroup",
                actions: ["AXPress"],
                children: [
                    AXTreeInputNode(role: "AXButton", title: "Deep", actions: ["AXPress"])
                ]
            ),
            AXTreeInputNode(role: "AXButton", title: "Safe sibling", actions: ["AXPress"])
        ]
    )
}
```

- [ ] **2–5 min — Run the RED policy check.**

```sh
swift test --package-path native --filter SnapshotTests
```

Expected RED reason: `AXEvidencePolicy` is missing. Independently, the inherited `buildRefs` implementation would incorrectly expose the actionable root in leaf modes when `[0]` is truncated.

- [ ] **2–5 min — Add the exact shared policy.** Insert immediately after `AXTreeEvidence` in `AXTree.swift`:

```swift
internal enum AXEvidencePolicy {
    static func deriveRefs(
        nodes: [AXNodeEvidence],
        boundaries: [AXTraversalBoundary],
        mode: HintMode
    ) -> [AXRefEvidence] {
        let boundaryPaths = Set(boundaries.map(\.path))
        var boundaryAncestorPaths = Set<[Int]>()
        for boundary in boundaries {
            for length in 0..<boundary.path.count {
                boundaryAncestorPaths.insert(Array(boundary.path.prefix(length)))
            }
        }

        var actionableAncestorPaths = Set<[Int]>()
        for node in nodes where !node.actions.isEmpty {
            for length in 0..<node.path.count {
                actionableAncestorPaths.insert(Array(node.path.prefix(length)))
            }
        }

        let selected = nodes.filter { node in
            let atOrBelowBoundary = (0...node.path.count).contains { length in
                boundaryPaths.contains(Array(node.path.prefix(length)))
            }
            guard !atOrBelowBoundary else { return false }

            switch mode {
            case .full:
                return true
            case .leafOnly, .leafCompact:
                guard !boundaryAncestorPaths.contains(node.path) else { return false }
                let editable = node.role == "AXTextArea" || node.role == "AXWebArea"
                return editable || (!node.actions.isEmpty && !actionableAncestorPaths.contains(node.path))
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
```

- [ ] **2–5 min — Make the producer use the policy and normalize action evidence.** In `AXTree.snapshot`, replace:

```swift
        let refs = buildRefs(nodes: nodes, boundaries: boundaries, mode: options.hintMode)
```

with:

```swift
        let refs = AXEvidencePolicy.deriveRefs(
            nodes: nodes,
            boundaries: boundaries,
            mode: options.hintMode
        )
```

In `AXTree.evidence(_:path:)`, replace the `actions:` assignment with:

```swift
            actions: Array(Set(input.actions)).sorted(),
```

Delete the complete obsolete `private static func buildRefs(nodes:boundaries:mode:)` function. No replacement wrapper should remain; production and validation must call the shared exact API directly.

- [ ] **2–5 min — Make snapshot comparison reject malformed producer or persisted evidence through the same policy.** Replace `SnapshotService.validateEvidence(_:live:ref:)` with:

```swift
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
```

- [ ] **2–5 min — Run focused GREEN checks.**

```sh
swift test --package-path native --filter SnapshotTests
swift test --package-path native --filter AXTrustTests
```

Expected GREEN: direct producer tests prove full and leaf truncation behavior; duplicate boundaries and mode-incoherent refs are rejected; AX trust tests remain green.

- [ ] **2–5 min — Review shared-policy ownership.**

```sh
git diff --check
git grep -n 'buildRefs\|deriveRefs\|AXEvidencePolicy.validate' -- native/Sources native/Tests
git diff -- native/Sources/ComputerUseCore/AXTree.swift native/Sources/ComputerUseCore/SnapshotService.swift native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git status --short
```

Confirm that `AXTree` is the only ref producer, `AXEvidencePolicy.deriveRefs` is the only ref-selection algorithm, and no leaf-mode boundary predicate remains elsewhere.

- [ ] **2–5 min — Optional authorized checkpoint only.**

```sh
git add -p native/Sources/ComputerUseCore/AXTree.swift native/Sources/ComputerUseCore/SnapshotService.swift native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --cached --check
git diff --cached
git commit -m "fix: centralize AX evidence policy"
```

---

## Task A3: Finish StateStore semantic validation and exact timestamp grammar

**Concern:** Replace duplicated quadratic tree validation with `AXEvidencePolicy.validate`, and make the accepted timestamp grammar exact without changing the ten-minute lifetime or expiry boundary.

**Files:**

- Modify `native/Sources/ComputerUseCore/StateStore.swift`
  - anchor: `parseSnapshotTimestamp(_:)`
  - anchor: `validateRecord(_:expectedID:)`
- Modify `native/Tests/ComputerUseCoreTests/StateStoreTests.swift`
  - anchor: replace `testWriteRejectsEveryMalformedSemanticRecordClass`
  - anchor: after `testLifetimeMustBeExactlyTenMinutes`
  - anchor: after `stateNode(path:role:title:bounds:childCount:)`

**Consumes:** Exact A2 `AXEvidencePolicy.validate(_:options:)`; current snapshot-specific `writeSnapshot`, `readSnapshot`, `sweep`, and `invalidateRecords` APIs; current exact integral second/nanosecond lifetime representation.

**Produces:**

- One state-record semantic gate that delegates all AX path/boundary/ref semantics to the shared policy.
- O(node count × path depth) semantic validation instead of Θ(node count²).
- Accepted timestamps are UTC `Z` timestamps with exactly `yyyy-MM-dd'T'HH:mm:ss`, optionally followed by `.` and **1 through 9 ASCII digits**.
- No fraction, 1–9 digit fractions, and exact ten-minute matching fractions remain accepted.
- Empty, non-ASCII, overlong, lowercase-`z`, or offset fractions/forms are rejected.
- `now == expiresAt` remains expired.

### A3 executable steps

- [ ] **2–5 min — Expand malformed semantic record tests to exact-policy cases.** Replace the complete `testWriteRejectsEveryMalformedSemanticRecordClass` method in `StateStoreTests` with:

```swift
    func testWriteRejectsEveryMalformedSemanticRecordClass() throws {
        let target = resolvedTarget()
        let rootNode = stateNode(
            path: [],
            role: "AXWindow",
            title: target.title,
            bounds: target.bounds,
            childCount: 0
        )
        let validEvidence = AXTreeEvidence(
            nodes: [rootNode],
            truncation: [],
            refs: [AXRefEvidence(ref: 1, path: [], node: rootNode)]
        )
        let childZero = stateNode(path: [0], role: "AXButton", childCount: 0)
        let childOne = stateNode(path: [1], role: "AXButton", childCount: 0)
        let parent = stateNode(path: [], role: "AXWindow", childCount: 2)
        let wrongRefNode = stateNode(path: [], role: "AXButton", childCount: 0)
        let twoNodeParent = stateNode(path: [], role: "AXWindow", childCount: 1)
        let twoNodeEvidence = AXTreeEvidence(
            nodes: [twoNodeParent, childZero],
            truncation: [],
            refs: [
                AXRefEvidence(ref: 1, path: [], node: twoNodeParent),
                AXRefEvidence(ref: 2, path: [0], node: childZero)
            ]
        )
        let truncatedOptions = TreeOptions(maxDepth: 8, maxElements: 2, hintMode: .full)
        let truncated = AXTree.snapshot(
            target: target,
            options: truncatedOptions,
            root: stateTruncationInput()
        )
        let firstBoundary = try XCTUnwrap(truncated.evidence.truncation.first)

        let cases: [(String, SnapshotRecord)] = [
            ("target IDs", snapshotRecord(target: resolvedTarget(pid: 0), evidence: validEvidence)),
            ("tree options", snapshotRecord(
                treeOptions: TreeOptions(maxDepth: 0, maxElements: 500, hintMode: .full),
                evidence: validEvidence
            )),
            ("negative counts", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [stateNode(path: [], role: "AXWindow", childCount: -1)],
                truncation: [],
                refs: []
            ))),
            ("unordered paths", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [parent, childOne, childZero],
                truncation: [],
                refs: []
            ))),
            ("duplicate paths", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [parent, childZero, childZero],
                truncation: [],
                refs: []
            ))),
            ("non-dense refs", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [],
                refs: [AXRefEvidence(ref: 2, path: [], node: rootNode)]
            ))),
            ("mismatched ref evidence", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [],
                refs: [AXRefEvidence(ref: 1, path: [], node: wrongRefNode)]
            ))),
            ("full mode missing refs", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [],
                refs: []
            ))),
            ("leaf mode unexpected ref", snapshotRecord(
                treeOptions: TreeOptions(maxDepth: 8, maxElements: 500, hintMode: .leafOnly),
                evidence: validEvidence
            )),
            ("reordered refs", snapshotRecord(evidence: AXTreeEvidence(
                nodes: twoNodeEvidence.nodes,
                truncation: [],
                refs: [twoNodeEvidence.refs[1], twoNodeEvidence.refs[0]]
            ))),
            ("duplicate boundaries", snapshotRecord(
                treeOptions: truncatedOptions,
                evidence: AXTreeEvidence(
                    nodes: truncated.evidence.nodes,
                    truncation: [firstBoundary, firstBoundary],
                    refs: truncated.evidence.refs
                )
            )),
            ("illegal truncation", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [AXTraversalBoundary(
                    path: [],
                    reason: .maxDepth,
                    observedChildren: 1,
                    totalChildren: 0
                )],
                refs: []
            )))
        ]

        for (name, record) in cases {
            let root = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try StateStore(rootURL: root).writeSnapshot(record), name) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }
```

- [ ] **2–5 min — Add strict timestamp and large-valid-tree tests.** Insert these methods in `StateStoreTests` immediately after `testLifetimeMustBeExactlyTenMinutes`:

```swift
    func testTimestampGrammarRejectsMalformedUTCForms() {
        let malformed = [
            "2999-01-01T00:00:00.Z",
            "2999-01-01T00:00:00.١Z",
            "2999-01-01T00:00:00.1234567890Z",
            "2999-01-01T00:00:00z",
            "2999-01-01T00:00:00+00:00"
        ]

        for value in malformed {
            let root = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try StateStore(rootURL: root).writeSnapshot(snapshotRecord(
                createdAt: value,
                expiresAt: "2999-01-01T00:10:00Z"
            )), value) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testLargeValidEvidenceRoundTripsWithoutChangingPolicy() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let childCount = 10_000
        let options = TreeOptions(
            maxDepth: 8,
            maxElements: childCount + 1,
            hintMode: .full
        )
        let evidence = wideEvidence(childCount: childCount, mode: options.hintMode)
        let record = snapshotRecord(treeOptions: options, evidence: evidence)
        let store = StateStore(rootURL: root)

        XCTAssertNoThrow(try store.writeSnapshot(record))
        XCTAssertEqual(try store.readSnapshot(id: record.id), record)
    }
```

Append these complete helpers immediately after `stateNode(path:role:title:bounds:childCount:)`:

```swift
private func stateTruncationInput() -> AXTreeInputNode {
    AXTreeInputNode(
        role: "AXWindow",
        children: [
            AXTreeInputNode(
                role: "AXGroup",
                children: [AXTreeInputNode(role: "AXButton")]
            ),
            AXTreeInputNode(role: "AXButton")
        ]
    )
}

private func wideEvidence(childCount: Int, mode: HintMode) -> AXTreeEvidence {
    let root = stateNode(path: [], role: "AXWindow", childCount: childCount)
    let children = (0..<childCount).map {
        stateNode(path: [$0], role: "AXButton", childCount: 0)
    }
    let nodes = [root] + children
    return AXTreeEvidence(
        nodes: nodes,
        truncation: [],
        refs: AXEvidencePolicy.deriveRefs(nodes: nodes, boundaries: [], mode: mode)
    )
}
```

- [ ] **2–5 min — Run the RED state checks.**

```sh
swift test --package-path native --filter StateStoreTests
```

Expected RED reasons on the inherited implementation:

1. `2026-09-08T10:00:00.Z` and the non-ASCII fraction are accepted by `parseSnapshotTimestamp`.
2. A full-mode record with missing refs and a leaf-mode record with impossible refs pass the local-only ref checks.
3. Duplicate boundary membership can pass the count/contains comparison.
The 10,001-node fixture is a round-trip characterization case, not behavioral RED proof of asymptotic complexity. It may pass on both implementations. Review the indexed implementation structurally to ensure it does not scan all nodes once per node; do not add hardware-dependent timing assertions or claim the round-trip alone proves linear complexity.

- [ ] **2–5 min — Replace timestamp parsing with strict ASCII fractional grammar.** Replace the complete `parseSnapshotTimestamp(_:)` function with:

```swift
private func parseSnapshotTimestamp(_ value: String) -> SnapshotTimestamp? {
    guard value.hasSuffix("Z") else { return nil }
    let body = String(value.dropLast())
    let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count <= 2, parts[0].count == 19 else { return nil }

    let fraction: String
    if parts.count == 2 {
        fraction = String(parts[1])
        guard (1...9).contains(fraction.utf8.count),
              fraction.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    } else {
        fraction = ""
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: String(parts[0])) else { return nil }

    let padded = fraction.padding(toLength: 9, withPad: "0", startingAt: 0)
    guard let nanoseconds = Int(padded) else { return nil }
    return SnapshotTimestamp(
        seconds: Int64(date.timeIntervalSince1970),
        nanoseconds: nanoseconds
    )
}
```

- [ ] **2–5 min — Replace quadratic/local AX validation with the shared policy.** Replace the complete `validateRecord(_:expectedID:)` function with:

```swift
private func validateRecord(_ record: SnapshotRecord, expectedID: String) -> Bool {
    guard canonicalUUID(record.id) == record.id,
          record.id == expectedID,
          record.version == stateRecordVersion,
          record.kind == "snapshot",
          validLifetime(record),
          validPositiveSafe(record.target.identity.pid),
          validPositiveSafe(record.target.identity.windowId),
          validBounds(record.target.bounds) else { return false }

    do {
        try AXEvidencePolicy.validate(record.evidence, options: record.treeOptions)
        return true
    } catch {
        return false
    }
}
```

The existing `validPositiveSafe(_:)` and `validBounds(_:)` remain by exact symbol name for target-level validation. Do not duplicate AX node/path/ref validation in `StateStore`.

- [ ] **2–5 min — Run focused GREEN checks.**

```sh
swift test --package-path native --filter StateStoreTests
swift test --package-path native --filter SnapshotTests
```

Expected GREEN: malformed semantic/timestamp cases are stale; the large record round-trips; exact ten-minute and exact-expiry tests remain green.

- [ ] **2–5 min — Review complexity and exactness.**

```sh
git diff --check
git grep -n 'compactMap.*candidate\|expectedBoundaries.contains\|AXEvidencePolicy.validate' -- native/Sources/ComputerUseCore/StateStore.swift native/Sources/ComputerUseCore/AXTree.swift
git diff -- native/Sources/ComputerUseCore/StateStore.swift native/Tests/ComputerUseCoreTests/StateStoreTests.swift
git status --short
```

Confirm there is no full-node scan inside another node loop, refs are compared exactly through A2, and timestamp fractions do not use `Character.isNumber` or `Int(...) ?? 0`.

- [ ] **2–5 min — Optional authorized checkpoint only.**

```sh
git add -p native/Sources/ComputerUseCore/StateStore.swift native/Tests/ComputerUseCoreTests/StateStoreTests.swift
git diff --cached --check
git diff --cached
git commit -m "fix: validate snapshot state exactly"
```

---

## Task A4: Verify and adopt descriptor-safe filesystem and fail-closed invalidation changes

**Concern:** Retain the inherited descriptor-relative/root-hardening behavior and prove injected write/sync/rename failures cannot fall through to action dispatch. This task does not redesign lock cancellation or state recovery policy.

**Files:**

- Verify inherited changes in `native/Sources/ComputerUseCore/DesktopLock.swift`
  - anchors: `SystemCallResult`, `DesktopLock.withLock(deadline:_:)`, `PrivateStateDirectory.openRoot`
- Modify `native/Sources/ComputerUseCore/StateStore.swift`
  - anchors: `StateStoreIO`
  - anchors: write/sync/rename calls inside `atomicWrite(_:named:directoryDescriptor:replacing:)`
- Modify `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`
  - anchor: after `testEnumerationFailureAfterPreflightPreventsDispatch`
  - anchor: helpers after `truncationPolicyInput`
- Verify inherited tests in `native/Tests/ComputerUseCoreTests/StateStoreTests.swift`
  - anchors: `testInvalidationFailsClosedForUnreadableRecognizedRecord`
  - `testRecordOpenAndReadRetryEINTR`
  - `testTransientReadFailureCannotBeSkippedDuringInvalidation`
  - `testRootSymlinkAndPathSwapNeverChmodUnrelatedObject`
  - `testSuccessfulFlockAtDeadlineIsReleasedWithoutRunningBody`
  - `testEINTRRetryChecksDeadlineBeforeAnotherFlockAttempt`

**Consumes:** Current descriptor-held root/record operations, `SystemCallResult`, fail-closed `invalidateRecords`, and `SnapshotService` preflight-before-invalidate-before-dispatch order.

**Produces:**

- Test-only injection for record write, descriptor sync, and rename syscall results.
- Invalidation write, file-sync, rename, and directory-sync failures all throw before dispatch.
- Failures before rename preserve the valid record; a directory-sync failure after rename leaves the record conservatively invalidated and still suppresses dispatch.
- Existing owner-only modes remain 0700 directories / 0600 files.
- Existing final-component `O_NOFOLLOW`, opened-descriptor verification, opened-descriptor `fchmod`, fd-held `flock`, post-acquisition deadline release, and EINTR retry behavior are retained.

### A4 executable steps

- [ ] **2–5 min — Add injected publication-failure tests.** Insert this method in `SnapshotTests` immediately after `testEnumerationFailureAfterPreflightPreventsDispatch`:

```swift
    func testEveryInvalidationPublicationFailurePreventsDispatch() throws {
        for failure in InvalidationIOFailure.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try treeFixture("save-cancel")
            let now = Date(timeIntervalSince1970: 1_788_861_900)
            let record = SnapshotRecord(
                id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                createdAt: "2026-09-08T10:00:00Z",
                expiresAt: "2026-09-08T10:10:00Z",
                target: snapshot.target,
                treeOptions: snapshot.treeOptions,
                evidence: snapshot.evidence
            )
            try StateStore(rootURL: root, now: { now }).writeSnapshot(record)

            let store = StateStore(
                rootURL: root,
                now: { now },
                io: failingInvalidationIO(failure)
            )
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root),
                store: store,
                observe: { _, _ in
                    AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
                },
                validateTarget: { _ in snapshot.target },
                now: { now }
            )
            var preflightRan = false
            var dispatchRan = false

            XCTAssertThrowsError(try service.withValidatedSnapshotAction(
                snapshotID: record.id,
                ref: 2,
                timeoutMilliseconds: 1_000,
                stateChanging: true,
                preflight: { _, _ in
                    preflightRan = true
                },
                dispatch: { _ in
                    dispatchRan = true
                }
            ), failure.rawValue)
            XCTAssertTrue(preflightRan, failure.rawValue)
            XCTAssertFalse(dispatchRan, failure.rawValue)

            let remainsValid = (try? StateStore(rootURL: root, now: { now }).readSnapshot(id: record.id)) != nil
            XCTAssertEqual(remainsValid, failure != .directorySync, failure.rawValue)
        }
    }
```

Append these complete helpers after `truncationPolicyInput`:

```swift
private enum InvalidationIOFailure: String, CaseIterable {
    case write
    case fileSync
    case rename
    case directorySync
}

private func failingInvalidationIO(_ failure: InvalidationIOFailure) -> StateStoreIO {
    var directorySyncCalls = 0
    return StateStoreIO(
        write: { descriptor, buffer, count in
            if failure == .write { return SystemCallResult(value: -1, error: EIO) }
            let value = Darwin.write(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        sync: { descriptor in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                return SystemCallResult(value: -1, error: errno)
            }
            let fileType = info.st_mode & S_IFMT
            if fileType == S_IFREG && failure == .fileSync {
                return SystemCallResult(value: -1, error: EIO)
            }
            if fileType == S_IFDIR {
                directorySyncCalls += 1
                if failure == .directorySync && directorySyncCalls == 1 {
                    return SystemCallResult(value: -1, error: EIO)
                }
            }
            let value = fsync(descriptor)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        renameRecord: { oldDirectory, oldName, newDirectory, newName in
            if failure == .rename { return SystemCallResult(value: -1, error: EIO) }
            let value = renameat(oldDirectory, oldName, newDirectory, newName)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        }
    )
}
```

- [ ] **2–5 min — Run the RED injected-I/O check.**

```sh
swift test --package-path native --filter SnapshotTests/testEveryInvalidationPublicationFailurePreventsDispatch
```

Expected RED reason: `StateStoreIO` does not accept `write`, `sync`, or `renameRecord` injections. This is a deterministic seam failure, not a live filesystem fault injection.

- [ ] **2–5 min — Extend `StateStoreIO` with exact syscall-boundary results.** Replace the complete `StateStoreIO` declaration with:

```swift
struct StateStoreIO {
    let directoryNames: (Int32) throws -> [String]
    let openRecord: (Int32, String) -> SystemCallResult<Int32>
    let read: (Int32, UnsafeMutableRawPointer?, Int) -> SystemCallResult<Int>
    let write: (Int32, UnsafeRawPointer?, Int) -> SystemCallResult<Int>
    let sync: (Int32) -> SystemCallResult<Int32>
    let renameRecord: (Int32, String, Int32, String) -> SystemCallResult<Int32>

    init(
        directoryNames: @escaping (Int32) throws -> [String] = liveDirectoryNames,
        openRecord: @escaping (Int32, String) -> SystemCallResult<Int32> = { directory, name in
            let value = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        read: @escaping (Int32, UnsafeMutableRawPointer?, Int) -> SystemCallResult<Int> = { descriptor, buffer, count in
            let value = Darwin.read(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        write: @escaping (Int32, UnsafeRawPointer?, Int) -> SystemCallResult<Int> = { descriptor, buffer, count in
            let value = Darwin.write(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        sync: @escaping (Int32) -> SystemCallResult<Int32> = { descriptor in
            let value = fsync(descriptor)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        renameRecord: @escaping (Int32, String, Int32, String) -> SystemCallResult<Int32> = {
            oldDirectory, oldName, newDirectory, newName in
            let value = renameat(oldDirectory, oldName, newDirectory, newName)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        }
    ) {
        self.directoryNames = directoryNames
        self.openRecord = openRecord
        self.read = read
        self.write = write
        self.sync = sync
        self.renameRecord = renameRecord
    }
}
```

- [ ] **2–5 min — Route atomic publication through the injected syscall seams without changing ordering.** Inside `atomicWrite(_:named:directoryDescriptor:replacing:)`, replace the complete `wroteAll` block with:

```swift
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = io.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                if result.value < 0 && result.error == EINTR { continue }
                if result.value <= 0 { return false }
                offset += result.value
            }
            return true
        }
```

Then replace the write/sync/rename/sync guards immediately following that block with:

```swift
        guard wroteAll else {
            throw stateFailure("Unable to write snapshot state")
        }
        let fileSync = io.sync(descriptor)
        guard fileSync.value == 0 else {
            throw stateFailure("Unable to write snapshot state")
        }
        let renamed = io.renameRecord(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            name
        )
        guard renamed.value == 0 else {
            throw stateFailure("Unable to publish snapshot state")
        }
        shouldRemoveTemporary = false
        let directorySync = io.sync(directoryDescriptor)
        guard directorySync.value == 0 else {
            throw stateFailure("Unable to synchronize snapshot state")
        }
```

Do not add rollback after rename. Once the invalidated record has replaced the old record, a later directory-sync error must remain conservatively invalidated while dispatch is suppressed.

- [ ] **2–5 min — Run the focused GREEN I/O checks.**

```sh
swift test --package-path native --filter SnapshotTests/testEveryInvalidationPublicationFailurePreventsDispatch
swift test --package-path native --filter SnapshotTests/testInvalidationFailurePreventsActionDispatch
swift test --package-path native --filter SnapshotTests/testEnumerationFailureAfterPreflightPreventsDispatch
swift test --package-path native --filter StateStoreTests/testTransientReadFailureCannotBeSkippedDuringInvalidation
swift test --package-path native --filter StateStoreTests/testRecordOpenAndReadRetryEINTR
```

Expected GREEN: all injected failures throw; no dispatch occurs; pre-rename failures preserve the record; directory-sync failure leaves it invalidated.

- [ ] **2–5 min — Verify inherited descriptor and lock hardening without rewriting it.**

```sh
swift test --package-path native --filter StateStoreTests/testRootSymlinkAndPathSwapNeverChmodUnrelatedObject
swift test --package-path native --filter StateStoreTests/testSnapshotRoundTripUsesPrivateModesAndAtomicName
swift test --package-path native --filter DesktopLockTests/testSuccessfulFlockAtDeadlineIsReleasedWithoutRunningBody
swift test --package-path native --filter DesktopLockTests/testEINTRRetryChecksDeadlineBeforeAnotherFlockAttempt
```

Expected GREEN proves the inherited candidate behavior:

- final root symlinks are rejected;
- post-open path replacement cannot redirect `fchmod`;
- directory/file modes remain 0700/0600;
- a lock acquired at the deadline is explicitly unlocked and the body does not run;
- EINTR returns to the deadline gate before another lock attempt.

- [ ] **2–5 min — Run the complete non-live recovery verification.**

```sh
swift test --package-path native
npm run typecheck
npm test
```

Expected GREEN: current-source Swift compiles with `AXTrustTests` included; all pure Swift tests pass; TypeScript remains unchanged and green. This is not live Accessibility, discovery, capture, permission, or input acceptance.

- [ ] **2–5 min — Inspect the complete inherited-plus-recovery diff.**

```sh
git diff --check
git status --short
git diff -- native/Sources/ComputerUseCore/DesktopLock.swift native/Sources/ComputerUseCore/StateStore.swift native/Sources/ComputerUseCore/SnapshotService.swift native/Tests/ComputerUseCoreTests/StateStoreTests.swift native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --stat
```

Review specifically that:

1. `PrivateStateDirectory.openRoot` performs `open(...O_NOFOLLOW)`, descriptor verification, and `fchmod` on that same descriptor.
2. `invalidateRecords` throws for every recognized record it cannot open, read, decode, or semantically validate; no `try?` remains in that path.
3. `atomicWrite` remains temp-create → 0600/verify → complete write → file sync → rename → directory sync.
4. `SnapshotService` never calls dispatch if invalidation throws.
5. Unrelated dirty files/hunks remain unstaged.

- [ ] **2–5 min — Optional authorized checkpoint only.** Because this boundary adopts inherited dirty work, stage interactively by reviewed hunk and inspect the index; never blanket-stage:

```sh
git add -p native/Sources/ComputerUseCore/DesktopLock.swift native/Sources/ComputerUseCore/StateStore.swift native/Sources/ComputerUseCore/SnapshotService.swift native/Tests/ComputerUseCoreTests/StateStoreTests.swift native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --cached --check
git diff --cached
git status --short
git commit -m "fix: fail closed on snapshot state I/O"
```

If any inherited hunk cannot be attributed to the verified descriptor/invalidation behavior, leave it unstaged and surface it for separate review.

---

## A-series completion gate

The A-series is complete only when all of the following are true:

- `AXTrustTests.swift` remains in the test target and current-source Swift compiles.
- Generic fixture reads and the live adapter share `AXTree.readSnapshot`.
- Hard AX status/type/array/value failures cannot become evidence.
- `AXEvidencePolicy.deriveRefs(nodes:boundaries:mode:)` is the only ref-selection implementation.
- `AXEvidencePolicy.validate(_:options:)` rejects malformed paths, noncanonical boundaries, unsafe leaf/full refs, and non-exact refs.
- StateStore invokes the shared policy once per record and no longer performs a complete node scan per node.
- Exact timestamp grammar, exact ten-minute lifetime, and `now >= expiresAt` rejection are tested.
- Descriptor-safe root handling and fail-closed invalidation remain present and pass deterministic I/O failure tests.
- Full Swift, TypeScript typecheck, and TypeScript unit suites are green without a live desktop invocation.
- Dirty inherited work is preserved, reviewed by hunk, and not blanket-staged.

---

