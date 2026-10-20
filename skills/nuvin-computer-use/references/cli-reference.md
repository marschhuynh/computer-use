# Command and recovery reference

Use this after reading SKILL.md. Examples are command shapes, not permission grants. Replace placeholders with fresh observed values; never reuse historical PIDs/window IDs/refs. All flags follow the command. Run only commands allowed by the user's current scope.

## Executable and target

An installed executable can be discovered with `command -v nuvin-computer-use`. Static `--help` / `--version` do not establish which source a native host was built from. A checkout can use `node dist/cli.js`; do not assume its generated artifacts reflect current source, or use `npx` to download an absent CLI automatically.

Once live observation is authorized:

```sh
nuvin-computer-use doctor --json
nuvin-computer-use apps --json
nuvin-computer-use windows --app com.google.Chrome --json
```

Choose an unambiguous app name/bundle ID or exact PID; `--app` and `--pid` are mutually exclusive. Use `--window <id>` when multiple eligible windows exist. An ambiguous app match may need an exact bundle/PID, not just a window flag. Inventory establishes identity/eligibility, not input focus. If a window is covered, minimized or on another Space, establish safe visible targeting or ask the user; do not assume app activation raises the selected window.

## Snapshot → semantic action

```sh
nuvin-computer-use snapshot --app com.google.Chrome --window <window-id> --json
nuvin-computer-use press --snapshot <snapshot-id> --ref <button-ref> --json
nuvin-computer-use set-value --snapshot <snapshot-id> --ref <editable-ref> --text 'example' --json
nuvin-computer-use scroll --snapshot <snapshot-id> --ref <scrollable-ref> --json
```

A ref is the integer JSON field, not a prefixed label. For `{"ref":12,"actions":["AXPress"]}`, use `press --snapshot <snapshot-id> --ref 12 --json`; `--ref ref12` is invalid. Select refs by observed identity, state and supported action; `press` requires `AXPress`. A displayed integer or `full` hint mode alone is not actionability. Refs are scoped to their snapshot, expire after about ten minutes and can be invalidated earlier by UI changes. Reobserve before the next ref action after a mutation. `STALE_SNAPSHOT` requires new evidence, not the same integer with a new snapshot guessed around it.

Snapshots provide `data.snapshotId`, nested `data.tree.elements`, and optionally coverage. Check truncation, `boundaries`, limits and `refCount`; `absenceIsConclusive` is false. A depth boundary may justify one bounded deeper snapshot; an element boundary may justify a larger element budget. Changing hint mode does not recover unvisited nodes. Missing coverage means unknown, not complete. Hard observation errors are not empty successful trees and supply no usable new refs.

## Screenshot → spatial action

```sh
nuvin-computer-use screenshot --app com.google.Chrome --window <window-id> \
  --output /tmp/authorized-window-01.png --json
nuvin-computer-use click --capture <capture-id> --x 420 --y 180 --json
nuvin-computer-use move --capture <capture-id> --x 420 --y 180 --json
nuvin-computer-use drag --capture <capture-id> --from 420,180 --to 620,300 --json
```

Choose a private, allowed output path; prefer a new filename over overwriting unrelated images. Inspect the PNG using the agent's image-viewing tool before deriving coordinates. A successful screenshot returns `data.captureId`, `path`, pixel `width`/`height`, target bounds in desktop points and timestamps.

- Default PNG: logical 1× dimensions. `--native`: native/backing pixels, often 2× on Retina. Read actual dimensions; never assume all displays use 2×.
- `--display <n>` selects a 1-based display; bare screenshot captures the main display. Display targets cannot combine with app/window targets. Display captures may expose other apps/private content.
- `--annotated` on a window explicitly adds an AX snapshot and ref badges. Display captures cannot be annotated. A badge does not create a ref for arbitrary canvas pixels; if AX annotation fails, do not assume a usable screenshot was produced.
- Click supports `--button left|right|middle` and `--count 1|2|3`. Drag is a single straight left-button stroke, not a multi-point path or pen-pressure primitive.
- Capture IDs expire after about ten minutes and may go stale on geometry changes. Even an unexpired capture can depict outdated content.
- `--cursor off` disables visualization, not safety checks or input delivery. Neither cursor motion nor overlay animation proves the app received the action.

### Native-pixel example

For a **2400 × 1600** PNG of a **1200 × 800** logical window, a selected original-image pixel **(600,400)** is passed as `--x 600 --y 400`. The CLI performs scaling and origin translation. Do not pass `(300,200)` or desktop coordinates to this capture. After a UI transition, capture/inspect again and confirm the intended location rather than assuming the same pixel still means the same control.

## Keyboard, typing and directional scrolling

```sh
nuvin-computer-use key --app com.google.Chrome --window <window-id> --key cmd+t --json
# Observe: did the intended window gain a new tab and focused address field?
# Only after that postcondition is verified:
nuvin-computer-use type --app com.google.Chrome --window <window-id> --text 'https://example.com' --json
# Observe typed value before submitting navigation if delivery is uncertain.
nuvin-computer-use key --app com.google.Chrome --window <window-id> --key return --json
nuvin-computer-use scroll --app com.google.Chrome --window <window-id> --direction down --amount 3 --json
```

