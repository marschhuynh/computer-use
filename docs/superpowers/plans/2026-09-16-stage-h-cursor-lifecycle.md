# Stage H — Cursor Visualization and Full Native Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Add the visible software cursor — an original, transparent, non-activating, click-through AppKit overlay that animates to targets, pulses on clicks, and shows drag feedback — plus the shared action timeline and the complete native lifecycle (SIGTERM/parent-loss cleanup).

**Architecture:** `CursorOverlay` (NSPanel, non-activating, ignoresMouseEvents) is driven by an `ActionTimeline` that sequences approach/pulse/drag *inside* the same command budget as the input it visualizes. An injectable `CursorRenderer` lets all ordering/timing tests run without a real window. `HostMain` gains full worker/main-actor ownership and parent-loss teardown.

**Tech Stack:** Swift 5.9, AppKit (NSPanel/NSWindow), XCTest.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Visible virtual cursor + §Foreground execution. **Roadmap slice:** Stage H. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **Original artwork** — do not copy Codex assets; an original distinctive cursor.
- Overlay is **transparent, non-activating, click-through**; it is *visualization only*, never the input path.
- Enabled by default for spatial actions; `--cursor off` disables visualization only, not safety checks.
- Bounded animation: approach ≤150 ms, click pulse 100 ms, all under the 15 s command budget.
- For AX `press`/`set-value`/`scroll`-to-ref, show feedback at the *validated element* when geometry exists; **lack of geometry never forces a coordinate fallback** — report visualization unavailable.
- No fabricated spatial target for `type`/`key` (no cursor needed).
- One helper/overlay lifecycle per command; origin = current pointer position, not a persisted session.
- Hide+close on completion/failure/cancellation/parent loss; **hide during capture** (don't rely on undocumented exclusion).
- If visualization init fails while enabled → fail before input; caller retries with `--cursor off`.

## File Structure

| File | Responsibility |
|---|---|
| `native/Sources/ComputerUseCore/CursorOverlay.swift` | NEW — NSPanel overlay + renderer |
| `native/Sources/ComputerUseCore/ActionTimeline.swift` | NEW — sequenced cursor+input timeline |
| `native/Sources/ComputerUseCore/ForegroundExecutor.swift` | drive visualization phases |
| `native/Sources/ComputerUseHost/HostMain.swift` | full lifecycle: worker/main ownership, parent-loss, cleanup |
| `native/Sources/ComputerUseCore/HostSupport.swift` | shared timeline seam |
| `native/Tests/ComputerUseCoreTests/CursorLifecycleTests.swift` | NEW — fake-renderer order/cleanup tests |

## Interfaces

**Consumes:** `ForegroundExecutor`+`NativeInputDriver` (Stages F–G), `ParentEOFObserver`+`HostSession` (`HostSupport.swift`, existing), element `bounds` from AX evidence.

**Produces (proposed — CONFIRM AT GATE):**
```swift
public protocol CursorRenderer {
    func prepare() throws                      // create overlay; fail before input
    func approach(_ point: CGPoint) async throws   // ≤150ms
    func pulse() async throws                  // 100ms click feedback
    func dragAlong(_ points: [CGPoint]) async throws
    func hide() async throws                   // also used pre-capture
    func teardown() async throws
}
public enum Visualization { case none, approach, pulse, drag }
```

`visualization` controlled vocabulary gains `approach`/`pulse`/`drag` (update `CONTROLLED_RESULT_VALUES` in `macos.ts` with emission).

---

### Task H1: `ActionTimeline` ordering (fake renderer)

- [ ] **Step 1 — failing test:** injectable renderer records call order → assert `prepare→approach→pulse→input→hide→teardown` for click; assert `hide` precedes capture; assert teardown on every path.
- [ ] **Step 2 — FAIL → Step 3 — implement** `ActionTimeline` sequencing with `CursorRenderer` seam.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: action timeline ordering`.

### Task H2: `CursorOverlay` panel (non-activating, click-through)

- [ ] **Step 1 — compile/availability test:** `NSPanel` with `.nonactivatingPanel`, `ignoresMouseEvents`, transparent original drawing; availability ≥ macOS 14.
- [ ] **Step 2 — FAIL → Step 3 — implement** `CursorOverlay` conforming to `CursorRenderer`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: cursor overlay panel`.

### Task H3: bounded animation + preparation failure

- [ ] **Step 1 — failing test:** approach ≤150 ms + pulse 100 ms within budget; `prepare` failure → zero input events, error before mutation.
- [ ] **Step 2 — FAIL → Step 3 — implement** timing + preflight-fail-before-input.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: bounded cursor animation and prep gate`.

### Task H4: element-anchored feedback + hide-before-capture

- [ ] **Step 1 — failing test:** press/set-value/scroll-ref pulse at validated element bounds; missing geometry → `visualization:"none"` (no fallback); screenshot hides overlay before capture.
- [ ] **Step 2 — FAIL → Step 3 — implement** element-anchored feedback + capture exclusion.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: element-anchored feedback and capture exclusion`.

### Task H5: full lifecycle cleanup

- [ ] **Step 1 — failing test:** SIGTERM/interrupt/parent-loss → overlay teardown + worker completion + held-input release; orphaned overlay cannot outlive host.
- [ ] **Step 2 — FAIL → Step 3 — implement** `HostMain` lifecycle wiring through `HostSession`+`ParentEOFObserver`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: full native lifecycle cleanup`.

## Exit Evidence

Fake-renderer order + resource-cleanup tests; compile/availability checks. Real click-through, actual visibility, foreground behavior, capture exclusion remain **live acceptance** (Stage K), not mocked passes.

## Carry-forward

`CursorRenderer`/`ActionTimeline`/`Visualization` complete the `visualization` vocabulary for Stage I's full result surface.
