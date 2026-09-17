# Using `nuvin-computer-use` from an agent

This document is the integration contract for an LLM agent (or orchestrator)
that drives the macOS desktop through this CLI. It assumes the package is
installed and `nuvin-computer-use` is on `PATH`.

## Mental model

The CLI is a **foreground automation primitive**, not an agent. Every call is
one command → one JSON reply → one process exit. There is no session, no
daemon, no persistent "current window." You re-establish context each call.

Two ways to act on the screen:

| Path | When to use | Flow |
|---|---|---|
| **Semantic (AX)** | Buttons, fields, menus — anything with an accessible identity | `snapshot` → find `ref` → `press`/`set-value`/`scroll --ref` |
| **Spatial (pixels)** | Canvas, games, custom-drawn UI, anything AX can't reach — incl. drawing | `screenshot` → pick pixel → `click`/`move`/`drag` |

Prefer **semantic** when an element has a `ref` — it's robust to position
changes and HiDPI. Fall back to **spatial** when the element isn't in the AX
tree.

## Response envelope

Every command emits exactly one JSON object on stdout with `--json`:

```jsonc
// success
{"schemaVersion":1,"ok":true,"command":"snapshot","data":{ ... }}
// failure
{"schemaVersion":1,"ok":false,"command":"click",
 "error":{"code":"STALE_CAPTURE","message":"...","details":{"mutationStatus":"potentiallyApplied"}}}
```

**Always parse `ok`.** On `false`, branch on `error.code`. Exit codes carry the
same info (see below) — `0` success, nonzero failure.

## Exit codes → error codes

| Exit | Meaning | Agent action |
|---|---|---|
| 0 | success | proceed |
| 1 | `NATIVE_FAILURE` `PROTOCOL_ERROR` `EXECUTION_UNCERTAIN` | retry once; if `mutationStatus:"potentiallyApplied"`, **the action may have happened** — re-observe before retrying |
| 2 | `INVALID_ARGUMENT` | fix flags; don't retry as-is |
| 3 | `MISSING_HELPER` `HELPER_VERSION_MISMATCH` `MISSING_DEPENDENCY` `UNSUPPORTED_PLATFORM` | environment problem — surface to user, run `doctor` |
| 4 | `PERMISSION_DENIED` | Accessibility/Screen Recording not granted — tell user to grant it |
| 5 | `TARGET_NOT_FOUND` `AMBIGUOUS_TARGET` `INELIGIBLE_TARGET` `STALE_SNAPSHOT` `STALE_CAPTURE` `FOCUS_FAILED` | re-target: re-run `apps`/`windows`/`snapshot`/`screenshot`; `FOCUS_FAILED` = the named app couldn't be raised — check it's running, then retry |
| 6 | `TIMEOUT` `BUSY` | retry with larger `--timeout`, or wait and retry |
| 130 | interrupted | abort the task |

## The core loop

### 1. Find the target

```sh
nuvin-computer-use apps --json          # running apps: name, bundleId, pid
nuvin-computer-use windows --app Notes --json   # its windows + eligibility
```

`--app` matches localized name **or** bundle id; it must be unambiguous.
`--window <id>` is required when more than one eligible window exists.

### 2. Semantic path — snapshot → ref → act

```sh
# Capture the AX tree; get a snapshotId + element refs.
nuvin-computer-use snapshot --app Notes --window 12345 --json
# → data.snapshotId, data.tree.elements[] each with role/ref/actions/bounds

# Act on a ref within the 10-minute snapshot lifetime.
nuvin-computer-use press --snapshot <uuid> --ref 7 --json
nuvin-computer-use set-value --snapshot <uuid> --ref 12 --text "new value"
nuvin-computer-use scroll --snapshot <uuid> --ref 20     # scroll element into view
```

**Element shape** (what you read to choose a ref):

```jsonc
{"role":"AXButton","ref":1,"identifier":"...","title":"Save","label":"Save",
 "value":null,"actions":["AXPress"],"enabled":true,"focused":false,
 "bounds":{"x":215,"y":784,"width":82,"height":26}}
```

- `ref` — the integer you pass to `press`/`set-value`/`scroll --ref`.
- `actions` — what the element supports (`AXPress`, `AXConfirm`, `AXShowMenu`,
  `AXScrollToVisible`, …). Only act on a ref whose `actions` include what you
  need; `press` requires `AXPress`.
