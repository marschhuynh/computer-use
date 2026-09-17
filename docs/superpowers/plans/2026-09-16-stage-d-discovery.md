# Stage D — Discovery and Useful Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the parsed-but-unimplemented `apps`, `windows`, and `doctor` commands into real read-only native operations with truthful results, and give them human-readable output.

**Architecture:** Reuse the existing `TargetResolver`/`NativeService` seams — `apps` and `windows` are *listing* paths that enumerate without resolving a unique target, `doctor` computes a truthful `ready` from its checks. Nothing in this stage mutates the desktop or touches snapshots/capture.

**Tech Stack:** Swift 5.9 / XCTest, Node 22+ / Vitest, existing `TargetResolver`, `NativeService`, `WireRequest`/`WireReply`, `TargetInventory` fixtures.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` (commands, results/exit codes, doctor contract). **Roadmap slice:** `2026-09-08-standalone-cli-continuation-roadmap.md` Stage D.

## Global Constraints

- `apps`/`windows`/`doctor` are **read-only**: no AX permission requirement to *list*, no state creation/sweep, and **no desktop lock** (doctor must report health even while a snapshot holds the lock — see review finding).
- `apps`/`windows` do **not** require launch identity — listing ≠ selecting. Spec: "listing does not select a target."
- `windows` preserves *every* candidate with `eligible` + `reason`; it never drops or silently selects.
- `doctor` must be truthful: `ready` is computed, not hardcoded; exit code = first failing category.
- Everything is injectable/pure — tests use `TargetInventory` fixtures and injected providers, never live apps or a real lock.
- Preserve floors: request ≤1 MiB, reply ≤16 MiB, `WireReply` envelope shape, JSON/stdout purity.

## File Structure

| File | Responsibility |
|---|---|
| `native/Sources/ComputerUseCore/NativeService.swift` | dispatch `apps`/`windows`/`doctor`; add `listApplications` + `listWindows` + truthful `doctor` |
| `native/Sources/ComputerUseCore/TargetResolver.swift` | expose a candidates+reason listing seam (no uniqueness filter) |
| `native/Tests/ComputerUseCoreTests/DiscoveryTests.swift` | new — pure provider/service tests for all three commands |
| `native/Tests/ComputerUseCoreTests/Fixtures/inventories.json` | add a `discovery-mixed` inventory if needed |
| `contracts/fixtures/native-replies.json` | paired `apps`/`windows`/`doctor` reply fixtures |
| `src/cli/output.ts` | per-command human formatting + control-char escaping |
| `src/cli/run.ts` | real per-command help text |

---

### Task D1: `apps` listing

**Files:**
- Modify: `native/Sources/ComputerUseCore/NativeService.swift` (add `case .apps`)
- Test: `native/Tests/ComputerUseCoreTests/DiscoveryTests.swift`
- Fixture: `contracts/fixtures/native-replies.json`

**Interfaces:**
- Consumes: `WireReply.success(command:data:)`, `JSONValue`, `NativeService.execute(_:context:)`, existing `TargetResolverProvider.listApplications` (`() async throws -> [ProcessMetadata]`).
- Produces: `AppSummary {name,pid,bundleId}` wire shape `{"apps":[{name,pid,bundleId}]}` — matches `projectData` `case 'apps'` in `src/backend/macos.ts`.

- [ ] **Step 1 — write the failing test**

```swift
// DiscoveryTests.swift
final class DiscoveryTests: XCTestCase {
    func testAppsListReturnsAllAppsWithoutResolving() async throws {
        let service = NativeService()
        let request = WireRequest(command: .apps, object: [
            "schemaVersion": 1, "command": "apps",
            "options": ["timeoutMs": 1000, "cursor": "off"]
        ])
        let reply = await service.execute(request, context: discoveryContext())
        XCTAssertTrue(reply.ok)
        guard case let .array(apps) = reply.data?["apps"] else {
            return XCTFail("expected apps array")
        }
        XCTAssertFalse(apps.isEmpty)
        for case let .object(app) in apps {
            XCTAssertNotNil(app["name"])
            XCTAssertNotNil(app["pid"])
            XCTAssertNotNil(app["bundleId"])
        }
    }
}
private func discoveryContext() -> CommandContext {
    CommandContext(timeoutMilliseconds: 1_000, clock: NativeClock(
        monotonicNow: { 0 }, wallNow: { Date(timeIntervalSince1970: 0) },
        sleepNanoseconds: { _ in }))
}
```

- [ ] **Step 2 — run to verify fail**

`swift test --package-path native --filter DiscoveryTests/testAppsList` → FAIL (`UNSUPPORTED_ACTION`).

- [ ] **Step 3 — minimal implementation**

In `NativeService.execute`, add above `default:`:

```swift
case .apps:
    let apps = try await TargetResolver().listApplications(context: context)
    return .success(command: .apps, data: [
        "apps": .array(apps.map { app in .object([
            "name": .string(app.name),
            "pid": .number(Double(app.pid)),
            "bundleId": app.bundleId.map(JSONValue.string) ?? .null,
        ]) })
    ])
