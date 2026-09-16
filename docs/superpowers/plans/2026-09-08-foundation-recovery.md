# Standalone CLI Foundation Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete a bounded, nine-task AX/state/protocol repair series, preserving useful unfinished work; then stop at an explicit lifecycle/identity planning gate before claiming foundation readiness.

**Architecture:** Keep the TypeScript CLI, package-local Swift host, and Swift-owned desktop/state transaction. Recover trustworthy AX evidence and private state first and close protocol/testing gaps. The user explicitly gated the cross-cutting cancellable-context/identity migration into the next separately written implementation plan. Capture, input, cursor, packaging, and live acceptance receive their own gated plans.

**Tech Stack:** Node.js 22+, TypeScript, existing Vitest 3, Swift tools 5.9+ / Swift language mode v5, macOS 14+, Foundation, AppKit, ApplicationServices, CoreGraphics, XCTest. No new dependency or schema-generator framework.

## Global Constraints

- Public specification: `../specs/2026-09-08-standalone-cli-design.md`.
- Approved recovery amendment: `../specs/2026-09-08-foundation-recovery-design.md`.
- Review evidence: `../../reviews/2026-09-08-foundation-review.md`.
- Foreground automation first, macOS only.
- TypeScript CLI plus a Swift native helper; reuse the existing backend where correct.
- Include both accessibility-reference actions and raw mouse actions in v1; neither is executed by this recovery.
- Display a virtual cursor as feedback; do not promise input isolation. Rendering remains future scope.
- No persistent daemon in v1. A native host lives for the duration of an individual command.
- Node.js 22 or newer; macOS 14 or newer; Swift 5.9 or newer.
- Default deadline is 15 seconds, covering input loading, lock acquisition, activation, animation, native operations, and verification. Cancellation cleanup has a separate 2-second grace period.
- Accepted timeout is an integer from 1 through 120,000 ms inclusive, checked by TS and Swift.
- Records expire after 10 minutes. State root: `~/Library/Application Support/nuvin-computer-use/`; directories 0700, files 0600.
- No implicit last target, silent fullscreen capture, semantic-to-coordinate fallback, automatic mutation retries, private SkyLight APIs, arbitrary model/script execution, MCP, Guardian, or background control.
- No original-source deletion or native desktop operation during recovery. No apps/windows/doctor/live snapshot success, capture, activation, input, or permission prompt in automated verification.
- Do not reset/clean/discard the unfinished patch. Do not commit unrelated files, merge, push, publish, or start later projects implicitly.
- This session is **planning only**. Existing baseline/task commit authorization applies when the user starts execution; it does not authorize staging the unfinished implementation while writing these documents.

---

## 1. What this plan replaces

This plan replaces the immediate execution strategy for the unfinished foundation (original Task 4 plus newly confirmed integration gaps). Its executable scope is the nine A/C tasks only. Lifecycle/identity findings R2/R3/R4 remain blocking and belong to the required next-plan gate approved by the user. It does **not** replay Tasks 1–3, erase their reviewed commits, or declare them globally correct merely because their task-local reviews passed.

The original `2026-09-08-standalone-cli.md` remains historical requirements/coverage evidence. Its Tasks 5–12 are **not** executable work packets after recovery; use the [staged continuation roadmap](2026-09-08-standalone-cli-continuation-roadmap.md).

### Read the plan as an index, two detailed volumes, and explicit gates

| Volume | Concern | File |
|---|---|---|
| A | AX trust, deterministic evidence, private state | [AX/state detailed steps](2026-09-08-foundation-recovery-ax-state.md) |
| C | Fresh native integration, request/reply contracts | [Protocol/test detailed steps](2026-09-08-foundation-recovery-contracts.md) |
| Next-plan gate | Native deadline/cancellation and refreshed identity — **not executable yet** | [Lifecycle/identity planning brief](2026-09-08-foundation-lifecycle-design-gate.md) |
| Roadmap | Unbuilt v1 subsystems and authorization gates | [Staged continuation](2026-09-08-standalone-cli-continuation-roadmap.md) |

The A/C letters group ownership; they do not determine execution order. The ordered ledger below does. Each detailed task includes files, interfaces, actual code/test blocks, RED/GREEN commands, and its review/commit boundary. An implementer receives one task plus its required interface context, not all volumes. The lifecycle document and continuation roadmap are visibly non-executable gates, not unfinished code packets.

## 2. Exact starting state and safe preservation

Workspace: `/Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli`
Branch: `feature/standalone-cli`
HEAD: `9b3a6d5056942eb4f12a8fb14316f3fa60cb937c`

