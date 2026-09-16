# Standalone CLI foundation: fresh implementation review

Date: 2026-09-08
Workspace: `/Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli`
Branch/HEAD: `feature/standalone-cli` / `9b3a6d5056942eb4f12a8fb14316f3fa60cb937c`
Scope: current source **plus unfinished Task 4 changes**, not only the committed diff.
Verdict: **not ready for capture/input implementation**. Preserve the architecture and useful work; repair the current foundation first.

## Fresh verification

| Command | Observed result | What it proves |
|---|---|---|
| `swift test --package-path native` | Exit 1; missing `AXTreeReader`, `AXTree.readSnapshot`, `axReadDisposition` | Current native test target is incomplete and does not compile. |
| `npm run typecheck` | Exit 0 | Current TypeScript typecheck passes. |
| `npm test` | 7 files, 239 tests pass | Mocked TS coverage and protocol tests against an existing staged host pass; **not** current Swift build evidence. |
| `git diff --check` | Exit 0 | No patch whitespace errors. |

No live desktop command, permission prompt, capture, or native input was run during this review. Native test compilation failed before XCTest ran. No implementation files were edited. Three independent reviewers inspected lock/state, AX/snapshot, and CLI/host. Their overlapping findings are consolidated below rather than added together into a misleading total.

## Unfinished work that must be preserved

Tracked modifications: `native/Sources/ComputerUseCore/{AXTree,DesktopLock,SnapshotService,StateStore}.swift`, `native/Tests/ComputerUseCoreTests/{SnapshotTests,StateStoreTests}.swift`.

Untracked implementation test: `native/Tests/ComputerUseCoreTests/AXTrustTests.swift`.

The tracked patch is 589 insertions / 63 deletions across six files; the untracked test is additional. A preservation patch and pre-review status are in `.superpowers/replan/`; source fingerprints were recorded in the session. Do not use `git clean`, reset the worktree, delete failing tests, or assume all outstanding edits are verified.

## Findings requiring recovery

### R1 — Blocking: AX trust seam is unfinished

`native/Tests/ComputerUseCoreTests/AXTrustTests.swift:7-18,36-55` references nonexistent APIs. Fresh compilation confirms the failure. Production `native/Sources/ComputerUseCore/AXTree.swift:246-315` still turns hard read/type failures into `nil`, `[]`, or `AXUnknown`. Repeated failed observations can compare equal as if complete.

**Recovery:** finish the pure tri-state reader and route production through the same typed/error-aware adapter. Preserve legitimate absence; reject hard errors and type mismatches.

### R2 — Blocking: cancellation does not reach active work

`native/Sources/ComputerUseHost/HostMain.swift:24-28` invokes synchronous `NativeService.execute` on main. `native/Sources/ComputerUseCore/DesktopLock.swift:17-23,54-79` polls synchronously. `native/Sources/ComputerUseCore/HostSupport.swift:124-147` stops the session on EOF but does not wait for active work cleanup. AX traversal has no shared cancellation/deadline checkpoints.

**Recovery:** one monotonic command context, cancellable lock suspension, explicit worker/main ownership, EOF→active cancellation, shutdown after resource release. Do not pull cursor/input implementation into this task.

### R3 — Important: selected identity is not refreshed across observation

`native/Sources/ComputerUseCore/AXTree.swift:152-166` reselects a window by title/bounds and stamps the supplied target. `SnapshotService.swift:53-58,86-99` does not revalidate the public window ID after reading or preflight. A same-metadata replacement window can be attributed to the old ID.

**Recovery:** selected-process-only inventory, private AX root pairing, resolver checks before/after observation and before dispatch. Preserve full reliable process-start precision; current `TargetResolver.swift:71-83` formats launch time to whole seconds. Normalize stale-record resolution failures without hiding permission/native failures.

### R4 — Important: invalidation may cross deadline before dispatch

`native/Sources/ComputerUseCore/SnapshotService.swift:93-99` checks time before potentially expensive invalidation, then immediately dispatches. The store can enumerate/fsync many records. The new pure preflight split helps but does not provide the required post-activation evidence refresh boundary.

