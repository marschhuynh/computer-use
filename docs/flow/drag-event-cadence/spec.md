# Offline input repair: drag cadence and AX diagnostics

Status: proposed revision; supersedes unapproved v1 hash `3b6541560bad635bb121498c249aa91fb5ab4384c71b08eb1ad728413cb1559c`. Workflow ID/directory remains `drag-event-cadence`.

## Authority and incorporated handoffs

- **E1 incorporated:** [drag diagnosis](evidence/diagnosis.md), research run `delegated-run-e43331b3-f202-4683-b340-bbaf887d5f10`, completed read-only. Its historical live gate is superseded below.
- **E2 incorporated:** actual user selected “All three logged issues, offline (Recommended)” and “Approve isolated setup and local commits (Recommended)” after saying “i will sleep now, let do all of the fix, but do not do the real test, ok?” G1 in [progress.md](progress.md) supersedes historical manual/unresolved-setup statements. All real/live/GUI/input testing is **PROHIBITED**; browser remains untouched. Live verification is **DEFERRED**, not an execution/completion gate.
- G1 delegates exact spec/plan approval, supported in-scope implementation decisions, offline checks/review, exact isolated setup and checked local commits to Assistant. Approved identities: branch `fix/offline-input-delivery`; worktree `/Users/marsch/Projects/nuvin/nuvin-computer-use-input-fixes`; helper workspace `/Users/marsch/Projects/nuvin/nuvin-computer-use-input-fixes/.agentic-flow/drag-event-cadence`. Narrow approved-spec/plan-only preparation commit on verified main is authorized; local source commits stay isolated. Assistant must verify resource conflicts, approve exact artifacts/assignments and record gates before dependent actions. No overwrite, push, merge, publishing, installation, permission changes, or cleanup is authorized. Grant is revocable; this document does not self-approve or create resources.
- **E3 incorporated:** [offline keyboard/AX findings](evidence/offline-keyboard-ax.md), research run `delegated-run-d2fd2506-4202-40fb-a3eb-4fcadf33bf68`, completed read-only. Apply the user's supported-causes-only/uncertain-findings condition: implement the drag pacing candidate and confirmed AX diagnostic-loss repair; keep keyboard functional delivery and underlying Chrome AX readiness open. No new research delegation is required.

## Problem

Historical CLI tests showed shortened Excalidraw pencil strokes, Kleki brush dabs, ineffective keyboard commands, and generic Chrome AX snapshot failures. Improve only evidence-supported behavior offline, without weakening targeting, deadlines, cancellation, release safety, or privacy. Distinguish “offline implementation/checks complete” from “real-world repair verified”; dispatch acknowledgements and offline tests cannot establish application success.

## Current behavior and evidence

- `native/Sources/ComputerUseCore/NativeInput.swift:369–397` synchronously posts down, 20 interpolated dragged events, and up with no deliberate waits. Final interpolation equals the endpoint; failed movement construction is silently skipped; interruption cleanup attempts up at the requested endpoint.
- `CommandContext.swift:84–103,115–134` provides remaining budget and checks, but its sleep is async and the driver drag protocol is synchronous (`NativeInput.swift:33–34`). Checks do not pace events. `ForegroundExecutionTests.swift:28–74,220–239` manufactures labels in a fake driver, not the live drag algorithm.
- E1 confirms the shipped unpaced algorithm and endpoint-preserving mocked CLI probes. Cursor animation precedes the shared input closure; it does not pace samples. **Unpaced posting is fact; receiver coalescing/frame-dependent loss and timing sufficiency are hypotheses.** No overlay cause is proved.
- E3 confirms parser preservation and expected keyboard construction/mappings (`NativeInput.swift:187–228,419–455`). Default HID and process routes differ in activation; neither proves focused-field continuity. No functional delivery cause was established by construction-only probes or disassembly. Timing, focus, routing and modifier interpretation remain hypotheses, not grounds for arbitrary sleeps/retries/keycode changes.
- AX failures lose operation/status: `AXTree.swift:651–668,685–697` collapses hard statuses and malformed successful results to generic failures except permission distinction. Saved live errors cannot identify the original failing stage. This diagnostic loss is confirmed; Chrome's underlying failure cause is not.
- Relevant owners: `AXSnapshotPreparation.swift:85–134,151–175` handles preparation reads/writes/timeouts; `AXTree.swift:353–359` shared messaging timeout setup; `TargetResolver.swift:522–529,620–660` resolution callers; `AXTree.swift:750–824,881–1030` batch/scalar/children/actions/bounds observation. The batch cache permits scalar fallback only on top-level `attributeUnsupported`; existing optional children/actions exceptions must remain unchanged.
- Existing transport carries details (`NativeService.swift:410–422`; `src/backend/macos.ts:562–597`). Preserve its supplied-value redaction rather than bypassing it.
- Historical reports: [TODO](../../todo/2026-10-19-live-cli-keyboard-and-drawing.md), [live report](../../verification/2026-10-19-excalidraw-cli-live-test.md). E1/E3 baseline HEAD is `be27f65ee25a0da4a63c9c3279e4261f13ebdbb7`; shipped hashes are recorded in E1. Whole-binary/source correspondence is not established. Do not substitute the differing cached native host for an identified fresh build. Raw private screenshots/logs stay local.

