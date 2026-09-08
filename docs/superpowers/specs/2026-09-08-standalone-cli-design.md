# nuvin-computer-use standalone CLI

Date: 2026-09-08
Status: Approved by user on 2026-09-08; implementation plan at `../plans/2026-09-08-standalone-cli.md`. Implementation not started.

## Goal

Turn the restored macOS computer-use implementation into a standalone `nuvin-computer-use` CLI. Deliver explicit desktop commands, reliable targeting, machine-readable output, and a visible software cursor. This is an automation utility, not an agent or agent tool.

## Approved direction

- Foreground automation first, macOS only.
- TypeScript CLI plus a Swift native helper; reuse the existing backend where correct.
- Include both accessibility-reference actions and raw mouse actions in v1.
- Display a virtual cursor as feedback; do not promise input isolation.
- No persistent daemon in v1. A native host lives for the duration of an individual command.
- Plan first; do not implement or commit as part of specification work.

## Non-goals

- No LLM integration, model credentials, reasoning loop, MCP server, or agent-tool registration.
- No compatibility wrapper for the old `FunctionTool` contract.
- No Windows/Linux support, background interaction, locked-screen operation, remote control, or multi-agent cursors.
- No arbitrary JavaScript execution, batch language, workflow recorder, or automatic mutation retries.
- No private SkyLight APIs in v1.
- No model-based approval reviewer or persistent per-app policy system in v1.
- No unattended testing against the user's personal applications.

## Architecture

```text
nuvin-computer-use <command>
  TypeScript CLI
    - parse and validate command arguments
    - format text / JSON results and errors
    - coordinate deadlines, cancellation, and desktop-operation lock
  macOS backend
    - versioned Swift helper protocol
    - native utility execution where still appropriate
  per-command Swift/AppKit host
    - app/window discovery, AX traversal and actions
    - window capture geometry and mouse-event execution
    - non-activating software-cursor overlay during actions
```

The TypeScript layer does not know about model messages or tool results. The Swift helper accepts validated structured requests and returns structured responses. Helpers must not write progress prose to the response channel. The host runs an AppKit event loop while needed; it is not installed as a login item or resident service.

Reuse the backend's useful native operations and dependency injection, but replace the old `ComputerUseTool` interface. Remove obsolete agent-only types and stale coordinate-action declarations when replacing their owning code, rather than maintain two public APIs. Historical documents and `integration-reference/` remain clearly marked as archival references, not supported integration surfaces.

## CLI commands

| Command | Contract |
| --- | --- |
| `doctor` | Report platform, helper version, dependency availability, and OS permission status. Read-only; does not install software or request permission implicitly. |
| `apps` | List app name, bundle identifier when available, and PID. |
| `windows` | List windows for an explicit app/PID, including window ID, bounds, and eligibility for foreground operations. |
| `snapshot` | Capture one target window's AX tree and return a snapshot ID. Preserve depth, element limit, and hint-mode controls. |
| `press` | Perform AXPress on an explicit snapshot/ref. No silent coordinate fallback. |
| `set-value` | Set AXValue on an explicit snapshot/ref. Merely focusing the control is not success. |
| `type` | Type text into the focused control of an explicitly targeted app/window. |
| `key` | Send a validated key or modifier combination to an explicitly targeted app/window. |
| `scroll` | Directional scrolling within an explicit target window, or bring a snapshot/ref into view. These forms are mutually exclusive. |
| `screenshot` | Save a PNG of one explicit target window and return a capture ID, dimensions, and path. `--annotated` adds ref badges and also returns the associated snapshot ID/tree. |
| `click` | Click image-pixel coordinates from an explicit capture. Support left/right/middle buttons and single/double/triple counts where the backend supports that combination; reject unsupported combinations before input. |
| `move` | Move to image-pixel coordinates from an explicit capture. |
| `drag` | Left-button drag between two image-pixel coordinates from an explicit capture. |

Standard flags: `--help`, `--version`, `--json`, and `--timeout` in integer milliseconds from 1 through 120,000 inclusive. Default deadline is 15 seconds, covering input loading, lock acquisition, activation, animation, native operations, and verification. Cancellation cleanup has a separate 2-second grace period. The upper bound is enforced by both TypeScript and Swift request validation.

Discovery commands do not select a target implicitly. For commands needing a target, accept either `--app` or `--pid`, and optionally `--window`. Resolve an app name only if unambiguous. A missing window selector is allowed only when exactly one eligible window exists. Errors enumerate eligible targets without selecting a frontmost default.

