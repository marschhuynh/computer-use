# Standalone Computer Use CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a standalone macOS `nuvin-computer-use` CLI with explicit AX and raw mouse commands, reliable observed-state checks, JSON/text output, and a visible per-command virtual cursor.

**Architecture:** TypeScript owns the shell interface and subprocess lifecycle. A versioned Swift/AppKit executable owns the desktop-operation lock, private snapshot/capture state, native targeting and input, and cursor visualization. Validate and execute each action inside one native invocation; no daemon, agent tool, model integration, or private macOS APIs.

**Tech Stack:** Node.js 22+, TypeScript, Node built-ins, existing Vitest 3, Swift 5.9+ package in Swift 5 language mode, AppKit, ApplicationServices, CoreGraphics, ScreenCaptureKit, XCTest. macOS 14+ deployment target.

## Global Constraints

- Approved specification: `../specs/2026-09-08-standalone-cli-design.md`.
- Foreground automation first, macOS only.
- TypeScript CLI plus a Swift native helper; reuse the existing backend where correct.
- Include both accessibility-reference actions and raw mouse actions in v1.
- Display a virtual cursor as feedback; do not promise input isolation.
- No persistent daemon in v1. A native host lives for the duration of an individual command.
- Node.js 22 or newer; macOS 14 or newer; Swift 5.9 or newer.
- Default deadline: 15 seconds, including input loading, lock acquisition and animation. Accepted integer timeout range: 1–120,000 ms inclusive. Cleanup grace: 2 seconds.
- Snapshot/capture records expire after 10 minutes.
- State root: `~/Library/Application Support/nuvin-computer-use/`; directories 0700, files 0600.
- No implicit last target, no silent fullscreen capture, no semantic-to-coordinate fallback, no automatic mutation retries.
- No arbitrary model/script execution, MCP, Guardian, background control, or private SkyLight APIs.
- No source changes, installations, native input, or commits during this planning session.
- During execution, do not delete original source files without the user's explicit authorization. Task 12 has a deletion approval gate.
- Do not commit automatically. Each task ends at a reviewable boundary; commit only when separately authorized.

## Baseline and ground truth

Repository: `/Users/marsch/Projects/nuvin-computer-use`.

Verified 2026-09-08:

- `npm test`: 2 suites, **113 tests passed** (54 backend, 59 tool); all mocked.
- `npm run typecheck`: passed.
- Node `v22.23.2`, Swift `6.3.3`, host arm64 macOS 26.
- Git `main` has no commits; all restored files are untracked. Do not assume a clean tracked baseline or use `git clean`.

Current ownership/defects relevant to this plan:

| Source | Evidence | Plan response |
| --- | --- | --- |
| `src/tools/ComputerUseTool.ts:169-176` | Tool name and implicit last snapshot/app are instance state | Replace with explicit CLI commands and persisted record IDs |
| `src/tools/computer/ax-helper/main.swift:535-555` | Metadata stores only snapshot ID/PID/app/hint mode | Store full observed identity/options/evidence |
| `src/tools/computer/ax-helper/main.swift:588-608`, `:687-696` | Re-traversal assigns current numeric refs; custom traversal limits lost | Compare recorded tree evidence before selecting any live ref |
| `src/tools/computer/ax-helper/main.swift:781-813` | set-value falls back to focus and reports a success-shaped result | Distinguish unsupported/failed setting from successful value change |
| `src/tools/computer/macos-backend.ts:229-301`, `:595-597` | Capture/intermediate files retained under old home path | Explicit output only; private temporary lifecycle |
| `src/tools/ComputerUseTool.ts:334-358` | Window-to-image scaling estimated using desktop dimensions | Window-specific pixel transform |
| `src/tools/computer/macos-backend.ts:370-398`, `:456-460` | Unchecked AppleScript interpolation and fixed activation sleep | Native input; observed focus polling under deadline |
| `src/tools/computer/ax-helper/main.swift:1043-1100` | Traverses multiple windows and may capture full desktop | One uniquely resolved window, no fullscreen fallback |
| `Makefile:3-7` | Build copies executable into user home | Project-local Swift build and package-relative lookup |

Historical plan comments are not authoritative behavior. Preserve useful AX traversal/filtering and badge-rendering algorithms, not old implicit targeting or result envelopes.

## File structure and ownership

```text
src/
  cli.ts                       executable entry point only
  cli/parse.ts                 command-specific flags → Request
  cli/output.ts                JSON/text and exit-code mapping
  cli/run.ts                   stdin text loading and backend orchestration
  core/protocol.ts             versioned TS request/result types
  core/validate.ts             protocol shape validators
  backend/macos.ts             helper discovery, deadlines, IPC, cancellation
native/
  Package.swift
  Sources/ComputerUseCore/
    Protocol.swift             Codable wire types and errors
    TargetResolver.swift       app/process/window eligibility and identity
    AXTree.swift                one-window AX tree + live ref map
    StateStore.swift           private versioned records and expiry
    DesktopLock.swift          per-user advisory lock
    SnapshotService.swift      read/validate recorded AX evidence
    CaptureService.swift       one-window capture + metadata
    Geometry.swift             point/pixel transforms + bounds
    ForegroundExecutor.swift   action preflight, focus, dispatch, verification
    NativeInput.swift          Unicode, keys, mouse, scroll, held-input cleanup
    CursorOverlay.swift        AppKit panel and original cursor drawing
    ActionTimeline.swift       bounded animation/event ordering
    NativeService.swift        typed command dispatcher; owns lock/state scope
  Sources/ComputerUseHost/
    HostMain.swift             AppKit event loop and stdin/parent lifecycle
  Sources/ComputerUseFixture/
    FixtureMain.swift          opt-in isolated test application
  Tests/ComputerUseCoreTests/
    ProtocolTests.swift
    TargetResolverTests.swift
    SnapshotTests.swift
    StateStoreTests.swift
    GeometryTests.swift
    ForegroundExecutorTests.swift
    CursorLifecycleTests.swift
scripts/
  build-native.mjs             compile and stage project-local helper
  native-tests.mjs             macOS guard for Swift unit tests
  package-smoke.mjs            isolated local tarball install
  live-fixture.mjs             explicit opt-in native acceptance runner
contracts/
  fixtures/                   paired TS/Swift valid/invalid request fixtures
  errors.json                 shared stable error-code/exit mapping
fixtures/
  native/                     pure app/window/tree/geometry JSON samples
  cli/                        harmless mock-native script fixtures
 tests/
  cli-parse.test.ts
  cli-output.test.ts
  cli-run.test.ts
  native-protocol.test.ts
  backend-macos.test.ts
  package.test.ts
```

