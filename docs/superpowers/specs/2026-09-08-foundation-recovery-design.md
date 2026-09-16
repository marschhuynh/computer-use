# Standalone CLI foundation recovery design

Date: 2026-09-08
Status: Written recovery design approved by the user on 2026-09-08; planning only, implementation paused.

## Purpose and scope

Recover a trustworthy, testable foundation from `feature/standalone-cli` at `9b3a6d5` plus its unfinished Task 4 edits. Preserve the approved public CLI design in `2026-09-08-standalone-cli-design.md`. Do not restart completed work, implement capture/input/cursor behavior, delete original sources, or claim live acceptance.

The user selected **detailed recovery plus staged remaining roadmap**, then approved **incremental foundation recovery** rather than literal migration to every old internal signature. This document amends the old plan's internal ledger; it does not change command syntax or authorize desktop operations.

## Current evidence

- Fresh `swift test --package-path native` fails compilation: `AXTrustTests.swift` references missing `AXTreeReader`, `AXTree.readSnapshot`, and `axReadDisposition` declarations.
- Fresh `npm run typecheck` exits 0; `npm test` reports 239 passing tests. Native protocol cases in that command currently execute an existing ignored `dist/native/computer-use-host`; this is not evidence of current Swift compilation.
- Unfinished changes already improve descriptor-safe root setup, lock post-acquisition deadline checks, fail-closed invalidation, semantic state checks, and separate preflight/dispatch. They must be reviewed and retained where correct, not erased or recommitted wholesale as verified.
- Independent current-tree reviews cover lock/state, AX/snapshot, and CLI/host integration. Their consolidated findings and source citations are in `../../reviews/2026-09-08-foundation-review.md`.

## Design decisions

### 1. Preserve and stabilize before migrating interfaces

The first deliverable completes the missing pure AX-read seam and connects the live adapter to it. Run the existing red tests; do not remove them to make the suite green. After native compilation returns, verify and checkpoint the inherited filesystem/invalidation fixes separately. No `git reset`, `git clean`, original-source deletion, or blanket staging of unfinished work.

### 2. Honest test layers

Default TypeScript unit tests use injected/mock backends only. A separate native protocol integration command builds the current host in the same invocation, passes its path explicitly to test code, and runs only protocol-safe requests. Pure Swift tests use fixtures and injected providers. All spawned test children have timeout and finally/defer cleanup, including setup/assertion failure. `apps`, `windows`, `doctor`, and successful `snapshot` are not invoked against real applications during recovery.

### 3. Reliable AX observations and one evidence policy

Use a generic injected reader with explicit `value`, `unavailable`, and `failure` outcomes. Only documented legitimate absence is unavailable. Hard AX errors and successful wrong-CF-type values reject observation. Required role/window identity must be present. Retain unsupported optional attributes without claiming an error was absence; unsupported value types fail closed rather than silently losing evidence. Public APIs only.

A single pure evidence policy determines paths, truncation boundaries, and refs for production and state validation. Full-mode refs cannot occur at/below unsafe boundaries. Leaf modes also exclude candidates whose unobserved descendants prevent proving leaf-most semantics. Validation uses indexed parent/child summaries, not a complete-tree scan per node. Exact refs and boundaries must equal the producer-derived values; duplicate boundaries, malformed paths, and inconsistent refs are rejected.

### 4. Scoped and refreshed target identity

List process metadata cheaply, then read AX/CG window inventory only for the explicitly resolved PID. Preserve process start identity at the reliable precision supplied by the public platform value rather than formatting it to whole seconds. Keep serializable target evidence separate from private live handles.

Revalidate selected process/window ID/title/bounds after AX observation, after preflight, and after any future activation boundary. These checks reduce the documented race; they do not establish impossible atomic identity across arbitrary external changes. Missing/changed persisted targets become `STALE_SNAPSHOT`; permission and native-read failures remain distinguishable. Full apps/windows success dispatch is a later discovery slice, not hidden inside recovery.

### 5. One command context and responsive host

Introduce `CommandContext` containing an absolute monotonic deadline, injected monotonic/wall clock, and cancellation state. Compute the native deadline once when a request is accepted; consumers never reset it. Wall time is only for record timestamps/expiry. `check()` must run at entry/exit of each phase, between record and AX-read groups, after invalidation, and immediately before dispatch.

`DesktopLock.withLock(context:operation:) async throws` uses cancellable, deadline-clamped suspension; it retains the open fd through the scope and unlocks on every exit. No synchronous lock sleep runs on the AppKit main thread. The host dispatches blocking AX/state work to a dedicated worker, marshals AppKit-owned access onto main explicitly, and bridges parent EOF to active cancellation. Main-loop shutdown follows worker cleanup; parent loss suppresses the reply but does not skip resource release. Public synchronous AX calls remain subject to a bounded messaging timeout; checkpoints cannot preempt an OS syscall already running, and Node's owned-child two-second cleanup/kill policy remains the hard fallback.