Inherited uncommitted implementation files:

```text
native/Sources/ComputerUseCore/AXTree.swift
native/Sources/ComputerUseCore/DesktopLock.swift
native/Sources/ComputerUseCore/SnapshotService.swift
native/Sources/ComputerUseCore/StateStore.swift
native/Tests/ComputerUseCoreTests/SnapshotTests.swift
native/Tests/ComputerUseCoreTests/StateStoreTests.swift
native/Tests/ComputerUseCoreTests/AXTrustTests.swift   # untracked, must be preserved
```

Fresh planning-time baseline:

- Swift test target: **compile failure**, missing AX reader seam declarations.
- TypeScript typecheck: **pass**.
- Vitest: **239 pass**, but native protocol cases use an existing ignored staged binary. This is not proof of the current native source.
- Whitespace diff check: **pass**.

### Recovery setup — preservation, not implementation

- [ ] Confirm the execution location and baseline. If HEAD or implementation fingerprints changed since planning, review the new delta before applying any plan block.

```sh
cd /Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli
git branch --show-current
git rev-parse HEAD
git status --short
```

- [ ] Preserve both tracked and untracked unfinished work in a newly named recovery directory. `git diff` alone does not preserve the untracked AX test.

```sh
mkdir -p .superpowers
recovery_dir="$(mktemp -d .superpowers/recovery-XXXXXX)"
git diff --binary > "$recovery_dir/tracked.patch"
cp native/Tests/ComputerUseCoreTests/AXTrustTests.swift "$recovery_dir/AXTrustTests.swift"
git status --porcelain > "$recovery_dir/status.txt"
shasum -a 256 native/Sources/ComputerUseCore/{AXTree,DesktopLock,SnapshotService,StateStore}.swift native/Tests/ComputerUseCoreTests/{SnapshotTests,StateStoreTests,AXTrustTests}.swift > "$recovery_dir/fingerprints.txt"
```

- [ ] Start a **new** `.superpowers/sdd/foundation-recovery-progress.md` ledger. Do not mark the old Task 4 complete or overwrite the old task history. Record each local task ID, baseline/diff path, verification and independent review verdict.

```sh
mkdir -p .superpowers/sdd
printf '# Foundation recovery execution\n\nBase: 9b3a6d5056942eb4f12a8fb14316f3fa60cb937c plus preserved unfinished edits\n' > .superpowers/sdd/foundation-recovery-progress.md
```

On resume, read the existing recovery ledger instead of recreating it. Do not redispatch completed tasks.

## 3. File ownership map

| Owning area | Existing files kept | Additions/replacements defined in the task |
|---|---|---|
| AX read/trust | `AXTree.swift`, `AXTrustTests.swift` | Internal generic read-result/reader seam and live classified adapter; no new public AX API |
| Evidence policy | `AXTree.swift`, `SnapshotService.swift`, `SnapshotTests.swift` | One `AXEvidencePolicy` for ref derivation and semantic validation |
| Snapshot store | `StateStore.swift`, `StateStoreTests.swift` | Indexed graph validation, strict time grammar, retained syscall seams/private atomic I/O |
| Desktop lock | `DesktopLock.swift`, lock tests in `StateStoreTests.swift` | Shared-context asynchronous acquisition; same fd and no-unlink policy |
| Wire contracts | `Protocol.swift`, `src/core/protocol.ts`, `src/backend/macos.ts`, fixtures | Exact keys, error details/start status, actual snapshot response validators |
| Test provenance | `tests/native-protocol.test.ts`, `package.json` | `scripts/native-protocol-tests.mjs`; current-build-only host injection and owned-child cleanup |
| Native lifetime | `HostSupport.swift`, `HostMain.swift`, `NativeService.swift` | `CommandContext`/clock/worker ownership specified in Volume B |
| Target observation | `TargetResolver.swift`, resolver fixtures/tests | Explicit-PID provider access, precise launch identity, stale validation and repeated target checks |
| Snapshot transaction | `SnapshotService.swift`, transaction tests | Context-bound phases, pure preflight, invalidation, foreground hook, fresh evidence, dispatch/cleanup |

No second state store, second native dispatch path, generic capture record stub, compatibility wrapper, or broad old-source refactor is created during recovery.

## 4. Ordered execution ledger