No two processes independently own record validation: Node sends one request and keeps the request channel alive; Swift locks, reads records, resolves, validates, acts, invalidates, responds, and releases. TypeScript never edits state files.

## Fixed interface ledger

Define these in Task 1; subsequent tasks must use these exact names and semantics.

```ts
export const DEFAULT_TIMEOUT_MS = 15_000;
export const MAX_TIMEOUT_MS = 120_000;
export type Target =
  | { app: string; windowId?: number; pid?: never }
  | { pid: number; windowId?: number; app?: never };
export type Point = { x: number; y: number };
export type Options = { timeoutMs: number; cursor: 'on' | 'off' };
export type TreeOptions = {
  maxDepth: number; maxElements: number;
  hintMode: 'full' | 'leafOnly' | 'leafCompact';
};
export type Direction = 'up' | 'down' | 'left' | 'right';
export type Command =
  | { command: 'doctor' | 'apps' }
  | { command: 'windows'; target: Target }
  | { command: 'snapshot'; target: Target; tree: TreeOptions }
  | { command: 'press'; snapshotId: string; ref: number }
  | { command: 'set-value'; snapshotId: string; ref: number; text: string }
  | { command: 'type'; target: Target; text: string; allowClipboardReplace: boolean }
  | { command: 'key'; target: Target; key: string }
  | { command: 'scroll'; snapshotId: string; ref: number }
  | { command: 'scroll'; target: Target; direction: Direction; amount: number }
  | { command: 'screenshot'; target: Target; output: string;
      overwrite: boolean; annotated: boolean; tree: TreeOptions }
  | { command: 'click'; captureId: string; point: Point;
      button: 'left' | 'right' | 'middle'; count: 1 | 2 | 3 }
  | { command: 'move'; captureId: string; point: Point }
  | { command: 'drag'; captureId: string; from: Point; to: Point };
export type Request = { schemaVersion: 1; options: Options } & Command;
export type JsonValue = null | boolean | number | string | JsonValue[] |
  { [key: string]: JsonValue };
export type Reply =
  | { schemaVersion: 1; ok: true; command: Command['command'];
      data: Record<string, JsonValue> }
  | { schemaVersion: 1; ok: false; command?: Command['command'];
      error: { code: string; message: string; details?: Record<string, JsonValue> } };
export interface Backend {
  execute(request: Request, signal: AbortSignal): Promise<Reply>;
}
```

`data` must still be runtime-validated per command using contract fixtures, not blindly accepted as arbitrary JSON. Swift uses `WireRequest`, `WireReply`, and typed command payloads encoding these same keys. Share fixture files, not generated bindings or a new schema-generator framework.

Response fields:

| Command | Required `data` fields |
| --- | --- |
| doctor | `ready`, `checks` array of `{name,status,message}`; checks use `ok/missing/denied/unknown`; exit nonzero according to the first failing prerequisite category |
| apps | `apps` array of `{name,pid,bundleId}`; nullable bundle ID |
| windows | `windows` array of `{id,title,bounds,eligible,reason}` |
| snapshot | `snapshotId,target,tree,truncated,createdAt,expiresAt` |
| screenshot | `captureId,target,path,width,height,createdAt,expiresAt`; annotated adds `snapshotId,tree,truncated` |
| mutations/move | `target,method,verification,visualization`; no input text echoed |

Error codes/exit map: `NATIVE_FAILURE`, `PROTOCOL_ERROR`, `UNSUPPORTED_ACTION`, `EXECUTION_UNCERTAIN` → 1; `INVALID_ARGUMENT` → 2; `UNSUPPORTED_PLATFORM`, `MISSING_HELPER`, `HELPER_VERSION_MISMATCH`, `MISSING_DEPENDENCY` → 3; `PERMISSION_DENIED` → 4; `TARGET_NOT_FOUND`, `AMBIGUOUS_TARGET`, `INELIGIBLE_TARGET`, `STALE_SNAPSHOT`, `STALE_CAPTURE` → 5; `TIMEOUT`, `BUSY` → 6; `INTERRUPTED` → 130.

Native private test seams:

- `Clock.now: Date`, `Clock.sleep(until: Date) async throws` for expiry/deadline tests.
- `TargetResolver.resolve(TargetSelector) throws -> ResolvedTarget` and `validate(TargetIdentity) throws -> ResolvedTarget`.
- `AXTree.read(ResolvedTarget, TreeOptions) throws -> ObservedTree`: includes serialized evidence and a private live `[Int: AXUIElement]` map. Only serialized evidence leaves the invocation.
- `StateStore.load(id:kind:now:)`, `save(record:)`, `invalidateApp(identity:)`, `sweep(now:)`; record kinds `snapshot/capture`.
- `DesktopLock.withLock(deadline:operation:) async throws -> T` acquires/releases around a closure.
- `NativeService.execute(WireRequest) async -> WireReply` is the only command dispatcher.

