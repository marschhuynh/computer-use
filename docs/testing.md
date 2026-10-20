# Testing

How to verify `nuvin-computer-use` — and, just as important, what each layer
does *not* prove.

## Suite matrix

| Command | Layer | What it covers | Needs |
|---|---|---|---|
| `npm run typecheck` | TypeScript | static types across `src/` | nothing |
| `npm test` | vitest, `tests/*.test.ts` | CLI flag parsing, JSON stdout purity, reply projection, exit-code mapping, backend timeout/cancel/malformed-reply handling — all fully mocked, no system calls | nothing |
| `npm run native-tests` | Swift XCTest, `native/Tests/ComputerUseCoreTests` | discovery/bundle confinement, AppKit/kernel process identity, raw AX preparation/batch provenance, publication/action/ref safety, coverage diagnostics, state-store transactions, geometry and cursor timeline — against AX **fixtures**, no live desktop | macOS + Swift toolchain |
| `npm run test:native-protocol` | `scripts/native-protocol-tests.mjs` | builds the host and exercises the JSON-lines request/reply protocol over real stdio | macOS |
| `npm run test:build-hygiene` | `scripts/test-build-hygiene.mjs` | builds TS; `dist/` has no stale artifacts, `cli.js` has shebang + exec bit, `src/cli.ts` is preserved | installed dependencies |
| `npm run build` | composed build | TS cleanup/compilation and executable CLI, release Swift host build/copy | macOS + Swift toolchain |
| `node scripts/package-smoke.mjs` (separate, not run for this integration) | end-to-end packaging | `npm pack` → isolated `npm install --prefix` → installed bin runs `--version`, `--help`, `doctor`; resolves the **bundled** helper (protocol 1) with no `~/.nuvin` install | macOS, network for npm |

## What unit tests do *not* prove

Per the design spec: **unit tests alone do not prove native input routing or
permission setup.** The vitest suite mocks the helper; the XCTest suite runs
against fixtures; the protocol tests run the real host but with scripted
requests. None of them prove that a `CGEvent` actually lands in a real app's
window, that TCC granted the launcher, or that the overlay draws.

For this integration, real-app acceptance is **user-owned / NOT RUN by
workers/coordinator** under H4, including Chrome, keyboard and Shopee. It is
**not an automated or local-integration gate**. Fixture assertions, source
retention guards and builds do not establish live delivery or readiness.

## Compact accessibility snapshots: separate gates

Traversal defaults and action validation remain unchanged.
Depth `8`, `500` nodes, `leafCompact`, timeout `15000` ms (maximum `120000`),
10-minute expiry, and existing ref/action safety contracts stay fixed.

| Gate | Local evidence | What remains outside it |
|---|---|---|
| **A — presentation and coverage** | `SnapshotTests`, `CaptureTests`, TS producer/consumer fixtures, parsing and JSON output; original paths, completed-subtree refs, strict omitted diagnostics and full persisted evidence | Real content completeness, input delivery, latency and release approval. |
| **B — shipping preparation / raw failure safety** | `AXSnapshotPreparationTests`, `AXTrustTests`, `SnapshotTransactionTests`: injected raw timeout/copy/write/multiple/single operations used by live adapters; preparation hard failures stop observation and all hard failures prevent publication; actual action validation dispatches unchanged completed-subtree refs and rejects changed/unsafe evidence without snapshot preparation | Actual AX effects, permissions, browser readiness, synchronous IPC latency and native-app side effects. |
| **C — composed candidate automation** | Seven ordered commands below, full discovered suite results and tested source identities in the candidate verification note | Independent review, integrated-main checks, user-owned real-app acceptance and release approval. |
| **D — independently reviewed local main** | Coordinator-owned fresh review of the exact candidate, preservation checks and the same ordered full main automated gates after local integration | Pending at candidate handoff; candidate exit 0 is not main or review evidence. |
| **User-owned real-app acceptance** | **NOT RUN by workers/coordinator**; the user performs this separately | Not an automated/local-integration prerequisite; no live acceptance or release approval claimed. |

