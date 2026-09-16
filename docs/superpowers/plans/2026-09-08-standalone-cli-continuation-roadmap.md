# Standalone CLI — Staged Continuation Roadmap

> This is a **gated roadmap**, not an executable substitute for the detailed recovery plans. Generate and approve the named subsystem plan only when its entry evidence exists. Do not hand an entire stage below to one implementation agent.

**Goal:** Complete the original v1 specification without repeating oversized Tasks 4–12 or inventing unverified interfaces early.

**Requirements authority:** `../specs/2026-09-08-standalone-cli-design.md` plus the approved foundation recovery amendment `../specs/2026-09-08-foundation-recovery-design.md`.

**Entry:** The nine-task repair gate in `2026-09-08-foundation-recovery.md` passes, the required `2026-09-08-foundation-lifecycle-design-gate.md` has been converted into a detailed plan and implemented, and the combined foundation has independent approval. The nine-task gate alone is **not** foundation readiness; combined foundation readiness is still not release readiness.

## Rules for every stage

- Freeze consumed/produced interfaces and shared success/failure fixtures before implementing the owning behavior.
- One reviewable task per independent invariant or end-to-end behavior; split setup into its owning task rather than a scaffolding project.
- Each task contains literal test code/local helpers, a RED command, exact implementation changes, GREEN commands, a review gate, and task-scoped commit instructions under existing authorization.
- No unimplemented function/type references, placeholder result values, silent skipped tests, environment bypasses, native discovery of personal apps, or automatic mutation retries.
- Preserve public floors and budgets: Node 22+, Swift 5.9/v5, macOS 14+, 15,000 ms default, 1–120,000 ms integer timeout, 2-second cleanup grace, 10-minute state, 0700/0600 modes.
- No background/daemon/private API work. Live input and original-source deletion each require separate explicit authorization.

## Stage D — Discovery and useful diagnostics

**Original coverage:** Tasks 2, 3, 9 and setup portions of 10.

**Entry:** Selected-PID resolver providers, precise launch identity, shared context, strict request/reply/error contracts, and fresh-host testing are approved.

**Owning files:** `native/Sources/ComputerUseCore/{TargetResolver,NativeService,Protocol}.swift`, `src/cli/{output,run}.ts`, `src/backend/macos.ts`, `contracts/fixtures/`, `docs/cli.md`.

**Plan slices:** (1) apps listing without requiring AX/launch identity; (2) windows listing preserving unmatched/ineligible candidates and reasons; (3) non-prompting doctor checks with truthful ready/first-failing-category exit; (4) human discovery output with terminal-control escaping and actual command help.

**Contract decisions:** Every listed window has ID/title/bounds/eligible/reason; listing does not select a target. Name ambiguity returns sanitized candidates. Doctor returning unknown permission attribution cannot be reported as ready. Test provider inventory, not running personal apps.

**Exit evidence:** Pure provider tests and complete paired response fixtures for all three commands; stdout/exit tests including ANSI/carriage returns; fresh protocol integration remains non-live. A real doctor read is a separately disclosed read-only acceptance step, not an implicit unit test.

## Stage E — Window capture, geometry, and unified record kinds

**Original coverage:** Task 5 and capture state from Task 4.

**Entry:** Foundation identity/evidence/private storage and cancellation scope are approved. Verify installed SDK's ScreenCaptureKit macOS-14 API signatures before writing the plan.

**Owning files:** create `native/Sources/ComputerUseCore/{Geometry,CaptureService}.swift`, `native/Tests/ComputerUseCoreTests/GeometryTests.swift`; modify `StateStore.swift`, `NativeService.swift`, command-specific TS validators and shared fixtures.

**Plan slices:** (1) pure pixel→window/screen transform and boundaries; (2) extend the **one** StateStore to snapshot/capture kinds and app-wide invalidation of both, removing replaced snapshot-only entry points; (3) window-only capture adapter with no desktop fallback; (4) verified resize/content rectangle and negative-display-origin transforms; (5) atomic no-overwrite output publication and abandoned-temp recovery; (6) annotation/tree consistency and transactional paired metadata publication.

