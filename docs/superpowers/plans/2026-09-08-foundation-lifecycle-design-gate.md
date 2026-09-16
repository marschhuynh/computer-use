# Native Lifecycle and Identity — Required Next-Plan Gate

**Status:** Explicitly gated by user decision on 2026-09-08. This document is a design/planning brief, **not an executable implementation plan**. No incomplete async migration is authorized by it.

**Entry:** All nine A/C tasks in `2026-09-08-foundation-recovery.md` are reviewed and the bounded repair gate passes. Re-read the resulting source and shared fixtures. Do not apply the abandoned `.superpowers/replan/lifecycle-*-draft.md` documents: their migration steps are incomplete.

**Why a separate gate:** Async ownership affects the lock, snapshot service, host completion state machine, live resolver, and their tests. Freezing a speculative multi-file migration before the AX/state/protocol repair lands repeats the original plan's sizing mistake. The user explicitly chose this gate over expanding the current plan into another oversized patch.

## 1. Requirements that remain unresolved after A/C

| Invariant | Current owning evidence | Required next-plan outcome |
|---|---|---|
| Parent loss reaches active work | `HostMain.swift:24-28`, `HostSupport.swift:124-147` | Cancellation reaches context and resource-owning worker; shutdown waits for cleanup; no parent-loss reply. |
| AppKit run loop stays serviceable | `NativeService.swift:14-35`, `DesktopLock.swift:54-79` | Lock suspension and state/AX work do not synchronously block main; only AppKit-owned operations hop to main. |
| One native deadline | `SnapshotService.swift:48-71,74-99` | One monotonic context created on accepted request and reused by every phase; no resetting time after lock or input. |
| No post-deadline dispatch | `SnapshotService.swift:93-99` | Check after invalidation, foreground preparation, fresh observation, immediately before dispatch, and before accepting completion. |
| Correct selected-window identity | `AXTree.swift:152-171`, `TargetResolver.swift:71-121` | Query only selected PID, retain reliable process-start precision, revalidate public window ID/title/bounds after AX read and preflight. |
| Safe preflight/invalidation/refresh ordering | `SnapshotService.withValidatedSnapshotAction` | Read-only capability preflight precedes invalidation; foreground preparation follows invalidation; dispatch receives a newly revalidated live handle. |

Line numbers describe the planning baseline; use symbol anchors after A/C changes. These are not repaired merely because the nine-task gate is green.

## 2. Design decisions already approved

- Keep public CLI syntax, `schemaVersion: 1`, Node 22+/macOS 14+/Swift 5.9/v5, 15,000 ms default / 1–120,000 ms timeout range and two-second Node cleanup grace.
- Use one `CommandContext` with an absolute monotonic deadline and cancellation. Wall time is separate and used only for record timestamps/expiry.
- `DesktopLock` remains fd-held `flock`; no PID-file recovery, unlink, or independent TypeScript lock. Asynchronous wait is clamped to the remaining budget and observes cancellation. `BUSY` follows actual contention; otherwise exhausted budget is `TIMEOUT`.
- Active AX/state work runs on an explicit worker boundary. NSWorkspace/NSApplication-owned state is read on main and reduced to value metadata before returning. Checkpoints do not claim to interrupt a kernel/AX call already blocked.
- `NativeService.execute` becomes async/context-aware in one compile-safe migration; do not leave a permanent synchronous compatibility dispatcher.
- Preserve A1 classified AX readers, A2 exact evidence policy, A4 no-follow/private/fail-closed storage, C1 current-source test provenance, C3 error details/status, and C4 actual snapshot response shape.
- The current snapshot-only store stays one implementation. Capture-kind extension is still the capture design gate, not this lifecycle plan.
- Keep `TargetIdentity.launchDate` as a canonical UTC timestamp with enough fractional precision to preserve the reliable public Date value (up to nine digits accepted by C4). A key/token change requires an explicit producer/consumer amendment, not a hidden alias.
- Preflight may receive the validated live handle to inspect capability/settable status, but must be side-effect-free by contract. The type system cannot enforce that restriction; do not claim it can. Foreground preparation is a separate post-invalidation hook.
- No actual activation, input, cursor rendering, live personal-app discovery, or permission prompts in this recovery. Use pure providers, clock/syscall seams, and injected foreground hooks.

## 3. Decompose the next implementation plan into these reviewable outcomes

These are planning work boundaries, **not unchecked code steps**. The next plan must replace each with exact files, complete signatures/replacement code/test helpers, RED/GREEN commands, and a local review gate.

### L1 — Context semantics only

**Own:** new focused context/clock file (or a narrowly scoped addition to `HostSupport.swift`) and `CommandContextTests.swift`.

Define monotonic `now`, wall `now`, async sleep, cancellation token and exact deadline arithmetic. No production caller migration in the pure-type task. Test timeout boundaries, cancellation precedence, overflow-safe deadline addition, and stable wall/monotonic separation. Introduce no implicit last-target state.

### L2 — Atomic async lock/service signature migration

**Own:** `DesktopLock.swift`, context consumers in `SnapshotService.swift`, `NativeService.swift`, `HostMain.swift`, and exact caller/test migrations.

