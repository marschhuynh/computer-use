# Offline input delivery — Tasks 1–2 evidence (2026-10-20)

The Task 1 record below is retained as historical evidence. The appended
**Task 2 / composed candidate** section updates its pending AX/build dispositions;
it does not close any live acceptance. Task 1 was independently accepted by the
coordinator before Task 2; Task 2 independent review remains a separate gate.

## Disposition and authority

**Live verification: DEFERRED / PROHIBITED under G1.** No real desktop,
browser, GUI, input posting, screen capture or AX query was performed. No
valid request was sent to a live host; no doctor, live fixture, package smoke,
installation, network, permission/TCC change, merge, push or publication ran.

Task 1 implements a **drag timing candidate**, not verified receiver repair:
20 straight-line samples, 15 ms minimum between all 22 normal posts, hence
21 gaps / 315 ms nominal down-to-up without overhead. Production sleep accuracy
is not assumed; measured monotonic elapsed time enforces each next gap.
Requested waits are positive and capped at 5 ms, remaining gap and remaining
command budget. Short budgets fail with the existing `TIMEOUT`, not compressed
pacing. There is no hard wall-clock completion or receiver-delivery guarantee.

The down and reusable up are prepared before holding the button. After down,
any construction/wait/context failure releases once at the last dispatched
position, without allocation, waiting or a valid context. This emergency up
is the sole intentional exception to normal pacing/context validity. Primary
errors remain failures; `verification:"dispatched"` remains dispatch-only.

Authority: Assistant's exact Task 1 approval under actual-user G1, recorded in
the canonical primary-checkout `docs/flow/drag-event-cadence/progress.md`.
That ledger was read, not modified. Task 1 includes non-live verification,
scoped documentation and a checked local task commit; it does not authorize
Task 2 implementation or any live acceptance.

## Identity and scope

All commands below ran in:
`/Users/marsch/Projects/nuvin/nuvin-computer-use-input-fixes`

- Branch: `fix/offline-input-delivery`.
- Base: `9016b83458ae0332a27632874e73a506116f4b38` (approved-doc preparation commit;
  product baseline `be27f65ee25a0da4a63c9c3279e4261f13ebdbb7`).
- Approved spec SHA-256: `a6abcde0d552ea99e8252f82c891a034ce750ae8d3038586a5df2fc3def4219f`.
- Approved plan SHA-256: `8c2e5fb64eebe65f09769db4d4c85a64418b9178b4db45161b1857b73ee31fa0`.
- This note accompanies the Task 1 source commit; the exact resulting commit
  SHA is recorded in `.agentic-flow/drag-event-cadence/task-1-report.md`.
- SwiftPM built fresh worktree-local debug artifacts in `native/.build`.
  No primary-checkout source execution or cached-host substitution occurred.
  No composed release/dist build was run; that is Task 2's gate.
- The existing untracked `node_modules` dependency symlink was preserved and
  is excluded from the commit. It is the authorized setup artifact, not a
  Task 1 dirty file. No dependency installation or lockfile change occurred.

Tested source SHA-256 values:

| Path | SHA-256 |
| --- | --- |
| `native/Sources/ComputerUseCore/NativeInput.swift` | `c97bd416fe87d5d645639739c73cf09de8a5f2ffc0ab3a16bf4f9d3e482c104f` |
| `native/Tests/ComputerUseCoreTests/DragCadenceTests.swift` | `de12497988bb1da5975072496fde26b5d7b3bdddecce478e7821130d4517c857` |
| `native/Tests/ComputerUseCoreTests/CaptureTests.swift` | `6387495c0c181fabd54f9a835c5e2c3c0501bb1813f8c1f1e67bab1e57053e4e` |

Task paths are precisely these three files, `docs/testing.md`, and this new
verification note. Public APIs/wire fields, keyboard/click/scroll behavior,
service routing, capture validation, foreground preparation and overlay
architecture are unchanged. `releaseHeldInputs` remains a no-op for this
driver's drag, preventing wrapper cleanup from double-releasing.

## Safety inspection before execution

