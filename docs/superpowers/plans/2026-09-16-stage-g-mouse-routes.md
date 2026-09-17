# Stage G — Capture-Bound Raw Mouse Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Implement `click`, `move`, and `drag` — raw mouse operations on `--capture` records that map image pixels to screen coordinates through Stage E's `CaptureGeometry`, with occlusion checks and held-button cleanup.

**Architecture:** Reuses `NativeInputDriver` (extend with CGEvent mouse), `ForegroundExecutor` (ownership preflight + held-input cleanup), and Stage E's `imageToScreen`/`CaptureRecord`. Every coordinate action validates the capture's identity/geometry is unchanged and the point hits the selected (non-occluded) window.

**Tech Stack:** Swift 5.9, CoreGraphics CGEvent mouse, XCTest.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Pixel targeting. **Roadmap slice:** Stage G. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **Capture-bound only** — coordinates come from a `--capture` UUID; validate finite/bounds, unchanged process/window identity/geometry, unexpired record.
- **Occlusion check** — hit-test the point; refuse if it lands on an occluding app/owned overlay, not the selected visible window.
- **Button/count matrix** — left 1/2/3, right 1, middle 1 only; reject unsupported combos *before* input.
- **`move` does not invalidate records** (spec); a completed `click`/`drag` does.
- **Bounded straight-interpolation drag** with route checks and down/up cleanup on interruption.
- Pointer movement is real foreground behavior even when `--cursor off`.

## File Structure

| File | Responsibility |
|---|---|
| `native/Sources/ComputerUseCore/NativeInput.swift` | extend driver with `click`/`move`/`drag` CGEvent mouse |
| `native/Sources/ComputerUseCore/ForegroundExecutor.swift` | occlusion hit-test + drag lifecycle |
| `native/Sources/ComputerUseCore/NativeService.swift` | dispatch `click`/`move`/`drag` via capture records |
| `native/Tests/ComputerUseCoreTests/MouseRouteTests.swift` | NEW — event-trace tests |

## Interfaces

**Consumes:** `CaptureRecord`+`CaptureGeometry`+`imageToScreen` (Stage E), `NativeInputDriver` (Stage F), `ForegroundExecutor` preflight/cleanup, `StateStore` capture read/invalidate.

**Produces (proposed — CONFIRM AT GATE):**
```swift
extension NativeInputDriver {
    func click(at point: CGPoint, button: MouseButton, count: Int) throws
    func move(to point: CGPoint) throws
    func drag(from: CGPoint, to: CGPoint) throws
}
public enum MouseButton { case left, right, middle }
```

---

### Task G1: capture-record → point resolution + validation

- [ ] **Step 1 — failing test:** load capture, `imageToScreen` the point, reject stale identity/changed geometry/expired record, reject out-of-bounds/`x==width` edge.
- [ ] **Step 2 — FAIL → Step 3 — implement** `resolveCapturePoint` (record read + identity/geometry revalidation + transform).
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: capture-bound point resolution`.

### Task G2: `move` (no invalidation)

- [ ] **Step 1 — failing test:** move emits a single move event at the resolved point; capture/snapshot records unchanged.
- [ ] **Step 2 — FAIL → Step 3 — implement** `case .move`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: mouse move`.

### Task G3: `click` (button/count validation + occlusion)

- [ ] **Step 1 — failing test:** matrix left{1,2,3}/right{1}/middle{1} accepted, others rejected pre-input; occluded point → zero events; success invalidates this CLI's records for the app.
- [ ] **Step 2 — FAIL → Step 3 — implement** `case .click` with hit-test + button/count gate + invalidation.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: click with occlusion check`.

### Task G4: `drag` (interpolated + cleanup)

- [ ] **Step 1 — failing test:** straight-line interpolation events, down→move→up sequence, interruption releases button and reports `potentiallyApplied`; route checks between event groups.
- [ ] **Step 2 — FAIL → Step 3 — implement** `case .drag` + down/up cleanup.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: drag with held-button cleanup`.

## Exit Evidence

Pure event traces for all supported combos and rejections; occlusion + stale-geometry zero-input tests; drag-interruption cleanup; no record revival after invalidation.

## Carry-forward

`NativeInputDriver` mouse methods + `resolveCapturePoint` are consumed by Stage H (cursor drives along the same timeline) and Stage I (dispatch table completes).
