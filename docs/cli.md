# `nuvin-computer-use` CLI

macOS desktop automation: a TypeScript CLI that spawns a per-command
Swift/AppKit helper (`dist/native/computer-use-host`) for accessibility-tree
(AX), screenshot, and input operations. Foreground automation, macOS only.

## Install / invoke

```sh
npm install -g .            # or: npm link
nuvin-computer-use <command> [flags]
```

The npm `bin` name is `nuvin-computer-use`. The helper is bundled inside the
package (`dist/native/computer-use-host`) — no `~/.nuvin` install required.

From a source checkout without installing:

```sh
npm run build               # TS -> dist/  +  Swift host -> dist/native/computer-use-host
./dist/cli.js <command>     # executable; or: node dist/cli.js
```

**Flag order matters:** all flags come *after* the command name.
`snapshot --app Notes --json` works; `--json snapshot` is rejected as a
positional argument.

## Commands

| Command | Synopsis |
|---|---|
| `doctor` | report permissions + helper protocol (read-only) |
| `apps` | list running applications (name, bundleId, pid) |
| `windows` | list windows for an app, with eligibility + reason |
| `snapshot` | capture a window's AX tree → `--snapshot` id |
| `press` | AXPress an element by `--snapshot <uuid> --ref N` |
| `set-value` | set AXValue on a ref |
| `type` | type text into a targeted app |
| `key` | send a key/modifier chord (`--key cmd+s`); bare = global chord |
| `scroll` | directional scroll, or scroll-to-ref |
| `screenshot` | save a PNG of one window or a full display → `--capture` id |
| `click` `move` `drag` | pointer ops on a `--capture` id's image pixels |

All 13 commands are implemented and dispatch real work.

## Read-only commands

### `doctor`

```sh
nuvin-computer-use doctor --json
# {"schemaVersion":1,"ok":true,"command":"doctor","data":{"ready":true,"checks":[
#   {"name":"helper-protocol","status":"ok","message":"Protocol version 1"},
#   {"name":"native-dependencies","status":"ok", ...},
#   {"name":"accessibility","status":"ok", ...},
#   {"name":"screen-recording","status":"ok", ...}]}}
```

Read-only and truthful: exits `0` when `ready:true`; when any check fails,
exits with the first failing check's category (`denied`→4, `missing`→3, else
1). Never prompts, installs, or writes state.

### `apps` / `windows`

```sh
nuvin-computer-use apps --json
nuvin-computer-use windows --app Finder --json
```

`apps` lists inventory even when a trustworthy process start is unavailable.
For `--app`, exact bundle-ID matches take precedence over name matches. If
several processes share that exact bundle, only that set is considered: a
unique regular app may disambiguate; otherwise selection is
`AMBIGUOUS_TARGET`. A differently bundled name collision cannot win. Only
when there are no exact bundle matches do exact names use the unique regular
app preference. `--pid` selects exactly that process, including helpers.

`windows` reports every matched window's `eligible` flag and reason. Minimized
or off-screen windows are ineligible; AX subrole `AXUnknown` is reported as
`eligible:false` / `reason:"nonStandardWindow"`. Listing does not require a
unique eligible window or a process start identity; snapshot/action targeting
does.

## Snapshot → element actions

```sh
nuvin-computer-use snapshot --app Notes [--window <id>] [--depth N] [--max-elements N] [--hint-mode full|leafOnly|leafCompact] --json
nuvin-computer-use press --snapshot <uuid> --ref 12 --json
nuvin-computer-use set-value --snapshot <uuid> --ref 7 --text "example"
```

- Exactly one of `--app` (name or bundleId, unambiguous) or `--pid`.
- `--window` optional only when exactly one eligible window exists.
- Snapshot records persist to `~/Library/Application Support/nuvin-computer-use/snapshots/` (dir `0700`, files `0600`), expire after 10 min, and are swept by later invocations. **They contain visible text — treat as sensitive.**

### Presentation and traversal

Traversal defaults and action validation remain unchanged.
Defaults are `--depth 8`, `--max-elements 500`, `--hint-mode leafCompact`,
`--timeout 15000` (maximum `120000` ms), and a 10-minute snapshot lifetime.
Depth and element limits bound **observation**; hint mode changes presentation
and ref policy, not which nodes the traversal visits.

- `leafCompact` keeps the real root, refs, traversal boundaries, meaningful
  descriptive/state/action nodes, and their ancestor context. It collapses
  only anonymous, non-root `AXGroup`/`AXScrollArea` wrappers with exactly one
  observed direct child and one retained child, and no ref, boundary,
  description, action, disabled state, or true focused/selected state.
  Neutral `enabled:true`, `focused:false`, `selected:false` do not
  prevent that narrow collapse. Retained fields keep their original values.