Inspected `native/Package.swift` (no external package dependencies/plugins),
`scripts/native-tests.mjs` (only `swift test --package-path native`), all native
fixture files' service/provider/adapter entry points and their called seams,
and `Fixtures/inventories.json`. Relevant safety findings:

- New `DragFixture` replaces all three drag operations. It constructs inert
  `CGEvent`s and copies event type, location, button and fake time immediately;
  it never calls `.post`. Synchronous wait only advances fake time or throws;
  unexpected async sleep fails. Tests run the shipping algorithm, not a
  duplicated interpolation loop.
- New cursor fixtures use a fresh service per mode, fake display providers,
  seeded records, unique temporary store/lock roots, no-op snapshot preparation,
  rejecting capture/activation/AX-observation closures and a recording renderer,
  never `CursorOverlay`. Wall time is fixed within capture lifetime. Cursor-on
  advances fake time by 100 ms only before input.
- Existing capture tests use injected synthetic image bytes/bitmap encoding,
  not screen capture. Existing foreground tests use recording drivers and fake
  activation. Discovery/doctor-shaped fixtures use fake providers/environment
  values, not live CLI/host requests or permission probes.
- AX preparation tests inject trust/create/timeout/copy/write operations.
  AX batch tests use injected multiple/single reads; the one success-only cache
  with default single reader cannot reach fallback. Live-reader children/actions
  are not invoked there; transaction traversal supplies fake replacements.
  Constructing inert AX handles/values performs no AX query.
- Snapshot/action tests inject observation, identity, preparation and dispatch;
  geometry, protocol decoding/serialization and window joins are pure fixtures.
  Default live closures retained by unused service routes are not executed.
- State/lock tests operate on unique temporary roots. Their only spawned process
  is `xcrun xctest` selecting the temporary lock helper test, not the native host.
  Existing concurrency/lock tests may use real timers/semaphores and temporary
  filesystem fixture cleanup; they do not interact with apps or desktop input.
  No separate workspace/user-artifact cleanup was performed.

## Regression-first evidence

All counts below are XCTest counts (the separate Swift Testing footer reporting
zero tests is not the XCTest result). Expected behavioral RED was obtained
from compiled tests, before each corresponding behavior change. Only a
mechanical seam initially exposed the old tight loop.

| Stage / literal command | Exit | Observed result |
| --- | --- | --- |
| Seam-only RED: `swift test --package-path native --filter DragCadenceTests` | 1 | 1 test, 23 assertion failures. Repeated to capture concise totals after the cold-build output; same 1/23 result. |
| Seam-only route RED: `swift test --package-path native --filter CaptureTests` | 1 | 20 tests, 2 assertion failures, both cursor-mode relative timelines. |
| Pacing GREEN: `swift test --package-path native --filter DragCadenceTests` | 0 | 1 test, 0 failures. |
| Pacing route GREEN: `swift test --package-path native --filter CaptureTests` | 0 | 20 tests, 0 failures. |
| Fail-closed release RED: `swift test --package-path native --filter DragCadenceTests` | 1 | 4 tests, 979 assertion failures (most are repeated forbidden clock reads after a deliberately failed construction). |
| Preallocated last-position release GREEN: `swift test --package-path native --filter DragCadenceTests` | 0 | 4 tests, 0 failures. |
| Pre-down interruption RED: `swift test --package-path native --filter DragCadenceTests` | 1 | 13 tests, 4 assertion failures: cancellation/expiry during down/up preparation still posted down. |
| Pre-down recheck GREEN: `swift test --package-path native --filter DragCadenceTests` | 0 | 13 tests, 0 failures. |
| Expanded route fixture compile correction: `swift test --package-path native --filter CaptureTests` | 1 | No tests executed; three new assertions incorrectly wrapped dictionary `WireError.details` in `.object`. **Not behavioral RED.** |
| Expanded route GREEN: `swift test --package-path native --filter CaptureTests` | 0 | 23 tests, 0 failures. |
| Final source/comment focused GREEN: `swift test --package-path native --filter DragCadenceTests` | 0 | 13 tests, 0 failures. |
| Full native fixture suite: `npm run native-tests` | 0 | 299 tests, 0 failures (17 XCTest suites). |