## Proposed solution

### 1. Pace the actual synchronous drag

Keep the synchronous API, left button and straight-line 20-sample algorithm. Introduce a narrow internal drag-only construction/post/synchronous-wait seam; production defaults use CoreGraphics and the existing HID tap. Tests invoke the algorithm actually used by `LiveInputDriver.drag`, with recorded construction/post calls and injected monotonic time; no real posts or wall-clock sleeps. Do not replace it with a fake sequence or build a general input framework.

Use **15 ms minimum gaps** between all consecutive normal posts: down → first sample, each sample pair, and final sample → up. There are 21 gaps: **315 ms nominal down-to-up duration**, excluding overhead/scheduling. Set sample 20 directly to the exact endpoint. Zero-length drags keep the same sequence/dwell at that point.

Measure gaps from the previous actual post using the context's monotonic clock. Synchronous waits use slices ≤5 ms, capped by remaining gap and remaining command budget. Check context before/after each slice and immediately before every normal post, including down/up. Recompute time after early-returning waits; never shorten gaps or burst to catch up after scheduling delay. Do not extend the deadline or compress pacing to fit. Scheduling may overshoot requested waits; no hard wall-clock completion guarantee is claimed.

### 2. Construction failure and release semantics

- Check context before preparation and immediately before down. Prepare down plus a reusable emergency up **before down is posted**. Failure to construct either throws `NATIVE_FAILURE` with no posts.
- Track last successfully posted position, initially start after down. Movement construction failure throws immediately; never silently skip a sample.
- Success uses the prepared up at the exact endpoint after final dwell/check. Cancellation, deadline, construction or wait failure after down posts that prepared up **exactly once, immediately at the last posted position**, without waits, context checks or new event allocation. Never jump to an unvisited requested endpoint. After final movement the last position is the endpoint.
- Emergency up is the sole intentional post-cancellation/expiry exception: release already-held input, not continued drawing. Preserve the primary `INTERRUPTED`, `TIMEOUT` or construction/wait error. Never convert cleanup into success. No up before down; no duplicate after normal release.
- CoreGraphics posting acknowledges dispatch, not receiver delivery. Do not invent a posting-error/receiver guarantee. This changes silent sample skipping and endpoint-jumping cleanup, not unrelated cleanup/public APIs.

### 3. Bounded timing candidate, not live experimentation now

The single candidate is 15 ms × 21 gaps (315 ms nominal), within E1's roughly 250–350 ms candidate window. It is not an established receiver threshold. Only deterministic offline pacing verification is permitted now; no live matrix, timing sweep, public duration option, adaptive sampling or automatic tuning. Future live evidence requires new authority. If a later authorized live attempt fails, stop batching and obtain bounded receiver-side event/timing evidence before another timing value or unrelated repair.

### 4. Privacy-safe AX diagnostic preservation

