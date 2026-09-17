# Stage F — Foreground Semantic Execution and Held-Input Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Implement the semantic mutation commands — `press`, `set-value`, `type`, `key`, and ref/directional `scroll` — as real foreground operations with verification, `mutationStatus` honesty, and held-input cleanup on cancellation.

**Architecture:** A `ForegroundExecutor` owns activation/ownership-preflight + post-action verification; `NativeInput` wraps `AXUIElementPerformAction`, `AXUIElementPostKeyboardEvent`, and CGEvent keyboard/scroll with an injected event seam so every test is a pure driver/event-sequence test. Every ref action goes through the existing `SnapshotService.withValidatedSnapshotAction` seam.

**Tech Stack:** Swift 5.9, ApplicationServices (AX), CoreGraphics (CGEvent), XCTest.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Foreground execution and safety. **Roadmap slice:** Stage F. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **Zero coordinate fallback** — `press` is `AXPress` only; `set-value` is `AXValue` only. Merely focusing a control is never success.
- **Invalidate before activation** — activation can change UI; refresh evidence after, keeping only this action's evidence.
- **No automatic mutation retry.** `notStarted` vs `potentiallyApplied` must be accurate on every error path.
- **Verification is required** — report `method`/`verification` truthfully; `verification:"unverified"` or `EXECUTION_UNCERTAIN` when it can't be proven.
- **Held-input cleanup** — on cancellation/failure, release only inputs this command pressed; never dispatch after `context` expiry.
- Keys/modifiers use an **allowlisted** syntax parser; text via args/stdin, never interpolated into AppleScript.
- Clipboard replacement only with `--allow-clipboard-replace`; report `clipboardReplaced:true`; never claim restoration preserved all formats.

## File Structure

| File | Responsibility |
|---|---|
| `native/Sources/ComputerUseCore/ForegroundExecutor.swift` | NEW — activation, ownership preflight, verification, phase tracking |
| `native/Sources/ComputerUseCore/NativeInput.swift` | NEW — AX actions + CGEvent keyboard/scroll seam |
| `native/Sources/ComputerUseCore/NativeService.swift` | dispatch `press`/`set-value`/`type`/`key`/`scroll` |
| `native/Tests/ComputerUseCoreTests/ForegroundExecutorTests.swift` | NEW — pure driver/event-sequence tests |
| `contracts/fixtures/native-replies.json` | mutation reply fixtures + `method`/`verification` controlled values |

## Interfaces

**Consumes (existing):** `SnapshotService.withValidatedSnapshotAction` (`SnapshotService.swift:107`), `TargetResolver.validate`, `CommandContext`, `StateStore.invalidateRecords`.

**Produces (proposed — CONFIRM AT GATE):**
```swift
public protocol NativeInputDriver {            // injected for tests
    func performAXAction(_ action: String, on element: LiveAXElement) throws
    func postKey(_ key: KeyChord, to pid: pid_t) throws
    func postText(_ text: String, to pid: pid_t) throws
    func scroll(_ direction: Direction, amount: Int, at element: LiveAXElement?) throws
    func releaseHeldInputs() throws
}
public struct ExecutionResult { target, method, verification, visualization }
```

Controlled vocabulary to add **in the same commit** as each real value:
`method` += `cg-event`; `verification` += `unverified`/`partial`; `visualization` stays `none` until Stage H.

---

### Task F1: `FocusObserver` + ownership preflight

- [ ] **Step 1 — failing test** (`ForegroundExecutorTests.swift`): injected observer reporting a different frontmost app → zero input events dispatched, error before mutation.
- [ ] **Step 2 — FAIL → Step 3 — implement** activation + frontmost polling + fresh post-activation evidence.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: foreground ownership preflight`.

### Task F2: `press` via `AXPress`

- [ ] **Step 1 — failing test:** snapshot→press ref dispatch order (invalidate→activate→preflight→AXPress→verify); assert no coordinate path exists.
- [ ] **Step 2 — FAIL → Step 3 — implement** `case .press` via `withValidatedSnapshotAction` + `NativeInputDriver.performAXAction("AXPress")`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: AXPress execution`.

### Task F3: `set-value` with readback verification

- [ ] **Step 1 — failing test:** set returns success only on confirmed `AXValue` readback; readback-failure → `EXECUTION_UNCERTAIN`/`unverified`, not success.
- [ ] **Step 2 — FAIL → Step 3 — implement** set + readback + verification result.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: AXValue set with verification`.

### Task F4: `scroll` (ref + directional)

- [ ] **Step 1 — failing test:** ref form → `AXScrollToVisible`; directional form → hit-tested window scroll; mutually-exclusive forms rejected upstream.
- [ ] **Step 2 — FAIL → Step 3 — implement** both scroll forms through `NativeInputDriver.scroll`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: scroll execution`.

### Task F5: `key` (allowlisted chords + held-key cleanup)

- [ ] **Step 1 — failing test:** `cmd+s`, `ctrl+opt+delete` parse; unknown key rejected; cancellation releases only held modifiers.
- [ ] **Step 2 — FAIL → Step 3 — implement** allowlisted `KeyChord` parser + post + `releaseHeldInputs` on cancel.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: key execution with held-input cleanup`.

### Task F6: `type` (Unicode groups + opt-in clipboard)

- [ ] **Step 1 — failing test:** bounded Unicode event groups; paste path only with `allowClipboardReplace` → `clipboardReplaced:true`; no hidden paste fallback; text never in errors.
- [ ] **Step 2 — FAIL → Step 3 — implement** `postText` + clipboard gate.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: type execution`.

## Exit Evidence

Pure driver/event-sequence tests: no fallback, focus-mismatch zero events, ignored set/readback failure, unknown keys, Unicode boundaries, no silent paste retry, cancellation releases only held inputs, no dispatch after context expiry. **No live keys/typing/activation** — Stage K.

## Carry-forward

`NativeInputDriver` + `ForegroundExecutor` + `ExecutionResult` consumed by Stage G (adds CGEvent mouse) and Stage H (cursor timeline).