| Delivery mode                    | Contract / limitation                                                                                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Targeted key/type default        | Activates the named app, then posts to the HID tap. Focus inside the app still matters; app activation is not exact-window/field confirmation.                     |
| Targeted key/type `--to-process` | Posts to the app's event queue without activation. Requires app/PID; may not reach helper-hosted panels. Does not select the intended window or guarantee success. |
| Bare key/type                    | Posts to whatever holds focus, with no target activation. Use only when that global behavior is intended and verified.                                             |

Return and Enter are aliases in this CLI; swapping them is not an independent delivery strategy. After a shortcut with no observed effect, stop the dependent action, reobserve and choose one justified recovery. A visible new-tab/address control may be safer than replaying the shortcut; its action still needs verification. Do not batch uncertain transitions or automatically retry potentially applied commands.

For authorized sensitive typing, use `type --text-file -` with secure stdin input, not a literal secret in argv/logs. Do not print/read secret values merely to construct the command. Clipboard replacement is a separate side effect: do not add `--allow-clipboard-replace` without explicit authorization.

## Reply meaning

Success and failure use different branches of the envelope:

```json
{"schemaVersion":1,"ok":true,"command":"click","data":{"method":"cg-event","verification":"dispatched"}}
{"schemaVersion":1,"ok":false,"command":"click","error":{"code":"STALE_CAPTURE","message":"...","details":{"mutationStatus":"notStarted"}}}
```

These are illustrative fields, not complete replies. Read IDs/paths from actual returned data; do not invent them.

| Action family                          | Verification means                                                                                                   |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| AX `press`, `set-value`, ref scrolling | `verified`: the accessibility operation succeeded at the API level. It does not prove the requested UI/task outcome. |
| Pointer, key/type, directional scroll  | `dispatched`: events were posted. It does not prove recipient identity, visible effect or completion.                |

`doctor.ready` is permission/helper evidence, not a snapshot, a semantic-ref guarantee, or proof of keyboard/drawing reliability. Automated tests and a built source fix likewise do not prove receiver behavior.

## Bounded failure recovery

Inspect the full structured reply before deciding; stop rather than spinning or hiding a failure.

| Failure                                                            | Next safe step                                                                                                                                                                          |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `INVALID_ARGUMENT`                                                 | Correct syntax/constraints; do not repeat unchanged.                                                                                                                                    |
| Missing helper/dependency, protocol mismatch, unsupported platform | Establish executable/environment. Surface the blocker; no automatic download/install or permission changes.                                                                             |
| `PERMISSION_DENIED`                                                | Stop and explain the missing capability. User controls permission changes. Do not repeatedly provoke prompts.                                                                           |
| Target missing/ambiguous/ineligible or `FOCUS_FAILED`              | Rediscover identity/eligibility when allowed; establish intended visible target/focus. No guessed IDs or new focus guarantee.                                                           |
| `STALE_SNAPSHOT` / `STALE_CAPTURE`                                 | Obtain and inspect fresh evidence; derive new ref/pixel from it.                                                                                                                        |
| `TIMEOUT` / `BUSY`                                                 | Check mutation uncertainty first. Reobserve if input may have occurred; only then consider one bounded retry with a justified budget. Never compress/repeat a partial drag blindly.     |
| `NATIVE_FAILURE`, protocol error, `EXECUTION_UNCERTAIN`            | Separate failed observation from uncertain mutation. Preserve safe error context; reobserve before replaying a possibly applied action. No arbitrary coordinate/keycode/Retina offsets. |
| Interrupted / exit 130                                             | Stop the task; do not auto-resume input.                                                                                                                                                |

For a mutating command, `mutationStatus:notStarted` says dispatch did not begin; correct the cause before retrying. `potentiallyApplied`, or missing/unreliable status where effect is uncertain, requires observation before another mutation. A failed read-only snapshot does not become an uncertain click: simply treat its observation as unavailable.

Newer native errors may include bounded `error.details.ax` (phase, operation, allowlisted attribute, actual status, scope, validation reason). Use these to report the failing operation—not to infer a fix, swallow a hard failure, or declare Chrome ready. Older executables may omit details; absence is unknown evidence.

If observations remain unavailable or actions repeatedly lack their intended effect, stop, report attempted/observed/unknown, and record a reproducible improvement item only if requested. A process-routing alternative or paced-drag build is not a universal remedy. Preserve the user's no-live restriction even when live evidence would resolve the issue.

## Privacy and completion

State records and images may contain private screen content. Keep them in an allowed private location, out of commits/reports unless explicitly sanitized and authorized. Do not blindly delete retained artifacts or overwrite unrelated files.

Report completed actions **with observed outcomes**, blocked/uncertain actions, and unverified scope. For offline-only work state that no desktop action was executed. Never report an intended drawing, successful navigation, or all bugs fixed from command acknowledgements alone.

Repository sources for contract drift: [CLI reference](../../../docs/cli.md), [agent guide](../../../docs/agent-guide.md), [testing scope](../../../docs/testing.md). Consult current build-specific evidence for known issues; historical success/failure is not a permanent capability guarantee.