Add optional structured `error.details.ax` at the native failure owner, using the existing error envelope. It is one flat object, at most **7 scalar fields** (only those defined below), no arrays/nested payloads. Fixed enum/allowlisted strings are ≤64 ASCII characters each:

| Field | Meaning / bounds |
| --- | --- |
| `phase` | `resolution`, `preparation`, or `observation`, assigned by the transaction owner |
| `operation` | One of `setMessagingTimeout`, `copyAttribute`, `setAttribute`, `copyMultipleAttributes`, `copyActionNames` |
| `attribute` | Optional exact compile-time allowlisted AX attribute name already used by these paths; omit for batch-level/timeouts/actions or unknown names; never echo an arbitrary supplied name |
| `statusCode` | Actual numeric AXError raw value, including 0 for malformed nominal success; omit when no AX status exists |
| `statusName` | Static AXError case name corresponding to that value, `unknown` for unmapped codes; never native free-form text; omit with absent status |
| `statusScope` | `direct`, `batchTopLevel`, or `batchEntry`; identifies whether a returned attribute status came from a multiple-read entry rather than the batch call |
| `reason` | One of `statusFailure`, `missingValue`, `unexpectedType`, `invalidArrayElement`, `batchLengthMismatch`, `invalidBoundsRepresentation`, `decodeFailure` |

Populate phase/operation/reason for diagnosed AX-result failures; no additional payload fields are allowed. Do not fabricate an AX status for context failures or injected non-AX errors. Malformed success must be distinguishable from hard AX failure; report status 0 plus its actual validation reason rather than inventing an AX error. Preserve the first concrete failing context, not an outer generic replacement. No history/list of failures, stack traces, counts, coordinates, PID, window identifiers or object descriptions are needed.

**Owning boundaries:** preparation attaches context to timeout setup, strict manual-state reads and actual manual/enhanced writes; resolution identifies its timeout/setup failures through the shared helper without mislabelling them observation. Observation owns batch top-level shape/status, per-entry/scalar decoding, children, actions and bounds validation. Small internal helper parameters/typed metadata may carry these static labels; do not refactor the AX tree or expose a new public framework. A batch top-level error is not falsely attributed to whichever scalar attribute happened to request the cache. Per-entry failure retains the entry's actual status and allowlisted attribute. Existing `NativeFailure`/service/TS projection carries details; no parallel logging channel or bypass of privacy projection.

**Privacy:** construct diagnostics from static labels, allowlisted attribute names and actual numeric status only, never from AX values/objects, titles, URLs, AX identifiers, supplied text, arbitrary exception/native descriptions, or whole trees. A label such as `AXTitle` may identify the requested attribute; its value must never appear. Unknown names are omitted, not truncated/hashed. Test raw native serialization and backend projection with synthetic sentinel content; projection is defense in depth, not the source of privacy safety.

**Fail-closed behavior stays identical:** preserve error codes/messages and `apiDisabled` → `PERMISSION_DENIED`; cancellation/deadline precedence, capability-negotiation statuses and existing unavailable/degradation rules; only top-level batch `attributeUnsupported` enables scalar fallback. Do not suppress hard errors, reinterpret malformed success as an empty successful tree, broaden retries/unsupported handling, observe/publish after hard preparation failure, or alter identity validation, lock release or snapshot publication. Diagnostics explain failure, not browser readiness.

### 5. Keyboard and underlying Chrome AX readiness remain open

No keyboard delivery product change is supported by E3. Preserve routes, mappings, key flags/modifier-release behavior and timing; no new keyboard framework merely to touch all three issues. Existing regressions continue offline. Record keyboard functional delivery and the actual Chrome snapshot failure cause as unresolved, with future authorized live investigation needed. AX diagnostic completion is not functional AX recovery.

## Alternatives considered

- Checks-only tight drag loop / overlay pacing: does not pace actual events, especially cursor-off.
- Broad async conversion or public duration/adaptive sweep: unnecessary scope before receiver evidence.
- Silent sample skips / endpoint-jumping release: incomplete success and unintended post-interruption drawing; use fail-closed last-position release.
- Arbitrary keyboard delays/routes/keycode changes: no proved offline functional cause; retain uncertainty instead.
- Raw AX dumps or free-form errors: privacy risk; bounded operation/status metadata is sufficient.
- Hide hard AX failures or broaden fallback: changes trust semantics and can publish misleading trees; diagnostics only.

