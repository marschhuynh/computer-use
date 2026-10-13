# Compact accessibility snapshots — non-live verification

Workflow date: 2026-10-02. **Checks actually run: 2026-10-13.**
Scope: Task 6 fixture measurements, regression tests, and recovery documentation.
No live desktop commands, permission grants, real AX activation, or latency
experiment were run. This note is implementation evidence and self-review,
not independent review, whole-change validation, or release approval.

Traversal defaults and action validation remain unchanged.

## Candidate and environment

- Production candidate / Task 6 base: `d180c6a68538431eb4a5d7f12ed3e5efb35d8243`.
  Task 6 changes only tests and documentation; production source is identical
  to that revision. The tested regression files are in the commit containing
  this note, with these SHA256 identities:
  - `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`:
    `754301dd49671793c848a8c912d6378719e675bb6dfefcc4fdf5790722a4e76e`
  - `tests/cli-parse.test.ts`:
    `5d52b1db60eeeb9a28e79c3cd1a34662bb473793782c1d3c67640a0a9214104b`
  - `tests/cli-run.test.ts`:
    `9b9bc3a93c7ff104bce473e25b32f1d4b0b959b77ac7627c945b44e2322f39c7`
- Worktree: `/Users/marsch/Projects/nuvin-computer-use/.worktrees/compact-accessibility-snapshots`.
- macOS `26.6.2` / build `25G83`, `arm64`.
- Apple Swift `6.3.3` (`swiftlang-6.3.3.1.3`, clang `2100.1.1.101`),
  target `arm64-apple-macosx26.0`; Swift driver `1.148.6`.
- Node `v24.19.0`, npm `11.17.0`, Vitest `3.2.7`.
- Task-scoped local checks/docs/commit were authorized by SETUP-1 and resumed
  implementation authority. Task 7/live/default activation remains excluded.

The local helper evidence is retained under
`.agentic-flow/compact-accessibility-snapshots/` (ignored, not distributed).
`task-6-report.md` records the final commit SHA after commit. The source/test
identities above bind these pre-commit checks without pretending a commit
already existed when they ran.

## Reproducible measurements

Run from the worktree/repository root on macOS:

```sh
swift test --package-path native --filter SnapshotTests
```

`testPresentationByteMeasurements` calls the pure `AXTree.snapshot`, never
live AX or a persisted observation. Its private `measurePresentation` helper
uses `JSONEncoder` with `.sortedKeys` for both:

1. **Tree-only:** `presentationWire(snapshot)["tree"]`.
2. **Whole reply:** `WireReply.success(command: .snapshot, data: presentationWire(snapshot))`.

`Data.count` measures actual serialized **UTF-8 bytes**. No pretty-printing,
trailing terminal newline, parallel Markdown, or screenshot is included.
Every run prints `PRESENTATION_METRIC`, `PRESENTATION_TREE`, and
`PRESENTATION_REPLY` for each fixture/mode, including the exact serializations.
`treeCeilBytesOver4` and `replyCeilBytesOver4` are **`ceil(bytes / 4)` integer
proxies**, computed as `(bytes + 3) / 4`, not actual model tokens. There is no
tokenizer dependency. Test-run duration is not product latency.

All inputs use the same synthetic `save-cancel` target: PID `42`, bundle
`com.example.Editor`, launch date `2026-09-08T10:00:00Z`, window `7`, title
`Document`, target bounds `(100,100,600,400)`. All snapshots use depth `8`,
max elements `500`, fixed ID `123e4567-e89b-42d3-a456-426614174000`, createdAt
`2026-09-08T10:00:00.000Z`, expiresAt `2026-09-08T10:10:00.000Z`. No fixture
PID is sent to live preparation. The only option varying within each pair is
`leafCompact` versus `leafOnly`; `full` is not a like-for-like ref comparison.

