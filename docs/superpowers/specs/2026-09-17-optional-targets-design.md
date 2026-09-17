# Optional targets for `key` and `screenshot` — design

**Date:** 2026-09-17
**Status:** approved design, pre-plan
**Scope:** `nuvin-computer-use` CLI + native host

## Summary

Today `key` and `screenshot` both require `--app <name>` or `--pid <pid>` and resolve to exactly one window. This change makes the target **optional** on both commands and adds two new execution modes:

- `key <chord>` with no target → **global** mode: post the chord into the HID event stream (`.cghidEventTap`), triggering system shortcuts and hitting whatever app holds focus — physical-keypress semantics.
- `screenshot --output <p>` with no target → **display** mode: capture the whole main display; `--display <n>` selects a monitor.

`--app/--pid` keep working unchanged on both commands — the new behavior only engages when the target is absent (or `--display` is given on `screenshot`).

## Goals

- Let an agent trigger system-wide keyboard shortcuts (`cmd+space`, `cmd+tab`, F-keys, mission-control chords) without naming an app.
- Let an agent capture the full screen (and any single display) for whole-desktop computer-use flows, not just one window.
- Keep every existing flag, reply field, and geometry invariant intact for the window-scoped path.

## Non-goals

- No multi-display "all monitors" capture in one shot — `--display` picks exactly one.
- No region/`rect` capture — display or window only.
- No change to `click`/`move`/`drag` semantics — they still resolve `--capture` records the same way; a display capture just happens to span the screen.
- No new AX/snapshot behavior — `--annotated` stays window-scoped.

## Design

### 1. Target model

`TargetSelector` (currently `app(String, windowId:)` / `pid(Int, windowId:)`) gains two cases:

```swift
public enum TargetSelector {
    case app(String, windowId: Int?)
    case pid(Int, windowId: Int?)
    case display(index: Int?)   // screenshot only; nil = main display
    case global                 // key only; no resolution needed
}
```

`ResolvedTarget` stays window-shaped for the existing path. A **display capture** reuses `ResolvedTarget` with a **synthetic identity**:

| Field | Window capture | Display capture |
|---|---|---|
| `identity.pid` | owning app pid | `0` |
| `identity.launchDate` | app launch date | capture-host launch date |
| `identity.bundleId` | app bundle id | `nil` |
| `identity.windowId` | `CGWindowID` | `0` |
| `title` | window title | `"Display <n>"` |
| `bounds` | window frame | `display.frame` (screen pt) |

`windowId = 0` and `pid = 0` mark a display capture. `CaptureGeometry` maps image↔screen over `display.frame`, so `click --capture <id> --x --y` on a full-screen capture lands anywhere on screen with **zero downstream changes** — `pixelsPerWindow` is still `imageSize / bounds`.

### 2. `key` — global mode

Wire: `{command:"key", key:"cmd+space"}` — `target` absent.

- **Decode:** `TargetSelector.decode(nil)` → `.global`. When `target` is absent on `key`, no resolution runs.
- **Dispatch:** bypasses `dispatchTargetMutation` (no window identity to re-validate); still runs inside `desktopLock` so a global chord can't interleave with a spatial click mid-timeline.
- **Input:** new `postGlobalKey(_ chord:context:)` on the input driver. Parses via the existing `KeyChord.toCGEvent` allowlist, then posts `keyDown` + `keyUp` via `CGEvent.post(tap: .cghidEventTap)` — **not** `postToPid`. Enters the HID stream → system shortcuts fire and the focused app receives it.
- **Reply:** `target` becomes `{ "scope": "global" }` (instead of `{pid, windowId}`); `method: "cg-event"`, `verification: "verified"`, `mutationStatus` semantics unchanged.
- **Permission:** `.cghidEventTap` needs the same accessibility/event-tap TCC trust as existing CGEvent posting — no new prompt, but `doctor` notes it.

`key --app X <chord>` is untouched — still `postToPid` to that app.

### 3. `screenshot` — display mode

Wire: `target` optional; new optional `display: Int` field.

