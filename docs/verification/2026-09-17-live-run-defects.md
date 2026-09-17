# Live-run defect report — Chrome window targeting (2026-09-17)

Field report from a real end-to-end session driven through the agent skill
(`nuvin-computer-use`), not a synthetic fixture run. All evidence is verbatim
CLI output from the session log.

## Environment

| | |
|---|---|
| CLI | `nuvin-computer-use --version` → `0.1.0` |
| Host | macOS, darwin arm64, single display 2056×1329 (logical) |
| `doctor` | `ready: true` — accessibility `ok`, screen-recording `ok` |
| Target app | Google Chrome (`com.google.Chrome`, pid 76606), 2 tabs, window visible on screen |
| Session | 2026-09-17, ~19:38–19:45 local |

Task being performed: open Chrome → play a song → open a paint app → draw on a
canvas with the spatial path.

## Timeline

| # | Command | Result |
|---|---|---|
| 1 | `windows --app "Google Chrome"` (after `open -a`) | ✅ window `51732`, `eligible: true` |
| 2 | `snapshot --app "Google Chrome" --window 51732` | ⚠️ `ok:true`, tree of **1** node (`AXWindow`, `ref: null`) |
| 3 | `screenshot --app "Google Chrome" --window 51732` | ✅ capture `52e5368b…` (2056×1290) |
| 4 | `click --capture 52e5368b… --x 760 --y 350` | ✅ `verified` — click landed, video started |
| 5 | `screenshot --app "Google Chrome" --window 51732` | ❌ `TARGET_NOT_FOUND` — "Window was not found" |
| 6 | `windows --app "Google Chrome"` | ❌ `{"windows":[]}` — and never recovers |
| 7 | `windows --pid 76606`, `windows --app com.google.Chrome` | ❌ `{"windows":[]}` |
| 8 | `windows --app Finder` (control) | ✅ 2 windows, `eligible: true` |
| 9 | `key --app "Google Chrome" --key cmd+t` | ❌ `TARGET_NOT_FOUND`, `mutationStatus: potentiallyApplied` |
| 10 | `type --app "Google Chrome" --text "jspaint.app"` | ❌ `TARGET_NOT_FOUND`, `mutationStatus: potentiallyApplied` |
| 11 | display-space `screenshot` + `click` on Chrome | ✅ worked throughout (pixel path unaffected) |

The break at step 4→5 is the whole story: **the one window target that worked
became permanently unfindable, silently, while the window itself stayed alive
and interactive.**

---

## D1 — High: Chrome window list goes permanently and silently empty mid-session

**Symptom.** `windows --app "Google Chrome"` first returned the window, then
began returning an empty list forever. Every window-scoped command
(`snapshot`, `screenshot --window`, `key`, `type`) then fails with
`TARGET_NOT_FOUND`, even though the window is on-screen, frontmost, and
receiving clicks from the same CLI's display-space path.

**Evidence.**

```
# step 1 — works
{"schemaVersion":1,"ok":true,"command":"windows","data":{"windows":[{"id":51732,
"title":"daft punk get lucky - YouTube","bounds":{"x":0,"y":39,"width":2056,
"height":1290},"eligible":true,"reason":null}]}}

# step 5 — after a click the CLI itself reported as `verified`
{"schemaVersion":1,"ok":false,"command":"screenshot","error":{"code":
"TARGET_NOT_FOUND","message":"Window was not found"}}          # exit 5

# steps 6–7 — forever after, including ~6 minutes later while the window is visible
{"schemaVersion":1,"ok":true,"command":"windows","data":{"windows":[]}}

# step 8 — same helper, same moment, another app enumerates fine
{"schemaVersion":1,"ok":true,"command":"windows","data":{"windows":[{"id":49018,
"title":"Desktop — Local",…,"eligible":true,"reason":null},…]}}
```

**Why it matters.** The skill's primary guidance is "prefer semantic when the
element has a `ref`". For a Chromium app this degrades to *nothing at all*, with
no error, no `reason`, and no recovery path — `ok:true` with an empty array is
indistinguishable from "this app really has no windows". A caller that trusts
`ok` concludes Chrome is windowless.

**Suspected cause (unconfirmed, worth isolating).** The failure coincides
exactly with Chrome beginning HTML5 video playback after step 4. Most likely the
Chromium AX window query is timing out or erroring (heavy AX tree / busy
renderer) and the helper swallows it into an empty success instead of surfacing
`TIMEOUT`/`NATIVE_FAILURE`.

**Suggested direction.**
1. Do not collapse a failed AX enumeration into `ok:true, windows:[]`. Propagate
   the underlying AX error/timeout, and self-heal on the next call.
2. Add a recovery/force path (`--force`, cache-bypass, or an AX re-query) so a
   single transient AX failure doesn't poison the target for the session.
3. Log the per-app AX query outcome somewhere inspectable (`--verbose`).
4. Reproduce matrix to pin the trigger: idle Chrome vs. media-playing Chrome vs.
   Chrome with a heavy page; and confirm whether other Chromium apps (Arc,
   Electron) behave the same.

## D2 — High: `snapshot` on Chromium returns one non-actionable node with no diagnostic

**Symptom.** `snapshot` reports success but the tree contains only the window
itself, so no `ref` exists to press or set. There is no hint that the web content
is unreachable or why.

**Evidence.** Steps 2 (repeated twice, same result):

```
ok True
snapshotId 1f1018b6-2054-4755-8cfc-ac2b934caa7d  n 1
AXWindow | ref None | daft punk get lucky - YouTube - Google Chrome - Test-MCP
```