| Fixture / helper in SnapshotTests | Input / observed nodes | Refs and original paths | Shape |
|---|---:|---|---|
| `neutral-wrapper` / `neutralWrapperInput` | 3 / 3 | 1, ID 1 at `[0,0]` | Exact Task 1 baseline: root → neutral group → button with separate title/label/value and false control states; no node bounds. |
| `zero-ref-text` / `zeroRefTextInput` | 2 / 2 | 0 | Exact Task 1 baseline: root → static text `Read only`. |
| `long-neutral-wrappers` / `longNeutralWrapperInput` | 8 / 8 | 1, ID 1 at `[0,0,0,0,0,0,0]` | Root → six alternating anonymous scroll-area/group wrappers → Save button; max actual depth 7. Wrappers have `enabled:true`, `focused:false`, `selected:false`; every node has bounds `(110,120,80,30)`. |
| `static-text-rich` / `staticTextRichInput` | 5 / 5 | 0 | Root plus four static-text children: `Status: ready`, `Read only — café ☕`, `No action is available here.`, `End of summary.` Unicode demonstrates byte rather than character counting. |

No fixture is truncated. Tests assert the default limits, complete immutable
evidence equality between leaf modes, original ref paths and IDs, unchanged
evidence after rendering, and expected emitted counts. Both wrapper fixtures
must be strictly smaller in compact **tree and whole reply** than current
`leafOnly`. Static-text fixtures retain all nodes and have equal trees across
leaf modes; no assertion requires them to beat the old ref-only projection.
Existing exact tree, boundary, geometry, and stale-evidence tests remain.

### Current modes (coverage included in whole reply)

| Fixture | Mode | Emitted nodes | Tree bytes | Whole-reply bytes | Tree `ceil(bytes/4)` proxy | Reply `ceil(bytes/4)` proxy |
|---|---|---:|---:|---:|---:|---:|
| neutral-wrapper | leafCompact | 2 | 195 | 754 | 49 | 189 |
| neutral-wrapper | leafOnly | 3 | 275 | 834 | 69 | 209 |
| zero-ref-text | leafCompact | 2 | 91 | 681 | 23 | 171 |
| zero-ref-text | leafOnly | 2 | 91 | 681 | 23 | 171 |
| long-neutral-wrappers | leafCompact | 2 | 210 | 769 | 53 | 193 |
| long-neutral-wrappers | leafOnly | 8 | 1055 | 1614 | 264 | 404 |
| static-text-rich | leafCompact | 5 | 266 | 856 | 67 | 214 |
| static-text-rich | leafOnly | 5 | 266 | 856 | 67 | 214 |

The long fixture saves **845 bytes** in each comparison to current leafOnly;
that is **not** a comparison to the original default. No original-default
measurement exists for that newly added fixture. Semantic text is not dropped
to obtain savings and budgets are not increased.

### Actual original-default baseline, same inputs

Task 1 captured these serializations **before renderer extraction or behavior
changes**, against original production revision
`159956b7554b2a85ce98bda56b77c993ea164155`, in
`task-1-before-extraction.log`, and reproduced them after the unchanged
extraction. `task-1-report.md` contains the original exact serialization.
Task 6 reread the raw baseline log and independently recounted all captured
UTF-8 strings, including current output, with Python
`len(serialized.encode("utf-8"))`; the 20 tree/reply strings and hashes are
retained in `task-6-serialized-metrics.json`. The baseline is measured history,
not a renderer reconstructed in Task 6 and not current leafOnly output.

| Fixture | Original → current compact emitted nodes | Refs before / after | Tree bytes original → current | Reply bytes original → current | Tree proxy original → current | Reply proxy original → current |
|---|---|---|---|---|---|---|
| neutral-wrapper | 3 → 2 | 1 / 1 | 275 → 195 | 662 → 754 | 69 → 49 | 166 → 189 |
| zero-ref-text | 0 → 2 | 0 / 0 | 15 → 91 | 402 → 681 | 4 → 23 | 101 → 171 |