```

Add to `TargetResolver` (no uniqueness/eligibility/launch-identity check):

```swift
public func listApplications(context: CommandContext) async throws -> [ProcessMetadata] {
    try context.check()
    return try await provider.listApplications()
}
```

- [ ] **Step 4 — run to verify pass** → PASS.
- [ ] **Step 5 — add `apps` reply fixture** to `contracts/fixtures/native-replies.json`.
- [ ] **Step 6 — commit:** `git add … && git commit -m "feat: implement apps listing"`

---

### Task D2: `windows` listing (preserve candidates + reason)

**Files:**
- Modify: `native/Sources/ComputerUseCore/TargetResolver.swift` (add `listWindows`), `NativeService.swift` (`case .windows`)
- Test: `DiscoveryTests.swift`; Fixture: `inventories.json` `discovery-mixed`

**Interfaces:**
- Consumes: `liveWindows(for:context:) -> [TargetWindow]` (existing, `TargetResolver.swift:348`), `TargetWindow{ax,cg}`.
- Produces: wire shape `{"windows":[{id,title,bounds:{x,y,width,height},eligible,reason}]}` — matches `projectData` `case 'windows'`.

- [ ] **Step 1 — failing test** (inject inventory with on-screen + minimized + off-screen + unmatched):

```swift
func testWindowsListPreservesEveryCandidateWithReason() async throws {
    let inventory = TargetInventory.fixture("discovery-mixed")
    let resolver = TargetResolver(inventory: inventory)
    let windows = try await resolver.listWindows(pid: 42, context: resolverContext())
    XCTAssertEqual(windows.count, inventory.apps[0].windows.count) // none dropped
    XCTAssertTrue(windows.contains { $0.eligible && $0.reason == nil })
    XCTAssertTrue(windows.contains { !$0.eligible && $0.reason != nil })
}
```

- [ ] **Step 2 — run → FAIL** (no `listWindows`).
- [ ] **Step 3 — implement `listWindows`** returning `[WindowSummary]`; `eligible = cg.onScreen && !ax.minimized`, else `reason` ∈ `{"offscreen","minimized","ax-cg-mismatch"}`. Wire `case .windows` in `NativeService` (decode target → resolve app *existence* only → `listWindows`).
- [ ] **Step 4 — run → PASS.**
- [ ] **Step 5 — add `windows` fixture + `discovery-mixed` inventory.**
- [ ] **Step 6 — commit:** `feat: implement windows listing preserving candidates`

---

### Task D3: truthful `doctor` (computed ready + category exit)

**Files:**
- Modify: `native/Sources/ComputerUseCore/NativeService.swift` `doctor()`, `src/cli/output.ts` (doctor exit path)
- Test: `DiscoveryTests.swift`, `tests/cli-output.test.ts` / `tests/cli-run.test.ts`

**Interfaces:**
- Consumes: existing `doctor()` check builders; `exitCode(reply)` `src/cli/output.ts`.
- Produces: `{"ready":Bool,"checks":[{name,status,message}]}`; `ok:false` reply with the failing code when `!ready`.

- [ ] **Step 1 — failing tests**

```swift
func testDoctorReadyIsComputedNotHardcoded() async throws {
    // inject all-ok checks -> ready true; inject a denied check -> ready false
}
```
```ts
it('maps a failing doctor to the failing category exit', () => { /* PERMISSION_DENIED -> 4 */ });
```

- [ ] **Step 2 — run → FAIL** (`ready` hardcoded false; exit always 0).
- [ ] **Step 3 — implement:** `ready = checks.allSatisfy { $0.status == "ok" }`; when `!ready`, return `.failure(command:.doctor, code: <first failing code>, …)` so `exitCode` maps the category. Remove the desktop lock from the `doctor` path (review finding).
- [ ] **Step 4 — run → PASS.**
- [ ] **Step 5 — commit:** `fix: make doctor truthful and lock-free`

---

### Task D4: human output + escaping

**Files:** `src/cli/output.ts`, `src/cli/run.ts` (per-command help); Test: `tests/cli-output.test.ts`.

- [ ] **Step 1 — failing test:** window title containing `\r`/`\x1b[` renders escaped in text mode; JSON mode emits exactly one object, no ANSI.
- [ ] **Step 2 — FAIL → Step 3 — implement** `escapeControl` + per-command formatters + real `--help` bodies.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: per-command human output and escaping`.

## Exit Evidence

- `swift test --package-path native` green incl. `DiscoveryTests`; `npm test` green.
- `contracts/fixtures/native-replies.json` has paired `apps`/`windows`/`doctor` replies.
- One **disclosed** real run: `node dist/cli.js doctor --json` and `node dist/cli.js apps --json` on a live Mac, logged separately from unit tests.

## Carry-forward (next stage consumes)

- `listApplications(context:)` / `listWindows(pid:context:)` and `AppSummary`/`WindowSummary` exist for Stage E+.
- `doctor` is lock-free and truthful — Stage J's package smoke relies on it.
