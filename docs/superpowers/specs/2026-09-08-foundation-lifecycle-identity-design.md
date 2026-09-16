# Standalone CLI foundation lifecycle and identity design

Date: 2026-09-08
Status: Approved design; planning only
Entry implementation: `5ce315185d53b24300108f438cb6f49b1abdf03c`

## Purpose

Close the three foundation blockers deliberately deferred by the bounded A/C recovery:

- **R2:** cancellation must reach active native work without blocking the AppKit main loop, and shutdown must follow resource cleanup;
- **R3:** selected process/window identity must remain precise and be refreshed across observation and preflight;
- **R4:** no desktop dispatch may occur after invalidation crosses the deadline or after foreground preparation invalidates the observed identity/evidence.

This design preserves the recovered AX trust, evidence, private state, request/reply, test-provenance, and mutation-certainty contracts. It does not implement public discovery, capture, semantic input, raw mouse input, cursor rendering, packaging, or live acceptance. Passing its eventual implementation gate establishes foundation readiness only.

## Constraints retained from the approved foundation

- Foreground macOS CLI; TypeScript process plus one package-local Swift host per command.
- Node.js 22+, macOS 14+, Swift 5.9+ in Swift v5 mode.
- One 15,000 ms default deadline; accepted integer range 1–120,000 ms.
- Two-second Node-owned child cleanup grace remains separate from the operation deadline.
- Ten-minute records under `~/Library/Application Support/nuvin-computer-use/`; directories 0700 and files 0600.
- Public APIs only. No daemon, private API, implicit target, automatic retry, model execution, MCP, capture/input/cursor implementation, permission prompt, or live personal-app verification.
- Preserve C3 wire status spellings exactly: `notStarted` and `potentiallyApplied`. Public output never exposes `notStarted`.
- Preserve the C4 public target key `launchDate` and snapshot response shape.
- Preserve the C1 separation between mock-only `npm test` and current-source `npm run test:native-protocol`.

## 1. Architecture and ownership

### Command context

Create one `CommandContext` when the native host accepts a valid request. It owns:

- one absolute monotonic deadline;
- a separate wall-clock source for record timestamps and expiry;
- one cancellation state;
- `check()` behavior that distinguishes deadline expiration from explicit interruption;
- deadline-clamped asynchronous suspension.

The deadline is computed once from the already-reduced native `timeoutMs`. No native consumer creates a fresh timeout. Overflow-safe arithmetic is required.

Cancellation uses one shared context token. Parent EOF cancels it, and Swift task cancellation is bridged into and checked through the same state. Consumers must not choose independently between a host token and `Task.isCancelled`.

If explicit interruption and deadline expiry are both observable at one checkpoint, explicit interruption takes precedence and maps to `INTERRUPTED`. Parent loss still suppresses the reply. Deadline expiry maps to `TIMEOUT` only when no explicit interruption is active.

### Worker and main actor

One serial native worker owns each accepted command's blocking transaction. Lock acquisition, AX reads, state I/O, evidence validation, and dispatch orchestration remain off the AppKit main thread.

Only APIs that require AppKit or `NSWorkspace` execute on `MainActor`. They return reduced value metadata before the worker continues. Main-actor closures must not retain the native desktop lock while synchronously waiting on the worker.

The worker boundary wraps the complete resource-owning command transaction rather than hopping each AX/state operation independently. Logical ownership remains with one command even when it awaits an explicit main-actor provider.

### Async migration boundary

`NativeService.execute` becomes async and accepts the command context. `DesktopLock.withLock` becomes async and context-aware. `SnapshotService` orchestration and injected phase closures become async, throwing, and context-aware. Pure parsers, evidence policy, JSON conversion, and deterministic state semantics remain synchronous.

The signature migration is one compile-safe task: production call sites, injected closures, test call sites, and async assertion helpers change together. There is no permanent synchronous compatibility dispatcher or duplicate production path.

### Lock ownership

