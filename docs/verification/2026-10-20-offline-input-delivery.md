# Offline input delivery — Task 1 evidence (2026-10-20)

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