Representative RED output:

```text
GeometryAndNominalCadence:
  timestamps [0, 0, ... 0] != [0, 15000000, ... 315000000]
  elapsed 0 != 315000000; waits [] != 63 × 5000000
  final sample (190.1, -90.69999999999999) != (190.1, -90.7)
DragCursorModesUseSameActualGeometryAndCadence:
  relative timestamps [0, 0, ... 0] != [0, 15000000, ... 315000000]
MovementConstructionFailureStopsAndReleasesWithoutAllocationOrWait:
  XCTAssertThrowsError failed: did not throw an error
  allocations 22 != 2; waits 60 != 3 (first failed sample)
WaitFailurePreservesPrimaryErrorAndReleasesOnceWithoutContextOrAllocation:
  release (210, 120) != last dispatched (110, 70); allocations 12 != 11
InterruptionDuringConstructionCannotSlipANormalPostThrough:
  XCTAssertTrue(f.posts.isEmpty) failed in four preparation cases
```

The compile correction was localized by inspecting `Protocol.swift`'s
`WireError.details: [String: JSONValue]?` and `NativeService.attachingStatus`.
Only the three test expectations were corrected to dictionaries. No product
behavior was changed for that failure. Subsequent focused/full runs passed.

Final full-suite output (2026-10-20, completion 10:09:05 as printed by XCTest):

```text
AXSnapshotPreparationTests 28; AXTrustTests 23; CaptureTests 23;
CommandContextTests 8; CursorLifecycleTests 5; DesktopLockTests 9;
DiscoveryTests 10; DragCadenceTests 13; ForegroundExecutionTests 28;
GeometryTests 7; HostLifecycleTests 10; ProtocolTests 6;
SnapshotTests 48; SnapshotTransactionTests 19; StateStoreTests 22;
TargetResolverTests 30; WindowIDJoinTests 10.
Executed 299 tests, with 0 failures (0 unexpected) in 2.511 (2.541) seconds
```

Cold debug compilation emitted warnings in unchanged source/tests (Swift 6
sendability/async-context warnings under this Swift 5 package, forced-downcast,
unused-result/await and closure-syntax warnings). No warning was treated as
proof of a failed check; all final required tests passed. No unrelated warning
cleanup was attempted.

## Acceptance coverage and self-review

- AC-1/2: seven geometry pairs (forward/reverse horizontal, vertical, diagonal,
  zero length), fractional endpoints; exactly 22 posts and exact sample 20/up;
  nominal 63 × 5 ms requests and 315 ms elapsed. Early-returning, sub-request,
  40 ms overshoot, construction/post overhead and near-UInt64-limit schedules
  prove measured gaps, positive bounded requests and no catch-up burst.
- AC-3/4: initial cancellation/expiry/both, construction-boundary interruptions,
  initial/middle/final dwell, normal-up precheck, 2 ms budget; nil down/up and
  first/middle/final movement, distinct wait error. Allocation/wait snapshots,
  forbidden cleanup clock reads and direct/wrapped routes prove immediate
  last-position release, original errors and no double up.
- AC-5: actual cursor-on/off input timelines agree after normalizing away the
  100 ms visualization lead-in. Nonzero-origin geometry, dispatch-only result,
  renderer lifecycle, stale/expired/invalidated/missing/moved-under-lock capture,
  invalid endpoint, preparation failure and mid-input failure are covered.
  Failed routes release the temporary lock; spatial routes never activate apps.
- Existing 28 foreground/key/click/scroll regressions and native trust/transaction
  tests remain unchanged and passed. Source diff confirms only drag behavior
  changed; no service, protocol, keyboard or AX product changes.
- `git diff --check`: exit 0. `git status --short`: exit 0; only the five Task 1
  paths plus the known untracked dependency symlink. No unexpected paths.
- Self-review command (exit 0): `git diff -- native/Sources/ComputerUseCore/NativeInput.swift native/Tests/ComputerUseCoreTests/CaptureTests.swift docs/testing.md`;
  additionally read the new `DragCadenceTests.swift` and this note. Reviewed
  safety, scope, failure ownership and acceptance coverage. This is self-review,
  **not independent review or approval**.