The original small wrapper's tree shrinks **80 bytes**, but its whole reply
**grows 92 bytes** after coverage. The zero-ref tree grows **76 bytes**, and
its whole reply **279 bytes**, intentionally preserving the real root/text
and adding honest coverage. Task 1's intermediate pre-coverage compact reply
sizes were 582 and 478; current coverage adds 172 and 203 bytes respectively.
None of this proves universal savings, real token counts, or lower latency.

For durable baseline reproduction, these are the exact original tree JSON
strings (275 and 15 UTF-8 bytes respectively, excluding the newline):

```json
{"elements":[{"children":[{"children":[{"actions":["AXPress"],"enabled":true,"focused":false,"label":"Commit","ref":1,"role":"AXButton","selected":false,"title":" Save ","value":"draft"}],"enabled":true,"focused":false,"role":"AXGroup","selected":false}],"role":"AXWindow"}]}
```

```json
{"elements":[]}
```

Exact original whole replies (662 and 402 bytes respectively):

```json
{"command":"snapshot","data":{"createdAt":"2026-09-08T10:00:00.000Z","expiresAt":"2026-09-08T10:10:00.000Z","snapshotId":"123e4567-e89b-42d3-a456-426614174000","target":{"bounds":{"height":400,"width":600,"x":100,"y":100},"bundleId":"com.example.Editor","launchDate":"2026-09-08T10:00:00Z","pid":42,"title":"Document","windowId":7},"tree":{"elements":[{"children":[{"children":[{"actions":["AXPress"],"enabled":true,"focused":false,"label":"Commit","ref":1,"role":"AXButton","selected":false,"title":" Save ","value":"draft"}],"enabled":true,"focused":false,"role":"AXGroup","selected":false}],"role":"AXWindow"}]},"truncated":false},"ok":true,"schemaVersion":1}
```

```json
{"command":"snapshot","data":{"createdAt":"2026-09-08T10:00:00.000Z","expiresAt":"2026-09-08T10:10:00.000Z","snapshotId":"123e4567-e89b-42d3-a456-426614174000","target":{"bounds":{"height":400,"width":600,"x":100,"y":100},"bundleId":"com.example.Editor","launchDate":"2026-09-08T10:00:00Z","pid":42,"title":"Document","windowId":7},"tree":{"elements":[]},"truncated":false},"ok":true,"schemaVersion":1}
```

## Commands and actual results

All final required commands ran in the named worktree using `/bin/bash`.
The helper runner `task-6-verify.sh` redirects complete output to each log,
captures `$?` immediately, appends `EXIT_CODE`, and fails if any check fails.
All logs below are in the ignored helper directory noted above.

| Command | Exit | Actual result | Final log |
|---|---:|---|---|
| `swift test --package-path native --filter SnapshotTests` | 0 | 43 tests, 0 failures; all 8 metric rows above | `task-6-final-snapshot.log` |
| `npm test -- tests/cli-parse.test.ts tests/cli-run.test.ts` | 0 | 70 tests: 51 parse, 19 run | `task-6-final-cli.log` |
| `npm run typecheck` | 0 | `tsc --noEmit`, no diagnostics | `task-6-final-typecheck.log` |
| `npm test` | 0 | 383 tests, 4 files | `task-6-final-ts.log` |
| `npm run native-tests` | 0 | 240 XCTest tests, 0 failures | `task-6-final-native.log` |
| `npm run test:native-protocol` | 0 | Fresh host build and 5 protocol tests, 0 failures | `task-6-final-protocol.log` |

`npm test` excludes native-protocol tests by design; the last command runs
those separately. Before execution, the protocol runner, test requests, shared
invalid fixtures, and host entry point were inspected: only protocol version,
invalid requests, unterminated/oversized input, and empty EOF are exercised.
Invalid requests return before `NativeService` dispatch. No valid GUI command
or permission prompt was requested. No optional release/package build or
package smoke was run; the protocol script's host build is non-live.