**Contract decisions:** Actual post-resize image dimensions and affine transform; no shadows/padding without verified content rect; unsupported mixed-display transform fails closed; explicit absolute output path; overwrite opt-in; strict capture UUID/target/geometry/timestamps; paired record failure cleanup. Do not estimate scale from whole-desktop dimensions.

**Exit evidence:** Pure known geometry fixtures (Retina, non-Retina, resize, asymmetric transforms, moved/resized windows, x==width), output/symlink/race tests, paired-record failure tests, complete paired response fixtures. No real capture claimed until authorized live acceptance.

## Stage F — Foreground semantic execution and held-input cleanup

**Original coverage:** Task 6.

**Entry:** Snapshot/capture store invalidation is unified; context-aware transaction phases, error mutation status, and target refresh APIs are approved.

**Owning files:** create `ForegroundExecutor.swift`, `NativeInput.swift`, `ForegroundExecutorTests.swift`; modify `NativeService.swift`, shared fixtures and TS controlled-semantic sets when new real values are established.

**Plan slices:** (1) injected FocusObserver and selected-window ownership preflight; (2) foreground activation/polling and fresh post-activation evidence; (3) AXPress with zero coordinate fallback; (4) AXValue support/set/readback with uncertainty on unavailable verification; (5) scroll-to-ref and hit-tested window directional scroll; (6) allowlisted key/modifier parser and held-key cleanup; (7) bounded Unicode event groups; (8) explicitly opted-in clipboard replacement with `clipboardReplaced:true` and no false clipboard-restoration claim.

**Contract decisions:** Exact real method/verification/visualization values enter shared fixtures and privacy controlled sets together. Every error path states `notStarted` or `potentiallyApplied` internally; input never appears in errors. Invalidate before activation because it can change UI; refresh while retaining only this action's evidence. Unsupported overlay-enabled execution fails before mutation until Stage H supplies it.

**Exit evidence:** Pure driver/event sequence tests for no fallback, focus mismatch zero events, ignored set/readback failure, unknown keys, Unicode boundaries, no silent paste retry, cancellation releases only held inputs, and no dispatch after context expiry. No live keys/typing/activation.

## Stage G — Capture-bound raw mouse routes

**Original coverage:** Task 7.

**Entry:** Stage E transforms and Stage F ownership/cleanup work are approved.

**Owning files:** `NativeInput.swift`, `ForegroundExecutor.swift`, `Geometry.swift`, native executor/geometry tests and command fixtures.

**Plan slices:** (1) click button/count validation (left 1/2/3, right 1, middle 1); (2) hit-test selected-window ownership excluding owned overlay; (3) move without record invalidation; (4) bounded straight interpolation drag with route checks and down/up cleanup; (5) cancellation between event groups and shared timeline seam.

**Exit evidence:** Pure event traces for all supported combinations and rejections; occlusion and stale geometry zero-input tests; drag interruption cleanup; no record revival. Pointer movement remains real foreground behavior even with cursor off.

## Stage H — Cursor visualization and full native lifecycle

**Original coverage:** Task 8 and visual portions of 9.

**Entry:** Async worker/main ownership, shared context, input ownership/cleanup, and one event timeline seam are proven.

**Owning files:** create `CursorOverlay.swift`, `ActionTimeline.swift`, `CursorLifecycleTests.swift`; modify `HostMain.swift`, `HostSupport.swift`, `ForegroundExecutor.swift`.

**Plan slices:** (1) injectable renderer/timeline order tests; (2) original transparent nonactivating click-through panel on main actor; (3) bounded approach ≤150 ms and pulse 100 ms under the same command budget; (4) preparation failure before invalidation/input; (5) post-animation ownership recheck; (6) hide-before-capture; (7) SIGTERM/interrupt/parent-loss cleanup with worker completion and held-input release.