No downstream task may change these names/signatures without updating the ledger, producer, consumer, and contract tests together.

## Task 1: Runnable CLI contract and package-local build

**Files:** create `src/cli.ts`, `src/cli/{parse,output,run}.ts`, `src/core/{protocol,validate}.ts`, `contracts/errors.json`, `contracts/fixtures/`, `tests/cli-{parse,output,run}.test.ts`, `tsconfig.build.json`; modify `package.json`, `tsconfig.json`, `.gitignore`.

**Consumes:** existing Node/TypeScript/Vitest configuration.
**Produces:** ledger types; `parse(argv: string[]): ParsedInvocation`; `run(argv: string[], deps: RunDependencies): Promise<number>`; `formatReply(reply: Reply, json: boolean): string`; `exitCode(reply: Reply): number`.

Use explicit parsed text-source types; never fabricate a Request.text value before reading input:

```ts
type TextSource = {kind:'literal';value:string} | {kind:'file';path:string};
type TextCommand = Extract<Command,{command:'type' | 'set-value'}>;
type DraftTextCommand<T = TextCommand> = T extends TextCommand
  ? Omit<T,'text'> & {textSource:TextSource} : never;
type DraftRequest = {schemaVersion:1;options:Options} &
  (Exclude<Command,TextCommand> | DraftTextCommand);
export type ParsedInvocation =
  | {kind:'help';command?:Command['command'];json:boolean}
  | {kind:'version';json:boolean}
  | {kind:'command';request:DraftRequest;json:boolean};
export type RunDependencies = {
  backend:Backend; signal:AbortSignal;
  readText(path:string,signal:AbortSignal):Promise<string>;
  writeStdout(text:string):void; writeStderr(text:string):void;
};
```

`run` resolves literal/file/stdin text into Request before calling Backend.execute. File and stdin reads honor the same deadline and signal as backend work; file-read/parse failures produce structured errors. Keep the request deadline end-to-end by passing only its remaining budget to the backend, not resetting the full timeout after text loading.

- [ ] Write failing tests with injected backend, never an actual desktop:

```ts
it('dispatches explicit snapshot targeting', async () => {
  const requests: Request[] = [];
  const backend: Backend = { execute: async request => {
    requests.push(request);
    return {schemaVersion: 1, ok: true, command: 'snapshot', data: {}};
  }};
  const code = await run(['snapshot','--pid','42','--window','7','--json'], {
    backend, signal: new AbortController().signal,
    readText: async () => '', writeStdout: () => {}, writeStderr: () => {},
  });
  expect(code).toBe(0);
  expect(requests[0]).toMatchObject({command:'snapshot',target:{pid:42,windowId:7}});
});
```

Add parse table tests for all commands, unknown flags, mutually exclusive forms, negative/NaN coordinates, missing output, ambiguous text sources, ref/capture IDs, and app+PID conflicts. Shared TS/Swift timeout fixtures accept 1 and 120000 and reject 0, -1, 1.5, 120001, and unsafe integers. Assert `--json` errors contain one JSON object and no ANSI, including unknown commands. Backend protocol tests own native reply validation; CLI fake backends must provide complete success fixtures before end-to-end tests are enabled.

- [ ] Run `npx vitest run tests/cli-parse.test.ts tests/cli-output.test.ts tests/cli-run.test.ts`; expect missing-module/test failures before implementation.
- [ ] Implement with `node:util.parseArgs`, strict per-command allowed flags, no argument-guessing fallback. Export no agent interfaces. Defaults: depth 8, max elements 500, leafCompact, scroll 3, DEFAULT_TIMEOUT_MS, cursor on, left single click. Require positive safe-integer depth/count; timeout must be a safe integer in 1..MAX_TIMEOUT_MS inclusive. Require nonnegative finite pixels and strict UUID record IDs. Use remaining deadline budget rounded down when handing off to native execution; if less than 1 ms remains, return TIMEOUT without spawning.
- [ ] Add build config with `module/moduleResolution: NodeNext`, `rootDir:src`, `outDir:dist`, `noEmit:false`, declarations optional/off. Add `bin: {"nuvin-computer-use":"dist/cli.js"}`, `engines.node: ">=22"`, `os:["darwin"]`, package files limited to dist/native output/docs. Retain `private:true` until publishing is authorized. Add `build:ts: tsc -p tsconfig.build.json`. Entry starts `#!/usr/bin/env node`; its direct invocation handles signals and returns process.exitCode, while importable run has no side effects.
- [ ] Pass the focused tests, `npm run build:ts`, `npm run typecheck`, and existing `npm test`. At this stage help/version are runnable; missing production backend reports a structured setup error, not fake success.

## Task 2: Versioned native host, discovery, and permission diagnostics

**Files:** create `native/Package.swift`, `native/Sources/ComputerUseCore/{Protocol,TargetResolver,NativeService}.swift`, `native/Sources/ComputerUseHost/HostMain.swift`, `native/Tests/ComputerUseCoreTests/{ProtocolTests,TargetResolverTests}.swift`, `scripts/{build-native,native-tests}.mjs`, `tests/native-protocol.test.ts`; modify `package.json`, `Makefile`.

**Consumes:** Request/Reply contract and fixtures from Task 1.
**Produces:** `computer-use-host --protocol-version` and newline-delimited stdin request mode; ledger native dispatcher/resolver; pure Swift testing and project-local helper build.