The shipping `SnapshotService` default invokes bounded preparation inside the
desktop lock, with target identity checks before/after it and final checks
after observation. Only actual optional write returns `attributeUnsupported`,
`failure` or `illegalArgument` negotiate capability. Timeout setup must
succeed; optional state reads use strict Boolean decoding with only
`attributeUnsupported`/`noValue` absence. Setup throws, hard raw statuses,
malformed success, cancellation and deadline expiry remain failures, not
successful unsupported preparation. Only top-level batch `attributeUnsupported`
permits individual fallback; per-entry scalar compatibility stays local.

An accepted manual/enhanced write means only **requested**, not “web AX ready”
or “browser fixed.” Calls request at most a 250 ms timeout against remaining
budget; synchronous IPC is not forcibly cancelled. A first manual enable may
wait 250 ms only with more than 500 ms remaining and prior state not true.
Live cost/latency/side effects remain unmeasured. Action validation keeps its
whole-tree stale policy and does not invoke snapshot preparation.

Run each candidate gate separately from the candidate root on macOS, and
retain full output/exit status/counts. After independent review and safe local
integration, the coordinator repeats these on main; those are separate gates:

```sh
npm run native-tests
npm run typecheck
npm test
npm run test:native-protocol
npm run test:build-hygiene
npm run build
npm test
```

Bounded post-build artifact checks are `node ./dist/cli.js --version`,
`node ./dist/cli.js --help` and
`./dist/native/computer-use-host --protocol-version` (expected protocol `1`).
They do not run GUI/input commands or prove TCC readiness. Package smoke,
installation, live desktop checks and release approval are not substituted
for these candidate/main gates.

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

## User-owned real-app acceptance — NOT RUN

The user will validate real apps separately. No worker/coordinator live GUI,
browser, foreground input, Chrome, keyboard or Shopee checks are authorized
for this integration. No real-app command recipe is part of its automated
plan. User-owned acceptance is not an automated or local-integration gate;
actual input effect, broader browser readiness, service-hosted panel targeting
and live/release acceptance remain unproved by the fixture/build checks.

## Offline input repair — drag-event-cadence (G1)

This workflow's live verification is **DEFERRED / PROHIBITED under G1**.
Do not run real desktop/browser/GUI, input posting, screenshots, real AX
queries, live fixtures, doctor or package smoke for this repair. This section
does not change another workflow's authority or grant future live permission.

`DragCadenceTests` injects event construction/post/wait operations into the
shipping synchronous `LiveInputDriver.drag`, sharing a fake monotonic clock.
No production event poster or sleep runs. The timing **candidate** is 20
straight-line samples with 15 ms minimum gaps between all 22 normal posts
(down, 20 samples, up): 21 gaps, 315 ms nominal without overhead. Synchronous
wait requests are positive, at most 5 ms, and capped by gap and command budget;
early wakes and scheduler delay never compress the next gap. Short budgets
can now return `TIMEOUT` rather than speed up a stroke.

Cancellation, expiry and construction/wait failure after down immediately
release the preallocated up at the last dispatched point. That single emergency
release is the intentional exception to pacing/context validity, not continued
drawing. Preparation failure posts nothing; cleanup does not allocate or wait.
`CaptureTests` proves actual input geometry/cadence equivalence for cursor-on/off
using seeded capture records, fake providers and a recording renderer. It also
checks stale geometry, failure envelopes, overlay cleanup and lock release.

Task 1's non-live commands are:

```sh
swift test --package-path native --filter DragCadenceTests
swift test --package-path native --filter CaptureTests
npm run native-tests
```

Inspect fixtures before execution: use injected post/wait, renderer and AX
operations, never live fallbacks. Inert event/AX-handle allocation and synthetic
image encoding are not desktop input, AX queries or real screen captures.
See the [offline evidence and unresolved acceptance report](verification/2026-10-20-offline-input-delivery.md)
for RED/GREEN results and scope. Dispatch-only `verification:"dispatched"` does
not prove receiver continuity or repair. Keyboard code remains unchanged and
functional delivery unresolved; Task 2's AX diagnostics/composed build gates
are pending. Underlying Chrome AX readiness and all live acceptance stay open.

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
