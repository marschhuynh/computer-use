# nuvin-computer-use

Standalone restoration of the `ComputerUseTool` from
[marschhuynh/nuvin-cli](https://github.com/marschhuynh/nuvin-cli) — macOS
desktop automation (accessibility tree + screenshots) for LLM agents.

## Provenance

The tool shipped in nuvin-cli's `packages/nuvin-core` and was deleted during
the 1.37 release repackaging. Source of this restoration is `aab1a6a`, the
last commit where the code existed.

| Commit (nuvin-cli) | Event |
|---|---|
| `340f343` | Tool added (2026-02-28): tool, macOS backend, `/setup`, viewer renderer |
| `aab1a6a` | AX snapshot params + bundled `ax-helper` binary — **restore source** |
| `8da3b87` / `ae96977` / `ba6b6f3` | Removed during release repackaging (`prepare cli release packaging #214`, `remove old packages`, `promote 1.37.0-rc.17`) |

All restored code files are byte-identical to `aab1a6a`. Verify any file:

```
git -C ../nuvin-cli show aab1a6a:<original-path> | diff - <local-file>
```

## What it does

One tool, ten actions:

`snapshot` (accessibility tree) · `press` / `set_value` (interact by element `ref`) ·
`type` · `key` · `scroll` · `screenshot` · `annotated_screenshot` (Vimium-style ref
hints overlaid) · `wait` · `list_apps`

macOS only. Backend stack: `ax-helper` (custom Swift binary over the Accessibility
API), `screencapture`, `osascript`, `cliclick`.

## Layout

```
src/tools/ComputerUseTool.ts        tool definition + action dispatch (383 lines)
src/tools/computer/types.ts         ComputerBackend, AX types (285 lines)
src/tools/computer/macos-backend.ts macOS backend (599 lines)
src/tools/computer/ax-helper/       Swift source (1621 lines) + compiled binary
tests/                              vitest suites (fully mocked, no system calls)
docs/plans/                         original design docs (2026-02-24)
docs/changeset-computer-use-tool.md original changeset
integration-reference/              original nuvin-cli wiring, for porting
src/ports.ts, src/tools/types.ts    type shims (see below)
```

## Setup

```sh
brew install cliclick            # mouse/keyboard backend
make ax-helper                   # swiftc build; installs to ~/.nuvin/bin/ax-helper
make ax-demo                     # CLI usage cheat sheet
```

## Develop

```sh
npm install
npm run typecheck
npm test
```

## Integration notes

- `src/ports.ts` is a minimal verbatim subset of the original 689-line
  `packages/nuvin-core/src/ports.ts`. The only deviation: `EventPort.emit`
  loosened to `unknown` (the original takes an `AgentEvent` union; the tool
  never reads `eventPort`).
- `src/tools/types.ts` is verbatim from the original
  `packages/nuvin-core/src/tools/types.ts` (`FunctionTool`,
  `ToolExecutionContext`, `ExecResult`).
- `integration-reference/` holds the original host wiring:
  `ToolCallViewer-registry.ts` (TUI render), `setup-command.ts` (`/setup`),
  `index-exports.patch` (package exports).
- To host in an agent, adapt the `FunctionTool` interface to the host tool
  contract and register it in the tool registry. The constructor accepts an
  injected `ComputerBackend`, which is how the tests mock the system.