- [ ] Add shared fixture cases: valid apps/windows/snapshot, unknown action, protocolVersion mismatch, bad numbers, missing target. Swift and TS must reject the same invalid shapes.
- [ ] Write failing pure Swift resolver tests for duplicate app names, PID reuse, zero/multiple eligible windows, duplicate AX-to-CG candidates, minimized/off-Space windows. Example test seam:

```swift
func testDuplicateAppNamesAreNotSelected() throws {
    let resolver = TargetResolver(inventory: .fixture("duplicate-apps"))
    XCTAssertThrowsError(try resolver.resolve(.app("Editor", windowId: nil))) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "AMBIGUOUS_TARGET")
    }
}
```

Implement fixture inventory loading in this task under TargetResolverTests; do not launch AppKit windows from the default unit test suite.

- [ ] Define the Swift package with `// swift-tools-version: 5.9`, `.macOS(.v14)`, core library, host executable, XCTest target, Swift version `.v5`. Build using `swift build --package-path native`; test using `swift test --package-path native`.
- [ ] Extract AX attribute/role helpers from original Swift code without changing old source yet. Resolve explicit `NSRunningApplication` by name/bundle/PID; persist PID plus launch date and bundle ID. If process start identity is unavailable, fail target resolution. Pair CG windows to AX windows using public role/title/bounds metadata, requiring unique matches; never use private `_AXUIElementGetWindow` or first-window guessing. Refuse unsupported ambiguous mappings.
- [ ] Implement doctor with no AX trust prompt (`AXIsProcessTrusted`), no Screen Recording prompt (`CGPreflightScreenCaptureAccess`), helper protocol version and dependency checks. Return `unknown` rather than falsely claiming permission attribution to a different host. Use no activation or capture in doctor.
- [ ] Host reads exactly one request line, keeping stdin open to observe parent loss. Work runs with a live AppKit main run loop; pure `--protocol-version` and protocol validation paths do not require GUI permissions. Unsupported valid commands return `UNSUPPORTED_ACTION` until their implementing task lands. stdout carries one response, stderr sanitized diagnostics only.
- [ ] Build script uses spawn argument arrays, `swift build -c release --package-path native`, `swift build --show-bin-path`, and stages executable into `dist/native/computer-use-host`. Replace Makefile home-install recipe with project-local build; retain usage examples only if accurate.
- [ ] Run Swift tests, TS protocol tests, `npm run build:ts`, and native build. Verify compilation with macOS 14 deployment target using the installed SDK. Record any API availability problems before later tasks depend on them.

## Task 3: Bounded Node-to-native execution and CLI wiring

**Files:** create `src/backend/macos.ts`, `tests/backend-macos.test.ts`, `fixtures/cli/mock-host.mjs`; modify `src/cli.ts`, `src/cli/run.ts`, `package.json`.

**Consumes:** protocol and native host from Tasks 1–2.
**Produces:** `MacOSBackend implements Backend`, helper version preflight, bounded request transport.

- [ ] Add mock-host modes: valid response, invalid JSON, wrong command, incompatible version, nonzero exit, never exits, exits after receiving request, and ignores SIGTERM. Test these with spawned Node fixtures, not native input.

```ts
it('never accepts a success JSON followed by a failing exit', async () => {
  const backend = new MacOSBackend({helper: fixture('success-then-exit-1')});
  const reply = await backend.execute(appsRequest(), new AbortController().signal);
  expect(reply).toMatchObject({ok:false,error:{code:'NATIVE_FAILURE'}});
});
```

Define fixture helpers locally in this test. Production has no environment override allowing arbitrary helper paths; helper injection is constructor-only for tests.

- [ ] Run `npx vitest run tests/backend-macos.test.ts`; confirm red.
- [ ] Resolve production helper using `new URL('../native/computer-use-host', import.meta.url)` from emitted `dist/backend/macos.js`. The package smoke test must prove it from installed output, not source working directory. Build inclusion must list only `src/cli.ts`, `src/cli/**/*.ts`, `src/core/**/*.ts`, and `src/backend/**/*.ts`; do not compile the restored agent tool into published dist.
- [ ] Probe protocol version within the overall command deadline. Spawn without a shell, write JSON plus newline but do not end stdin until work completes/cancels. Set bounded output collection (16 MiB response, 64 KiB stderr); overflow is a protocol failure, never truncated success. Do not log request text.
- [ ] On abort/deadline, request termination, wait up to 2 seconds for native cleanup, then force termination of the owned child only. Wait for its actual exit before returning. If the host did not report whether mutation began, classify mutating requests as potentially applied in error details; do not reuse their records.
- [ ] Route help/version without invoking the backend. Non-macOS native commands return UNSUPPORTED_PLATFORM. Wire apps/windows/doctor to the host and add `build` to run TS then native builds.
- [ ] Pass focused transport tests, all Vitest suites, typecheck, and `npm run build`. Do not run live apps/windows/doctor during automated tests.

## Task 4: Private state records, cross-process lock, and snapshot validation

**Files:** create `native/Sources/ComputerUseCore/{DesktopLock,StateStore,AXTree,SnapshotService}.swift`, `native/Tests/ComputerUseCoreTests/{StateStoreTests,SnapshotTests}.swift`, `fixtures/native/`; modify `NativeService.swift`, `TargetResolver.swift`.

**Consumes:** resolver, request types, pure fixture infrastructure.
**Produces:** ledger lock/store/tree/snapshot interfaces and native `snapshot` implementation.

- [ ] Write red fixtures for reordered controls retaining the same numeric ref, changed labels/actions/geometry, removed targets, PID reuse, expired record, custom traversal depth/limit, and observed truncation boundaries.