- Compact non-ref context omits bounds; ref-bearing nodes keep available
  bounds, and root geometry remains in `data.target.bounds`. All original
  evidence, including hidden wrappers' states and geometry, remains available
  to action validation. Projected child indexes are **not ref IDs**.
- `leafOnly` is the verbose tree/geometry alternative with the **same leaf
  ref policy** as `leafCompact`. Both select eligible actionable leaves and
  editable areas under the existing boundary exclusions; text can be shown
  without any ref. `full` retains the verbose tree but uses a different ref
  policy, including non-actionable nodes. A boundary node itself and
  depth-excluded or incomplete subtrees cannot supply safe refs. A completed
  descendant subtree can retain refs below a `maxElements` ancestor when a
  later sibling was not visited. Every action still validates the full stored
  evidence, target identity and fresh ref/element continuity before dispatch;
  a displayed ref alone is not an action guarantee.

A static-text-rich compact reply may be larger than the old ref-only view.
Compaction neither reclaims traversal budget nor recovers unvisited nodes.
Use `--json` to read the single structured reply; non-JSON output stays a
short success line, without a second Markdown tree or automatic screenshot.

### Snapshot coverage

New helpers include `data.coverage` on snapshots and explicitly requested
window `screenshot --annotated` replies. Coverage is optional only for legacy
protocol-1 replies: missing coverage means **unknown diagnostics**, not zero
counts or a complete traversal. Consumers must accept omission without
inventing coverage; malformed known fields are rejected. Schema version
remains `1`; package the updated native producer and TypeScript consumer
together.

| Field | Meaning |
|---|---|
| `scope` | Always `"selectedWindow"`; not a whole-app or whole-desktop inventory. |
| `absenceIsConclusive` | Always `false`, even when there are no boundaries. Missing UI remains unknown. |
| `observedNodes` | Number of nodes actually recorded in original AX evidence. |
| `emittedNodes` | Number of JSON tree nodes after presentation; the difference from observed nodes is presentation-only. |
| `refCount` | Number of derived refs, **not** a count of actionable controls (especially in `full`). |
| `limits.maxDepth`, `limits.maxElements` | Actual requested traversal options, not a promise of full coverage. |
| `boundaries` | Emitted traversal-cut diagnostics from original evidence paths, not a complete copy of persisted evidence when diagnostics are summarized. Empty when no cut was recorded. |
| `boundaries[].path` | Original zero-based evidence child path; `[]` is the real root. Never resolve it against projected compact child indexes. |
| `boundaries[].reason` | `"maxDepth"` or `"maxElements"`; no timeout/cancellation boundary reason. |
| `boundaries[].observedChildren` | Observed **direct children** of that boundary node. |
| `boundaries[].totalChildren` | Reported total **direct children**, not total omitted descendants. |
| `omittedBoundaries` | Positive optional count of depth-cut diagnostics omitted from this reply; absent when none were omitted. Full persisted evidence is retained. |
| `noRefReason` | Omitted when refs exist. With zero refs: `"traversalLimited"` if boundaries exist, otherwise `"noEligibleRefs"`. Describes the observed condition, not a proved root cause. |

Coverage uses a 32-entry diagnostic budget, retaining **all `maxElements`
cuts** and filling the remaining budget with depth cuts. Excess depth
diagnostics are summarized by positive `omittedBoundaries`. This is not an
absolute 32-entry cap: retaining all element-cap cuts can exceed that budget.
Stored evidence and action validation keep every boundary, including those
not emitted. Missing legacy coverage remains unknown, not proof of readiness,
absence or completeness; known fields remain strictly validated.

`data.truncated` remains present and matches whether boundaries exist. A root
element-cap boundary can legitimately exclude every ref in **all** hint
modes. For example, a root with two children, whose first child itself has
one child, observed with `--max-elements 2` yields this coverage:

```json
{
  "scope": "selectedWindow",
  "absenceIsConclusive": false,
  "observedNodes": 2,
  "emittedNodes": 2,
  "refCount": 0,
  "limits": {"maxDepth": 8, "maxElements": 2},
  "boundaries": [
    {"path": [0], "reason": "maxElements", "observedChildren": 0, "totalChildren": 1},
    {"path": [], "reason": "maxElements", "observedChildren": 1, "totalChildren": 2}
  ],
  "noRefReason": "traversalLimited"
}
```

