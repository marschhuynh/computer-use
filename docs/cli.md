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

`windows` reports each window's `eligible` flag and the reason when
ineligible (minimized, off-screen, etc.).

## Snapshot → element actions

```sh
nuvin-computer-use snapshot --app Notes [--window <id>] [--depth N] [--max-elements N] [--hint-mode full|leafOnly|leafCompact] --json
nuvin-computer-use press --snapshot <uuid> --ref 12 --json
nuvin-computer-use set-value --snapshot <uuid> --ref 7 --text "example"
```

- Exactly one of `--app` (name or bundleId, unambiguous) or `--pid`.
- `--window` optional only when exactly one eligible window exists.
- Snapshot records persist to `~/Library/Application Support/nuvin-computer-use/snapshots/` (dir `0700`, files `0600`), expire after 10 min, and are swept by later invocations. **They contain visible text — treat as sensitive.**

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

```sh
npm run typecheck
npm test                      # vitest, fully mocked
npm run native-tests          # Swift XCTest (fixtures)
npm run test:native-protocol  # real host over stdio
npm run test:build-hygiene
node scripts/package-smoke.mjs  # isolated-install end-to-end
```

See `docs/testing.md` for what each layer does and does not prove, and for
live-acceptance gating.

## Known limitations

- Target resolution fails for login-launched apps (Finder, Dock,
  SystemUIServer) where `NSRunningApplication.launchDate` is `nil` —
  reports `TARGET_NOT_FOUND`.
- **`NSOpenPanel`/`NSSavePanel` are untargetable.** Open/Save dialogs run in
  a separate `openAndSavePanelService` process (no `launchDate`), so the
  dialog window can't be resolved by `--app` (the app owns no such window) or
  by `--pid` (the service has no start identity). Dismiss the panel via
  `key --app <app> --key escape`, then target the app's real window.
- Apps on an inactive Space, minimized, or with non-standard window-server
  reporting report `TARGET_NOT_FOUND` / `INELIGIBLE_TARGET`.
- `press`/`set-value` rely on the app honoring the AX action; success means
  the call was accepted, not that the UI visibly changed.
- `screenshot --annotated` overlays numbered ref-hint badges at each
  snapshot ref's bounds — read the PNG to map pixels → `--ref`. Badges scale
  with the capture: `--native` draws them at Retina size.

See `docs/superpowers/specs/2026-09-08-standalone-cli-design.md` for the full
contract and `docs/permissions.md` for TCC/attribution detail.
