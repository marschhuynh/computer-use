# Live Acceptance — 2026-09-17

Stage K live verification against the disposable `CUFixture` app
(`fixtures/app/`, bundle id `com.nuvin.cu-fixture`, two windows). Authorization:
user approved live foreground input for this session. Fixture is in-memory —
no disk/clipboard/user-data access.

## Environment

- macOS arm64, host built from `main` @ working tree
- Accessibility + Screen Recording granted to the launching terminal
- Fixture: primary window (button `ref=1`, text field `ref=2`, scroll area
  `ref=5`, 60 labeled rows) + secondary window

## Per-command matrix

| Command | Result | Evidence |
|---|---|---|
| `doctor` | **pass** | `ready:true`, all checks `ok`, exit 0 |
| `apps` | **pass** | fixture listed with `bundleId com.nuvin.cu-fixture` |
| `windows` | **pass** | both fixture windows reported with eligibility |
| `snapshot` | **pass** | clean AX tree, refs + actions; `snapshotId` returned |
| `press` | **pass** | `method:accessibility` `verified`; status flipped to `pressed` |
| `set-value` | **pass** | `method:accessibility` `verified`; field shows set text |
| `type` | **pass** | Unicode `héllo ✓` + `typed text ✓` landed in field |
| `key` | **pass** | `cmd+a` / `escape` dispatched `verified` |
| `scroll` (directional) | **pass** | `method:cg-event` `verified` |
| `scroll` (to-ref) | **unavailable** | fixture rows (`AXStaticText`) don't expose `AXScrollToVisible` — command correctly reports action-unsupported; not a tool defect |
| `screenshot` | **pass** | window-tight PNG at native scale, `captureId` + record |
| `screenshot --annotated` | **pass** | PNG + `snapshotId` + `tree`; ref badges drawn on image |
| `click` | **pass** | `method:cg-event` `verified` `visualization:pulse`; no host crash |
| `move` | **pass** | `visualization:approach` |
| `drag` | **pass** | `visualization:drag` |

## Bugs found & fixed during this session

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `click`/`move`/`drag` crashed host (abort trap 6) | `NSPanel` created off main thread | Confine all AppKit to `DispatchQueue.main`/`MainActor` in `CursorOverlay` |
| 2 | every `screenshot` failed "no image data" | `pngEncode` cast `CGImageDestination` to `NSMutableData` (always nil) instead of returning the buffer | Retain + return the buffer; draw into RGBA context for the SCK pixel format |
| 3 | PNG letterboxed (display canvas, not window) | `SCStreamConfiguration` defaulted to display-size | Pin `sourceRect`/`width`/`height` to window frame × `NSScreen.backingScaleFactor` |
| 4 | `writeCapture` → `STALE_CAPTURE` | `createdAt`/`expiresAt` from two `wallNow` calls → `validLifetime` ns mismatch | Single `Date` base for both |
| 5 | `type` dropped leading chars | per-scalar `keyDown`/`keyUp` burst with no delay | 4 ms pacing between events |
| 6 | `click` dispatched but didn't register | 0 ms synthetic down→up; pointer never moved first | `mouseMoved` to point + 50 ms down/up interval |
| 7 | `snapshot` failed on any `NSScrollView` | an element returned a scalar/collection attribute as a non-matching type (e.g. `AXChildren`/`AXValue` as a lone `AXUIElement`), tripping the strict typeid check | Degenerate-type `.success` reads → `.unavailable` in `liveAXChildren`/`liveAXActions`/`liveAXString`/`liveAXBool` |

## Platform limitation discovered

`NSOpenPanel`/`NSSavePanel` run in `openAndSavePanelService` — a separate,
login-launched process with no `launchDate`. Such panels are untargetable
(`TARGET_NOT_FOUND`), same class as Finder/Dock/login agents. Documented as a
known limitation.

## Overlay / lifecycle checks

- Cursor overlay appears on spatial actions (`approach`/`pulse`/`drag`), no
  crash, no leftover overlay after command completion.
- `--cursor off` would suppress visualization (not exercised; non-default).
- `press`/`set-value` carry `visualization:"none"` (element-anchored, no
  fabricated coordinate) — correct per spec.

## Not covered (honest gaps)

- Multi-display / negative-origin coordinate transforms — single display here.
- `drag` interruption mid-path, parent-kill cleanup — not exercised.
- Physical-pointer end position after `move`/`drag` not independently asserted
  (relies on `verified` dispatch, not a pointer-position readback).
- `--cursor off` path not exercised.

## Re-run

```sh
NUVIN_CU_LIVE=1 node scripts/live-fixture.mjs
```

Refuses without the env gate + interactive "yes". Builds the fixture if absent.