`ref` is `null`, so `press`/`set-value` are unreachable by construction.

**Suggested direction.** Chromium does not build its renderer AX tree until a
client sets `AXManualAccessibility` (`kCFBooleanTrue`) on the app's AX element
(VoiceOver does this implicitly). Setting it before snapshotting a Chromium-based
app would restore the documented semantic path. At minimum, detect the
"window-only tree" shape and return a warning such as
`AX_TREE_NOT_EXPOSED (set AXManualAccessibility or fall back to the pixel path)`
instead of a silent 1-node success.

## D3 — Medium: `type` has no windowless mode, so text entry dies with the target

**Symptom.** When window targeting breaks, `key` still has a documented bare
"system-wide chord" mode, but `type` requires `--app|--pid` — so there is **no
way to enter text at all**, even though focus is already in the right app.

**Evidence.** `type --help`:

```
type --app <name>|--pid <pid> (--text <s>|--text-file <path>) [--allow-clipboard-replace] — type text.
```

**Suggested direction.** Add `type --global` (post to whatever holds focus, as
bare `key` already does) and/or a clipboard-backed `type --paste` mode. Note
`--allow-clipboard-replace` already exists, so the plumbing is half-present.

## D4 — Medium: `mutationStatus: potentiallyApplied` is wrong for pre-dispatch failures

**Symptom.** Target-resolution failures report `potentiallyApplied`, which per
the safety contract forces "never blind-retry — observe first" and costs a full
re-screenshot round-trip. In this run the events were provably **never
dispatched**.

**Evidence.**

```
{"schemaVersion":1,"ok":false,"command":"key","error":{"code":"TARGET_NOT_FOUND",
"message":"Window was not found","details":{"mutationStatus":"potentiallyApplied"}}}
{"schemaVersion":1,"ok":false,"command":"type","error":{"code":"TARGET_NOT_FOUND",
"message":"Window was not found","details":{"mutationStatus":"potentiallyApplied"}}}
```

Verification: a display screenshot taken immediately afterwards shows **no new
tab** (the tab strip still has exactly the same two tabs) and the omnibox was
never populated — `cmd+t` and the typed URL never reached Chrome.

**Suggested direction.** Derive `mutationStatus` from whether the event was
actually posted, not from the error class. A failure during target *resolution*
is `notStarted`; reserve `potentiallyApplied` for post-dispatch uncertainty.

## D5 — Low: no activation / open / URL verb, forcing an out-of-band fallback

Chrome was running with zero windows. `apps` shows it, `windows` shows nothing,
and there is no way to get from "running, windowless" to "addressable window"
inside the CLI — I had to shell out to `open -a "Google Chrome" <url>`. Ironically
that `open` created a tab inside window `51732`, a window the helper insisted did
not exist (D1).

**Suggested direction.** `activate --app <name>` (bring to front / raise /
re-open window) and optionally `open --app <name> --url <url>`, so the whole loop
stays in one tool.

## D6 — Low: display-capture metadata is not correlatable

Full-display captures report `title: "Display 1"`, `windowId: 1`,
`bundleId: null`, and a `pid` that changes on **every single call**:

```
18740 → 18833 → 18957 → 19225 → 19662
```

That pid is the helper's own throwaway process, not the captured target, and the
same fields are meaningful for window captures. Consumers cannot tell from a
capture record which display/host actually produced it.

**Suggested direction.** For display captures omit target-style identity fields or
fill them with the owning display (display id, scale, native vs. logical) rather
than `windowId: 1` / a per-invocation pid.

## Minor observations (low confidence, catalogued for completeness)

- Window titles seen by the helper carried a ` - Test-MCP` suffix
  (`"daft punk get lucky - YouTube - Google Chrome - Test-MCP"`). Possibly a Chrome
  automation/extension artifact in this machine's profile; flagging in case it
  indicates the helper attaching to a non-default Chrome instance.
- `snapshot` role strings are AX-prefixed (`AXWindow`) while the skill docs describe
  roles as `button`, `field`, `menu`. Worth aligning, since agents match on those
  strings.
- `doctor` reports `"No external helper dependency is required by this host version"`
  while a `computer-use-host` process is running. Probably just message wording.

---

## What worked (so the pixel path isn't over-corrected)

The spatial path was rock solid throughout, including on the window whose target
had gone missing: full-display `screenshot` → read pixel → `click` landed
precisely on YouTube's Skip button and on a video thumbnail, and `drag`-based
drawing on a canvas is reachable the same way. `--capture` id handling, expiry,
and stale-id semantics never bit me. D1–D4 are about the **semantic/targeting**
layer only.

## Minimal repro for the dev team

```sh
open -a "Google Chrome" "https://www.youtube.com/results?search_query=test"
sleep 4
nuvin-computer-use windows --app "Google Chrome" --json            # ✅ window id, eligible:true
nuvin-computer-use screenshot --app "Google Chrome" --window <id> \
    --output /tmp/a.png --overwrite --json                          # ✅ captureId
nuvin-computer-use click --capture <captureId> --x 760 --y 350 --json  # ✅ verified — starts a video
nuvin-computer-use windows --app "Google Chrome" --json            # ❌ [] — never recovers
nuvin-computer-use screenshot --app "Google Chrome" --window <id> --json  # ❌ TARGET_NOT_FOUND, exit 5
```

The click that appears to trigger it is the one that begins media playback; test
with a click that doesn't start a video to confirm whether playback (AX tree
load) is the real trigger or the click itself is coincidental.
