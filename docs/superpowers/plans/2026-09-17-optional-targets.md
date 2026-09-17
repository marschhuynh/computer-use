# Optional targets for `key` and `screenshot` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `--app/--pid` optional on `key` (bare → system-wide HID-tap chord) and `screenshot` (bare → whole main display, `--display <n>` for a specific monitor), keeping the window-scoped path unchanged.

**Architecture:** Widen `TargetSelector` with `.display(index)` and `.global` cases. `key` with no target posts via `CGEvent.post(tap: .cghidEventTap)` instead of `postToPid`. `screenshot` with no target (or `--display`) captures an `SCDisplay` into a synthetic `ResolvedTarget` (windowId=0, pid=0) whose `CaptureGeometry` spans the display frame — so `click`/`move`/`drag` work unchanged.

**Tech Stack:** TypeScript (Node 22, `node:util` parseArgs) CLI + Swift (ScreenCaptureKit, CoreGraphics, ApplicationServices) native host over newline-JSON stdio.

**Spec:** `docs/superpowers/specs/2026-09-17-optional-targets-design.md`

## Global Constraints

- macOS only; Swift tools-version per `native/Package.swift`; Node ≥ 22.
- Wire protocol stays `schemaVersion: 1` — `target` becomes *optional* on `key`/`screenshot`; `screenshot` adds optional `display: Int`. No version bump (additive/relaxing only).
- `validBoolean`/`integer`/`hasExactKeys` semantics preserved; new keys must be validated, never silently ignored.
- `windowId = 0` / `pid = 0` mark a display-capture `ResolvedTarget` — never collide with a real window/pid.
- `--annotated` requires a window target → reject on display targets with `INVALID_ARGUMENT`.
- Chord allowlist (`KeyChord.isValid`/`toCGEvent`) is the *only* permitted input for both `postKey` and the new `postGlobalKey` — no new key surface.
- Existing `key --app`/`screenshot --app` behavior is unchanged; all current tests must keep passing.

---

## File structure

| File | Responsibility |
|---|---|
| `src/core/protocol.ts` | `key`/`screenshot` `target` → optional; `screenshot` += `display?: number` |
| `src/cli/parse.ts` | relax `target()` usage for `key`/`screenshot`; `--display` value; emit `target`/`display` conditionally |
| `src/cli/run.ts` | help lines |
| `native/Sources/ComputerUseCore/Protocol.swift` | relax `validTarget` for `key`/`screenshot`; add `display` |
| `native/Sources/ComputerUseCore/TargetResolver.swift` | `TargetSelector += .display, .global`; display resolution → synthetic `ResolvedTarget` |
| `native/Sources/ComputerUseCore/CaptureService.swift` | `liveDisplayCapture`; `screenshot` branches on target kind |
| `native/Sources/ComputerUseCore/NativeInput.swift` | `postGlobalKey` driver method + `NativeInput.globalKey` |
| `native/Sources/ComputerUseCore/NativeService.swift` | `key`/`screenshot` dispatch on absent target |
| tests + `contracts/fixtures/native-protocol.json` | fixtures + XCTest/vitest for both new modes |
| `docs/cli.md`, `docs/agent-guide.md`, `README.md` | document bare/global/display usage |

---

### Task 1: Widen `TargetSelector` with `.display` and `.global`

**Files:**
- Modify: `native/Sources/ComputerUseCore/TargetResolver.swift:5-18` (enum + decode), `:151-169` (`windowsApplication`), `:180-239` (`resolve`)
- Test: `native/Tests/ComputerUseCoreTests/TargetResolverTests.swift`

**Interfaces:**
- Consumes: existing `TargetSelector.decode`, `WindowBounds`, `ResolvedTarget`, `TargetIdentity`.
- Produces:
  - `TargetSelector` cases `.display(index: Int?)` and `.global`
  - `TargetSelector.decode(_ value: Any?) -> TargetSelector?` — `nil`/non-dict → `nil` (caller maps absent target to `.global`/`.display` per command); a dict with `"display"` int → `.display`.
  - `resolveDisplay(index:context:) async throws -> ResolvedTarget` — new method producing the synthetic display `ResolvedTarget`.