This is a successful bounded observation with a real nonempty root, not an
empty window. Failed target resolution and hard AX observation failures
(such as permission, liveness, or unresponsive-server errors) still return
errors; `TIMEOUT` and `INTERRUPTED` never become successful partial snapshots.
Existing compatibility behavior treats a bare `AXError.failure` on an optional
scalar or action-list read as unavailable: a successful snapshot may omit that
scalar or report no actions. That scalar compatibility does not apply to
setup or top-level batch failures. Only raw top-level `attributeUnsupported`
permits individual-read compatibility fallback; hard batch errors and malformed
successful batches fail without retrying singles. Success does not guarantee
every optional AX attribute was available.
See [recovery guidance](agent-guide.md#snapshot-coverage-and-recovery) for
limit-specific retries and explicit screenshots. Use the **new snapshot's
refs** after every retry or mode change.

### Bounded preparation (requested, not ready)

The shipping snapshot path performs bounded `AXSnapshotPreparation` inside
the desktop lock, bracketed by target identity checks before and after it.
Trust and an exact positive PID are validated before optional state/read/write
IPC. Each call uses a requested messaging-timeout cap of at most 250 ms,
recomputed against the remaining command budget after application creation;
synchronous native calls are not forcibly cancelled by that cap.

Only an actual optional `AXManualAccessibility`/`AXEnhancedUserInterface`
write returning `attributeUnsupported`, `failure` or `illegalArgument` can
reject that write and negotiate the next attribute. Both rejected means
unsupported, not ready. The optional manual-state read accepts only a strict
Boolean success or absence (`attributeUnsupported`/`noValue`); timeout setup
must succeed. Malformed successful state, setup errors, permission/liveness
failures, cancellation and deadline expiry stop observation/publication rather
than becoming preparation success. `apiDisabled` remains `PERMISSION_DENIED`;
other hard AX errors remain `NATIVE_FAILURE`.

A newly requested manual enable with prior state not true waits 250 ms only
when more than 500 ms remains; enhanced/unsupported/already-enabled or lower
budgets do not incur that wait. A successful write means **requested**, not
“web AX ready” or browser fixed. Identity checks, preparation and observation
consume the same deadline/lock budget; live latency and side effects are
unmeasured. Preparation is not run during action validation.

## Direct input

```sh
nuvin-computer-use type --app Notes --text "hello" [--allow-clipboard-replace]
nuvin-computer-use type --app Notes --text-file -          # stdin; keeps text off argv
nuvin-computer-use type --app Notes --text "x" --to-process  # background queue; no activation
nuvin-computer-use type --text "x"                         # bare = type into whatever holds focus
nuvin-computer-use key  --app Notes --key cmd+s
nuvin-computer-use key  --app Notes --key cmd+s --to-process # background queue; no activation
nuvin-computer-use key  --key cmd+space                      # bare = system-wide chord (e.g. Spotlight)
nuvin-computer-use scroll --app Notes --direction down --amount 3
nuvin-computer-use scroll --snapshot <uuid> --ref 20       # mutually exclusive with direction form
```

`key`/`type` delivery modes:

- **`--app`/`--pid` (default)** — the named app is **activated** (raised, takes
  focus) before the input is posted to the HID event tap, so it lands on the
  app *and* its panels/helper-hosted windows that don't share the app's event
  queue. If the app can't be raised, the command fails `FOCUS_FAILED` before
  any input is posted.
- **`--to-process`** — posts to the app's own event queue in the background
  without activating it. Reaches the app but not open/save panels. Requires
  `--app`/`--pid`.
- **bare `key`, bare `type`, `type --global`** — no activation; the input goes
  to the HID tap and lands on whatever currently holds focus.

## Screenshot → pointer actions

```sh
nuvin-computer-use screenshot [--app Notes|--display <n>] --output ./notes.png [--overwrite] [--annotated] --json
# -> data.captureId
# bare (no --app/--pid/--display) captures the main display;
# --display <n> picks a monitor (1-based)

nuvin-computer-use click --capture <uuid> --x 420 --y 180 [--button left|right|middle] [--count 1|2|3]
nuvin-computer-use move  --capture <uuid> --x 420 --y 180
nuvin-computer-use drag  --capture <uuid> --from 420,180 --to 620,300
```

Screenshots are a separate explicit command; `snapshot` never captures one
automatically. `--annotated` requires a window target and requests one new
snapshot, returning its `snapshotId`, tree, `truncated`, and coverage alongside
the capture. It uses the same depth 8 / 500 nodes / `leafCompact` defaults
unless overridden. Badges use original evidence-ref bounds, never compact
context geometry; use that returned snapshot's refs for semantic actions.
Plain window/display captures do not include an AX tree or coverage.

`--x`/`--y`/`--from`/`--to` are **image pixels** in the saved PNG, translated
back to screen coordinates via the capture record (Retina-aware). Display
captures work identically for `click`/`move`/`drag` — pixels map into the
whole-screen space. Pointer ops check that the target is still on screen
before dispatch.

## Global flags

- `--json` — one JSON object on stdout; diagnostics to stderr.
- `--timeout <ms>` — 1–120000 (default 15000); enforced TS and Swift.
- `--cursor on|off` — virtual-cursor overlay for spatial actions. Default on.
  **Disables the visualization only — not execution safety checks.**
- `--help`, `--version` — global or per-command.

## Output and exit codes

Success: `{"schemaVersion":1,"ok":true,"command":"...","data":{...}}`
Error:   `{"schemaVersion":1,"ok":false,"command":"...","error":{"code":"...","message":"...","details":{...}}}`

Mutation replies (`press`/`set-value`/`key`/`type`/`scroll`/`click`/`move`/`drag`)
report what is actually provable:

- `data.method` — `accessibility` (AX action on a snapshot ref) or `cg-event`
  (posted CoreGraphics event).
- `data.verification` — `verified` when the AX call itself succeeded
  (`accessibility` method); `dispatched` when the event was posted
  (`cg-event` method). `dispatched` does **not** mean the input had effect —
  delivery can't be observed. Re-screenshot/snapshot to confirm.
- `error.details.mutationStatus` — on failure only: `notStarted` (dispatch
  never began, e.g. `FOCUS_FAILED`) or `potentiallyApplied` (the event may
  have run — re-observe before retrying).

| Exit | Codes |
|---|---|
| 0 | success |
| 1 | `NATIVE_FAILURE` `PROTOCOL_ERROR` `UNSUPPORTED_ACTION` `EXECUTION_UNCERTAIN` |
| 2 | `INVALID_ARGUMENT` |
| 3 | `UNSUPPORTED_PLATFORM` `MISSING_HELPER` `HELPER_VERSION_MISMATCH` `MISSING_DEPENDENCY` |
| 4 | `PERMISSION_DENIED` |
| 5 | `TARGET_NOT_FOUND` `AMBIGUOUS_TARGET` `INELIGIBLE_TARGET` `STALE_SNAPSHOT` `STALE_CAPTURE` `FOCUS_FAILED` |
| 6 | `TIMEOUT` `BUSY` |
| 130 | `INTERRUPTED` (Ctrl+C) |

## Security and privacy notes

- **Foreground automation, no sandbox.** These commands move the real pointer
  and post real input to the named target. Grant Accessibility + Screen
  Recording to the launching terminal — see `docs/permissions.md`.
- **Don't pass secrets on the command line** — `--text` is visible in shell
  history and process lists. Prefer `--text-file -` (stdin). Text is capped
  at 1 MiB.
- **Supplied text is never echoed** in replies or diagnostics; the reply
  projector strips it even from helper output.
- **Every helper reply is shape-validated** — command echo, UUID shape, ref
  contiguity, expiry arithmetic, and controlled
  `method`/`verification`/`visualization` values.
- **State is private and short-lived** — snapshots/captures under
  `~/Library/Application Support/nuvin-computer-use/` (`0700`/`0600`), 10-min
  expiry, contain visible text. Don't commit or share them.

## Testing

Run composed-candidate automated gates separately, in this order:

```sh
npm run native-tests          # complete Swift fixture suite
npm run typecheck
npm test                      # vitest with mock hosts
npm run test:native-protocol   # protocol-version and invalid requests only
npm run test:build-hygiene
npm run build                 # complete TS + release-native build
npm test                      # post-build mock rerun
```

See `docs/testing.md` for fixture/build evidence versus later independent
review and integrated-main automated checks. This integration's real-app
acceptance is **user-owned / NOT RUN by workers/coordinator** (including
Chrome, keyboard and Shopee); it is **not an automated or local-integration
gate**. Automated success does not establish live readiness or release approval.

## Known limitations

- AppKit launch date is preferred for process start identity. When it is
  missing, targeting uses a validated matching-PID kernel process start.
  If neither source provides a trustworthy start, targeting still reports
  `TARGET_NOT_FOUND`, while application/window inventory remains available.
  Persisted identity uses exact comparison: a source
  transition with different formatted timestamps can reject as stale.
- Open/Save dialogs (`NSOpenPanel`/`NSSavePanel`) may be hosted by a separate
  service. `--app` targets the named application's own windows; targeting a
  service by `--pid` still depends on trustworthy start identity, a unique
  eligible window match, and permissions. Panel targeting is not guaranteed.
- Apps on an inactive Space, minimized, or with non-standard window-server
  reporting report `TARGET_NOT_FOUND` / `INELIGIBLE_TARGET`.
- `press`/`set-value` rely on the app honoring the AX action; success means
  the call was accepted, not that the UI visibly changed.
- `screenshot --annotated` overlays numbered ref-hint badges at each
  snapshot ref's bounds — read the PNG to map pixels → `--ref`. Badges scale
  with the capture: `--native` draws them at Retina size.

See `docs/superpowers/specs/2026-09-08-standalone-cli-design.md` for the full
contract and `docs/permissions.md` for TCC/attribution detail.