Do not wrap every command in a second outer lock.

- `SnapshotService` remains the sole lock owner for snapshot and future snapshot-based action transactions.
- `NativeService` owns the lock only for `doctor` until later command coordinators define their own sole owner.
- The same verified descriptor remains open from acquisition through operation completion, then unlocks/closes exactly once on every exit.

## 2. Host lifecycle

For a valid request, `HostSession` has four states:

```text
ready → running → finished
          ↓
      cancelling → finished
```

Transitions:

- `ready + start`: create and own one command task, then enter `running`.
- `ready + parent EOF`: cancel without starting work, perform cleanup, then enter `finished`.
- `running + completion`: emit exactly one reply, clean up, then enter `finished`.
- `running + parent EOF`: cancel the context and task, suppress any reply, then enter `cancelling`.
- `cancelling + completion`: keep the reply suppressed, finish cleanup, then enter `finished`.
- Duplicate starts, late completions, and duplicate completions are ignored safely.

A worker cancelled before its body begins must still invoke its owning completion callback. It may not return silently and strand the session in `cancelling`.

Run-loop shutdown occurs on the appropriate main-thread boundary only after worker and lock cleanup. Parent loss never emits a reply, but it also never skips cleanup.

Startup EOF is classified by framing state:

- zero bytes before any request: silent shutdown without starting work;
- partial unterminated input: exactly one `PROTOCOL_ERROR`, preserving the shared protocol test;
- complete newline-delimited request: normal session behavior.

The host still handles one request and exits. This design does not introduce a daemon.

## 3. Target identity and resolver flow

### Provider split

Split live target resolution into two provider layers:

1. A `MainActor` process-metadata provider lists cheap application metadata without reading AX windows.
2. After selector disambiguation, a selected-PID provider reads AX/CG windows only for that process on the worker.

An ambiguous application selector fails before any AX-window provider invocation. An explicit PID invokes the selected-window provider for exactly that PID.

### Launch identity

Keep the public key `launchDate`. Preserve the reliable public process-start `Date` with canonical UTC precision, allowing up to nine fractional digits as already admitted by C4. Do not reduce it to whole seconds, rename it, or replace it with an undocumented token.

Applications lacking a reliable start date remain available to later discovery listings but cannot participate in persisted identity-sensitive targeting. Missing identity must not silently erase discovery candidates.

### Serializable evidence and private handles

Serializable target evidence remains separate from private live AX handles. No AX handle, private object description, or app-supplied value enters persisted/public identity.

Revalidate PID, launch date, bundle ID, window ID, title, and bounds:

- after initial AX observation;
- after pure preflight;
- after foreground preparation;
- immediately before dispatch.

Use A1's classified AX reading and Core Foundation type checks instead of duplicating permissive `as?` reads.

### Refreshed element continuity

The action transaction retains the preflight live element and obtains a fresh live element after foreground preparation. Compare them with an injected, public-API-safe identity predicate.

- A detectable element replacement returns `STALE_SNAPSHOT`, even if public title/bounds evidence still matches.
- If the element is still the same, rerun side-effect-free preflight against the refreshed element and dispatch the newly prepared value with that same element.
- Never pair preparation from an old element with a different fresh handle.

The identity predicate is test-injected. Production must not use pointer-description parsing or private APIs.

The production predicate compares verified `AXUIElement` references with public Core Foundation equality (`CFEqual`), not pointer descriptions or serialized metadata. Tests inject the predicate to prove both continuity and replacement paths.

### Failure classification

- AX API disabled or trust denial: `PERMISSION_DENIED`.
- Hard AX statuses, cannot-complete, invalid UI elements, or Core Foundation type mismatches: `NATIVE_FAILURE`.
- Conclusive missing/replaced persisted process/window/element identity or persisted evidence mismatch: `STALE_SNAPSHOT`.
- Fresh target absence retains the existing target-selection error.

A persisted-validation call must not collapse permission or native-read failures into stale state.