**Recovery:** explicit phases and checks after invalidation/foreground preparation/fresh observation and immediately before dispatch. Tests advance the injected clock in each phase and assert zero dispatch with records left invalidated.

### R5 — Important: evidence policy is duplicated, incomplete, and unnecessarily expensive

`native/Sources/ComputerUseCore/AXTree.swift:219-236` suppresses refs below boundaries but can promote an actionable ancestor to a leaf when descendants are truncated. `StateStore.swift:348-367` scans all nodes per parent, accepts duplicate boundary entries when count/membership match, and `:369-376` does not compare refs to the exact mode-derived set. `StateStore.swift:289-305` accepts empty/non-ASCII timestamp fractions.

**Recovery:** share pure deterministic reference/truncation rules; index parent/child relationships once; require exact canonical boundary/ref output; strict ASCII timestamp grammar and exact interval arithmetic.

### R6 — Important: request validation drifts across TS and Swift

`native/Sources/ComputerUseCore/Protocol.swift:95-153` tolerates conflicting/extra keys, including app plus an invalid PID. `src/cli/parse.ts:121-129` silently drops `--amount` in ref-scroll form. Swift has the analogous mixed-form acceptance.

**Recovery:** shared exact-key fixtures and fail-before-dispatch guards; keep existing CLI syntax and staged command behavior. Add typed payload decoding incrementally where consumed, not a replacement of every command at once.

### R7 — Important: reply contract remains incomplete

`native/Sources/ComputerUseCore/Protocol.swift:7-15,63-92` cannot carry optional error details. `src/backend/macos.ts:187-205` returns correlated structured failures lacking mutation-start evidence without the conservative status used for synthetic failures. Snapshot success validation at `src/backend/macos.ts:237-258` accepts arbitrary target/tree objects and invalid ID/time strings.

**Recovery:** paired real producer/consumer fixtures, details/status preservation, conservative unknown-start classification, strict snapshot response predicates. Keep the approved flexible semantic/privacy strategy; do not repeat generic substring rewriting or freeze every action to placeholder result strings.

### R8 — Important: native integration tests can validate stale artifacts

`tests/native-protocol.test.ts:8-23` uses ignored `dist/native/computer-use-host`; `package.json:15-23` does not build it before `npm test`. `build:ts` deletes it. The test's child helper has no bounded failure cleanup; Swift lock tests also lack cleanup on every failed setup path (`StateStoreTests.swift:307-320,444-472`).

**Recovery:** default mock-only tests plus separate build-current-native integration command; explicit test-only host injection; bounded finally/defer ownership cleanup. A missing host must not become a silent skip/pass.

## Old findings already improved in the partial patch

Retain and verify these rather than fixing them again:

- Final-component root symlink/path-chmod race: descriptor `open`/`fstat`/`fchmod` now used (`DesktopLock.swift:100-127`).
- Late successful `flock` acquisition: checked after success; EINTR returns through deadline check (`DesktopLock.swift:62-78`). Remaining issue is cancellation/nonblocking host integration.
- Silent invalidation skip: recognized unreadable/malformed records now fail closed (`StateStore.swift:138-150`).
- Preflight consumes records: separate preflight now precedes invalidation (`SnapshotService.swift:74-99`). Remaining issue is deadline/refresh phase composition.
- Exact ten-minute arithmetic: fractional seconds now compared as integral seconds/nanoseconds (`StateStore.swift:280-312`). Remaining issue is accepted grammar.
- Semantic checks now exist on read/write; they need one canonical policy and linear/indexed implementation, not another independent schema framework.

## Deliberately unbuilt / not verified

- `apps`/`windows` successful dispatch, complete doctor readiness/error behavior, and human output remain staged; do not call the current CLI complete.
- Capture/annotations/coordinate transforms, semantic and raw input, cursor, final coordinator, isolated tarball install, live fixture and source retirement are not implemented.
- A current-source host success snapshot test, real permissions, AX routing, real display geometries and overlay behavior have not been proven.
- Identical controls with identical public evidence remain inherently indistinguishable. The selected-window check narrows a detectable identity race; it cannot make AX observation atomic against external UI changes.
- Same-user hostile writers and kernel calls that do not return cannot be fully controlled by the application lock. No-follow/private modes and Node's owned-child kill bound are defense layers, not an absolute sandbox.