| Order | Task | Independent deliverable | Mandatory local gate |
|---:|---|---|---|
| 1 | A1a | Pure AX reader seam restores native test compilation | `AXTrustTests` compile and pass |
| 2 | A1b | Production AX adapter rejects hard status/type failures | Pure adapter/status tests and `SnapshotTests` |
| 3 | C1 | Default mock-only tests; current-build native protocol command; owned child cleanup | `npm test`, `test:native-protocol`, `DesktopLockTests` |
| 4 | A2 | One canonical ref/truncation/evidence policy | Direct producer tests in every hint mode and invalid-evidence tests |
| 5 | A3 | Strict, indexed semantic records and exact timestamps | `StateStoreTests`, including malformed boundaries/refs/fractions and scale case |
| 6 | A4 | Verified adoption of inherited filesystem/invalidation repairs | Fault-injected state tests, no-dispatch assertions, repeated lock tests |
| 7 | C2 | Exact-key TS/Swift request parity and exclusive scroll forms | Shared fixtures, parser tests, fresh native protocol tests |
| 8 | C3 | Error details and mutation certainty cross the wire safely | Shared status fixtures and structured failure backend tests |
| 9 | C4 | Snapshot replies validated against the actual Swift producer | Producer fixture equality and malformed reply matrix |
| Stop after 9 | Required next-plan gate | Write/approve lifecycle/identity recovery from the repaired source | Do not implement capture/input or claim full foundation readiness |

No writer agents run in parallel on these files. Read-only reviewers may run concurrently with controller verification once no writer is active. Do not move to a task whose producer interfaces are not present and approved.

### Review and inherited-change staging

A1a/A1b may have a focused green test target while unrelated inherited Task 4 assertions remain red. Record that state honestly; a focused compile-recovery review is not the integrated foundation gate.

Every review package must contain both the task delta and enough inherited context to distinguish newly introduced defects from explicitly scheduled recovery work. No blanket `git add -A` or whole dirty-file stage is permitted merely because an agent says “done.” For a new task-owned file, ordinary targeted `git add` is appropriate. For inherited dirty files, use hunk selection. In a noninteractive CLI, prepare a reviewed patch under `.superpowers/sdd/` and use `git apply --cached --check` / `git apply --cached`; do not hang a shell tool on `git add -p`.

If an owned hunk depends on an unreviewed inherited hunk, include that prerequisite in the review or defer the commit until both are reviewed. Do not reset the working file to isolate commits. A task report can identify a deferred checkpoint; final integration requires every incorporated hunk to have been reviewed.

## 5. Internal interface ledger and cross-volume contracts

These are deliberate amendments to the original plan's overly ambitious frozen internal ledger. Public command syntax and `schemaVersion: 1` remain unchanged.

### Evidence

```swift
AXTree.readSnapshot(target:options:root:reader:)
    // returns (snapshot: AXTreeSnapshot, elementsByRef: [Int: Element])
AXEvidencePolicy.deriveRefs(nodes:boundaries:mode:) -> [AXRefEvidence]
AXEvidencePolicy.validate(_:options:) throws
```

The exact generic declaration and complete bodies are in A1a/A2. A1b's Core Foundation bridge checks type IDs **before** casts; raw public action names remain strings, not undocumented formatted-description parsing. Later context injection must preserve these semantics and existing pure tests.

### State and time

The current snapshot-specific store remains the sole storage implementation. Recovery does not fake generic capture records. The capture stage extends that one store to both kinds and migrates call sites atomically. Wall timestamps describe record expiry; monotonic ticks describe command deadlines. No consumer recreates a full timeout after lock/read/invalidation.

`CommandContext`, `NativeClock`, async lock/service signatures and worker/main ownership must be frozen by the next lifecycle/identity plan, not guessed during these nine repairs. If a compiler or platform constraint invalidates a proposed signature, stop and update its producer, every consumer, tests and this ledger together; never leave two competing production paths.

### Mutation certainty

Internal native wire `error.details.mutationStatus` admits exactly:

```text
notStarted
potentiallyApplied
```

The public CLI includes only `potentiallyApplied` when relevant. Missing status on a valid structured failure after mutation dispatch is conservative; explicit `notStarted` suppresses that marker. An invalid spelling is a protocol failure. Native successful preflight does not imply an action occurred; the status follows the first possible side effect, not an optimistic success flag.

C3 changes `NativeFailure`, `WireError`, `WireReply.failure` and TS projection together. The next lifecycle plan must retain `failure.details` forwarding when making dispatch async. New semantic values are admitted by the approved flexible/privacy strategy; shared collision fixtures establish which constants may legitimately equal supplied text.

### Snapshot response and identity precision