- [ ] **Step 1: Write the failing test** — decode + exhaustive-switch compile coverage.

```swift
// In TargetResolverTests.swift
func testDisplayAndGlobalSelectorsDecode() throws {
    XCTAssertNil(TargetSelector.decode(nil)) // absent target -> caller picks .global/.display
    guard case .display(let idx) = TargetSelector.decode(["display": 2]) else {
        return XCTFail("expected .display")
    }
    XCTAssertEqual(idx, 2)
    // A bare dict with no app/pid/display is not a valid selector.
    XCTAssertNil(TargetSelector.decode(["unexpected": true]))
}
```

- [ ] **Step 2: Run to verify it fails** — `.display` case doesn't exist.

Run: `swift test --package-path native --filter TargetResolverTests`
Expected: compile error / `TargetSelector` has no `.display`.

- [ ] **Step 3: Implement** — add cases; `resolve`/`windowsApplication` throw `INVALID_ARGUMENT` on `.display`/`.global` (they aren't app-window resolvable); `decode` maps `["display": Int]` → `.display`.

```swift
public enum TargetSelector {
    case app(String, windowId: Int?)
    case pid(Int, windowId: Int?)
    case display(index: Int?)   // screenshot only; nil = main display
    case global                 // key only; not resolvable to a window
}

// in decode: after app/pid checks, before `return nil`:
if let display = targetInteger(target["display"]) { return .display(index: display) }

// in windowsApplication + resolve switch, add:
case .display, .global:
    throw NativeFailure("INVALID_ARGUMENT", "This target is not a window")
```

- [ ] **Step 4: Run to verify pass** — same command; green + existing tests still pass.

- [ ] **Step 5: Commit** — `git commit -m "feat(target): add .display/.global selector cases"`

---

### Task 2: `key` — global HID-tap input path

**Files:**
- Modify: `native/Sources/ComputerUseCore/NativeInput.swift:7-27` (protocol), `:48-53` (`NativeInput.key`), `:146-163` (`postKey`)
- Modify: `native/Sources/ComputerUseCore/NativeService.swift:223-234` (`case .key`)
- Modify: `native/Sources/ComputerUseCore/Protocol.swift:143-145` (relax `target` requirement)
- Test: `native/Tests/ComputerUseCoreTests/` — driver-mock test file for input (find the existing `NativeInput`/`ForegroundExecution` test double)

**Interfaces:**
- Consumes: `KeyChord.toCGEvent`, `NativeInputDriver`, `desktopLock`, `mutationResult`.
- Produces:
  - `NativeInputDriver.postGlobalKey(_ chord: String, context: CommandContext) throws`
  - `NativeInput.globalKey(_ chord: String, context: CommandContext) throws` — validates allowlist, calls driver.
  - `key` request: `target` optional; absent → `.global` → `postGlobalKey`.

- [ ] **Step 1: Failing test** — recording driver double captures a global post.

```swift
func testGlobalKeyPostsViaHIDTapNotPid() async throws {
    let recorder = GlobalKeyRecorder() // test double conforming to NativeInputDriver
    let input = NativeInput(driver: recorder)
    try input.globalKey("cmd+space", context: context())
    XCTAssertEqual(recorder.postedChords, ["cmd+space"])
    XCTAssertTrue(recorder.usedHIDTap)   // not postToPid
}
```
(The test double flags whether `postGlobalKey` was invoked vs `postKey`; the real driver's `usedHIDTap` is implied by the code path — assert the call landed on the global method.)

- [ ] **Step 2: Run → fail** (`postGlobalKey`/`globalKey` undefined).

- [ ] **Step 3: Implement.**
  - Protocol += `func postGlobalKey(_ chord: String, context: CommandContext) throws`.
  - `NativeInput.globalKey`: `guard KeyChord.isValid(chord)` → `try driver.postGlobalKey(chord, context:)`.
  - Live driver `postGlobalKey`: same chord→(key,flags) as `postKey`, but `down.post(tap: .cghidEventTap)` / `up.post(tap: .cghidEventTap)` instead of `postToPid`.
  - `NativeService .key`: `let selector = TargetSelector.decode(request.object["target"])` — if `nil` (target absent) → `.global` path: inside `desktopLock`, `try self.input.globalKey(key, context:)`, reply `target = {scope:"global"}`. If a `target` dict is present → existing `resolve`+`postToPid` unchanged.
  - `Protocol.swift .key`: `hasExactKeys` accepts `{schemaVersion,command,options,key}` (target absent) *or* `+ target`; when present `validTarget`.

- [ ] **Step 4: Run → pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(key): bare key posts chord globally via HID tap"`

---

### Task 3: `screenshot` — display capture path

**Files:**
- Modify: `native/Sources/ComputerUseCore/CaptureService.swift` — `liveWindowCapture` region, add `liveDisplayCapture`; `screenshot` branches on `ResolvedTarget` kind or a new param.
- Modify: `native/Sources/ComputerUseCore/TargetResolver.swift` — `resolveDisplay(index:context:)`.
- Modify: `native/Sources/ComputerUseCore/NativeService.swift:126-170` (`case .screenshot`) — no target → `.display(nil)`; `--display` → `.display(n)`; `--annotated` + display → `INVALID_ARGUMENT`.
- Modify: `native/Sources/ComputerUseCore/Protocol.swift:156-160` — `target` optional, add `display` key.
- Test: `native/Tests/ComputerUseCoreTests/CaptureTests.swift`, `TargetResolverTests.swift`

**Interfaces:**
- Consumes: `SCShareableContent.displays`, `SCContentFilter(display:excludingWindows:)`, `displayScale`, `pngEncode`, synthetic `ResolvedTarget` (Task 1).
- Produces:
  - `resolveDisplay(_ index: Int?, context:) async throws -> ResolvedTarget` → synthetic target (`windowId=0`, `pid=0`, `bounds=display.frame`, `title="Display <id>"`).
  - `CaptureService.screenshot(target:output:overwrite:native:context:annotations:)` — unchanged signature; the window `Capturer` closure already yields a `CapturedImage`, and a display target just needs a capturer that hits `SCDisplay`.
  - **Dispatch seam:** the injected `Capturer` is `(windowId, native, context)`. A display target has `windowId=0`, so the capturer can't distinguish it from a window. Add a second capture entry point — `liveDisplayCapture(display: SCDisplay, native: Bool, context:) async throws -> CapturedImage` — and have `NativeService` pick the capturer by target kind: window targets use `liveWindowCapture`, display targets use `liveDisplayCapture`. Concretely, `CaptureService` takes a `(ResolvedTarget, Bool, CommandContext) async throws -> CapturedImage` closure (widened from `(Int, Bool, CommandContext)`) so it can route on `target.identity.windowId == 0`.

- [ ] **Step 1: Failing test** — `resolveDisplay` returns synthetic target; geometry maps display pixel→screen point.

```swift
func testResolveDisplayProducesSyntheticTarget() async throws {
    let resolver = TargetResolver(provider: displayStubProvider())
    let target = try await resolver.resolveDisplay(nil, context: context())
    XCTAssertEqual(target.identity.windowId, 0)
    XCTAssertEqual(target.identity.pid, 0)
    XCTAssertEqual(target.bounds, WindowBounds(x: 0, y: 0, width: 2056, height: 1329))
    // geometry: pixel == point at 1x over display bounds
    let geo = CaptureGeometry(windowBounds: target.bounds, imageSize: CGSize(width: 2056, height: 1329), scale: 1)
    let pt = try geo.imageToScreen(CGPoint(x: 100, y: 50))
    XCTAssertEqual(pt, CGPoint(x: 100, y: 50))
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.**
  - `resolveDisplay`: enumerate `SCShareableContent.displays`; pick `index ?? main`; build synthetic `ResolvedTarget` (`identity.pid=0`, `windowId=0`, `launchDate`=host launch, `bundleId=nil`, `bounds=display.frame`, `title="Display \(displayID)"`). Out-of-range → `INVALID_ARGUMENT`.
  - **Widen the `Capturer`:** `CaptureService.Capturer` becomes `(ResolvedTarget, Bool, CommandContext) async throws -> CapturedImage` (was `(Int, Bool, CommandContext)`). `liveWindowCapture` keeps its signature and is wrapped: the default capturer is `{ target, native, ctx in target.identity.windowId == 0 ? try await liveDisplayCapture(display: lookupDisplay(for: target), native: native, context: ctx) : try await liveWindowCapture(windowID: target.identity.windowId, native: native, context: ctx) }`. `screenshot` calls `capturer(target, native, context)`; `screenshot`'s own signature and the `CapturedImage`/`geometry` path are unchanged. Update the two test-injected capturers in `CaptureTests`/`NativeService` fallback to the new 3-arg target-first shape.
  - `liveDisplayCapture(display:native:context:)`: `SCContentFilter(display:excludingWindows:[])` over the `SCDisplay`; `sourceRect = display.frame`; `scale = native ? displayScale(containing: display.frame) : 1`; `width/height = frame × scale`; `pngEncode`; `backingScale = image.width / display.frame.width`.
  - `NativeService .screenshot`: `target` absent → `resolveDisplay(request.object["display"])`; `--annotated` + display → `INVALID_ARGUMENT("annotated requires --app/--pid")`; `target` present → existing window path. `target` + `display` both present → `PROTOCOL_ERROR`.
  - `Protocol.swift .screenshot`: exact-keys = base + `output,overwrite,annotated,native,tree` + optional `target`/`display` (not both); `display` must be `positiveInteger`.

- [ ] **Step 4: Run → pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(screenshot): bare/--display captures full display"`

---

### Task 4: TS CLI + wire types

**Files:**
- Modify: `src/core/protocol.ts:18,21` — `key` `target` → optional; `screenshot` `target` → optional + `display?: number`.
- Modify: `src/cli/parse.ts:103` (screenshot flags/values), `:120` (key), `:151` (screenshot) — relax `target()` requirement, add `--display`, emit conditionally.
- Modify: `src/cli/run.ts:42,44` — help lines.
- Test: `tests/cli-parse.test.ts`

**Interfaces:**
- Consumes: Swift wire contract (Tasks 2-3).
- Produces:
  - `key`: `target?: Target`; bare `key --key <chord>` → `target` absent.
  - `screenshot`: `target?: Target`, `display?: number`; bare/`--display` → `target` absent.

- [ ] **Step 1: Failing test** — parse bare forms.

```ts
it('parses targetless key and screenshot', () => {
  expect(parse(['key', '--key', 'cmd+space'])).toMatchObject({ request: { command: 'key', target: undefined } });
  expect(parse(['screenshot', '--output', '/tmp/x.png'])).toMatchObject({ request: { command: 'screenshot', target: undefined } });
  expect(parse(['screenshot', '--output', '/tmp/x.png', '--display', '1']))
    .toMatchObject({ request: { command: 'screenshot', display: 1 } });
});
it('rejects screenshot target+display', () => {
  expect(() => parse(['screenshot', '--app', 'X', '--display', '0', '--output', '/tmp/x.png'])).toThrow();
});
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement.**
  - `protocol.ts`: `key` → `target?: Target`; `screenshot` → `target?: Target; display?: number`.
  - `parse.ts`: add `'display'` to `ValueName`; screenshot values += `'display'`; for `key`/`screenshot` call a `optionalTarget(values)` that returns `undefined` when neither `--app` nor `--pid` given (instead of throwing); `display` → `safeInteger`; enforce `!(target && display !== undefined)`.
  - `run.ts` help: `key --app <name>|--pid <pid> [--key <chord>]` → `key [--app|--pid] --key <chord> (bare = global chord)`; `screenshot` → `screenshot [--app|--pid|--display <n>] --output <path> ...`.

- [ ] **Step 4: Run → pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(cli): optional target on key/screenshot, --display flag"`

---

### Task 5: Shared fixtures + docs

**Files:**
- Modify: `contracts/fixtures/native-protocol.json`
- Modify: `native/Tests/ComputerUseCoreTests/ProtocolTests.swift` (valid-requests list)
- Modify: `docs/cli.md`, `docs/agent-guide.md`, `README.md`
- Test: `tests/cli-parse.test.ts` (fixture-driven), `ProtocolTests.swift` (fixture-driven)

**Interfaces:** fixture `argv` must parse (TS) and `request` must validate (Swift).

- [ ] **Step 1: Failing fixtures** — add cases; both fixture-driven suites reject them before implementation lands.

```json
{"name":"valid-key-global","valid":true,"argv":["key","--key","cmd+space"],"request":{"schemaVersion":1,"command":"key","key":"cmd+space","options":{"timeoutMs":15000,"cursor":"on"}}},
{"name":"valid-screenshot-display","valid":true,"argv":["screenshot","--output","/tmp/x.png","--display","0"],"request":{"schemaVersion":1,"command":"screenshot","output":"/tmp/x.png","display":0,"overwrite":false,"annotated":false,"native":false,"tree":{"maxDepth":8,"maxElements":500,"hintMode":"leafCompact"},"options":{"timeoutMs":15000,"cursor":"on"}}},
{"name":"invalid-screenshot-target-plus-display","valid":false,"request":{"schemaVersion":1,"command":"screenshot","target":{"pid":42},"display":0,"output":"/tmp/x.png","overwrite":false,"annotated":false,"native":false,"tree":{"maxDepth":8,"maxElements":500,"hintMode":"leafCompact"},"options":{"timeoutMs":1,"cursor":"on"}}},
{"name":"invalid-display-negative","valid":false,"request":{"schemaVersion":1,"command":"screenshot","display":-1,"output":"/tmp/x.png","overwrite":false,"annotated":false,"native":false,"tree":{"maxDepth":8,"maxElements":500,"hintMode":"leafCompact"},"options":{"timeoutMs":1,"cursor":"on"}}}
```

- [ ] **Step 2: Confirm fixture suites pass** with Tasks 1-4 in place (they're the same validation code paths).

- [ ] **Step 3: Update `validRequestsForEveryCommandForm()`** — add bare `key` (no `target`) and `screenshot`+`display` literals so the unexpected-key rejection test covers the new shapes.

- [ ] **Step 4: Docs** — `cli.md` synopsis + a "bare key = global, bare screenshot = full screen" note; `agent-guide.md` spatial path; README quick-start line.

- [ ] **Step 5: Full verify + commit.**

Run: `npm run typecheck && npm test && swift test --package-path native && npm run test:native-protocol`
Expected: all green.
`git commit -m "feat: fixtures + docs for optional targets"`

---

## Self-review notes

- **Spec coverage:** global key (T2), display screenshot (T3), selector widening (T1), CLI/wire (T4), fixtures/docs (T5). `--annotated`-display rejection and `target`+`display` mutual exclusion covered in T3/T4 steps.
- **Type consistency:** `postGlobalKey`, `globalKey`, `resolveDisplay`, `.display(index:)`, `.global`, `display?: number` — names are uniform across tasks.
- **Ambiguity resolved:** `SCDisplay.frame` confirmed `(0,0,2056,1329)` top-left points → `sourceRect`/`bounds`/`CaptureGeometry` consistent; display `backingScale` reuses existing `displayScale(containing:)`.
- **Known follow-up (not in scope):** `displays` enumeration command to list monitors for `--display` discovery — separate change if wanted.