## Recommendation

Use the approved recovery design at `../superpowers/specs/2026-09-08-foundation-recovery-design.md` and a new, smaller-task implementation plan. Preserve original Tasks 5–12 as requirements inventory only; generate a new executable plan per subsystem after the foundation review gate. Prior Task 1–3 approvals are valuable task-local evidence, not substitutes for this cross-component review.

## Bounded nine-task recovery outcome

Date: 2026-09-08  
Reviewed range: `9b3a6d5056942eb4f12a8fb14316f3fa60cb937c..5ce315185d53b24300108f438cb6f49b1abdf03c`  
Verdict: **approved for the bounded A1a/A1b/C1/A2/A3/A4/C2/C3/C4 repair only; not foundation readiness**.

### Checkpoints

- `96c2c08566bd50ad1562c3382566192b8528b610` — A1a pure AX reader seam.
- `3fb508abbb250f2e82263b9817eabeded1803686` — A1b classified live AX adapter.
- `af1c42c7eb401ac665c67be1d9f942b7d4a5f555` — C1 fresh native protocol integration and subprocess ownership.
- `20606c2d036ca2a9159da0a593d95e4377becc17` — A2 canonical indexed AX evidence policy.
- `9026ca02c44390cdfccc440d4e5236d197793d7f` — combined A3 strict/indexed state semantics and A4 fail-closed filesystem/invalidation adoption.
- `fbbab7f714dcfe24cdc69e574970dd675bbad2d2` — C2 exact native request contracts.
- `cfc0c926a9988ef4c19a115e8bd72a449a797f45` — C3 structured native details and mutation certainty.
- `5ce315185d53b24300108f438cb6f49b1abdf03c` — C4 strict snapshot reply validation against the Swift producer.

The six initially modified tracked files and initially untracked `AXTrustTests.swift` are incorporated in the reviewed range. Their preserved prestate remains under `.superpowers/recovery-ddQyD7/`; the final broad reviewer accounted for that patch and found no discarded inherited implementation hunk.

### Integrated verification at `5ce3151`

Current-HEAD evidence produced during C4 was reused rather than rerun redundantly:

| Command | Observed result |
|---|---|
| `swift test --package-path native` via `npm run native-tests` | 69 tests passed, 0 failures |
| `npm run typecheck` | Exit 0 |
| `npm test` | 6 files, 243 tests passed; native protocol suite excluded |
| `npm run test:native-protocol` | Current Swift host built in the invocation; 4 protocol-safe tests passed |

The remaining integrated gate then ran:

| Command/check | Observed result |
|---|---|
| `npm run test:build-hygiene` | Exit 0; build hygiene regression passed |
| `npm run build` | Exit 0; TypeScript clean build and native product build completed |
| post-build `npm test` | 6 files, 243 tests passed |
| `test ! -e dist/tools`; `test ! -e dist/ports.js`; `test -f src/tools/ComputerUseTool.ts`; `test -x dist/native/computer-use-host` | All passed |
| `git diff --check` | Exit 0 |

No live desktop command, successful native snapshot, permission prompt, capture, activation, or input was run.

### Final range review

Independent review of the complete range plus the preserved initial patch returned:

- requirements verdict: **Pass for the bounded nine-task recovery**;
- code-quality verdict: **Approve**;
- Critical findings: none;
- Important findings: none;
- Minor findings: none.

R1, R5, R6, R7, and R8 are repaired within the approved bounded scope. R2 (cancellation/main-loop responsiveness), R3 (selected-process identity precision and refresh), and R4 (post-invalidation deadline/fresh-evidence boundary) remain explicit blockers for the required lifecycle/identity plan. Capture, input, cursor, packaging, live automation, permissions, and source retirement remain unbuilt or unverified. Do not proceed to continuation stages or claim foundation readiness until the lifecycle/identity gate is implemented and independently approved.