- `screenshot` bare → `.display(nil)` → main `SCDisplay` (first in `SCShareableContent.displays` / `CGMainDisplayID`).
- `screenshot --display <n>` → `.display(n)` → nth display, **1-based** (`--display 1` = first/primary display; wire `positiveInteger` excludes 0, matching bare `nil` → primary). Out-of-range → `INVALID_ARGUMENT`.
- **Capture:** `liveDisplayCapture(displayIndex:native:context:)` — sibling to `liveWindowCapture`. `SCContentFilter(display:excludingWindows:)` over the `SCDisplay`, `sourceRect = display.frame`, `configuration.width/height = frame × (native ? backingScale : 1)`. PNG = whole display at logical res by default.
- **`--annotated` + display → `INVALID_ARGUMENT`** (`annotated requires --app/--pid`) — AX refs are window-scoped, so badges can't be placed on a full-screen shot. Keeps the two modes honest.
- Record, geometry, atomic publish, and `captureId` lifecycle identical to window captures.

### 4. Wire contract

`key` and `screenshot` relax `hasExactKeys` / `validTarget`:

- `key`: `target` becomes optional (was required). Exact-key set loses `target` when absent; when present must still be `validTarget`.
- `screenshot`: `target` optional; `display` (positive int) added to the allowed key set. `target` and `display` are mutually exclusive → both present = `PROTOCOL_ERROR` / `INVALID_ARGUMENT`.
- TS `Target` stays `{app|pid, windowId?}`; `key`/`screenshot` command types make `target` optional and `screenshot` adds `display?: number`.

## Files touched

| File | Change |
|---|---|
| `src/core/protocol.ts` | `key`/`screenshot` `target` → optional; `screenshot` += `display?: number` |
| `src/cli/parse.ts` | `--app/--pid` optional on `key`/`screenshot`; `--display` value on screenshot; emit `target`/`display` conditionally |
| `src/cli/run.ts` | help lines for both commands |
| `native/.../Protocol.swift` | relax `validTarget` for `key`/`screenshot`; add `display` key |
| `native/.../TargetResolver.swift` | `TargetSelector += .display, .global`; `resolve` handles `.display` |
| `native/.../CaptureService.swift` | `liveDisplayCapture`; `screenshot` branches on target kind |
| `native/.../NativeInput.swift` | `postGlobalKey` via `post(tap:)` |
| `native/.../NativeService.swift` | `key`/`screenshot` dispatch: no-target → global/display path, skip window validation |
| tests + `contracts/fixtures/native-protocol.json` | fixtures for global key, display screenshot, mutual-exclusion errors |
| `docs/cli.md`, `docs/agent-guide.md`, README | document bare/global/display usage |

## Error handling

| Case | Code |
|---|---|
| `key` bare, valid chord | succeeds — global post |
| `key` bare, bad chord | `INVALID_ARGUMENT` (existing chord validation) |
| `key` bare, no event-tap trust | `PERMISSION_DENIED` |
| `screenshot` bare | main display capture |
| `screenshot --display 9` (out of range) | `INVALID_ARGUMENT` |
| `screenshot --app X --display 0` | `INVALID_ARGUMENT` (mutually exclusive) |
| `screenshot --annotated` bare/`--display` | `INVALID_ARGUMENT` |
| `screenshot` bare, no Screen Recording | `PERMISSION_DENIED` (existing) |

## Testing

- **Swift XCTest:** selector decode for `.display`/`.global`; display capture produces synthetic `ResolvedTarget` + correct geometry; `postGlobalKey` posts via HID tap (injected driver, no real HID); mutual-exclusion + `--annotated` rejection; protocol fixtures round-trip.
- **vitest:** parse bare `key`/`screenshot`, `--display`, flag combinations; request shape matches fixtures.
- **Shared fixtures:** `valid-key-global`, `valid-screenshot-display`, `invalid-screenshot-app-plus-display`, `invalid-screenshot-annotated-display`, `invalid-display-out-of-range`.
- **Integration:** live `key cmd+space` smoke is manual-only (fires a real system shortcut); display capture verified against a real display in live acceptance.

## Safety

- `key` global can fire destructive system chords (`cmd+q` quits the focused app). Mitigations: the chord allowlist already bounds what's sendable; `desktopLock` prevents interleaving; `mutationStatus: potentiallyApplied` is reported honestly. Bare-no-target → global was chosen over a required `--global` flag for UX consistency with bare `screenshot` → screen; this is the documented, approved trade-off.
- Display captures can include other apps' content — same Screen Recording permission surface as window capture, no new TCC scope.
