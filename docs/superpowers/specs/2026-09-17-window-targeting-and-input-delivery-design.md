# Window targeting + input delivery — design

**Date:** 2026-09-17
**Status:** approved design; plan written, targeting half implemented
**Scope:** `nuvin-computer-use` CLI + native host
**Plan:** `docs/superpowers/plans/2026-09-17-input-delivery-and-honesty.md`
**Field report:** `docs/verification/2026-09-17-live-run-defects.md`
**Defects addressed:** D1 (window join), D3 (windowless `type`), the input half of D4 (`mutationStatus`). D2, D5, D6 are non-goals below.

## Summary

Two related defects in the semantic layer made the CLI unusable on real apps:

1. **Window correlation guessed identity.** AX and CG are two separate window registries (see *Background*). The join between them matched `role + title + exact bounds`. Any app whose two titles diverge — Chrome appending a `🔊` audio glyph to `kCGWindowName`, `AXTitle` carrying a `- <app> - <profile>` suffix, overlapping same-size windows — silently matched nothing, and `windows`/`snapshot`/`key`/`type`/`click`/`move`/`drag` all collapsed.

2. **Absent optional attributes aborted snapshots.** Notes, Calendar and other SwiftUI-era apps answer `kAXErrorFailure` for attributes that simply don't exist on an element (`AXSubrole`, an empty action list) where AppKit apps answer `.noValue`/`.attributeUnsupported`. The classifier mapped every non-`noValue`/`attributeUnsupported` `AXError` to a fatal read failure, so one unreadable attribute on one decorative element killed the whole snapshot (`NATIVE_FAILURE`).

Separately, input delivery had a reachability bug: `key`/`type` posted into the *target process's* event queue (`postToPid`), so they could never reach UI owned by another process — open/save panels, sheets, helper-hosted windows.

## Background — AX vs CG

macOS exposes windows through two independent systems:

- **AX (`AXUIElement`, ApplicationServices)** — the semantic view, built for assistive tech. App-authored; its handles are opaque and per-process, so they can't be printed or passed to a later invocation. Provides refs, roles, actions, the element tree.
- **CG (`CGWindowList` / `CGWindowID`, WindowServer)** — the compositor's view: pixels, on-screen truth, stacking, display. Provides the stable integer `CGWindowID` (`--window <id>`) that `screenshot`/`click` need and that survives this CLI's one-process-per-command lifetime.

They are both necessary; the bug was the **string-matching bridge** between them.

## Goals

- Join AX windows to their `CGWindowID` by **resolution, not correlation** — no titles, no bounds arithmetic.
- Re-find a snapshot's target window by id, fixing the same comparison bug in `capture`.
- Degrade an absent *optional* attribute to "absent" instead of aborting the snapshot; keep identifying attributes and permission/liveness failures fatal.
- Deliver targeted `key`/`type` so the input reaches the app named by `--app`/`--pid` — including its panels — by **activating it then posting to the HID event tap**.
- Add `type --global` **and bare targetless `type`** (both mean "type into whatever holds focus," matching bare `key`) plus a `--to-process` background-queue opt-in.
- Make `verification` and `mutationStatus` report honestly.

## Non-goals

- **D2** — setting `AXManualAccessibility` so Chromium exposes its *renderer* tree. Chrome's chrome UI (toolbar, address bar) already snapshots; the web content tree is a separate, larger change.
- **D5** — an `activate`/`open --url` verb. Activation here is internal to `key`/`type` delivery, not a standalone command.
- **D6** — display-capture identity metadata.
- No change to `press`/`set-value`/`scroll --ref` semantics — they stay snapshot→ref→AX action.
- No change to `click`/`move`/`drag` pixel delivery — they stay CGEvent-at-point; only their *capture re-validation* benefits from the id join.

## Design

### 1. Window identity: resolve the `CGWindowID`, don't infer it

`_AXUIElementGetWindow(AXUIElementRef, CGWindowID*)` returns the window id for an AX element. No public API does this (verified on macOS 14/15; `AXWindowNumber`/`AXWindowID`/`AXIdentifier` are all absent or non-unique), and it is the unanimous choice of every major macOS window manager (yabai, AeroSpace, Rectangle, Amethyst/Silica, Hammerspoon, Loop). Signature stable since Mac OS X 10.5.

**Runtime-resolved, not link-bound.** The symbol is fetched via `dlopen`/`dlsym` once, cached, stored as a nullable pointer. Link-time binding (`@_silgen_name`/`extern`) would crash the process at launch if the symbol ever disappears; dynamic resolution degrades instead. This is Loop's documented lesson.

**`WindowIDResolver`** wraps it:

```swift
public struct WindowIDResolver {
    public var isAvailable: Bool
    public func windowID(for element: AXUIElement) -> Int?   // nil = not a window / unavailable
}
```