Initial Task 6 focused native compilation exited 1 because the new fixture
passed `bounds` before `actions`. The actual `AXTreeInputNode` initializer
requires `actions` first. Source inspection confirmed this test-only cause;
argument order was corrected with no product fix, followed by 43 passing
focused tests and the final full suite above. That compile failure is retained
in `task-6-focused-native.log`, not claimed as TDD RED. This task adds regression
coverage for already-implemented behavior; no new behavior or optimization was
implemented. Initial focused CLI tests also passed (70, exit 0).

## Gate and self-review record

| Gate | Status | Evidence and limits |
|---|---|---|
| **A: presentation/coverage local checks** | **PASS (local checks + self-review only)** | Exact native producer/TS consumer fixtures, malformed/legacy coverage handling, 43 snapshot + 19 capture tests, unchanged defaults and timeout limits, one backend invocation / one JSON output, and all commands above. Task 6 independent review, whole-change review and final validation still follow. |
| **B: inactive preparation local checks** | **PASS (fake/injected tests)** | Tasks 4–5 are implemented, not “unimplemented.” Fresh full native suite includes 17 AXSnapshotPreparation, 15 AXTrust and 16 SnapshotTransaction tests; all pass. Compiled adapter is inactive; no-op hook is shipping default. Tests cover errors, cancellation/deadline, identity and publication behavior, not live acceptance. |
| **C: live Arc/native-app comparison** | **NOT RUN / HOLD** | No live authorization. No browser activation, asynchronous AX materialization, real IPC timing or native-app side effects proved. |
| **Live-default activation/release decision** | **HOLD** | No approval inferred from A/B. Requires separately authorized live evidence and an explicit decision; no default wiring performed. |

Self-review of Task 6 scoped diffs found only the eight intended tests/docs
files changed; no product source edits. Read-only inspection confirms refs
still derive from evidence, durable record/state-store formats are unchanged,
traversal limits remain fixed, and annotation bounds still come from
`snapshot.evidence.refs[*].node.bounds`, not projected context geometry.
Existing action validation and stale-evidence tests are unchanged. Added CLI
regressions preserve legacy omission and explicit annotated defaults, with no
extra backend request or output payload. Self-review is not independent
approval.

## Residual limits and next gates

- **No-op is not zero cost.** Task 5 added **two target identity validations**
  around preparation even with the no-op hook. Live process/window metadata
  and AX reads, time holding the lock, deadline consumption, and earlier
  transient identity/title/bounds errors have not been measured. Traversal
  defaults and action validation being unchanged does not mean all snapshot
  behavior or latency is unchanged.
- The bounded AX module is implemented, compiled and fake-tested but not wired
  into the shipping path. An accepted AX write would mean **requested**, not
  ready. No Arc fix or activation readiness is claimed.
- Coverage reports original evidence paths, and direct-child counts only.
  `refCount` is not an actionable-control count, especially in `full`;
  `noRefReason` reports a zero-ref condition, not a proved cause. A root
  element cap can yield zero refs in all modes. Neither missing coverage nor
  empty boundaries proves UI absence. Timeout/cancellation remain errors,
  not partial success. Legacy helpers may omit coverage.
- Retry a relevant traversal limit only when warranted; changing presentation
  cannot recover unvisited nodes. Use the **new snapshot's refs** after every
  retry. Screenshots are explicit and separate; text with no ref is context,
  not a basis for synthesizing a ref from compact child indexes. See the
  [CLI coverage contract](../cli.md#snapshot-coverage) and
  [agent recovery guidance](../agent-guide.md#snapshot-coverage-and-recovery).
- Task 3's lockfile install reported **four existing dependency vulnerabilities
  (1 moderate, 1 high, 2 critical)**. This is carried dependency debt, not a new
  audit result. No dependency changes, upgrades or remediation were performed.
- Synthetic fixture output only is committed. Coordinator-owned untracked
  `docs/flow/` and ignored helper evidence remain outside the scoped commit;
  no source-checkout artifacts, private screenshots, or live logs were changed.
- Independent Task 6 review, whole-change review, and validation remain next
  steps. This note does not grant release, merge, push, or live/default approval.