```swift
func testReorderedLiveTreeRejectsOldRef() throws {
    let before = try treeFixture("save-cancel")
    let after = try treeFixture("cancel-save")
    XCTAssertThrowsError(try SnapshotService.validateEvidence(before, live: after, ref: 1)) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
    }
}
```

Expose `validateEvidence(_:live:ref:)` as a pure internal method in SnapshotService and define fixture decoding in SnapshotTests.

- [ ] Run `swift test --package-path native --filter SnapshotTests` and `--filter StateStoreTests`; expect failures.
- [ ] Use a per-user advisory `flock(LOCK_EX|LOCK_NB)` held on an open fd for the duration of the command. Kernel releases abandoned locks; do not unlink a locked file or invent PID-file stale-lock recovery. Owner metadata, if displayed, includes process start identity and is informational only. Lock-file setup is allowed for observations, but apps/windows/doctor must not create/sweep snapshot directories. Bound acquisition by Clock/deadline and release via defer.
- [ ] Store `{version,kind,id,createdAt,expiresAt,target,treeOptions,evidence,invalidated}` plus capture-specific geometry later. UUID-only path construction. Open with no-follow checks, private modes, same-user ownership; atomic temp/write/fsync/rename in a private directory. Reject malformed/unsupported versions and expired/invalidated records. Sweep only recognized state-owned filenames while locked, preserving unrelated files.
- [ ] AXTree traverses only the uniquely selected window, returns full comparison evidence independent of compact display formatting, and preserves exact tree options. Move usable traversal/filtering code from original source by copying into core first. Build output refs deterministically but never treat their number as identity. Capture truncation state; fail if evidence around target cannot establish trustworthy correspondence.
- [ ] `SnapshotService.validateEvidence` compares exact observed ordered structure, target process/window identity and geometry, and ref target evidence. Select from the newly read live ref map only after comparison. Do not serialize raw AXUIElement pointers. Refresh checks and the eventual action remain inside the same host/lock.
- [ ] Every state-changing attempt invalidates all records for its app *before dispatching the first possible side effect*, after obtaining current in-memory evidence. This conservatively covers host crashes. Keep in-memory evidence for that one action only. Preflight/validation failures do not invalidate. Plain move does not invalidate. If foreground activation itself can alter relevant app state, re-read evidence after activation and before input; never revive records invalidated by an interrupted prior action.
- [ ] Verify fixture tests and subprocess lock tests: two helpers do not overlap critical sections; kill one mock lock owner and show a second proceeds; no actual desktop calls. Typecheck and full test suite remain green.

## Task 5: Window-scoped capture, geometry, and annotations

**Files:** create `native/Sources/ComputerUseCore/{CaptureService,Geometry}.swift`, `native/Tests/ComputerUseCoreTests/GeometryTests.swift`; modify `StateStore.swift`, `NativeService.swift`; add capture fixtures and protocol tests.

**Consumes:** selected-window identity, state/lock, AXTree.
**Produces:** `CaptureService.capture(target:output:overwrite:annotated:treeOptions:) async throws -> CaptureResult`, `Geometry.imageToScreen(_:capture:) throws -> CGPoint`, screenshot command and CaptureRecord.

- [ ] Write red geometry cases with known transforms:

```swift
func testResizedRetinaWindowUsesWindowBounds() throws {
    let capture = captureFixture(originX: -100, originY: 50,
                                 widthPoints: 800, heightPoints: 600,
                                 widthPixels: 800, heightPixels: 600)
    let point = try Geometry.imageToScreen(CGPoint(x: 400, y: 300), capture: capture)
    XCTAssertEqual(point, CGPoint(x: 300, y: 350))
}
```

Additional cases: x=width rejection, negative/NaN, scale 2 capture resized to 1, asymmetric transforms, moved/resized window rejection, changed process, and no selected-window fallback to desktop.

- [ ] Run focused Swift geometry/state tests; confirm red.
- [ ] Implement window-only ScreenCaptureKit capture using public macOS-14-compatible APIs: `SCShareableContent`, `SCContentFilter(desktopIndependentWindow:)`, `SCScreenshotManager.captureImage`. Confirm actual SDK signatures and availability before use. Avoid screenshots that include window shadows/padding unless their exact content rect is recorded. Prefer disabling shadows; if unavailable on the deployment floor, crop to a verified content rect. Never call full-screen capture as recovery.
- [ ] Store image-to-screen affine scales from actual captured content bounds and final pixel dimensions; include original backing/capture scale for diagnostics. Reuse existing 1568px/1.15MP resize policy but return actual post-resize dimensions. For windows straddling incompatible display scales, reject if one verified transform cannot represent the capture.
- [ ] Annotated capture: read selected AX tree, capture, then re-read target/evidence; accept only consistent observations. Reuse badge drawing with original simple red-number markers. Clip badges to content bounds; transformed origin uses this window, not main display. Commit snapshot/capture records together after successful output publication; clean both if publication fails.
- [ ] Publish via a private sibling temp file and atomic no-overwrite operation (e.g. link-to-final then unlink temp) unless overwrite explicitly requested. Existing files and symlinks must not be clobbered accidentally. Keep content paths out of automatic diagnostics.
- [ ] Pass geometry, output publication, state cleanup and protocol fixture tests. Native live capture remains deferred to authorized Task 11.

## Task 6: Native foreground executor, semantic actions, keys, and Unicode

**Files:** create `native/Sources/ComputerUseCore/{ForegroundExecutor,NativeInput}.swift`, `native/Tests/ComputerUseCoreTests/ForegroundExecutorTests.swift`; modify `NativeService.swift`, `SnapshotService.swift`.