This is a compile-boundary task, not permission to redesign all behavior at once. Enumerate every call site before writing the plan. Supply full replacements for async XCTest assertions/local helpers: `XCTAssertThrowsError` cannot await an async expression. Do not show an intermediate GREEN command after deleting an old method while its callers still reference it. Preserve C1's subprocess defers and C3's `failure.details` propagation.

Test cancellable lock waiting, deadline-clamped sleep, EINTR through context checks, success-at-deadline unlocking, real contention BUSY vs uncontended TIMEOUT, and exactly one fd release. No permanent old sync wrapper.

### L3 — Selected-process resolver and precise start identity

**Own:** `TargetResolver.swift`, resolver fixtures/tests, and visibility-only reuse of A1 classified AX helpers if needed.

Keep pure fixture resolution available. Replace eager all-app AX inventory with cheap main-actor process metadata followed by selected-PID-only window reads on the worker. Public CF type checks are shared with A1 rather than duplicated. Missing start identity prevents targeting but does not silently erase an app from the later discovery listing. Normalize missing/ambiguous/ineligible persisted targets to stale; permission/native failures stay distinct.

Test ambiguous app name sends zero AX window reads, explicit PID queries exactly that PID, same-second starts differ, missing/replaced window IDs become stale, and permission errors survive. Do not implement final apps/windows listing in this task; Stage D owns preserving all unmatched/ineligible listing candidates.

### L4 — Cooperative AX/state work boundaries

**Own:** worker abstraction, context/checkpoint plumbing in `AXTree.swift`, `StateStore.swift`, and their focused tests.

Show exact loop/checkpoint changes rather than saying “thread cancellation through.” Checks belong between AX request groups, record enumeration, EINTR retries, read/write chunks and publication boundaries. Preserve atomicity: partial invalidation remains fail-closed, and an expired/cancelled context never permits action dispatch. Bound public AX messaging timeout within the stated policy; distinguish hard OS-call limitations from cooperative guarantees.

Test cancellation during an injected slow read and between records, and verify the main queue can process a sentinel while worker work is active. No timing-dependent sleeps to assert event order; use injected clocks/semaphores/expectations with bounded cleanup on assertion failure.

### L5 — Retained snapshot transaction and identity refresh

**Own:** `SnapshotService.swift` plus small pure transaction harness/tests.

Freeze phases in this order:

```text
check → lock → sweep/load → resolve → AX read/compare → target recheck
→ pure capability preflight → target recheck/check
→ invalidate app records → check
→ foreground preparation hook → check
→ fresh resolve/read/compare → target recheck/check
→ dispatch with prepared data and fresh live element → check/cleanup
```

For snapshot creation, refresh selected identity after observation and check context around publication. Define what a failed post-publication checkpoint returns without pretending no record was written. For action tests, retain current record evidence only in memory after invalidation; never restore invalidated records.

Provide the complete local harness rather than an undefined `ActionHarness`. Cover preflight failure keeping records, invalidation failure preventing dispatch, context crossing during invalidation, replacement after preflight, post-hook tree change, fresh handle selection, dispatch failure leaving records invalidated, and a non-state-changing path that does not invalidate. No real foreground behavior yet.

### L6 — Host completion/cancellation state machine

**Own:** `HostSupport.swift`, `HostMain.swift`, `HostLifecycleTests.swift`.

The host must distinguish ready, running, cancelling and finished states. EOF before start shuts down without starting work; EOF during active work cancels but waits for completion/lock release; normal completion replies once; late/duplicate completions are suppressed. Shutdown/run-loop wakeup occurs on the appropriate thread only after cleanup. A worker that sees cancellation before starting must still deliver completion to its owning session, rather than returning silently and hanging the cancelling state.

Test all state transitions with injected work; assert the lock-release event precedes shutdown; prove a main-queue sentinel runs during injected background work. Explicitly defer held-input/SIGTERM/cursor cleanup implementation to Stage H unless the next written design broadens scope with approval.

## 4. Integration decisions the next plan must settle explicitly

1. Exact `CommandContext`/`NativeClock` declarations and cancellation ownership, including task cancellation vs the host token.
2. The sole lock owner for each command; avoid nested service/native dispatcher lock acquisition.
3. Whether worker dispatch wraps whole synchronous groups or individual operations; never call an async resolver from a synchronous closure without an explicit bridge.
4. Every closure signature in `SnapshotService.init`, including its context and actor/worker contract. Both old and new test closures must compile at the same task boundary.
5. Mutation-status policy at transaction checkpoints. C3 already defines internal `notStarted|potentiallyApplied`; do not lose that information in native error conversion.
6. Error mapping when AX state cannot be read during initial observation vs validation of persisted evidence.
7. Record publication cleanup after cancellation and the recovery path for recognized malformed state. Do not invent source/user-file deletion or silent quarantine policy.

## 5. Exit gate — only then is the foundation ready for Stage D/E

The next written plan must include and then run:

```sh
swift test --package-path native
npm run typecheck
npm test
npm run test:native-protocol
npm run test:build-hygiene
npm run build
npm test
```

Require an integrated review of A/C plus lifecycle/identity changes, with explicit proof of R2/R3/R4 closure from `../../reviews/2026-09-08-foundation-review.md`. Mark no live permission, AX routing, capture, input, overlay or installed-tarball behavior as verified. After that review passes, proceed to Stage D in `2026-09-08-standalone-cli-continuation-roadmap.md`.