Snapshot/ref and capture-based commands derive their target from the named record. Reject conflicting explicit app/window selectors. There is no persistent implicit "last app" or "last snapshot".

Examples:

```sh
nuvin-computer-use doctor --json
nuvin-computer-use apps --json
nuvin-computer-use windows --app Safari --json
nuvin-computer-use snapshot --app Safari --window 123 --json
nuvin-computer-use press --snapshot <id> --ref 12
nuvin-computer-use set-value --snapshot <id> --ref 7 --text "example"
nuvin-computer-use type --app TextEdit --window 456 --text-file -
nuvin-computer-use key --app TextEdit --window 456 --key cmd+s
nuvin-computer-use scroll --app Safari --window 123 --direction down --amount 3
nuvin-computer-use scroll --snapshot <id> --ref 20
nuvin-computer-use screenshot --app Safari --window 123 --output ./safari.png --json
nuvin-computer-use click --capture <id> --x 420 --y 180
nuvin-computer-use click --capture <id> --x 420 --y 180 --button right
nuvin-computer-use move --capture <id> --x 420 --y 180
nuvin-computer-use drag --capture <id> --from 420,180 --to 620,300
```

`type` and `set-value` accept exactly one of `--text` or `--text-file`; `--text-file -` reads stdin. Document that command-line text may be exposed through shell history/process inspection. Do not echo supplied text in success output or diagnostics.

## Results and exit codes

Text output is the human default. `--json` produces exactly one JSON object on stdout, including for parse and execution failures. Diagnostics go to stderr; no spinner or ANSI styling on stdout in JSON mode.

Success envelope: `{ "schemaVersion": 1, "ok": true, "command": "...", "data": { ... } }`.

Error envelope: `{ "schemaVersion": 1, "ok": false, "command": "...", "error": { "code": "...", "message": "...", "details": { ... } } }`. Omit unknown command and optional details when unavailable. Error details must not include supplied text or full native command arguments.

| Exit | Meaning |
| --- | --- |
| 0 | Command completed successfully |
| 1 | Native execution or verification failure |
| 2 | Invalid arguments |
| 3 | Unsupported platform, missing/incompatible helper, or missing dependency |
| 4 | Required OS permission unavailable |
| 5 | Missing, stale, expired, ambiguous, or ineligible target |
| 6 | Timeout or desktop resource busy |
| 130 | Interrupted by Ctrl+C |

Machine-readable error codes distinguish cases within each exit class, such as `STALE_SNAPSHOT`, `STALE_CAPTURE`, `AMBIGUOUS_TARGET`, `UNSUPPORTED_ACTION`, and `EXECUTION_UNCERTAIN`.

Native event dispatch succeeding does not prove the UI achieved the caller's goal. Report the execution method and verification performed. If input may already have occurred when verification fails, return an uncertainty error and do not retry.

## Snapshot identity and invalidation

Current code persists PID/app/hint mode and rebuilds sequential refs from the live tree (`src/tools/computer/ax-helper/main.swift:535`, `:588`, `:687`). A snapshot ID alone is not stable element identity.

Replace this with versioned snapshot records containing:

- Random, strictly validated opaque ID and creation time.
- Process identity including process start identity, bundle identifier when available, and PID.
- Selected window identity and observed geometry.
- Exact traversal options, truncation information, and ordered observed tree evidence.
- Ref-to-target evidence: structural path, role, available AX identifier, relevant attributes/actions, and geometry.

Before a ref action, verify process/window identity and rebuild the observed tree with the same options. Require the recorded observed structure and target evidence to match; do not fuzzy-match, silently renumber, or select among ambiguous candidates. If trustworthy re-identification cannot be established, fail with `STALE_SNAPSHOT`.

This is conservative observed-state validation, not a guarantee against arbitrary changes between validation and execution. Identical replacement controls may be indistinguishable through public AX attributes. Document this limitation explicitly rather than claim fail-proof identity.

Records expire after 10 minutes. Successful state-changing commands invalidate this CLI's older snapshot and capture records for the target app. Plain `move` does not invalidate records. An uncertain mutation also invalidates records. External changes are detected only to the extent allowed by the validation rules.

## Pixel targeting and screenshots

A capture records process/window identity, original window geometry, image size, backing scale, resize transform, and timestamp. Coordinates are measured in the saved image's pixels, not arbitrary desktop coordinates. Conversion uses the selected window and display information; never estimate Retina scale by dividing window pixels by full-screen width.

Validate finite coordinates and bounds before acting. Reject changed process/window identity or geometry, expired/invalidated records, and unsupported display configurations. Do not silently translate stale coordinates after a window move or resize. Refuse coordinate input when the intended point cannot be validated as belonging to the selected visible window; do not click an occluding application.