**Consumes:** lock/state, validated targets/live refs, request deadline.
**Produces:** `ForegroundExecutor.perform(request:context:) async throws -> ActionResult`; semantic press/set-value, type/key, both scroll forms; held-input cleanup and mutation-start tracking.

Define `ActionContext` here: resolved target, optional validated live ref, optional validated capture, deadline/cancellation, and callback marking side-effect start (record invalidation). Keep AX objects within Swift.

- [ ] Inject an `InputDriver` and `FocusObserver` into executor. Red tests assert unsupported AXPress never calls coordinate input; focus-only set-value is failure; ignored AXValue fails verification; foreground mismatch sends zero events; key injection strings rejected; unsupported paste sends nothing without opt-in; cancellation releases held inputs.

```swift
func testPressNeverFallsBackToMouse() async throws {
    let harness = ExecutorHarness(actions: [])
    let result = await harness.executePress()
    XCTAssertEqual(result.errorCode, "UNSUPPORTED_ACTION")
    XCTAssertEqual(harness.input.mouseEvents.count, 0)
}
```

Create ExecutorHarness in this test using the injected driver/observer seams; provide actual fake evidence and target identity rather than bypassing validation.

- [ ] Run `swift test --package-path native --filter ForegroundExecutorTests` red.
- [ ] Activate only visible eligible current-Space targets using public APIs, raise the explicit AX window where needed, and poll observed frontmost PID/window until correct or deadline. No fixed 300 ms success assumption. Refuse hidden/minimized/off-Space/ambiguous targets before activation. For state-changing commands, invalidate persisted app records before activation because activation can itself change UI state; keep the current record in memory and revalidate tree/geometry after activation. A stale result after activation remains invalidated. For move, avoid claiming the capture survived an observed geometry/content failure.
- [ ] Implement AXPress and AXValue directly; verify set-value readback where supported. On unavailable verification after possible write, return EXECUTION_UNCERTAIN. Scroll-to-ref requires AXScrollToVisible support; no screen-center fallback. Directional scroll uses selected-window center after hit-testing ownership, not desktop center.
- [ ] Replace text/key AppleScript interpolation with CoreGraphics key events and a fixed modifier/key map. Unicode uses `CGEventKeyboardSetUnicodeString` in bounded chunks. Supply CLI text only through stdin JSON. Unknown keys/modifiers fail before dispatch. Do not silently retry text via paste. Explicit clipboard replacement path uses NSPasteboard and paste key sequence; return `clipboardReplaced:true` without logging content.
- [ ] Track every pressed key/modifier/button. Cleanup releases only inputs pressed by this host and marks uncertainty if release fails. Check cancellation/deadline between event groups. Action results report dispatch/AX readback verification truthfully.
- [ ] Pass focused tests, all Swift tests, full Vitest, typecheck, and build. Production defaults continue to fail unsupported cursor-enabled execution until cursor host Task 8; tests can explicitly request cursor off.

## Task 7: Raw mouse commands with capture-bound coordinates

**Files:** modify `NativeInput.swift`, `ForegroundExecutor.swift`, `NativeService.swift`, `Geometry.swift`, `ForegroundExecutorTests.swift`; extend TS command/response fixtures.

**Consumes:** capture records, geometry, focus checks, invalidation and input cleanup.
**Produces:** click/move/drag execution using the selected capture; no free-desktop mouse target.

- [ ] Add red tests for right/middle click, double/triple left click, negative/bounds errors, stale geometry, occluding target, unsupported multi-click combinations, cancellation between down/up, and drag interruption. Mouse movement must not invalidate capture; click/drag invalidate before first side effect.
- [ ] Run the executor and geometry tests red.
- [ ] Support left 1/2/3, right 1, middle 1; reject other button/count combinations before input. Use public CoreGraphics global foreground events; set click-state consistently. Validate owner hit-test excluding this tool's overlay windows. Recheck selected window immediately before each click group.
- [ ] Drag uses bounded interpolation between validated endpoints; validate route remains within selected visible window before down and check during the sequence. Use the same event timeline later consumed by overlay, not a second animation clock. No invented Bezier route outside target bounds.
- [ ] Implement move with foreground ownership and capture geometry checks but without record invalidation. Explain that move can move the user's pointer even with cursor off.
- [ ] Pass pure dispatch sequence and cancellation tests. No live clicks until Task 11.

## Task 8: Native app lifecycle and virtual-cursor rendering

**Files:** create `native/Sources/ComputerUseCore/{CursorOverlay,ActionTimeline}.swift`, `native/Tests/ComputerUseCoreTests/CursorLifecycleTests.swift`; modify `ComputerUseHost/HostMain.swift`, `ForegroundExecutor.swift`.

**Consumes:** bounded input sequences and action geometry from Tasks 6–7.
**Produces:** `@MainActor CursorOverlay` with `prepare(target:)`, `move(to:)`, `pulse()`, `setDragging(_:)`, `hide()`, `close()`; injectable renderer interface for non-GUI tests. `ActionTimeline` coordinates visual and input steps under a common clock.

- [ ] Write red lifecycle/ordering tests with a fake renderer and driver:

```swift
func testOverlayFailurePreventsInput() async throws {
    let harness = ExecutorHarness(cursorPreparationFails: true)
    let result = await harness.executeClick(cursor: .on)
    XCTAssertFalse(result.ok)
    XCTAssertEqual(harness.input.mouseEvents.count, 0)
    XCTAssertTrue(harness.overlay.closed)
}
```

Also test cursor off bypass, missing AX geometry reports unavailable without mouse fallback, parent lost during drag triggers release/close, capture hides overlay, and no stdout progress output.