## Unresolved acceptance / provenance

| Item | Disposition |
| --- | --- |
| Drag offline pacing and release implementation | Task 1 automated checks complete; **timing candidate only**. |
| Drag receiver continuity / Excalidraw and Kleki behavior | **Unverified; DEFERRED / PROHIBITED under G1.** Offline dispatch cannot establish stroke continuity or endpoint reception. |
| Keyboard functional delivery | **Unresolved; unchanged.** E3 found no supported functional delivery cause/fix. No arbitrary keycode, timing, focus or routing change was made. |
| AX diagnostic-loss repair | **Task 2 pending**, not implemented here. Existing AX regression results do not establish the new diagnostic acceptance criteria. |
| Underlying Chrome AX failure/readiness | **Unresolved.** Historical generic failures cannot identify the failing operation/status retroactively; diagnostics would not prove recovery. |
| Task 2 focused AX, TS typecheck, JS tests, native protocol, build hygiene, fresh composed release build and post-build gates | **Not yet run for this candidate; Task 2 pending.** Task 1 is not AC-6's composed completion gate. |
| All live acceptance, including keyboard/Chrome/drag receiver outcomes | **DEFERRED / PROHIBITED under G1.** Requires new authority; no implicit future execution instruction. |
| Independent review | Coordinator-owned gate after this Task 1 candidate; not performed by the implementation owner. |

Historical provenance only: primary-checkout
`docs/todo/2026-10-19-live-cli-keyboard-and-drawing.md` and
`docs/verification/2026-10-19-excalidraw-cli-live-test.md`; E1 drag diagnosis and
E3 offline keyboard/AX findings as incorporated in the approved spec. Those
original untracked files, live TODOs and private artifacts were not copied,
modified, closed or staged. This new sanitized note does not replace historical
observations or claim all three functional bugs repaired.


## Task 2 / composed candidate — offline implementation complete

**Live verification: DEFERRED / PROHIBITED under G1.** Drag remains a **timing
candidate** with receiver continuity unverified. AX work is a **diagnostic
improvement**, not Chrome recovery. **Keyboard delivery: unresolved.**
**Chrome AX readiness: unresolved.** This report does not claim all three
functional bugs fixed.

Authority: canonical primary-checkout `docs/flow/drag-event-cadence/progress.md`,
“Task 1 accepted; Task 2 exact approval,” Assistant under G1. No delegation and no
writes or source execution in the primary checkout. The inherited spec and plan
hashes were verified exactly; the full Task 2 brief equals the approved plan's
Task 2 section. Base HEAD during every source check/build was
`22146226ce646a6d9b56c9e03c58a41a2dfc28bc` on `fix/offline-input-delivery`.
Candidate content is pinned below; the subsequent task-scoped commit is recorded
in the helper `task-2-report.md`. No product/test source changed after the ordered
gates; only task documentation and local evidence were then completed.

### Implemented scope and safety

- Optional `details.ax` contains only phase, operation, allowlisted attribute,
  paired numeric actual status/static name, scope and reason; at most seven
  scalar fields, ASCII strings ≤64 characters. Unknown attributes are omitted;
  unknown codes retain their numeric value plus `unknown`.
- Timeout failures receive explicit resolution/observation labels at those
  callers; unrelated action setup retains the unlabelled default. Preparation
  timeout, strict Boolean reads and actual hard writes own their context. Existing
  cancellation/deadline checks and negotiation status rules remain unchanged.
- Observation preserves top-level batch ownership (no invented attribute),
  entry/direct provenance and actual status distinct from compatibility sentinels.
  Missing/shape/array/bounds/decode failures retain their specific reason and
  status `0` for malformed success. Bounds still reads position then size before
  classifying, preserving failure/absence precedence. First diagnosed failures
  propagate unchanged.
- No retry, weakened trust rule, empty-success fallback or added publication path.
  Optional scalar/actions/children policies remain intact. Transaction fixtures
  prove no observation after hard preparation, no publication after hard failure,
  released locks, and unchanged identity brackets and valid/unsupported controls.
