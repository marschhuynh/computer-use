# Stage E — Window Capture, Geometry, and Unified Record Kinds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Implement `screenshot` — capture one target window to PNG, record a `capture` record alongside `snapshot` records in the unified `StateStore`, and provide the pure pixel→window/screen transform that Stage G's mouse commands consume.

**Architecture:** Pure `Geometry` math (pixel ↔ window ↔ screen, scale/resize/negative-origin) is fully unit-testable; `CaptureService` wraps `ScreenCaptureKit` window-only capture; `StateStore` is extended (not forked) to a `capture` record kind. Annotated screenshots pair a capture with a consistent snapshot.

**Tech Stack:** Swift 5.9 / ScreenCaptureKit (macOS 14 API), CoreGraphics, XCTest; TS validators already exist.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Pixel targeting and screenshots. **Roadmap slice:** Stage E. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **Verify ScreenCaptureKit macOS-14 API signatures before writing the plan's capture calls** — this is a `CONFIRM AT GATE` item (see E1).
- Window-only capture; **never** fall back to full-desktop capture.
- Coordinates are measured in the saved image's pixels; never estimate Retina scale by dividing window pixels by full-screen width.
- Explicit absolute `--output` path; no overwrite unless `--overwrite`. Atomic publication via private temp file; abandoned-temp recovery.
- `--annotated` returns a *consistent* capture+snapshot pair; verify target consistency across AX traversal and capture or fail.
- One `StateStore` — add `kind:"capture"`, do not fork.

## File Structure

| File | Responsibility |
|---|---|
| `native/Sources/ComputerUseCore/Geometry.swift` | NEW — pure pixel↔window/screen transforms |
| `native/Sources/ComputerUseCore/CaptureService.swift` | NEW — ScreenCaptureKit window capture adapter |
| `native/Sources/ComputerUseCore/StateStore.swift` | extend to `capture` kind + app-wide invalidation of both kinds |
| `native/Sources/ComputerUseCore/NativeService.swift` | dispatch `screenshot` |
| `native/Tests/ComputerUseCoreTests/GeometryTests.swift` | NEW — pure transform fixtures |
| `native/Tests/ComputerUseCoreTests/CaptureTests.swift` | NEW — record/publication/consistency tests |

## Interfaces

**Consumes (existing):** `ResolvedTarget{identity,title,bounds}`, `SnapshotService` (for `--annotated` pair), `StateStore` record write/sweep, `CommandContext`.

**Produces (proposed — CONFIRM AT GATE):**
```swift
public struct CaptureGeometry {
    let windowBounds: WindowBounds   // screen-space window rect
    let imageSize: CGSize            // saved PNG pixel dims
    let scale: CGFloat               // backing scale (from capture metadata)
    let resizeTransform: CGAffineTransform  // image->window mapping
}
public struct CaptureRecord: Codable { kind:"capture", id, createdAt, expiresAt, target, geometry, path }
public func imageToScreen(_ p: CGPoint, in g: CaptureGeometry) -> CGPoint
public func screenToImage(_ p: CGPoint, in g: CaptureGeometry) -> CGPoint
```

---

### Task E1: pure `Geometry` transforms (no ScreenCaptureKit)

- [ ] **Step 1 — failing test** (`GeometryTests.swift`): fixtures for Retina (scale 2), non-Retina (scale 1), resized image (imageSize ≠ windowBounds), negative display origin, window moved/resized after capture, boundary `x == width`.
- [ ] **Step 2 — FAIL → Step 3 — implement** `imageToScreen`/`screenToImage` as exact affine math; reject non-finite/out-of-bounds.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: pure capture geometry transforms`.

### Task E2: `capture` record kind in `StateStore`

- [ ] **Step 1 — failing test:** write/read `CaptureRecord`; `invalidateRecords` invalidates snapshot *and* capture for the same app; expired capture swept.
- [ ] **Step 2 — FAIL → Step 3 — extend** `SnapshotRecord`→unified `StateRecord` (or a `kind` discriminator) keeping `version`, `id`, `expiresAt`, `invalidated`, `target`; keep existing snapshot decode backward-compatible.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: unify capture records in StateStore`.

### Task E3: window-only capture adapter + atomic output

- [ ] **Step 1 — CONFIRM AT GATE:** verify `SCScreenshotManager`/`SCContentFilter`/configuration API exists on the installed SDK for macOS 14; record the exact signatures at top of `CaptureService.swift`.
- [ ] **Step 2 — failing test:** injected capturer returns image+metadata → `CaptureGeometry` built; absolute `--output` writes atomically, `--overwrite` honored, no desktop fallback.
- [ ] **Step 3 — FAIL → Step 4 — implement** `CaptureService` + `case .screenshot` in `NativeService` (write capture record + return `{captureId,target,path,width,height,createdAt,expiresAt}`).
- [ ] **Step 5 — PASS → Step 6 — commit** `feat: window screenshot with capture record`.

### Task E4: `--annotated` paired consistency

- [ ] **Step 1 — failing test:** annotated reply carries `snapshotId`+`tree`+`truncated` and the capture/snapshot target identities must match (else fail).
- [ ] **Step 2 — FAIL → Step 3 — implement** paired transactional publication (both records or neither) + ref-badge transform using the same `CaptureGeometry`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: annotated screenshot consistent pair`.

## Exit Evidence

Pure geometry fixtures (all transforms/boundaries), output/symlink/race tests, paired-record failure tests, `native-replies.json` screenshot fixtures. **No real capture claimed** until authorized live acceptance (Stage K).

## Carry-forward

`CaptureGeometry` + `imageToScreen`/`screenToImage` + `CaptureRecord` are consumed by Stage G (`click`/`move`/`drag` map `--capture`+pixels→screen).