### 6. Explicit transaction phases

The retained snapshot and live handle remain inside one native lock scope:

`check → sweep/load → resolve/read/compare → pure preflight → identity/check → invalidate → check → foreground preparation hook → fresh resolve/read/compare → check → dispatch → check/cleanup`.

The foreground hook is a testable integration point only during recovery; no activation/input implementation is added. Preflight performs no state-changing operation. A preflight failure keeps records valid. Any failure after invalidation leaves them invalidated; cancellation cannot restore them. Move's no-invalidation semantics are preserved for its later capture-based executor.

### 7. Explicit, modest internal-ledger amendment

- Keep the useful current names `TreeOptions`, `TargetIdentity`, `ResolvedTarget`, `AXTreeSnapshot`, `AXTreeObservation`, and `LiveAXElement`.
- Replace lock-owned timeout creation with the shared `CommandContext`; migrate callers and tests in the same reviewed task.
- Keep snapshot-specific `StateStore` storage during recovery. Make time/checkpoints explicit at service boundaries; do not invent capture payloads or duplicate a generic store in parallel. The capture design gate owns extending this one store to kind-aware snapshot/capture records and app-wide invalidation of both.
- Make `NativeService.execute` asynchronous/context-aware and pass one context through the call graph. No compatibility wrapper retaining a second synchronous production path.
- Keep public wire `schemaVersion: 1` unless a concrete public incompatible change is separately approved. Tighten exact-key validation and add missing optional error details as producer/consumer contract work.
- Future typed Swift payloads are introduced command family by command family where consumed, not as an all-command rewrite. Validators must reject conflicting or unknown keys before dispatch regardless of staging.

### 8. Wire-contract closure without another privacy redesign

Preserve the user-approved flexible semantic strings plus parsed-value privacy guard from Task 3. Extend paired fixtures for strict target selectors, both exclusive scroll forms, error details, and actual snapshot success data. Native error details must support sanitized candidate metadata and explicit mutation certainty; conservative Node classification covers structured failures lacking trustworthy start status as well as transport failures. The precise status spellings are frozen in the recovery plan and tested on both sides before native mutation commands are added.

Snapshot reply validation must use the actual producer's target/tree/UUID/timestamp shape. Capture-result validation is specified with the capture design, not guessed here. No error may echo input text or full command arguments. Projection cannot detect every transformed/partial disclosure: native producers must never emit input content in the first place.

## Final planning-boundary decision

After reviewing the lifecycle draft, the user explicitly chose to make lifecycle/identity a **required next-plan gate**, rather than accept incomplete migration code or another oversized task. The current executable plan therefore contains nine AX/state/protocol/test repairs. The lifecycle design decisions above remain binding requirements for the next plan, but are not claimed implemented by those nine tasks. The full foundation completion criteria below apply only after both the bounded repair series and the subsequent lifecycle/identity implementation are reviewed.

## Full foundation completion criteria

1. Current-source Swift tests compile and pass; TS tests pass; current-source native protocol integration passes separately.
2. Cancellation during a contended lock and injected long observation releases resources without late publication/dispatch.
3. AX failures cannot become complete evidence; unsafe truncated refs and malformed persisted evidence are rejected.
4. A replacement process/window or deadline crossed during invalidation yields zero dispatch in pure tests.
5. Request/reply fixtures agree across TS/Swift, including error details and unknown mutation-start handling.
6. Original sources and unfinished work are preserved or incorporated in reviewed commits; no unrelated files are staged.
7. The foundation receives an integrated review; package installation and live behavior remain explicitly unverified.

## Staged continuation gates

After recovery, design and plan these separately: discovery/user-facing diagnostics; capture/geometry/publication and kind-aware state; semantic input/focus/cleanup; raw mouse routes/hit tests; cursor/host lifecycle; full coordinator/privacy/output; package/source-install documentation; opt-in live fixture; authorized obsolete-source retirement. Each gate freezes producer/consumer fixtures before implementation and names a measurable exit criterion. The original Tasks 5–12 remain requirements coverage, not executable oversized work packets.

## Non-goals and authorization

No native desktop operations, permission prompts, screenshot capture, original-source deletion, implementation code edits, installations, or commits are authorized by this planning document itself. Baseline/task commits were authorized earlier during execution; planning documents will be left reviewable rather than using that authorization to stage unfinished implementation. Node 22+, macOS 14+, Swift 5.9+/Swift v5, public APIs, 15,000 ms default / 1–120,000 ms range, two-second cleanup grace, ten-minute records, 0700 directories and 0600 files remain unchanged.