- `bounds` — screen-space rect (points). Use the center for spatial fallback.
- `hint-mode`: `leafCompact` (default) refs only actionable leaves; `full`
  refs every node; `leafOnly` refs actionable leaves incl. editable areas.

**Ref stability:** refs are valid only for that `snapshotId` and only while the
window is unchanged. Any mutation (`press`, typing) may change the tree —
**re-snapshot before your next ref action.** A stale snapshot returns
`STALE_SNAPSHOT` (exit 5) → re-snapshot and re-derive the ref.

### 3. Spatial path — screenshot → pixel → act

```sh
nuvin-computer-use screenshot --app Notes --window 12345 \
    --output /tmp/notes.png --overwrite --json
# → data.captureId, data.width/height (image px), data.target.bounds (screen pt)

# Whole-desktop computer-use: bare captures the main display,
# --display <n> picks a monitor (1-based).
nuvin-computer-use screenshot --output /tmp/screen.png --json
nuvin-computer-use screenshot --display 2 --output /tmp/screen2.png --json

nuvin-computer-use click --capture <uuid> --x 420 --y 180 --json
nuvin-computer-use move  --capture <uuid> --x 420 --y 180 --json
nuvin-computer-use drag  --capture <uuid> --from 420,180 --to 620,300 --json
```

- The PNG is **logical resolution** (1×) by default — `data.width/height`
  equal the window's logical size. Pass `--native` for full Retina pixels
  when you need sharper text (e.g. OCR); `--x`/`--y`/`--from`/`--to` are
  always image pixels and map back correctly either way.
- `--annotated` draws numbered ref badges on the PNG *and* returns the AX tree —
  the fastest way to correlate "what I see" with "what I can press."
  (Window targets only — display captures have no AX tree to annotate.)
- `--capture` ids expire in 10 min and are invalid if the window moved —
  `STALE_CAPTURE` → re-screenshot. For display captures, `click`/`move`/`drag`
  map pixels into whole-screen space the same way.

#### Canvas & custom-drawn UI