A non-success status or `0` means "this element is not a window" (e.g. Finder's desktop `AXScrollArea` returns `-25201` by design) — callers filter, not fail.

### 2. `liveWindows` — join on id

`TargetResolver.liveWindows` resolves each AX window's id and pairs it with the CG entry **by id equality**. `CGWindowMetadata.title` is what gets reported (it is the rendered, user-visible title — `"... 🔊"`), matching `windowJSON`'s existing `cg.title ?? ax.title` precedence.

**Honest-collapse rule.** When ids are available (`strictJoin`), an AX-reported window that joins to nothing throws `NATIVE_FAILURE` instead of yielding `ok:true, windows:[]` — a correlation collapse and "this app has no windows" must be distinguishable. On the fallback path (symbol unavailable) an unmatched window is expected, so it stays non-fatal.

### 3. Fallback correlation, honest

If the symbol is unavailable, correlate on `role + title + exact bounds` as before — but a candidate matching **several** CG windows fails `AMBIGUOUS_TARGET` rather than picking one. Measured correlation produced a wrong id once; a wrong id silently drives input at the wrong window, so ambiguity is an error, not a guess.

### 4. `AXTree.capture` — re-find by id

`capture` re-finds the window to walk by its resolved `CGWindowID` (`selectTargetWindow(candidates:targetWindowID:)` → index). The old path compared the target's *CG* title against each window's *AX* title — guaranteed to fail whenever they diverge. Fallback retains the title+bounds correlation.

### 5. Absent optional attributes degrade to absent

A bare `kAXErrorFailure` on a **non-identifying** attribute means "not present," not "unreadable":

```swift
func axAttributeIsIdentifying(_ attribute: String) -> Bool   // only AXRole
func axScalarReadResult<Value>(attribute:status:value:expectedTypeID:decode:) -> AXReadResult<Value>
func axActionNamesReadResult(status:names:) -> AXReadResult<[String]>
```

- `.failure` on `AXSubrole`/`AXIdentifier`/`AXTitle`/`AXDescription`/`AXValue`/booleans/actions → `.unavailable` → `nil`/`[]`.
- `.failure` on **`AXRole`** stays fatal — it's read via `required()` and every ref/evidence decision keys off it.
- `.apiDisabled`, `.invalidUIElement`, `.cannotComplete` always stay fatal — they mean no-permission / dead-element / unresponsive-AX-server, which would corrupt the rest of the traversal.
- `.success` with a nil payload stays a **failure** (a contract violation — AX claimed it wrote a value and didn't); `.success` with a wrong CF type stays `.unavailable` (a degenerate element, not a failure). Both preserved from the existing invariant.

### 6. Input delivery: activate, then tap

`--app X`/`--pid N` on `key`/`type` now means "raise X, then type into it":

1. **Activate** — `NSRunningApplication(pid).activate(options:)` then poll `NSWorkspace.frontmostApplication` until it's `pid`, at ~20ms inside the command deadline. On timeout → `FOCUS_FAILED`.
2. **Deliver to the HID tap** — `CGEvent.post(tap: .cghidEventTap)`. WindowServer routes to the now-frontmost app, including panel/helper-hosted windows inside it. `postToPid` bypasses WindowServer routing, which is exactly why it could never reach an open/save panel.

**Delivery modes:**

| Mode | Activation | Posting | Use |
|---|---|---|---|
| `--app/--pid` (default) | yes | `.cghidEventTap` | reach the app *and* its panels |
| `--to-process` | no | `postToPid` | type into a **background** app without focusing it |
| `--global` / bare | no | `.cghidEventTap` | type into whatever is already focused |

`KeyDelivery { .process, .focused }` selects the path inside `NativeInput.key`/`type`. The plan adds `postFocusedText` (each scalar's down/up to the tap, same 4ms pacing as `postText`, so ordering is preserved and the clipboard is untouched) and a `type(_:to:delivery:context:)` overload — these do not exist yet and are created in plan Tasks 3–4, which also supply the `tapText`/`tapKeys` recorder separation the tests rely on.

### 7. Honesty fields

- **`verification`** — `"verified"` only when an AX action returned success (`accessibility` method: press/set-value/scroll-ref). For `cg-event` results (key/type/click/move/drag/global) only dispatch is provable, so they report `"dispatched"`. `docs/cli.md`/`agent-guide.md` updated to match.
- **`mutationStatus`** — `notStarted` when the failure happened before dispatch began (target-resolution `TARGET_NOT_FOUND`, activation `FOCUS_FAILED`), `potentiallyApplied` only when the input may already have run. Two fixes needed: (a) the native side must *emit* `notStarted` — a failure thrown in `resolve` runs before `dispatchTargetMutation`'s `entered` flag is set and is caught by the outer `run` handler, which attaches no status; (b) the TS boundary (`projectReply`, macos.ts:198-201) currently **drops** a wire-supplied `notStarted` — `publicStatus` resolves to `undefined` unless the wire says `potentiallyApplied`, so the status never reaches the reply. It must carry `notStarted` through, not merely avoid coercing it.

## Files touched

| File | Change |
|---|---|
| `native/.../WindowIDResolver.swift` *(new)* | dlsym'd `_AXUIElementGetWindow`, `joinWindows`, `selectTargetWindow`, `AXWindowCandidate` |
| `native/.../TargetResolver.swift` | `liveWindows` joins by id; remove `matches(ax:cg:)` |
| `native/.../AXTree.swift` | `capture` re-finds by id; `axAttributeIsIdentifying`, `axScalarReadResult`, `axActionNamesReadResult` |
| `native/.../NativeInput.swift` | `KeyDelivery`, `postFocusedKey`/`postFocusedText` via `.cghidEventTap`, `key`/`type` overloads; remove dead `AXUIElementCreateApplication` in `postKey` |
| `native/.../NativeService.swift` | activate-then-deliver in `key`/`type` dispatch; `toProcess`; `verification` values; `type --global` |
| `native/.../ComputerUseCore` (activation) | `activate(pid:context:)` → `FOCUS_FAILED` |
| `src/core/protocol.ts` | `key`/`type` `target` optional + `toProcess?`; `type` gains `--global` semantics |
| `src/cli/parse.ts` | `--to-process`, `type` targetless/`--global`, mutual-exclusion guards |
| `src/cli/run.ts` | help lines |
| `src/backend/macos.ts` | preserve `notStarted` for pre-dispatch failures |
| `native/Tests/…/WindowIDJoinTests.swift` *(new)*, `AXTrustTests.swift`, `ForegroundExecutionTests.swift` | join, degradation, activation, delivery tests |
| `docs/cli.md`, `docs/agent-guide.md` | delivery modes, honesty semantics |

## Error handling

| Case | Code |
|---|---|
| AX window resolves a `CGWindowID` with no CG entry | filtered out (off-screen/another Space) |
| `AXRole != AXWindow` / no id | filtered (not a window) |
| ids available but nothing joined | `NATIVE_FAILURE` (strict join) |
| fallback match ambiguous | `AMBIGUOUS_TARGET` |
| snapshot target window no longer found | `STALE_SNAPSHOT` |
| optional attr `.failure` | degrade to absent |
| `AXRole` `.failure` / `.apiDisabled` / `.invalidUIElement` / `.cannotComplete` | `STALE_SNAPSHOT` / `PERMISSION_DENIED` / `NATIVE_FAILURE` |
| app can't be raised | `FOCUS_FAILED` (pre-dispatch → `notStarted`) |
| resolve `TARGET_NOT_FOUND` | `notStarted` |
| `--to-process` without `--app`/`--pid` | `INVALID_ARGUMENT` |
| `--to-process` on bare `key`/`type` | `INVALID_ARGUMENT` |
| `type --global` **or bare `type`** | posts to focus, `scope: "global"` |

## Testing

- **Swift XCTest:** `joinWindows` (id join ignores decorated titles, disambiguates stacked bounds, filters non-windows, strict-join honesty); `selectTargetWindow` (id selection, stale when missing); `axActionNamesReadResult`/`axScalarReadResult` (degrade `.failure`, keep permission/liveness fatal, `AXRole` stays identifying); `activate` (frontmost wait, `FOCUS_FAILED`); targeted `key`/`type` activate-then-tap and `--to-process` skip-activate; `verification`/`mutationStatus` values.
- **vitest:** `--to-process`/`--global`/targetless `type` parsing + mutual exclusion; `projectReply` preserving `notStarted`.
- **Live:** Chrome-with-audio `windows`/`snapshot`; Notes/Calendar `snapshot`; a TextEdit open-panel `escape`; `type` with no target.

## Safety

- **Private symbol.** `_AXUIElementGetWindow` is undocumented but stable since Leopard, used by every major window manager, and runtime-resolved so removal degrades rather than bricks the binary. No App Store (npm), notarization doesn't scan for it, and AX already requires an unsandboxed process.
- **Focused delivery changes semantics.** `--app X` now activates X and types into focus. This is the intended contract — it fixes both the panel-reachability bug and the "typed into the wrong app" foot-gun that a raw HID-tap-without-activation would create. `--to-process` preserves the background-app capability for callers that genuinely want it.
- **`FOCUS_FAILED` is honest.** An app that can't be raised fails before any input runs (`notStarted`), never silently typing into whatever was focused.
- **`--global`/bare `type` types into whatever holds focus** — same surface as bare `key`. No new TCC scope.