- Native sentinel tests cover titles, values, URLs, identifiers, CF objects/array
  members, unknown names and arbitrary thrown error descriptions. JSONEncoder of
  actual NativeService replies retains safe metadata without those payloads.
  Deliberately supplied NativeFailure values still pass through unchanged;
  generic non-AX errors keep existing generic serialization. TS projection is
  unchanged and redaction can remove diagnostic scalars or the entire object.
- All exercised AX, input, renderer, discovery and capture operations use injected
  providers/event sinks/CF values or synthetic encoded images. Inert handle/event
  construction is not IPC or posting. Typed `CFArray` APIs cannot safely represent
  a wrong non-array pointer; no unsafe-pointer fabrication was attempted. Existing
  wrong-array unavailability guards are retained; decoder failures use narrow pure
  decoder injection rather than any real AX query.
- Inspected package/scripts, discovered native fixtures, mock-host JSON mode,
  CLI static exits and native framing/validation guards before gates. Protocol
  tests submit 27 invalid shared fixtures, framing/EOF cases and static version;
  no valid GUI-host command is sent. Synthetic in-process request names are not
  live apps/doctor/snapshot/input operations.
- No real desktop, browser, GUI, screenshots, input posts, AX query, doctor,
  app/window discovery, live fixture or package smoke. No installs, network,
  permission/TCC changes, merge/push/publication or discretionary cleanup. Normal
  approved build-local dist regeneration and fixture teardown only. `node_modules`
  remains the pre-existing untracked dependency symlink, never staged/deleted.

### Task 2 meaningful RED/GREEN

All commands and evidence in this section have cwd
`/Users/marsch/Projects/nuvin/nuvin-computer-use-input-fixes`.
Full stdout/stderr is retained under `.agentic-flow/drag-event-cadence/` in
`task2-*.log`; these are newly generated synthetic logs, not copied private history.
Counts are XCTest counts, not the separate zero-test Swift Testing footer.

| Behavior slice / command | Compiled RED (exit 1) | GREEN (exit 0) | Log suffixes after `task2-` |
| --- | --- | --- | --- |
| Shared timeout: `swift test --package-path native --filter AXDiagnosticsTests` | 2 tests / 6 missing-details assertions | 2 / 0 | `timeout-red`, `timeout-green` |
| Preparation owners: `swift test --package-path native --filter AXSnapshotPreparationTests` | 28 / 36 missing-details assertions | 28 / 0 | `preparation-red`, `preparation-green` |
| Preparation propagation: `swift test --package-path native --filter SnapshotTransactionTests` | 19 / 27 missing-details assertions | 19 / 0 | `transaction-preparation-red`, `transaction-preparation-green` |
| Batch ownership: `swift test --package-path native --filter AXTrustTests` | 23 / 46 missing-details assertions | 23 / 0 | `batch-red-confirmed`, `batch-green` |
| Batch propagation: `swift test --package-path native --filter SnapshotTransactionTests` | 19 / 10 missing-details assertions | 19 / 0 | `transaction-batch-red`, `transaction-batch-green` |
| Scalar/entry provenance: `swift test --package-path native --filter AXTrustTests` | 24 / 23 missing-details assertions | 24 / 0 | `scalar-red`, `scalar-green` |
| Children/actions: `swift test --package-path native --filter AXTrustTests` | 25 / 15 missing-details assertions | 25 / 0 | `collections-red`, `collections-green` |
| Bounds/extraction: `swift test --package-path native --filter AXTrustTests` | 27 / 27 missing-details assertions | 27 / 0 | `bounds-red`, `bounds-green` |
| First array decode reason: `swift test --package-path native --filter AXTrustTests` | 28 / 1; `invalidArrayElement` incorrectly displaced earlier `decodeFailure` | 28 / 0 | `first-decode-red`, `trust-final` |

Representative owner RED: `failure.details` was `nil` instead of the exact safe
`ax` object (e.g. preparation/setMessagingTimeout/-25204/cannotComplete/direct).
No signature/compiler failure was counted as RED. Mechanical timeout, collection
and pure decoder seams preserved existing decisions before behavioral assertions.