Canvas, games, paint apps, and any pixel-rendered surface have **no AX tree** —
`--annotated` and `press`/`set-value` can't reach them. The spatial path is the
only way in, and it's sufficient: `screenshot` → read the PNG → `click`/`drag`
pixels. Verified end-to-end (drew on jspaint.app's canvas).

- **Drawing = many `drag`s.** A `drag` is one straight left-button stroke.
  Compose shapes from short drags: an octagon ≈ 8 drags vertex-to-vertex; an
  arc ≈ 2-3 drags. There's no multi-point path primitive — build curves from
  segments. `click` = a point (dot, a toolbar cell, a color swatch).
- **Tools & colors are just pixels.** Toolbar cells and swatch rows aren't AX
  elements — `click` their image-pixel centers to select, then `drag` on the
  canvas. Read swatch positions carefully off the PNG (two-row palettes are
  easy to mis-pick — verify the active color with a re-`screenshot` before a
  long draw).
- **Always re-`screenshot` to confirm.** Pointer ops report `dispatched` —
  the event was posted, not that the canvas changed. Re-capture and look.
- **Canvas pixels ≠ window pixels.** `--x`/`--y`/`--from`/`--to` are image
  pixels across the *whole captured region* (window or display) — compute a
  control's pixel from the PNG's own coordinates, not from memory of the
  window layout.

### 4. Raw input

```sh
nuvin-computer-use type --app Notes --text "hello"        # keystrokes (Unicode ok)
nuvin-computer-use type --app Notes --text-file -         # read text from stdin
nuvin-computer-use type --app Notes --text "x" --to-process  # post to the app's queue, no activation
nuvin-computer-use type --text "x"                        # bare = type into whatever holds focus
nuvin-computer-use key  --app Notes --key cmd+s           # chord: cmd,ctrl,alt,shift + key
nuvin-computer-use key  --key cmd+space                   # bare = system-wide chord (Spotlight etc.)
nuvin-computer-use scroll --app Notes --direction down --amount 3
```

`type`/`key`/`scroll --direction` target the **app/window**, not a ref — they
post input to whatever has focus inside that window. Focus the right field
first (`click` it or `press` it via a ref).

`key`/`type` have three delivery modes:

- **`--app`/`--pid` (default): activate, then type.** The named app is raised
  frontmost (stealing focus) and the input is posted to the HID event tap, so
  it reaches the app *and* its panels/helper-hosted windows — this is what
  lets `key --app X --key escape` dismiss an `NSOpenPanel`. If the app can't
  be raised the command fails `FOCUS_FAILED` with `mutationStatus:
  "notStarted"` — nothing was posted.
- **`--to-process`: background queue.** Posts to the app's own event queue
  without activating it — for input to an app that must stay in the
  background. It cannot reach panels (they live in another process's queue).
  Requires `--app`/`--pid`.
- **bare `key`, bare `type`, `type --global`: whatever holds focus.** No
  activation; the input lands on the currently focused app — useful for
  global shortcuts like Spotlight.

## Safety contract — read this before automating

- **This is real foreground input.** `click`/`type`/`key` move the physical
  pointer and post real events to the focused app. There is no sandbox and no
  semantic reviewer — a click on "Delete" deletes.
- **`verification` honesty.** Success replies carry `data.verification`:
  `verified` = the AX action itself succeeded (`press`/`set-value`/
  `scroll --ref`); `dispatched` = the event was posted (`key`/`type`/
  `click`/`move`/`drag`/directional `scroll`) — it may land but be
  unobserved, so it says nothing about effect. Neither means the UI changed;
  re-observe when it matters.
- **`mutationStatus` honesty.** On a failure, `error.details.mutationStatus`
  tells you whether input may have been dispatched:
  `notStarted` = dispatch never began (e.g. `FOCUS_FAILED`, a focus-targeted
  `key`/`type` whose app never came frontmost) — safe to retry blindly;
  `potentiallyApplied` = **re-observe before retrying** (the action may
  have already happened).
- **Never pass secrets via `--text`** — it's visible in shell history and
  process lists. Use `--text-file -` and pipe via stdin. Supplied text is
  never echoed back in replies.
- **State is private and short-lived.** Snapshots/captures live under
  `~/Library/Application Support/nuvin-computer-use/` (`0700`/`0600`), expire
  in 10 min, and contain on-screen text — treat as sensitive.
- **`--cursor off`** disables only the visual overlay — not safety checks.

## Failure → recovery recipes

| You get | Do |
|---|---|
| `TARGET_NOT_FOUND` | App login-launched (Finder/Dock) or panel-service dialog → target a real window; dismiss `NSOpenPanel` with `key --app X --key escape` |
| `AMBIGUOUS_TARGET` | add `--window <id>` from `windows` output |
| `INELIGIBLE_TARGET` | window minimized/off-Space — bring it on-screen first |
| `FOCUS_FAILED` | `--app`/`--pid` `key`/`type` couldn't raise the app — verify it's running (`apps`), then retry; `notStarted`, so a retry is safe |
| `STALE_SNAPSHOT` / `STALE_CAPTURE` | re-run `snapshot`/`screenshot`, re-derive ref/coords |
| `PERMISSION_DENIED` | Accessibility/Screen Recording missing → `doctor`, tell user to grant to the launching terminal |
| `EXECUTION_UNCERTAIN`/`potentiallyApplied` | **don't blind-retry** — snapshot/screenshot to see if it already happened |

## Minimal agent loop (pseudocode)

```
reply = run("snapshot --app {app} --window {wid} --json")
if !reply.ok: handle(reply.error.code); continue
el = pick(reply.data.tree.elements, by: role/label/actions)
act  = run(f"press --snapshot {reply.data.snapshotId} --ref {el.ref} --json")
if act.error?.code in (STALE_SNAPSHOT, STALE_CAPTURE): re-snapshot; continue
if act.error?.details.mutationStatus == "potentiallyApplied": re-observe first
```

## Limits (don't promise these)

- Only the named foreground target — no background/locked-screen automation.
- No input isolation: your events interleave with the real user's.
- No semantic understanding of what a control *does* — you chose it.
- `press`/`set-value` success = the AX call was accepted, not that the UI
  changed. Verify with a fresh `snapshot`/`screenshot` when it matters.