Capture targeting does not establish semantic identity of UI content. An externally changed button in the same geometry can still be a different target. Recommend a fresh screenshot for consequential coordinate actions.

Require an explicit `--output` path for screenshots; do not overwrite existing files unless `--overwrite` is supplied. Never fall back to full-desktop capture if window capture fails. Return path, dimensions, capture ID, and target metadata; do not base64-encode images into CLI output.

Annotated screenshots return a matched tree/snapshot and capture. Coordinate transforms for badges use the same capture metadata. Verify target consistency across AX traversal and capture; report failure if consistency cannot be established. Keep the software cursor out of these artifacts by hiding it during capture rather than relying on undocumented exclusion behavior.

## Visible virtual cursor

The cursor is visual feedback, separate from input execution. Actual operations remain foreground operations and may move the physical mouse or change focus. State this in help and documentation.

- Render an original, distinctive cursor using a transparent, non-activating, click-through AppKit overlay. Do not copy Codex graphical assets.
- Enabled by default for spatial actions; `--cursor off` disables visualization, not execution safety checks.
- Animate movement, show a click pulse for clicks/presses, and show drag feedback synchronized with dispatched drag events.
- For AX press, set-value, and scroll-to-ref, show feedback at the validated element when geometry is available. Lack of geometry does not force a coordinate fallback; report that visualization was unavailable.
- Do not fabricate a spatial target for `type` or `key`; these need not display a cursor.
- One helper/overlay lifecycle per command. Start from a documented per-command origin based on current pointer position, not an implicit persisted cursor session.
- No artificial movement outside the target window for aesthetic effect. Target the current window's screen/Space; reject unsupported fullscreen/Space conditions rather than switching silently.
- Hide and close on command completion, failure, cancellation, or parent loss. The native host must detect parent/IPC loss so a killed Node process does not leave an orphan overlay.
- If visualization initialization fails while enabled, fail before input. The caller may explicitly retry with `--cursor off`.

The native action host owns input sequencing while the overlay is active. It must not let a separate uncontrolled subprocess continue injecting input after the host reports completion or cancellation.

## Foreground execution and safety

The user's explicit command authorizes that action; there is no semantic reviewer capable of deciding whether a button sends money or deletes a document. OS permissions and explicit targeting are not a complete security sandbox.

- Use one per-user lock across CLI desktop observations and actions, preventing this CLI's concurrent commands from interleaving. Bound waiting by the command deadline. Recover abandoned locks only after validating owner identity; use process start identity to avoid PID reuse errors.
- Activate the selected app/window where necessary and verify foreground ownership immediately before global input. Recheck at meaningful sequence boundaries. This reduces but cannot eliminate races with user input or other automation.
- Do not silently minimize, unhide, switch Spaces, or restore windows. Report ineligible targets and tell the user how to prepare them.
- No automatic retry of mutations or coordinate fallback from AXPress.
- `set-value` only succeeds when the requested value is set with the applicable verification. Focusing the field is not a successful replacement.
- Validate keys/modifiers using allowlisted syntax. Pass values as arguments or stdin rather than interpolating unchecked strings into AppleScript.
- Prefer native Unicode input that leaves the clipboard unchanged. If an application requires paste, require explicit `--allow-clipboard-replace`; do not pretend text-only clipboard restoration preserves all clipboard formats. Do not use hidden fallback paste.
- Propagate child-process failures; enforce timeouts and cancellation; best-effort release any pressed mouse buttons/modifiers during cleanup. Report uncertainty if a partial action already occurred.

## State and privacy

Use a dedicated per-user state directory under `~/Library/Application Support/nuvin-computer-use/`, with owner-only directory/file permissions. Persist only metadata and AX evidence necessary for cross-command validation. AX evidence can contain sensitive visible text; document this plainly.

Validate opaque record IDs before constructing paths. Write records atomically; do not accept arbitrary record paths from the CLI. Commands that create or consume snapshot/capture state sweep expired records while holding the state/desktop lock. Help, version, doctor, apps, and windows do not create or sweep snapshot state. Expiry is enforced on read even if expired files have not yet been swept. No background cleanup process: unused expired records remain on disk until a later state-using invocation or manual removal.

Do not retain screenshots or annotated intermediate images for debugging. Only explicitly requested output files persist; use private temporary files and remove them on normal completion/error paths. Account for recovery of abandoned temporary files on a later invocation. User-requested screenshot files remain the user's responsibility.