**Exit evidence:** Fake-renderer/driver order and resource cleanup tests; independent compile/availability checks. Real click-through, actual visibility, foreground behavior, and capture exclusion remain live acceptance requirements, not mocked passes.

## Stage I — Full coordinator, content limits, and public output

**Original coverage:** Task 9.

**Entry:** Every behavior-producing subsystem has its exact result fixtures. No generic unsupported branch remains for a supported command combination.

**Owning files:** `NativeService.swift`, `HostMain.swift`, `src/cli/{run,output,parse}.ts`, TS/native validators, all shared fixtures.

**Plan slices:** (1) one lock owner and complete command dispatch table; (2) text file/stdin byte cap 1 MiB and end-to-end cancellation; (3) request-line cap 2 MiB and response cap 16 MiB in both processes, rejecting oversize before unsafe parsing/dispatch; (4) absolute screenshot path and no request-text/argv diagnostics; (5) command-specific human formatting/control escaping and JSON purity; (6) partial execution/timeout/status acceptance matrix.

**Exit evidence:** Every command has complete success/error fixtures through CLI→backend→native seams, negative preflight/status tests, and bounded-input/output tests. Existing trusted-only diagnostic/privacy limits are documented honestly; no semantic security reviewer is implied.

## Stage J — Package and source-install documentation

**Original coverage:** Task 10.

**Entry:** Fresh build outputs contain no old agent artifacts; all final command contracts and default test layers pass.

**Owning files:** `scripts/package-smoke.mjs`, `tests/package.test.ts`, `package.json`, `README.md`, `docs/{cli,permissions}.md`, `Makefile`.

**Plan slices:** (1) manifest/shebang/native execute-mode assertions; (2) local prepack build and tarball contents; (3) isolated prefix install with scripts disabled and installed help/version/explicitly read-only doctor; (4) permission attribution/source-build docs and exact error recovery.

**Exit evidence:** Installed helper discovery works without a global/home helper; no node_modules/state/legacy tool in tarball; docs state host architecture only, unsigned/source-built identity limits, foreground pointer warning, cursor off semantics, protected-text input advice and private evidence retention. Do not publish.

## Stage K — Authorized fixture acceptance

**Original coverage:** Task 11.

**Entry:** Automated gates pass and user explicitly authorizes live foreground input in a disposable fixture session with needed permissions.

**Owning files:** fixture executable, `scripts/live-fixture.mjs`, `docs/testing.md`, `docs/verification/`.

**Plan slices:** dedicated in-memory two-window fixture; opt-in/refusal runner (`NUVIN_CU_LIVE=1` is necessary but not by itself human authorization); per-command acceptance matrix; owned-parent kill/drag interruption; capture/overlay checks; available display geometry checks; sanitized acceptance report.

**Exit evidence:** Report passed/failed/unavailable separately. Use only exact fixture PID/start identity/window IDs. No personal app discovery, clipboard/user-file access by fixture, unrelated process kills, or unverified combinations labeled passing. Re-run default mocked/pure/native integration afterward.

## Stage L — Authorized retirement and release-readiness review

**Original coverage:** Task 12.

**Entry:** New behavior/test counterparts and live acceptance report exist. Produce exact old-source/test replacement inventory; ask for explicit deletion permission.

**Owning files:** original `src/tools/`, `src/ports.ts`, obsolete tests and build/docs only after authorization. Historical plans/integration references remain archival.

**Exit evidence:** No old runtime imports, home helper lookup, base64 tool envelope, unchecked AppleScript, semantic-coordinate fallback or full-desktop recovery remains. Run in order: typecheck → mocked TS tests → pure Swift tests → fresh native protocol integration → build → package smoke. Final whole-branch review must distinguish automated evidence from live evidence. No merge/push/publish/signed distribution/background-control work without instruction.
