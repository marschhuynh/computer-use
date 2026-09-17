# nuvin-computer-use

Standalone macOS desktop-automation CLI, restored from
[marschhuynh/nuvin-cli](https://github.com/marschhuynh/nuvin-cli). A TypeScript
CLI spawns a per-command Swift/AppKit helper
(`dist/native/computer-use-host`) that drives the Accessibility tree,
ScreenCaptureKit, and `CGEvent` input. Foreground automation for LLM agents
and scripts — macOS only.

## Commands

`doctor` · `apps` · `windows` · `snapshot` · `press` · `set-value` · `type` ·
`key` · `scroll` · `screenshot` · `click` · `move` · `drag`

Every command emits a single JSON reply (`--json`) or a human-readable line,
with a stable exit-code contract. See **[docs/cli.md](docs/cli.md)** for the
full reference, and **[docs/agent-guide.md](docs/agent-guide.md)** for how an
LLM agent drives the desktop through it.

## Requirements

- macOS 14+, Node.js ≥22, Xcode Command Line Tools with Swift ≥5.9 (to build
  the helper from source)
- **Accessibility** and **Screen Recording** granted to the launching
  terminal/host — see **[docs/permissions.md](docs/permissions.md)** for
  attribution and the unsigned/source-built limits.

## Build

```sh
npm install
npm run build        # TS -> dist/  +  Swift helper -> dist/native/computer-use-host
./dist/cli.js doctor
```

## Install

```sh
npm link             # or: npm install -g .
nuvin-computer-use doctor
```

The helper is resolved from inside the installed package — no `~/.nuvin`
install, no Homebrew dependencies.

## Quick start

```sh
nuvin-computer-use doctor --json          # permissions + helper check
nuvin-computer-use snapshot --app Notes   # AX tree -> snapshotId
nuvin-computer-use press --snapshot <id> --ref 3
nuvin-computer-use screenshot --app Notes --output notes.png --json
nuvin-computer-use screenshot --output screen.png --json  # bare = main display; --display <n> picks one
nuvin-computer-use click --capture <id> --x 200 --y 140
nuvin-computer-use key --key cmd+space                    # bare = global chord
```

## Develop / test

```sh
npm run typecheck
npm test                          # vitest, mocked
npm run native-tests              # Swift XCTest fixtures
npm run test:native-protocol      # real host over stdio
node scripts/package-smoke.mjs    # isolated-install smoke
```

See **[docs/testing.md](docs/testing.md)** for the suite matrix and
live-acceptance gating.

## Provenance

The original `ComputerUseTool` shipped in nuvin-cli's `packages/nuvin-core`
and was deleted during the 1.37 release repackaging; the restore source is
`aab1a6a`. This repository rebuilds it as a standalone CLI rather than an
agent `FunctionTool`. Original design docs live in `docs/plans/`; the current
spec and stage plans are under `docs/superpowers/`.