## Packaging and permissions

Expose an npm executable named `nuvin-computer-use`. Resolve the helper from the installed package, not a required pre-existing `~/.nuvin/bin/ax-helper`. Version the helper protocol and fail early on mismatch.

Start with a source-buildable macOS package targeting Node.js 22 or newer and macOS 14 or newer. A documented build compiles TypeScript and the local Swift/AppKit helper using Xcode Command Line Tools with Swift 5.9 or newer. These are proposed support requirements, not a claim that the restored binary has been verified on every supported version. The development build writes only project-local artifacts, does not install into the user's home, and does not install Homebrew dependencies. The implementation plan must check native API availability against this deployment target; any required increase must be surfaced rather than silently changed.

Use `doctor` to explain permission attribution for the terminal/launching host and the helper. Do not claim a fully signed/notarized stable app identity in v1; validate the supported launch path on a real Mac. Source-build distribution and permission requirements must be documented before calling the CLI ready. Signing/notarization and prebuilt multi-architecture delivery are separate release work, not blockers to a locally built v1.

Existing cliclick use may remain where correct; doctor reports it when required. Do not introduce private APIs just to remove a dependency.

## Verification and acceptance

1. CLI tests exercise every command, conflicting/missing flags, JSON stdout purity, text output, error codes, paths, and non-macOS failure.
2. Backend tests cover nonzero exits, timeout, cancellation, malformed helper responses, version mismatch, and no input after preflight failure.
3. Swift fixture tests cover tree reordering, inserted/removed elements, identical/ambiguous targets, process reuse, window changes, custom traversal limits, record expiry, and invalidation.
4. Transform tests cover Retina/non-Retina, resized screenshots, negative display origins, coordinate boundaries, window moves, and matching annotation positions.
5. Lock/state tests cover concurrent invocations, crashed owners, atomic writes, permission modes, expiry, and no hidden shared last-target state.
6. Overlay lifecycle tests cover initialization failure, command failure, cancellation, parent loss, click-through behavior, and screenshot exclusion. Native rendering assertions need opt-in macOS execution rather than mocked claims.
7. An opt-in dedicated macOS fixture window proves snapshot → press/set-value, Unicode entry, keys, directional scroll, mouse click/move/drag, screenshots, and annotated screenshots.
8. Live acceptance checks verify visible cursor feedback, physical-pointer/foreground behavior as documented, and no leftover overlay/held input after cancellation.
9. Package smoke test installs the locally built package into an isolated prefix and runs help/version/doctor, proving helper discovery without a global nuvin installation.

Unit tests alone do not prove native input routing or permission setup. Do not report live verification unless it was explicitly authorized and performed against the fixture app.

## Delivery order

1. CLI/backend separation, helper protocol, packaging, and read-only discovery/doctor.
2. Window-scoped snapshots, private state, stale-target validation, locking, and capture transforms.
3. Foreground semantic and raw-input commands with strict execution outcomes.
4. Per-command native cursor host and synchronized visual feedback.
5. End-to-end fixture validation, package smoke tests, and user documentation.

Each stage must remain testable independently; the implementation plan will break these into concrete files and verification steps after specification review.

## Related specifications and references

### Local historical designs

- `../../plans/2026-02-24-computer-use-tool.md`: original coordinate-action tool and backend; historical context, not the new CLI contract.
- `../../plans/2026-02-24-ax-tree-computer-tool.md`: AX-first discovery and reference-based actions; preserve the concept but replace unsafe live ref rebuilding.
- `../../plans/2026-02-24-annotated-screenshot-design.md`: matching ref badges and screenshots; retain with corrected window-specific transforms.
- `../../../README.md`: restoration provenance and source layout.

### External research

- https://developers.openai.com/codex/computer-use — official product permissions and macOS-background versus Windows-foreground behavior. Do not infer undocumented event-routing internals from product behavior.
- https://github.com/iFurySt/open-codex-computer-use/blob/main/docs/references/codex-computer-use-reverse-engineering/software-cursor-overlay.md — third-party evidence of Codex's separate software-cursor window and lifecycle, not an official API contract.
- https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md — Cua's background input techniques and limitations; motivates separating visualization from execution, but private APIs are out of v1 scope.
- https://github.com/trycua/cua/blob/main/libs/cua-driver/README.md — native app hosting, cursor lifecycle, and macOS permission attribution considerations. Its daemon architecture is not adopted for v1.
- https://developers.openai.com/api/docs/guides/tools-computer-use — distinction between an automation runtime and a model/API loop. The new CLI contains only automation, not the loop.
