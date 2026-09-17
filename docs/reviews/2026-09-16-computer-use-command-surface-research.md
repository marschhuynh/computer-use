# Computer-use command surface: evidence from primary sources

Date: 2026-09-16
Scope: what actions/commands a "computer-use" tool should expose, per the authoritative implementations (Anthropic, OpenAI, Google), the native macOS input/AX surface, and common UI-automation agent vocabularies.
Current CLI under review: 13 commands — `doctor, apps, windows, snapshot, press, set-value, type, key, scroll, screenshot, click, move, drag` (`src/core/protocol.ts`).

---

## 1. Anthropic — `computer` tool / `computer_toolset_20260801`

The current GA surface is a **17-member toolset**; each action is a named member tool, not an `action` enum (earlier `computer_20241022`/`computer_20250124`/`computer_20251124` versions used a single `action` field). Source: official docs.

**Observe:** `screenshot` (full display image), `zoom` (region `[x0,y0,x1,y1]` → full-res crop image), `cursor_position` (returns `X,Y` text).
**Mutate:** `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click` (each takes optional `coordinate` and optional `text` holding modifiers `shift/ctrl/alt/super` or `+`-joined combos); `left_click_drag` (`start_coordinate`→`coordinate`); `mouse_move` (`coordinate`, for hover); `left_mouse_down`/`left_mouse_up` (for drags `left_click_drag` can't express); `scroll` (`scroll_direction` up/down/left/right, `scroll_amount` in wheel clicks, optional `coordinate`, optional `text` modifiers); `type` (`text` at current focus); `key` (key or `+`-combo, `repeat` 1–100); `hold_key` (`text`, `duration` ≤300s); `wait` (`duration` ≤300s).
**Input type:** coordinates only (screenshot pixel space); no semantic element refs.
**Returns:** image for `screenshot`/`zoom`; coordinates text for `cursor_position`; short `OK` for the rest. Batched member calls run in order; first failure halts the batch.
URL: https://docs.claude.com/en/docs/agents-and-tools/tool-use/computer-use-tool
Version evolution in the reference impl: `Action_20241022` = {key, type, mouse_move, left_click, left_click_drag, right_click, middle_click, double_click, screenshot, cursor_position}; `20250124` adds {left_mouse_down, left_mouse_up, scroll, hold_key, wait, triple_click}; `20251124` adds `zoom`; `computer_toolset_20260801` exposes all 17 as members.
URL: https://github.com/anthropics/claude-quickstarts/blob/main/computer-use-demo/computer_use_demo/tools/computer.py

## 2. OpenAI — `computer` function tool (Responses API / Operator / computer-use-preview)

The model returns a `computer_call` with an ordered `actions` array; the model can request **`click`, `double_click`, `drag`, `move`, `scroll`, `keypress`, `type`, `wait`, `screenshot`** — 9 action types. Example: `{"type":"click","button":"left","x":405,"y":157}`.
**Input type:** pixel coordinates only (`x`, `y`, `button`, `text`, `keys`, `scroll_x/y`, `path` for drag, `ms` for wait). First call may be a lone `screenshot` to observe.
**Returns:** caller posts back `computer_call_output` containing a `computer_screenshot` image.
**Navigation/discovery:** none — no DOM/AX access in this tool; the recommended newer path on the same docs page is "code execution" (model writes PyAutoGUI/Playwright code).
URL: https://platform.openai.com/docs/guides/tools-computer-use

## 3. Google — Gemini Computer Use (`computer_use` tool)

Two generations on one docs page. **Gemini 3.5+** scopes actions by `environment` (browser / mobile / desktop); each call carries an `intent` rationale string.
**Desktop env:** `click`, `double_click`, `triple_click`, `middle_click`, `right_click`, `mouse_down`, `mouse_up`, `move`, `type` (`text`, `press_enter`), `drag_and_drop` (start→end), `scroll` (`x`,`y`,`direction`,`magnitude_in_pixels`), `press_key`, `key_down`, `key_up`, keyboard shortcut (`keys` list), `take_screenshot`, `wait`.
**Mobile env adds:** `open_app`, `list_apps`, `long_press`, `go_back`. **Browser env adds:** `navigate`, `go_back`, `go_forward`.
**Legacy Gemini 2.5 (preview-10-2025):** `open_web_browser`, `wait_5_seconds`, `go_back`, `go_forward`, `search`, `navigate`, `click_at`, `hover_at`, `type_text_at` (`press_enter`, `clear_before_typing`), `key_combination`, `scroll_document`, `scroll_at` (`magnitude`), `drag_and_drop`; plus `excluded_predefined_functions` and custom function registration.
**Input type:** normalized 0–999 coordinates (caller denormalizes); semantic-ish navigation verbs for browser/mobile only.
**Returns:** caller returns a `function_result` with fresh screenshot + URL per action.
URL: https://ai.google.dev/gemini-api/docs/computer-use

## 4. macOS native surface (HIServices AX + CGEvent/XCTest)

**AXUIElement action API** (`AXUIElementPerformAction` + `AXUIElementCopyActionNames`): actions are per-element strings, roughly "things you could do with a single click." Standard constants in `AXActionConstants.h`: `kAXPressAction`, `kAXPickAction`, `kAXCancelAction`, `kAXConfirmAction`, `kAXRaiseAction`, `kAXShowMenuAction`, plus `kAXShowAlternateUIAction`/`kAXShowDefaultUIAction`; apps vend additional actions (e.g., `AXScrollToVisible`, page-scroll actions) discoverable only via `AXUIElementCopyActionNames`. Settable attributes (`AXUIElementSetAttributeValue` after `AXUIElementIsAttributeSettable`) cover `AXValue`, `AXFocused`, `AXSelected`, etc. `AXUIElementCopyElementAtPosition` maps screen point → element; `AXUIElementPostKeyboardEvent` posts keys to a specific app; the system-wide element exposes `AXFocusedUIElement`.
URLs: https://developer.apple.com/documentation/applicationservices/axactionconstants_h , https://developer.apple.com/documentation/applicationservices/axuielement_h , https://leopard-adc.pepas.com/documentation/Accessibility/Reference/AccessibilityLowlevel/AXUIElement_h/CompositePage.html

**XCUIElement (macOS 15+ / Xcode 16.3+, the vendor's own UI-automation vocabulary):** `click()`, `doubleClick()`, `rightClick()`, `hover()`, `scroll(byDeltaX:deltaY:)`, `typeText`, `typeKey`, `press(forDuration:)`, `press(forDuration:thenDragTo:)`, plus modifier flags; element-resolved hittable points (semantic targeting, not raw pixels).
URL: https://developer.apple.com/documentation/xcuiautomation/xcuielement

**CGEvent (Quartz event stream):** supports mouse down/up/dragged/moved per button, `CGEventCreateScrollWheelEvent` (pixel or line units, multi-axis), keyboard down/up with keycodes + modifier flags, and posting to a specific PSN — i.e., the native substrate can express every click/drag/scroll/hold/hover primitive the vendors expose, including chorded modifiers and per-app delivery.

**Gaps a macOS CLI can hit that cross-platform tools ignore:** menu-bar/status-item interaction (`AXMenuBar`, `AXShowMenu` on menu extras), `AXScrollToVisible` for off-screen AX elements, `AXShowMenu`/`AXPick` for context menus without synthetic right-clicks, `AXRaise`/`AXFocusedWindow` for focus management, text insertion via `AXValue` vs key events (already covered by `set-value` vs `type`).

## 5. Agent vocabulary across other tools (lowest common denominator)

| Tool | Surface (primary source) |
|---|---|
| OSWorld action space | `MOVE_TO, CLICK(button,x,y,num_clicks), MOUSE_DOWN, MOUSE_UP, RIGHT_CLICK, DOUBLE_CLICK, DRAG_TO, SCROLL(dx,dy), TYPING, PRESS, KEY_DOWN, KEY_UP, HOTKEY` + control tokens `WAIT/FAIL/DONE`; also free-form pyautogui code. https://github.com/xlang-ai/OSWorld/blob/main/mm_agents/prompts.py , https://arxiv.org/html/2404.07972v2 |
| Playwright `mouse`/`Locator` | `mouse.click/dblclick/down/move/up/wheel`; locator-level `click, dblclick, fill, press, type (pressSequentially), hover, dragTo, tap, scrollIntoViewIfNeeded` — semantic-ref inputs, actionability auto-wait. https://playwright.dev/docs/api/class-mouse , https://playwright.dev/docs/api/class-locator |
| Peekaboo (native macOS, closest analog) | `see, screen list, window list` (observe); `click, type, press, scroll, drag, set-value, action` (act); `app, window, menu, menubar, dock, dialog, space` (macOS control); `agent, capture, mcp`. https://github.com/openclaw/Peekaboo |
| MacOS-MCP | `Click, Type, Scroll, Move, Shortcut, App, Desktop, Shell, Scrape, Wait` + snapshot tool. https://github.com/CursorTouch/MacOS-MCP |
| Windows Agent Arena `Computer` | `mouse: move_id/move_abs/single_click/double_click/right_click/scroll(direction)`; `keyboard: write/press`; `clipboard: copy_text/copy_image/paste`; `os: open_program`; `window_manager: switch_to_application`. https://microsoft.github.io/WindowsAgentArena/static/files/windows_agent_arena.pdf |

**LCD "must-have" mutation set** (present in ≥4 of the 6 non-CLI surfaces): click (left/right/middle, multi-count), move/hover, drag, scroll, type text, key/chord press, wait. **Observe set:** screenshot + a structural tree/snapshot. **Navigation/discovery:** list apps/windows, and in web-scoped tools navigate/back/forward.

---

## Implications for this CLI

**Already covered (13 commands map cleanly):**
- Observe: `screenshot`, `snapshot` (AX tree + refs), `windows`, `apps`, `doctor` — matches/exceeds every vendor's observe surface (none have a semantic tree).
- Mutate: `click` (button+count covers left/right/middle/double/triple), `move` (hover), `drag`, `scroll` (ref or direction+amount), `type`, `key` (chords), `press` (AX action), `set-value` (AX attribute write — beyond vendor surfaces).
- Wait: partially — only implicit via command timeouts; no explicit `wait` command.

**Plausible additions, ranked by evidence:**
1. **`wait`** — explicit duration wait appears in Anthropic, OpenAI, Gemini, OSWorld, MacOS-MCP. Trivial, universally expected. High confidence.
2. **`hold-key`** (or `key` with `duration`) — Anthropic `hold_key`, Gemini `key_down`/`key_up`, OSWorld `KEY_DOWN`/`KEY_UP`; needed for hold-to-reveal UIs (e.g., Option-key menus, long presses). Medium-high.
3. **Mouse button down/up primitives** (`mouse-down`/`mouse-up`) — Anthropic `left_mouse_down/up`, Gemini `mouse_down/up`, Playwright `down/up`, OSWorld; enables custom drag paths and modifier-drag that `drag` can't express. Medium.
4. **Modifier flag on `click`/`scroll`** — Anthropic `text` param, OpenAI `keypress` keys field, Playwright modifiers; required for shift-click range select, cmd-click multi-select. Medium.
5. **Generic AX `action`** (perform arbitrary action name from `AXUIElementCopyActionNames`) — Peekaboo ships `action`; unlocks `AXShowMenu`, `AXScrollToVisible`, `AXConfirm`, `AXCancel`, `AXPick` without growing the grammar per action. Medium-high for an AX-first tool.
6. **Menu-bar / `menubar` discovery+press** — Peekaboo and MacOS-MCP both ship menu/menu-bar commands; status items are macOS-unique and unreachable via window-scoped `snapshot` unless `apps`/`snapshot` already walks `AXMenuBar`. Medium (verify current coverage first).
7. **`cursor-position`** — Anthropic only; trivially cheap, useful for verification. Low-medium.
8. **`zoom`/region capture** — Anthropic `zoom`; mitigates small-text legibility on Retina screenshots. Low-medium (screenshot already supports annotated/tree output; a `rect` crop arg may suffice).
9. **`raise`/`focus` window** — `AXRaise`/`AXFocusedWindow`/`AXMain`; window management is in Peekaboo (`window`), MacOS-MCP (`App`), WAA (`switch_to_application`). Current `windows` is read-only. Medium if activation isn't already handled elsewhere.
10. **`hover_at`-style element scroll-into-view** — `AXScrollToVisible` via generic `action` (item 5) rather than a dedicated command.

**Deliberately out of scope for a foreground macOS utility:**
- `navigate`, `go_back`, `go_forward`, `search`, `open_web_browser`, `open_app` (Gemini browser/mobile; these are agent-level or `open`/AppleScript territory, not UI primitives — though `open_app`/`list_apps` exists on Gemini mobile and MacOS-MCP `App`; a thin `launch` verb is defensible but optional).
- `long_press`, `tap`, `swipe`, `pinch`, `rotate`, `twoFingerTap` (touch surfaces; no macOS trackpad-gesture CGEvent equivalent worth exposing).
- `clipboard` verbs (WAA, mac-use-mcp): orthogonal subsystem; `type` already has `allowClipboardReplace`.
- `cursor_position` variants that track the *user's* mouse vs synthetic input: fine as read-only, but continuous tracking/streaming video is out of scope (Anthropic's "flipbook" limitation note).
- DONE/FAIL/WAIT control tokens (OSWorld): agent-loop semantics, belong to the caller not the CLI.
- Batch/atomic multi-action sequencing: vendors implement it in the protocol envelope (Anthropic toolset blocks, OpenAI `actions[]`); a per-invocation CLI gains this via a batch request, not new command names.

**Bottom line:** the current 13-command surface already covers the cross-vendor LCD for mutation and exceeds it for observation (semantic refs + AX actions). The strongest evidence-backed gaps are `wait`, `hold-key`, mouse `down`/`up`, a modifier field on `click`/`scroll`, and a generic AX `action` escape hatch — all present in ≥2 authoritative surfaces and all expressible via HIServices/CGEvent.

## Sources

- https://docs.claude.com/en/docs/agents-and-tools/tool-use/computer-use-tool
- https://github.com/anthropics/claude-quickstarts/blob/main/computer-use-demo/computer_use_demo/tools/computer.py
- https://platform.openai.com/docs/guides/tools-computer-use
- https://ai.google.dev/gemini-api/docs/computer-use
- https://developer.apple.com/documentation/applicationservices/axactionconstants_h
- https://developer.apple.com/documentation/applicationservices/axuielement_h
- https://leopard-adc.pepas.com/documentation/Accessibility/Reference/AccessibilityLowlevel/AXUIElement_h/CompositePage.html
- https://developer.apple.com/documentation/xcuiautomation/xcuielement
- https://github.com/xlang-ai/OSWorld/blob/main/mm_agents/prompts.py
- https://arxiv.org/html/2404.07972v2
- https://playwright.dev/docs/api/class-mouse
- https://playwright.dev/docs/api/class-locator
- https://github.com/openclaw/Peekaboo
- https://github.com/CursorTouch/MacOS-MCP
- https://microsoft.github.io/WindowsAgentArena/static/files/windows_agent_arena.pdf