C4 validates actual `SnapshotResult.wireData` and `treeJSON`, including UUIDs, target metadata/bounds, tree node/ref types, and exact lifetime. The target wire key remains `launchDate`, using canonical UTC ISO text with up to nine fractional digits; the identity recovery preserves full reliable public Date precision without renaming it to an opaque token. If a different public identity token is needed, that is a new producer/consumer design decision rather than an undocumented validator exception.

### Test artifact provenance

After C1:

```text
npm test                         mock-only TypeScript
swift test --package-path native pure current-source Swift
npm run test:native-protocol      current-source build, injected host, protocol-safe requests only
npm run build                    clean TS output, native staging last
```

The test-only host environment variable is consumed only by test code. Production helper lookup remains package-relative, with constructor injection only for tests. No successful native command is smuggled into “protocol coverage.”

## 6. Bounded repair verification gate — not foundation readiness

Run these after all nine A/C tasks are reviewed:

- [ ] Verify the current native source, not a pre-existing staged executable.

```sh
swift test --package-path native
npm run typecheck
npm test
npm run test:native-protocol
npm run test:build-hygiene
npm run build
npm test
```

Expected: all commands exit 0, no unexplained skipped native tests, no live desktop dispatch, no leak of owned test children. Test counts may increase; do not hardcode the planning baseline as a future passing count.

- [ ] Verify build and original-source boundaries.

```sh
test ! -e dist/tools
test ! -e dist/ports.js
test -f src/tools/ComputerUseTool.ts
test -x dist/native/computer-use-host
git diff --check
git status --short --branch
```

- [ ] Review the invariants actually repaired here: classified AX failures cannot become trustworthy evidence; malformed/truncated evidence fails; recognized-record invalidation fails closed; structured error uncertainty and snapshot response validation cross TS/Swift boundaries; default tests cannot use a stale native binary. Explicitly retain R2/R3/R4 as unresolved lifecycle/identity blockers.
- [ ] Request one independent review of the nine-task repair range and preserved initial patch. Resolve change-related Important/Critical findings, then stop and write the required lifecycle/identity plan. Full integrated foundation approval requires that next plan to be implemented and reviewed too.
- [ ] Update the recovery ledger and review report with exact command output summaries, commits, inherited hunks incorporated, and limitations. Do not mark live capture/input/permissions/package install as verified.

## 7. Coverage map

| Fresh review finding | Recovery task(s) |
|---|---|
| R1 missing AX seam/error→absence | A1a, A1b |
| R2 cancellation/main-loop blockage | Required lifecycle next-plan gate; remains unresolved after A/C |
| R3 scoped inventory/identity race/launch precision | Required lifecycle next-plan gate; remains unresolved after A/C |
| R4 late dispatch after invalidation | Required lifecycle next-plan gate; remains unresolved after A/C |
| R5 truncation, duplicated/quadratic semantics, strict fractions | A2, A3 |
| R6 exact-key/mixed-form drift | C2 |
| R7 details/status/snapshot reply validation | C3, C4 |
| R8 stale native binary and test-subprocess leakage | C1; active production host cancellation remains the lifecycle gate |
| Already improved root/lock/read/invalidation paths | A4 verifies/adopts; the next lifecycle plan must preserve them |
| Capture, input, cursor, package, live acceptance, retirement | Explicit stages in the continuation roadmap; not claimed complete here |

## 8. Plan verification and limitations

The implementation baseline was freshly checked as documented in the review report. During plan self-review, complete JavaScript blocks were syntax-checked in their documented enclosing contexts; complete Swift declaration blocks were parsed. The new AX adapter and evidence-policy snippets were also typechecked against the current native models, correcting invalid CF conditional casts before execution.

These checks are **not** a claim that every proposed migration is already compiled or tested. The nine A/C task code blocks remain implementation instructions; RED/GREEN verification and independent task review are required at execution time. OS calls cannot be made perfectly cancellable by checkpoints, public AX evidence cannot prove identity of indistinguishable replacement controls, and plan code must not be used to claim native acceptance.

## 9. Execution handoff

Planning leaves implementation paused. When explicitly started, choose:

1. **Subagent-driven:** one small A/C task per implementer, task-scoped review, durable progress, repair-range review, then stop at the next-plan gate.
2. **Inline execution:** execute the same ordered tasks with the same RED/GREEN and review gates.

Do not resume the stopped giant Task 4 fixer. Start at A1a from the preserved current state. After the nine-task repair gate, write and approve `2026-09-08-foundation-lifecycle-design-gate.md`’s implementation plan from the new source. Only after lifecycle/identity recovery and its integrated foundation review may the continuation roadmap begin. Do not resume the old oversized Task 5 by default.
