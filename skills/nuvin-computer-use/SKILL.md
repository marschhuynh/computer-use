---
name: nuvin-computer-use
description: Drive the macOS desktop from the `nuvin-computer-use` CLI — semantic actions on the accessibility tree (snapshot → press/set-value/scroll) and pixel actions on screenshots (screenshot → click/move/drag), including drawing on canvas and custom-drawn UI that the AX tree can't reach. Use whenever the user wants to operate, automate, click, type, draw, or control a real macOS app or window, or asks you to perform a GUI task on the host — even if they don't name this tool.
---

# nuvin-computer-use

A foreground-automation primitive for macOS, not an agent. Every call is one
command → one JSON reply → one process exit. There is no session, no daemon, no
persistent "current window" — you re-establish context on every call. Always
pass `--json` and parse `ok` before acting on `data`.

Two ways to act on the screen. Choose by what the target exposes:

| Path | Reach | Flow |
|---|---|---|
| **Semantic (AX)** | Buttons, fields, menus — anything with an accessible identity | `snapshot` → find `ref` → `press` / `set-value` / `scroll --ref` |
| **Spatial (pixels)** | Canvas, games, paint apps, custom-drawn UI — anything AX can't reach | `screenshot` → pick pixel → `click` / `move` / `drag` |

Prefer **semantic** when the element has a `ref` — it survives position changes
and HiDPI. Fall back to **spatial** when the element isn't in the AX tree. A
canvas has no AX tree at all; the spatial path is the only way in, and it's
sufficient (verified end-to-end by drawing on a web paint app).

## Preflight

```sh
nuvin-computer-use doctor --json     # permissions + helper check
nuvin-computer-use apps --json       # running apps: name, bundleId, pid
nuvin-computer-use windows --app Notes --json   # windows + eligibility
```

`doctor` must return `ready:true`. `PERMISSION_DENIED` (exit 4) means
Accessibility or Screen Recording isn't granted to the launching terminal —
surface that to the user; don't retry.

`--app` matches localized name **or** bundle id and must be unambiguous; add
`--window <id>` (from `windows`) when more than one eligible window exists.

## Semantic path — snapshot → ref → act

```sh
nuvin-computer-use snapshot --app Notes --window 12345 --json
# → data.snapshotId + data.tree.elements[] {role,ref,title,label,actions,bounds}

nuvin-computer-use press --snapshot <uuid> --ref 7 --json
nuvin-computer-use set-value --snapshot <uuid> --ref 12 --text "new value"
nuvin-computer-use scroll --snapshot <uuid> --ref 20      # scroll into view
```

Choose a `ref` by `role`/`title`/`label` and confirm `actions` includes what you
need (`press` requires `AXPress`). Refs live only for that `snapshotId` and only
while the window is unchanged — **re-snapshot before each ref action**; a stale
snapshot returns `STALE_SNAPSHOT` (exit 5).

## Spatial path — screenshot → pixel → act

```sh
nuvin-computer-use screenshot --app Notes --window 12345 \
    --output /tmp/notes.png --overwrite --json
# → data.captureId, data.width/height (image px)

# whole desktop: bare captures the main display; --display <n> (1-based) picks a monitor
nuvin-computer-use screenshot --output /tmp/screen.png --json

nuvin-computer-use click --capture <uuid> --x 420 --y 180 --json
nuvin-computer-use move  --capture <uuid> --x 420 --y 180 --json
nuvin-computer-use drag  --capture <uuid> --from 420,180 --to 620,300 --json
```

`--x`/`--y`/`--from`/`--to` are **image pixels** in the saved PNG, mapped back
through the capture's geometry — they work identically whether the capture is a
window or a full display, logical (default 1×) or `--native` (Retina). Read the
PNG, choose the pixel, pass it. `--capture` ids expire in ~10 min and go stale
if the window moved → `STALE_CAPTURE` (exit 5) → re-screenshot.

`--annotated` overlays numbered ref badges on the PNG *and* returns the AX tree
— the fastest way to correlate "what I see" with "what I can press." Window
targets only; display captures have no AX tree.

### Canvas & custom-drawn UI

`press`/`set-value`/snapshot can't reach pixel-rendered surfaces. Draw and
interact purely on pixels:

- **Drawing = many `drag`s.** A `drag` is one straight left-button stroke.
  Compose shapes from short drags — an octagon ≈ 8 vertex-to-vertex drags, an
  arc ≈ 2–3. There's no multi-point path primitive; build curves from segments.
  `click` = a point (a toolbar cell, a color swatch, a dot).
- **Tools & colors are pixels too.** Toolbar cells and swatch rows aren't AX
  elements — `click` their image-pixel centers, then `drag` on the canvas.
  Read swatch positions carefully off the PNG; multi-row palettes are easy to
  mis-pick — verify the active tool/color with a re-`screenshot` before a long
  draw.
- **Always re-`screenshot` to confirm.** Pointer ops report `verified` (the
  event dispatched), not that the canvas changed. Re-capture and look.
- **Pixels are region-relative.** Compute a control's pixel from the PNG's own
  coordinates (window or display space), not from memory of the layout.

## Raw input

```sh
nuvin-computer-use type --app Notes --text "hello"      # keystrokes (Unicode ok)
nuvin-computer-use type --app Notes --text-file -        # stdin; keeps text off argv
nuvin-computer-use key  --app Notes --key cmd+s          # chord: cmd,ctrl,alt,shift + key
nuvin-computer-use key  --key cmd+space                  # bare = system-wide (Spotlight etc.)
nuvin-computer-use scroll --app Notes --direction down --amount 3
```

`type`/`key`/`scroll --direction` target the **app/window**, not a ref — they
post input to whatever has focus inside it. Focus the right field first
(`click` it or `press` its ref). A bare `key` posts the chord system-wide to
whatever holds focus — use it for global shortcuts (Spotlight, app-switcher).

## Errors → recovery

Every command returns `{"ok":bool,"error":{"code","message","details"}}`.
Always parse `ok`. On `false`, branch on `error.code`:

| Exit / code | Do |
|---|---|
| 0 | proceed |
| 1 `NATIVE_FAILURE` `EXECUTION_UNCERTAIN` | check `error.details.mutationStatus`: `notStarted` → safe retry; `potentiallyApplied` → **re-observe before retrying** (the action may already have run) |
| 2 `INVALID_ARGUMENT` | fix flags; don't retry as-is |
| 3 `MISSING_HELPER` `HELPER_VERSION_MISMATCH` | environment problem → run `doctor`, surface to user |
| 4 `PERMISSION_DENIED` | Accessibility/Screen Recording missing → tell user to grant to the launching terminal |
| 5 `TARGET_NOT_FOUND` `AMBIGUOUS_TARGET` `INELIGIBLE_TARGET` `STALE_SNAPSHOT` `STALE_CAPTURE` | re-target: re-run `apps`/`windows`/`snapshot`/`screenshot` |
| 6 `TIMEOUT` `BUSY` | retry with a larger `--timeout`, or wait and retry |

`AMBIGUOUS_TARGET` → add `--window <id>`. `INELIGIBLE_TARGET` → the window is
minimized/off-Space; bring it on-screen. `potentiallyApplied` → never
blind-retry — observe first.

## Safety contract

- **This is real foreground input** — `click`/`type`/`key` move the physical
  pointer and post real events to the focused app. No sandbox, no semantic
  reviewer: a click on "Delete" deletes.
- **`mutationStatus` honesty** — on failure, `error.details.mutationStatus`
  says whether input may have been dispatched. Honor it before retrying.
- **Never pass secrets via `--text`** — visible in shell history and process
  lists. Use `--text-file -` and pipe via stdin; supplied text is never echoed.
- **Snapshot/capture records contain on-screen text** — private, expire in 10
  min; treat as sensitive.

## Command reference

```
doctor · apps · windows · snapshot · press · set-value · type · key · scroll
screenshot · click · move · drag
Global: --json · --timeout <ms> · --cursor on|off · --help · --version
```

`key`/`screenshot` take an optional target: `--app|--pid` (window-scoped),
`--display <n>` (screenshot only, 1-based monitor), or bare (key→global chord,
screenshot→main display). `--app` and `--pid` are mutually exclusive;
`--display` can't combine with a window target.