One test-wiring mistake was diagnosed before batch production changes:
`task2-batch-red.log` unexpectedly passed 23 tests because `assertBatchFailure`
accepted but did not inspect its new expected `ax` argument. Inspection of that
helper localized the omission; adding the assertion produced 46 genuine RED
failures (`batch-red-confirmed`), then the owner implementation passed them.
Self-review also found the array classifier's second scan could replace an earlier
injected decode failure with a later invalid member. A compiled regression proved
that mismatch; recording the first reason during decoding fixed it before gates.
Neither case changed optional availability or permitted a live fallback.

Final focused results, all exit 0:

| Literal command | Result | Log |
| --- | --- | --- |
| `swift test --package-path native --filter AXDiagnosticsTests` | 4 passed | `task2-diagnostics-final.log` |
| `swift test --package-path native --filter AXSnapshotPreparationTests` | 28 passed | `task2-preparation-final.log` |
| `swift test --package-path native --filter AXTrustTests` | 28 passed | `task2-trust-final.log` |
| `swift test --package-path native --filter SnapshotTransactionTests` | 20 passed | `task2-transaction-final.log` |
| `npm test -- tests/backend-macos.test.ts` | 291 passed, 1 file | `task2-backend-focused.log` |
| `swift test --package-path native --filter DragCadenceTests` | 13 passed | `task2-drag-final.log` |
| `swift test --package-path native --filter CaptureTests` | 23 passed | `task2-capture-final.log` |

### Ordered composed gates

The following ran separately in this exact order, all exit 0, with full output
retained in the corresponding `task2-gate-NN-*.log` (same cwd above):

| # | Literal command | Observed output/result |
| --- | --- | --- |
| 1 | `npm run native-tests` | 309 XCTest tests / 18 suites, 0 failures; completion 10:30:56, 2.805 seconds |
| 2 | `npm run typecheck` | `tsc --noEmit` passed |
| 3 | `npm test` | 399 tests / 4 files passed |
| 4 | `npm run test:native-protocol` | Fresh debug host; 5 tests passed (27 invalid fixtures within one test) |
| 5 | `npm run test:build-hygiene` | `build hygiene regression passed` |
| 6 | `npm run build` | Fresh TS/release native build; `Build complete! (18.39s)` |
| 7 | `npm test` | Post-build 399 tests / 4 files passed |
| 8 | `env NUVIN_COMPUTER_USE_TEST_HOST=/Users/marsch/Projects/nuvin/nuvin-computer-use-input-fixes/dist/native/computer-use-host node node_modules/vitest/vitest.mjs run tests/native-protocol.test.ts` | 5 tests passed against exact release dist host; no debug-host substitution |
| 9 | `node ./dist/cli.js --version` | `0.1.0` (known package-version mismatch left untouched) |
| 10 | `node ./dist/cli.js --help` | Static usage/command/global-flag text |
| 11 | `./dist/native/computer-use-host --protocol-version` | `1` |

Release build emitted existing forced-cast, unused-result, trailing-closure and
Swift 6 sendability warnings under this Swift 5 package. The original casts and
unrelated warning sites were not changed to silence them. All required offline
gates passed; no required offline check was omitted. All live acceptance is
**DEFERRED / PROHIBITED under G1**, not an unrun offline gate.

### Built source and artifact identity

Build base HEAD: `22146226ce646a6d9b56c9e03c58a41a2dfc28bc` plus the four AX
production and five test paths listed below. Documentation was completed after
the checks. Exact SHA-256 identity (computed after the build):