## 4. Deadline and cooperative cancellation

`CommandContext.check()` runs at entry and exit of every transaction phase and at bounded internal checkpoints:

- between AX request groups and traversal groups;
- between state records during sweep/invalidation;
- around read/write chunks and publication boundaries;
- after interrupted system calls before retry;
- after invalidation;
- after foreground preparation;
- after fresh observation;
- immediately before desktop dispatch;
- before accepting completion where no earlier commit point governs the result.

Asynchronous lock waiting is clamped to the remaining budget and observes cancellation. `BUSY` means the budget expired while actual lock contention was observed. Exhaustion without contention is `TIMEOUT`.

Cooperative checks do not claim to preempt a kernel or AX call already blocked. Public AX messaging remains bounded within the command's remaining policy. Node's owned-child TERM/KILL cleanup remains the outer hard bound.

Before each live AX request group, set the public AX messaging timeout to no more than `min(2.0 seconds, context.remaining)`. If no positive budget remains, fail before issuing the AX request.

## 5. Transaction flow

### Snapshot creation

```text
check
→ acquire lock with the same context
→ sweep
→ resolve selected target
→ observe AX tree
→ refresh and compare target identity
→ check
→ construct record timestamps from context wall clock
→ context-aware atomic write
→ durable publication commit
→ success
```

State I/O checks the context during preparatory writes and before atomic publication. Existing no-follow, owner-only, write/sync/rename/directory-sync, and fail-closed behavior remains unchanged.

Durable publication is the commit point. Once rename and required directory sync have safely published the valid record, the operation result is success even if cancellation is observed immediately afterward. If the parent is gone, the host suppresses delivery but still completes cleanup. The service must not report timeout while leaving an apparently failed but valid record, and it must not invent rollback deletion.

Snapshot creation does not mutate the desktop, so C3 desktop `mutationStatus` is not added to its public result.

### Snapshot-based action

```text
check
→ lock
→ sweep/load
→ resolve/read/compare persisted evidence
→ identity recheck
→ pure preflight
→ identity recheck/check
→ invalidate app records when state-changing
→ check
→ foreground-preparation hook
→ check
→ fresh resolve/read/compare
→ private live-element continuity check
→ rerun pure preflight
→ check immediately before dispatch
→ dispatch
→ completion check/cleanup
```

Rules:

- Preflight is side-effect-free by contract; the type system does not claim to enforce that.
- Preflight failure keeps records valid.
- Any failure after successful invalidation leaves records invalidated.
- Cancellation never restores invalidated records.
- Foreground preparation remains an injected no-op/test hook in this phase; no activation is implemented.
- Dispatch remains injected in this phase; no real input is implemented.
- Non-state-changing future operations retain no-invalidation semantics.
- Replacement or evidence change after preflight yields zero dispatch.

### Mutation certainty

Before the first possible desktop side effect, structured native failures carry internal `mutationStatus: notStarted` where the action boundary requires certainty. Once dispatch may have begun, uncertain failures carry `potentiallyApplied`. No third status spelling is introduced, and `NativeFailure.details` remains preserved through async conversion.

Record invalidation changes private state but does not itself mean the desktop mutation began.

## 6. Error and privacy behavior

- Deadline expiration: `TIMEOUT`.
- Explicit CLI/task interruption: `INTERRUPTED`.
- Parent loss: no reply; cleanup still completes.
- Actual lock contention at budget exhaustion: `BUSY`.
- AX trust denial: `PERMISSION_DENIED`.
- Hard native/AX failure: `NATIVE_FAILURE`.
- Persisted target/evidence replacement: `STALE_SNAPSHOT`.

Unknown errors remain sanitized. No error includes supplied input text, full command arguments, app-private AX values, or raw filesystem paths. Existing TypeScript privacy projection helpers and stable public error-code set remain unchanged.

## 7. Implementation boundaries

The implementation plan must produce six independently reviewable tasks.