## User stories

- As a drawing caller, I need bounded event pacing and safe interruption; actual visible stroke success remains to be verified later.
- As an AX caller, I need a privacy-safe failing stage/operation/status without losing fail-closed behavior.
- As the sleeping user, I need supported offline progress without any desktop interaction or unsupported claims of repair.

## Acceptance criteria

- **AC-1 — Actual sequence/geometry:** Tests of the production drag algorithm observe exactly one left down at start, 20 ordered straight-line dragged samples, one up at exact endpoint. Cover forward/reverse horizontal, vertical, diagonal and zero-length cases; sample 20 exactly equals endpoint.
- **AC-2 — Pacing:** Deterministic clock proves every adjacent normal post has ≥15 ms spacing including initial/final dwell; no-overhead duration is 315 ms. Each requested wait is positive, ≤5 ms and ≤remaining gap/budget. Cover early-returning waits/late clock advances; no catch-up burst or real sleeps.
- **AC-3 — Cancellation/deadline:** Initially cancelled/expired contexts have no posts/waits. Interruption during initial dwell, middle movement and final dwell yields existing `INTERRUPTED`/`TIMEOUT`, no subsequent normal posts and exactly one last-position emergency up after down. Include budget shorter than a slice and interruption immediately before normal posting.
- **AC-4 — Failure/release:** Inject down/emergency-up construction failures before down, movement construction failure after down and wait failure. Verify no posts on preparation failure; otherwise one immediate last-position release, primary error preserved, no skipped samples/false success or duplicate up. Cleanup must not wait, allocate another event or require a valid context.
- **AC-5 — Compatibility/safety:** Offline route tests prove cursor-on/off reach equivalent actual input geometry/order/relative cadence, excluding pre-input visualization delay. Fake overlay/input seams must never invoke live UI. Preserve capture/identity validation, foreground preparation semantics, lock, overlay cleanup, failure envelopes and truthful `verification:"dispatched"`. No public command/options or unrelated click/scroll/key behavior changes.
- **AC-6 — Offline candidate checks:** Focused drag and AX regressions pass, followed by native tests, TS typecheck, JS tests, mocked/non-live native protocol checks, build hygiene, fresh build and post-build non-live checks. Record commands, results, source/build identity and dirty changes; no cached-host substitution. Inspect commands for live side effects before running; omit/mark prohibited live-dependent checks rather than invoking them.
- **AC-7 — Verification disposition:** Completion report explicitly labels live verification **DEFERRED / PROHIBITED under G1** and separates automated implementation completion from real-world repair. No real-app/AX queries, GUI, input posts, screenshots or browser interaction may be run as acceptance. Live verification is not required to complete the approved offline scope. Drag receiver success, keyboard delivery and underlying Chrome AX readiness remain unverified/open.
- **AC-8 — Diagnostic accuracy:** Synthetic failures cover resolution/preparation timeout setup, strict preparation read/write, observation batch top-level and per-entry errors, scalar/children/actions/bounds hard failures and malformed success. Assert correct phase/operation/allowlisted attribute, actual status code/name/scope and specific validation reason. Status 0 malformed success differs from hard error; batch failures do not invent an attribute; context errors retain existing code/precedence without fabricated status.
- **AC-9 — AX trust/transactions unchanged:** Existing and focused tests prove permission distinction, exact preparation negotiation, top-level-unsupported-only scalar fallback, malformed-success/hard-error rejection and existing optional unavailable rules. Hard preparation failure causes no observation/publication; lock releases; stale/invalid identity never publishes a snapshot. No new retries, empty-success trees or loosened capability fallback.
- **AC-10 — Privacy/transport:** Native serialization and TS backend projection tests show bounded `details.ax` survives ordinary errors while sensitive supplied-value redaction remains unchanged. Inject sentinel AX titles, values, URLs, identifiers, objects and arbitrary error descriptions; none may appear anywhere in diagnostic output. Unknown attributes are omitted and unknown AX codes use numeric value plus `unknown`, not free-form text. No data-dependent logs added.
- **AC-11 — Supported-scope reporting:** Preserve keyboard behavior; document E3's absence of a supported delivery fix and unresolved Chrome AX cause. Final offline report identifies drag as a timing candidate, AX work as diagnostic improvement, and the unresolved functional outcomes; it never claims all three functional bugs fixed.