| File | SHA-256 |
| --- | --- |
| `dist/cli.js` | `2cc55b2e6cd36ae2a5e8f80244764acd4a6b2093bb938ac87e3e19e018d9f6df` |
| `dist/native/computer-use-host` | `1548c5bd441f914ee0df3287f4e5cb82ee7b2b5ff3fc0d8a388b63bbcb4635da` |
| `native/Sources/ComputerUseCore/NativeInput.swift` | `c97bd416fe87d5d645639739c73cf09de8a5f2ffc0ab3a16bf4f9d3e482c104f` |
| `native/Sources/ComputerUseCore/AXTree.swift` | `cf9a7fc88ed7210290f8cf64994582013a082a89ea2c701c961daaa0b718e801` |
| `native/Sources/ComputerUseCore/AXSnapshotPreparation.swift` | `03a8a80c9ca5d873030ae770f0ef882dbfd116f9de49173d3b10d1de2ad5a363` |
| `native/Sources/ComputerUseCore/AXDiagnostics.swift` | `c7d55e6258176ff2bfee1438370605a6b8e9c020b83059d8e44a9557ed43a2b7` |
| `native/Sources/ComputerUseCore/TargetResolver.swift` | `5ca43e0365a3b82d2f37f4a978414a2443e42fc20bf7d8b72b97e1d3ca27351a` |

The worktree `native/.build/arm64-apple-macosx/release/computer-use-host` hash
exactly equals the dist host hash. `dist` was absent before gate 5; neither it
nor `native/.build` is an external directory symlink (Swift's internal debug
symlink stays within this build). No primary dist/cache or historical host was
used. Build log `task2-gate-06-build.log` SHA-256:
`bd7c2cbce458d8bd08df9df3e28da13f157902e4c861b4869064792bd25c1396`.
The helper `task2-source-build.sha256` also pins all five changed test files;
its SHA-256 is `a5322e9929b20ec3ec6f2004c0aa7be95bd12129b30aceddd7cddd4402a2fb52`.
`task2-log-manifest.json` inventories complete log byte sizes, hashes and totals.

Task 2 changed paths (11; no Task 1 input/test edits):

- `native/Sources/ComputerUseCore/AXDiagnostics.swift` (new)
- `native/Sources/ComputerUseCore/AXTree.swift`
- `native/Sources/ComputerUseCore/AXSnapshotPreparation.swift`
- `native/Sources/ComputerUseCore/TargetResolver.swift`
- `native/Tests/ComputerUseCoreTests/AXDiagnosticsTests.swift` (new)
- `native/Tests/ComputerUseCoreTests/AXSnapshotPreparationTests.swift`
- `native/Tests/ComputerUseCoreTests/AXTrustTests.swift`
- `native/Tests/ComputerUseCoreTests/SnapshotTransactionTests.swift`
- `tests/backend-macos.test.ts`
- `docs/testing.md`
- `docs/verification/2026-10-20-offline-input-delivery.md`

Self-review read the full production/test diffs and both new files, including
ownership, decoder/status provenance, privacy and unchanged policy controls.
`NativeInput.swift`, `src/backend/macos.ts`, `SnapshotService.swift` and
`Protocol.swift` diffs against Task 1 are empty. No keyboard method/keycode/timing
or Task 1 drag behavior changed. `git diff --check` passed. Status contained only
the above task paths plus the known untracked dependency symlink; generated
builds/helper evidence are ignored. Independent review is not this self-review.

### Current unresolved-item disposition (supersedes Task 1 pending rows)

| Item | Current disposition |
| --- | --- |
| Drag algorithm cadence/release | Offline implementation/regressions passed; **timing candidate**, not receiver acceptance. |
| Drag receiver continuity, Excalidraw/Kleki live matrix | **Unverified; DEFERRED / PROHIBITED under G1.** No live TODO closed. |
| AX diagnostic loss | Offline diagnostic improvement implemented and checked; safe metadata reaches native/TS envelopes unless privacy redaction removes it. |
| Keyboard delivery | **Keyboard delivery: unresolved.** E3 supports no functional repair; keyboard unchanged. |
| Underlying Chrome snapshot/AX cause | **Chrome AX readiness: unresolved.** Diagnostics do not recover historical missing status or prove functional readiness. |
| Composed offline candidate | All required focused, full-suite, build and post-build gates passed. |
| Task 2 independent review | Separate coordinator-owned gate; not self-approved. |
| Future real-app evidence | Requires new authority; **DEFERRED / PROHIBITED under G1**. No implied follow-up live execution. |
