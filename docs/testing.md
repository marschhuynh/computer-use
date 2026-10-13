# Testing

How to verify `nuvin-computer-use` — and, just as important, what each layer
does *not* prove.

## Suite matrix

| Command | Layer | What it covers | Needs |
|---|---|---|---|
| `npm run typecheck` | TypeScript | static types across `src/` | nothing |
| `npm test` | vitest, `tests/*.test.ts` | CLI flag parsing, JSON stdout purity, reply projection, exit-code mapping, backend timeout/cancel/malformed-reply handling — all fully mocked, no system calls | nothing |
| `npm run native-tests` | Swift XCTest, `native/Tests/ComputerUseCoreTests` | discovery/target resolution, snapshot records, state store (locking, atomic write, expiry, sweep), capture geometry, cursor timeline — against AX **fixtures**, no live desktop | macOS + Swift toolchain |
| `npm run test:native-protocol` | `scripts/native-protocol-tests.mjs` | builds the host and exercises the JSON-lines request/reply protocol over real stdio | macOS |
| `npm run test:build-hygiene` | `scripts/test-build-hygiene.mjs` | `dist/` has no stale artifacts; `cli.js` has shebang + exec bit | after `npm run build` |
| `node scripts/package-smoke.mjs` | end-to-end packaging | `npm pack` → isolated `npm install --prefix` → installed bin runs `--version`, `--help`, `doctor`; resolves the **bundled** helper (protocol 1) with no `~/.nuvin` install | macOS, network for npm |

## What unit tests do *not* prove

Per the design spec: **unit tests alone do not prove native input routing or
permission setup.** The vitest suite mocks the helper; the XCTest suite runs
against fixtures; the protocol tests run the real host but with scripted
requests. None of them prove that a `CGEvent` actually lands in a real app's
window, that TCC granted the launcher, or that the overlay draws.

Do not report live verification as done unless it was **explicitly authorized
and run against a real app** (see Stage K live acceptance).

## Compact accessibility snapshots: separate gates

Traversal defaults and action validation remain unchanged.
Depth `8`, `500` nodes, `leafCompact`, timeout `15000` ms (maximum `120000`),
10-minute expiry, and existing ref/action safety contracts stay fixed.

| Gate | Local evidence | What remains outside it |
|---|---|---|
| **A — presentation and coverage** | `SnapshotTests`, `CaptureTests`, TS producer/consumer fixtures, CLI parsing and one-JSON-output tests; full non-live commands below | Live routing, real content completeness, latency, release approval. Independent review is a separate step. |
| **B — inactive preparation safety** | `AXSnapshotPreparationTests`, `AXTrustTests`, `SnapshotTransactionTests`: fake writes, deadlines/cancellation, identity bracketing, no record publication on failure, no preparation during action validation | Real AX writes, browser readiness, IPC timing and native-app side effects. Gate A does not depend on live activation. |
| **C — live comparison/default decision** | Requires separately authorized Arc/native-app comparison and explicit release decision | **NOT RUN / HOLD** for this change's non-live verification. No permission, readiness, or default-activation approval is inferred from A/B. |

The bounded AX preparation module is implemented, compiled, and fake-tested,
but **inactive in the shipping path**. `SnapshotService`'s preparation hook
remains explicitly no-op. A future accepted `AXManualAccessibility` or
fallback `AXEnhancedUserInterface` write would mean only **requested**, not
“web AX ready” or “Arc fixed.” Wiring that live module into the default needs
separate approval after the live gate, not merely green fixture tests.

No-op does **not** mean unchanged snapshot cost: collection now performs two
additional target identity validations around preparation inside the desktop
lock. Live process/window metadata and AX reads consume deadline/lock budget
and may reject transient identity/title/bounds changes earlier. Their cost,
latency, and transient failure rate are unmeasured. Action validation itself
is unchanged.

Reproduce the non-live gates from the repository root on macOS:

```sh
swift test --package-path native --filter SnapshotTests
npm test -- tests/cli-parse.test.ts tests/cli-run.test.ts
npm run typecheck
npm test
npm run native-tests
npm run test:native-protocol
```

Inspect the protocol runner before using it as a non-live check:
`scripts/native-protocol-tests.mjs` builds a fresh host;
`tests/native-protocol.test.ts` invokes `--protocol-version`, invalid shared
requests, malformed framing/oversized input, and empty EOF. It sends no valid
GUI command. Do not extend or replace those requests with live desktop work
without authorization. No permission setup is proved by these commands.

### Payload measurements and fixture privacy

`SnapshotTests.testPresentationByteMeasurements` uses synthetic inputs, a
fixed target/UUID/timestamps, and `JSONEncoder` with `.sortedKeys`. It prints
actual serialized **UTF-8 bytes** separately for `data.tree` and the complete
`WireReply.success(command: .snapshot, data: ...)` (including coverage).
No pretty-printing or terminal newline is counted. The printed
`treeCeilBytesOver4` / `replyCeilBytesOver4` values are **`ceil(bytes / 4)`
proxies**, not actual tokenizer measurements; there is no tokenizer dependency.

Compare `leafCompact` and `leafOnly` on the same input/options and assert
unchanged evidence/refs. A bounded long neutral-wrapper chain must shrink in
both tree and whole reply. Static-text-rich zero-ref output intentionally
retains text and need not beat the old ref-only projection. To claim a change
from the original default, use its actually captured same-input serialization,
not the current `leafOnly` output: coverage adds bytes of its own. There is
no universal byte/token savings claim. Measure real command latency separately;
XCTest duration and payload size are not latency evidence.

Use only synthetic or approved sanitized fixtures in committed evidence. Real
AX records and screenshots contain on-screen text; do not commit them or raw
live logs, or send fixture PIDs to the live AX preparation driver. Tests must
inject fake/no-op preparation and use temporary state roots. See the
[measured verification note](verification/2026-10-02-compact-accessibility-snapshots.md)
for the exact commands, byte baselines, and held gates. It is local evidence,
not an independent review or release authorization.

## Live acceptance (opt-in, macOS)

Live checks require a real desktop and explicit authorization — they move the
physical pointer, change focus, and post real input. They are **not** part of
`npm test`. To run them, see the Stage K plan
(`docs/superpowers/plans/2026-09-16-stage-k-live-acceptance.md`), which
specifies:

- `snapshot` → `press`/`set-value` against a fixture app window
- `key`, `type` (incl. Unicode), directional `scroll`
- `screenshot` + `click`/`move`/`drag` on `--capture` coordinates
- visible cursor feedback, documented physical-pointer/foreground behavior,
  and no leftover overlay or held input after cancellation

## Notes for contributors

- **Host protocol quirk:** the Swift host holds stdin open while processing.
  When scripting against `computer-use-host` directly, keep stdin open until
  the reply arrives — closing it early triggers `ParentEOFObserver` and
  cancels the command.
- **Snapshot state:** tests that write state use a temporary root; real
  invocations write to `~/Library/Application Support/nuvin-computer-use/`
  (owner-only). Snapshot/capture records contain visible text — treat as
  sensitive.
- **Timeout:** the Swift suite and native-protocol tests build the host
  first — allow several minutes on a cold build.