## Constraints

- Dragged samples: 20.
- Normal inter-post minimum: 15,000,000 ns; nominal dwell: 315,000,000 ns.
- Synchronous requested wait maximum: 5,000,000 ns, additionally capped by gap/budget.
- No deadline extension; emergency release is the only post-interruption exception.
- Keep synchronous `NativeInputDriver.drag` and public CLI/wire command schemas unchanged; optional AX details use existing envelope.
- No real/live/GUI/input checks, even smoke checks or purported read-only live AX queries; no browser interaction.
- Spec assignment writes only this file; no product/test edits, tests, builds, setup or commits by the spec owner.
- Execution/setup/local commits only through Assistant's exact recorded G1 gates; no push/merge/publish/install/permission changes/cleanup.
- Preserve unrelated work and private artifacts; no personal screenshot/log copying.

## Failure cases

Short budgets may now time out before stroke completion; fail/release rather than compress pacing. Cancellation after final movement but before normal up still fails and releases at endpoint. Preparation failures never hold a button; later failures never advance to an unvisited point. Release is best-effort dispatch, not receiver receipt. Scheduler overshoot is checked before further normal dispatch. AX diagnostic construction must never stringify a payload or replace the primary error; missing diagnostics are preferable to leaking data or inventing status. Generic historical errors cannot be retroactively localized. Correct offline behavior does not prove the paced stroke or Chrome AX works live.

## Testing decisions and deferred verification

Use `@testable import ComputerUseCore`, the drag-local seam and `CommandContext`/`NativeClock` for AC-1–4; keep existing fake-driver routing tests for AC-5. Reuse `AXPreparationAPI`/`AXSnapshotPreparationTests.swift:89–179`, `LiveAXBatchCache`/`AXTrustTests.swift:269–397`, `SnapshotService`/`SnapshotTransactionTests.swift:137–315` and `tests/backend-macos.test.ts:784–791` for synthetic diagnostics/trust/privacy checks. Pure construction/in-memory fixtures only; no real API queries/posts are authorized. Exact internal helper names and test organization are implementation details.

Repo scripts (`package.json:46–55`): `npm run native-tests`, `npm run typecheck`, `npm test`, `npm run test:native-protocol`, `npm run test:build-hygiene`, `npm run build`. Planning must validate their non-live scope, order candidate-dependent checks against the fresh build and report any prohibited exclusions. No tests/builds were run during spec preparation.

**DEFERRED / PROHIBITED now:** the prior mandatory coordinator live matrix is removed from the execution/completion gate. Preserve its future intent only: after new authority, coordinator personally checks isolated Excalidraw pencil/Kleki brush strokes in both cursor modes, forward/reverse/diagonal, Kleki stabilization 0/1, immediate and settled endpoint/continuity observations, and a shape-tool regression. Rediscover targets and inspect individual strokes before batches. Keyboard focus/postcondition and AX stage/status checks also require separately authorized live work. Do not perform any of these now or infer future consent from G1.

## Out of scope

Speculative keyboard delivery repairs/frameworks; underlying Chrome AX recovery without evidence; capture-origin/multi-display fixes; artwork completion; browser/DOM injection; duration flags/adaptive interpolation; broad input/AX refactors; overlay redesign; live verification; publishing/merge/push; install/permission/cleanup changes. All three issues are tracked, but unsupported functional causes are deliberately not patched.

## Open questions

No blocking product decisions or offline factual dependencies remain for this bounded revision. Drag receiver causality/timing sufficiency, keyboard functional cause and Chrome AX readiness remain unresolved experimental questions, not unattended decision prompts. They do not block offline implementation/check completion; they block claiming real-world functional repair and require newly authorized evidence gathering.