- [ ] Run `swift test --package-path native --filter CursorLifecycleTests`; confirm red.
- [ ] Use `NSApplication.shared` with accessory activation policy and a borderless nonactivating NSPanel. Set `isOpaque=false`, clear background, `ignoresMouseEvents=true`; refuse key/main status. Draw an original pointer path plus click pulse, not vendor assets. Keep panel within the active target screen and do not join/switch Spaces to chase windows.
- [ ] Establish the AppKit host on the main thread; run async command processing without blocking the event loop with synchronous sleeps or `waitUntilExit`. Use a task/timer-based ActionTimeline. Add no networking, XPC service registration, or login item.
- [ ] During startup read one bounded stdin line, then observe stdin EOF and parent termination while executing. Cancel the action when Node dies, release held inputs, close panel, exit. Also handle SIGTERM/interrupt and host-side absolute command timeout; reply only after cleanup. Process exit itself destroys its windows.
- [ ] Show AX action feedback at element center when available. If current system pointer is outside target bounds, start the drawn cursor at the target entry/target point rather than animate across unrelated apps. Smooth movement is bounded to at most 150 ms per approach and counts against deadline; click pulse is 100 ms. Use documented per-command origin, no persisted cursor state.
- [ ] Recheck target ownership after animation and immediately before input: visuals must not authorize a stale click. Cursor motion does not imply execution success. Hide before any capture.
- [ ] Pass renderer lifecycle tests and build. Real click-through/focus behavior remains unproven until native fixture acceptance.

## Task 9: End-to-end command coordinator and record lifecycle

**Files:** modify `NativeService.swift`, `HostMain.swift`, `src/cli/run.ts`, `src/cli/output.ts`, all protocol fixtures; extend `tests/cli-run.test.ts`, `tests/backend-macos.test.ts`, `StateStoreTests.swift`, `ForegroundExecutorTests.swift`.

**Consumes:** all commands, state/capture validation, overlay host, transport.
**Produces:** complete v1 command dispatch with no staged unsupported branches for supported combinations.

- [ ] Add acceptance-contract tests for every command with fake backend and full valid data shape. Assert no plaintext typed text in outputs/errors, cursor state correctly reported, and snapshot/capture invalidation on partial execution.
- [ ] Add native orchestration tests verifying order: lock → sweep/load → resolve/validate → overlay prepare → invalidate persisted app records → activation/revalidation → dispatch/verify → overlay/input cleanup → reply → unlock. Carry current record evidence in memory past invalidation. Observation-only paths omit mutation steps and never activate another app. Preflight/overlay failures stop before invalidation/input; failures after activation keep records invalidated. Plain move does not invalidate records merely for pointer movement.
- [ ] Run focused TS/Swift suites red.
- [ ] Complete error mapping and JSON/text formatting. `doctor` can return detailed checks with nonzero exit: format a PERMISSION_DENIED/MISSING_DEPENDENCY reply containing sanitized checks when not ready. Escape terminal control characters in app/window labels and AX text in human output; keep literal content JSON-escaped in JSON mode. Test labels containing ANSI escape and carriage-return sequences. Help describes supported syntax; no hidden env switches that bypass target validation.
- [ ] Resolve screenshot output to an absolute path in TypeScript. Read input files with bounded size (1 MiB text input); reject duplicate input sources before reading. Validate finite bounds and timeout in both TS and Swift; each validator enforces 1..120000 integer milliseconds with matching shared fixtures. Swift's maximum/default mirror MAX_TIMEOUT_MS/DEFAULT_TIMEOUT_MS and are checked by contract tests. Limit request line to 2 MiB and response to 16 MiB on both sides.
- [ ] Ensure cancellation after side-effect start does not accidentally report successful completion. Record invalidation survives forced parent/child death because it precedes event dispatch. Preserve existing user screenshot files on capture/publish errors.
- [ ] Pass all mocked and pure native suites and build. No native automation is claimed yet.

## Task 10: Package isolation and supported setup documentation

**Files:** create `scripts/package-smoke.mjs`, `tests/package.test.ts`, `docs/cli.md`, `docs/permissions.md`; modify `package.json`, `README.md`, `Makefile`, `.gitignore`.

**Consumes:** complete dist/native build and CLI.
**Produces:** locally installable CLI independent of old nuvin-cli paths, documented launch identity and setup.

- [ ] Add failing package test requiring staged helper, executable shebang, no old agent public entry, no node_modules or user-state files in tarball, and no global helper lookup.
- [ ] Run `npx vitest run tests/package.test.ts` red.
- [ ] Define scripts: `build:ts`, `build:native`, `build`, `test:native`, `test:package`, `test:live`. Native script fails clearly on unsupported OS; do not silently label skipped native tests as passed. `prepack` builds artifacts locally; no postinstall Homebrew/swiftc/home-install side effects.
- [ ] package-smoke creates a project-local temporary prefix, runs npm pack then installs that tarball into the prefix with scripts disabled (artifacts already built), and invokes installed help/version plus mock-safe doctor. On macOS doctor is a read-only real permission check; accept documented nonzero setup exits, never prompt. Keep exit/status interpretation explicit.
- [ ] Set output helper executable permissions in build script. Source builds must be for the current host architecture; do not imply universal binaries. README distinguishes source install from future signed prebuilt distribution and lists Node/macOS/Swift floors.
- [ ] Document permission grants for the actual launching terminal/native host with screenshots only if produced during authorized setup. Do not assume permissions granted to a copied binary transfer to the packaged one. Include `--cursor off`, foreground pointer warning, protected-text input advice, private-state retention semantics, and exact error recovery.
- [ ] Run `npm run build`, `npm run test:package`, all tests/typecheck. Inspect packed manifest output; do not publish.

## Task 11: Opt-in native fixture and live acceptance

