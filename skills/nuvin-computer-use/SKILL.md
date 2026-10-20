---
name: nuvin-computer-use
description: Use when an agent needs to operate a real macOS app or window through nuvin-computer-use, including accessibility refs, screenshots, coordinate clicks, typing, keyboard shortcuts, scrolling, or canvas drawing. Also use when CLI actions report success without visible effect. Not for implementing the CLI or DOM-only browser tasks.
---

# nuvin-computer-use

The CLI controls the real desktop, not a sandbox. Use **observe → choose → act → verify**, one uncertain state transition at a time. Read [the command and recovery reference](references/cli-reference.md) for syntax and failure handling.

## Before operating

1. Confirm the allowed app/task and side effects. Respect no-live/no-command instructions: prepare guidance only when operation is prohibited. Do not infer permission to publish, delete, submit, install, replace the clipboard, or change system permissions.
2. Establish which executable will run. An installed `nuvin-computer-use` and checkout `node dist/cli.js` may differ. A source merge does not rebuild `dist`; version text alone does not establish build provenance. Do not silently build, install, or switch binaries.
3. When live preflight is allowed, run `doctor --json`, then `apps --json` and `windows --app <app> --json`. Resolve ambiguity with fresh process/window identity. Permission readiness is not AX readiness or delivery proof.
4. Coordinate exclusive desktop use. App PID, matching bounds, or an exact-window screenshot does not prove that window is exposed or focused. Stop when the intended recipient is uncertain.

## Choose from observed capabilities

| Evidence                                         | Action                                               |
| ------------------------------------------------ | ---------------------------------------------------- |
| Fresh snapshot ref supports `AXPress`            | `press --snapshot <id> --ref <ref> --json`           |
| Suitable editable ref                            | `set-value` using that snapshot/ref                  |
| No usable ref; inspected screenshot shows target | `click --capture <id> --x <px> --y <px> --json`      |
| Canvas stroke                                    | `drag --capture <id> --from <x,y> --to <x,y> --json` |

Refs are **integers**: a returned `{"ref":12}` is passed as `--ref 12`, not `--ref ref12`. `press` invokes accessibility directly; it does not click the ref's bounds. `click` accepts capture pixels, not snapshot refs. No automatic fallback connects them. A canvas or toolbar may expose useful accessibility: inspect evidence instead of assuming by app category. Missing nodes are not proof of absence; inspect snapshot coverage.

A snapshot is not a screenshot. Inspect the saved PNG explicitly. Default images are logical **1×**; `--native` requests backing-resolution pixels. Use returned `width`/`height` and original-image coordinates—never manually halve Retina coordinates or add desktop origin. If a viewer rescales the image, translate the selected point back to original pixels.

## Verify before continuing

- Parse `ok` first. Successful actions report `verified` for an accepted AX call or `dispatched` for a posted event. **Neither proves visible task completion.** Confirm the intended postcondition with a fresh observation.
- After a UI mutation, obtain fresh snapshot refs. Refresh captures after geometry changes or whenever the pictured layout is no longer current; re-identify coordinates rather than blindly reusing them.
- After shortcuts that change tabs, windows, or focus, verify the target field **before typing**. Never chain URL/text entry after an ineffective shortcut. `--to-process` changes routing; it is not a guaranteed repair or exact-window focus control.
- For drawing, verify tool/color and one short stroke's continuity/endpoints before batching. If it produces dabs, stops short, or lands elsewhere, stop and retain evidence; do not invent coordinate offsets or claim success from dispatch.
- On failure, follow the reference's bounded recovery rules. Report attempted action, observed effect, unresolved uncertainty, and next safe step. Keep screenshots/AX logs private; never embed secrets in command arguments.