### L1 — Command context and clocks

Add pure context/clock/cancellation types and focused tests. Cover monotonic and wall-clock separation, cancellation precedence, timeout boundaries, clamped sleep, and overflow-safe deadline arithmetic. No production caller migration occurs here.

### L2 — Atomic async worker/lock/service migration

Introduce the serial worker and migrate `DesktopLock`, `SnapshotService`, `NativeService.execute`, host caller, injected closures, and affected tests together. Supply async throwing XCTest helpers. Preserve sole lock ownership, C1 subprocess cleanup, and C3 details forwarding. Do not claim green at an intermediate broken signature state.

### L3 — Selected-PID resolver and precise identity

Split providers, retain pure fixture resolution, preserve launch precision, and reuse A1 classified AX reads. Test ambiguous names produce zero AX-window reads, explicit PID queries exactly one PID, same-second process starts differ, missing/replaced windows become stale, and permission/native failures remain distinct. Do not implement public `apps` or `windows` success output.

### L4 — Cooperative AX/state work boundaries

Thread context checks through bounded AX and state groups. Test cancellation during an injected slow read and between state records, plus a main-queue sentinel while worker work is active. Preserve A2 evidence policy and A4 atomic/fail-closed storage. Use deterministic barriers and clocks, not timing sleeps.

### L5 — Snapshot/action transaction

Implement the approved phase orders, strict live-element continuity, second pure preflight, foreground hook, publication commit semantics, and mutation-status boundaries. Test preflight failure, invalidation failure, deadline crossing during invalidation, replacement after preflight, post-hook tree change, element replacement, fresh preflight pairing, dispatch failure, and non-state-changing behavior.

### L6 — Host completion/cancellation state machine

Implement `cancelling`, cancel-before-start completion, reply-once/suppression, cleanup-before-shutdown, correct main-thread run-loop wakeup, and empty-versus-partial startup EOF. Use injected work to test every transition and prove lock release precedes shutdown.

## 8. Test and review strategy

- Follow RED/GREEN for every behavior change.
- Use pure fixtures, injected providers, injected clocks, barriers, semaphores, and expectations with bounded cleanup.
- Do not use timing-dependent sleeps to prove order.
- Use a local async throwing assertion helper; `XCTAssertThrowsError` cannot await.
- Preserve C1 subprocess `defer`/TERM/KILL/reap behavior in every affected test.
- No real app discovery, permission prompt, activation, AX mutation, capture, input, cursor, or successful live snapshot.
- Every task records RED evidence, focused GREEN evidence, affected-suite results, changed files, limitations, scoped staging, and independent review.
- No two writer agents operate on these files concurrently.

After L1–L6 pass their local reviews, run:

```sh
swift test --package-path native
npm run typecheck
npm test
npm run test:native-protocol
npm run test:build-hygiene
npm run build
npm test
```

Then request one integrated review of the A/C recovery plus lifecycle/identity range. The review must explicitly prove R2, R3, and R4 closed while retaining the repaired A1/A2/A4/C1/C3/C4 contracts.

## 9. Completion boundary

The lifecycle/identity implementation is complete only when:

1. Parent loss and explicit cancellation reach active work and shutdown follows resource release.
2. The AppKit main loop processes a deterministic sentinel while AX/state work is active.
3. One absolute monotonic deadline reaches lock, resolver, AX, state, service, and dispatch phases without reset.
4. A same-second replacement process or replacement window/element produces zero dispatch.
5. Deadline or cancellation during invalidation produces zero dispatch and leaves invalidated records invalidated.
6. Successful durable snapshot publication is reported consistently with the record that exists.
7. Error details, mutation certainty, strict request/reply contracts, private state safety, and current-source test provenance remain intact.
8. Full automated gates and integrated independent review pass.

Passing this gate means the foundation may proceed to Stage D. It does not mean the CLI actions, capture, cursor, package installation, or live behavior are complete or verified.