**Files:** create `native/Sources/ComputerUseFixture/FixtureMain.swift`, `scripts/live-fixture.mjs`, `docs/testing.md`; modify `native/Package.swift`, `package.json`.

**Consumes:** installed CLI, native host and complete action surface.
**Produces:** explicit, bounded live verification isolated to a dedicated application/window.

- [ ] Build an AppKit fixture with two uniquely titled windows; buttons with stable accessibility IDs; editable Unicode field; a scroll area; a drawable drag surface with event counters; a control that inserts/reorders children; and a read-only event log. All controls operate on in-memory test data. Fixture must not access network, clipboard, or user files itself.
- [ ] Make the runner refuse unless `NUVIN_CU_LIVE=1` is set. Print a foreground-input warning and require user authorization before an engineer runs it. Start fixture, record its PID/start identity/window IDs, and pass explicit target IDs to every command. Never discover a personal app by approximate name.
- [ ] Run first against a disposable test session after permissions are granted. Check snapshot IDs, deliberate stale-ref rejection, custom tree limits, Unicode AXValue and typing, focus failure, click counts/buttons, scroll, move, drag, annotation alignment, and capture paths. Refresh records after mutations.
- [ ] Validate cursor visible during spatial actions and absent from saved captures; overlay must not receive clicks or activate itself. Observe actual pointer movement and foreground changes match documentation. Test cursor off separately.
- [ ] Interrupt a long drag and kill only the test Node parent during another action. Verify no overlay/native child remains and no mouse button/modifier remains pressed. Never kill unrelated processes.
- [ ] Test Retina and additional display geometries only when available. Mark unavailable display/OS combinations as not verified, not passing. A failure in window identity/permission attribution blocks release readiness; do not solve it by adding private APIs or silently increasing permissions.
- [ ] Save a concise acceptance report under `docs/verification/` with platform/toolchain, commands, checks passed/failed/skipped, and no captured personal content. Run default mocked/native tests again afterward.

## Task 12: Retire obsolete tool code and final documentation

**Files:** modify README/Makefile/build/test config; retire `src/tools/ComputerUseTool.ts`, `src/tools/types.ts`, `src/ports.ts`, and replaced `src/tools/computer/` code plus old tests only after explicit deletion authorization. Retain historical designs and integration references as archival text unless the user authorizes removing them.

**Consumes:** equivalent command behavior covered by new tests and Task 11 report.
**Produces:** one supported CLI implementation, no unused agent wrapper or duplicate backend.

- [ ] Produce an exact replacement/deletion inventory and ask for authorization before deleting original restored files. Until authorized, keep originals out of the published package, clearly archival, without renaming them into misleading unused aliases. Record that cleanup is blocked, not complete.
- [ ] Preserve useful test cases: old key translation/Unicode and AX compact-tree cases must have counterparts in new TS/native suites. Do not delete tests merely because they reveal a regression.
- [ ] With authorization, remove the old FunctionTool, ports shims, replaced backend/binary and obsolete tests. Update README from "restoration" to CLI usage while retaining provenance and links to historical designs.
- [ ] Check for imports/references to removed runtime files, old `~/.nuvin/bin` setup commands, base64 tool envelopes, unchecked AppleScript construction, and hidden full-desktop screenshot fallback. No compatibility shim.
- [ ] Run final gates in order: `npm run typecheck`, `npm test`, `npm run test:native`, `npm run build`, `npm run test:package`. Report live acceptance separately from automated gates.
- [ ] Summarize changed files, verification, limitations, and remaining signed-distribution/background-control work. Do not commit, push, publish, or begin those future projects without instruction.

## Task dependency and review checkpoints

```text
1 CLI contract
  → 2 native protocol/discovery
    → 3 subprocess transport
      → 4 state + snapshot identity
        → 5 capture + transforms
          → 6 semantic/input executor
            → 7 raw mouse
              → 8 cursor host
                → 9 full coordinator
                  → 10 package
                    → 11 authorized live fixture
                      → 12 authorized source cleanup
```

This is deliberately sequential at state/native-host boundaries. Do not parallelize writers of Protocol.swift, NativeService.swift, or the interface ledger.

- Checkpoint A (Tasks 1–3): CLI contract, native build, transport failure behavior.
- Checkpoint B (Tasks 4–5): private state ownership, snapshot re-identification limitations, capture coordinate evidence.
- Checkpoint C (Tasks 6–9): mutation invalidation before effects, cursor/input ordering, cancellation and focus races.
- Checkpoint D (Tasks 10–12): installation independence, actual live evidence, authorized cleanup.

## Spec coverage and plan self-review

| Spec requirement | Tasks |
| --- | --- |
| CLI only, no agent/MCP/daemon | 1, 2, 10, 12 |
| Explicit app/PID/window and command flags | 1, 2, 9 |
| JSON/text, stderr, exit codes | 1, 3, 9 |
| AX snapshot evidence and invalidation | 4, 6, 9 |
| Capture-relative raw mouse commands | 5, 7 |
| Annotated images and no full-screen fallback | 5 |
| Virtual cursor, per-command host, cleanup | 8, 9, 11 |
| Focus validation and no automatic fallback | 6, 7, 9 |
| Text privacy/Unicode/clipboard opt-in | 1, 6, 9, 10 |
| Lock/state ownership, permissions, expiry | 4, 9 |
| Package-local helper and source builds | 2, 3, 10 |
| Pure native, mocked, package, opt-in live verification | 1–11 |
| Remove obsolete agent wrapper without destructive surprises | 12 |

Before execution, reread the spec and current tree. During execution, treat fresh compiler/test output as authoritative. Never mark a native behavior as verified because a mocked transport test passed.
