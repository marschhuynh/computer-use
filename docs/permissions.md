# Permissions

`nuvin-computer-use` drives the real macOS desktop through the Accessibility
(AX) and ScreenCaptureKit APIs plus `CGEvent` input. Those APIs are gated by
user-granted TCC permissions. This document explains what is required, how
macOS attributes the permission, and what the unsigned/source-built helper
changes about that.

## Required permissions

| Permission | Needed for | Without it |
|---|---|---|
| **Accessibility** | `snapshot`, `press`, `set-value` (AX tree + AX actions); `click`, `move`, `drag`, `key`, `type`, `scroll` (CGEvent input also requires it) | Commands fail with `PERMISSION_DENIED` (exit 4) |
| **Screen Recording** | `screenshot` (ScreenCaptureKit), and therefore `--capture`-based `click`/`move`/`drag` | `screenshot` fails; capture-dependent mouse commands have no capture to resolve |

`doctor`, `apps`, and `windows` do **not** require either permission and are
safe to run to check state.

## How macOS attributes the permission

macOS grants Accessibility and Screen Recording to a **code identity** — the
responsible process that performs the API call — not to "the program" in the
abstract. For this package:

- **The helper** (`dist/native/computer-use-host`) performs the AX traversal,
  ScreenCaptureKit capture, and `CGEvent` posting. macOS evaluates *its*
  identity.
- **The launching host** (Terminal.app, iTerm, your editor's integrated
  terminal, or whatever invokes `nuvin-computer-use`) is the responsible
  process for a child process that has no standalone code identity. In
  practice this means the permission prompt and the entry in
  **System Settings → Privacy & Security → Accessibility** /
  **Screen Recording** usually name your *terminal/launcher*, not the helper.

Consequence: granting permission to "Terminal" grants it to every unsigned
child process Terminal spawns. That is macOS's model, not something this
package adds — but it is worth understanding before you grant.

## Unsigned / source-built helper — honest limits

The helper is **built locally and unsigned** (no Developer ID signing, no
notarization). This is the supported v1 distribution model, and it has real
consequences:

- **TCC prompts attribute to the launcher**, not a stable app name. You will
  not see a `nuvin-computer-use` entry in Privacy & Security; you will see
  your terminal (or whichever host spawned the command).
- **Rebuilds can reset or re-prompt permission.** An unsigned binary's code
  requirement does not survive across rebuilds the way a signed bundle's does.
  If `doctor` suddenly reports `denied` after a rebuild, re-check the launcher
  entries in Privacy & Security.
- **No Gatekeeper path is needed for a local build**, but the same binary
  downloaded from the internet *would* be quarantined. Building from source
  avoids that; installing a prebuilt tarball is not a supported v1 path.
- **Do not claim or expect a stable signed identity in v1.** Signing and
  notarization are separate release work.

## Checking status

```sh
nuvin-computer-use doctor
```

`doctor` is **read-only**: it reports the current grant state and exits
non-zero when not ready, but it never opens the permission prompt, never
writes state, and never installs anything. Use it after granting or revoking
to confirm what macOS recorded.

## Foreground semantics

Granting permission does **not** make automation safe or isolated:

- `key`, `type`, `scroll`, `click`, `move`, `drag`, `press`, `set-value` act
  on the **foreground target** you name. They move the physical pointer and
  change focus. There is no input isolation.
- The software-cursor overlay is **visual feedback only**. `--cursor off`
  disables the visualization, not any safety check.
- Commands author *exactly what you ask*: there is no reviewer deciding
  whether a click sends money or deletes a file. Target deliberately.

## Private state

`snapshot` and `screenshot` write evidence to
`~/Library/Application Support/nuvin-computer-use/` (owner-only: directories
`0700`, files `0600`). Snapshot records contain the window's AX tree —
**including visible on-screen text** — and persist for 10 minutes before
expiry and sweep. Treat that directory as sensitive; don't commit it, share
it, or leave it on a shared machine.

## Summary

- Grant Accessibility + Screen Recording to the **launching terminal/host**.
- `doctor` reports truth; run it after any change.
- Unsigned helper → launcher-attributed prompts, possible re-prompt on rebuild.
- Permissions ≠ sandbox: this is foreground automation with real input.
