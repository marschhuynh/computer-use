# Stage K — Authorized Fixture Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Prove the full command set against a dedicated, disposable macOS fixture window — with explicit user authorization for live foreground input — and produce a sanitized acceptance report.

**Architecture:** A dedicated two-window fixture app (in-memory, no disk/clipboard access) is the only live target. `scripts/live-fixture.mjs` is opt-in (`NUVIN_CU_LIVE=1` is *necessary but not sufficient* — a human must explicitly authorize). A per-command acceptance matrix records pass/fail/unavailable separately.

**Tech Stack:** Swift/AppKit fixture app, Node runner, real AX + Screen Recording permissions.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Verification and acceptance. **Roadmap slice:** Stage K. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **Requires explicit user authorization for live foreground input.** Automated gates passing is not authorization.
- Dedicated fixture only — **no personal app discovery**, no clipboard/user-file access, no unrelated process kills.
- Only the exact fixture PID / start identity / window IDs may be targeted.
- Report passed/failed/unavailable **separately** — never label an unverified combination as passing.
- After acceptance, re-run the default mocked/pure/native-integration suites to confirm no regression.

## File Structure

| File | Responsibility |
|---|---|
| `fixtures/app/` | NEW — minimal two-window fixture app (owned, disposable) |
| `scripts/live-fixture.mjs` | NEW — opt-in runner + refusal when not authorized |
| `docs/testing.md` | how to run; permission setup |
| `docs/verification/YYYY-MM-DD-acceptance.md` | NEW — sanitized acceptance report |

## Interfaces

**Consumes:** full CLI (Stage J built), real `computer-use-host`, `NUVIN_CU_LIVE` env gate.

**Produces:** an acceptance matrix — for each of `doctor`/`apps`/`windows`/`snapshot`/`press`/`set-value`/`type`/`key`/`scroll`/`screenshot`/`click`/`move`/`drag`: pass | fail | unavailable, with notes.

---

### Task K1: dedicated fixture app

- [ ] **Step 1 — build** a minimal AppKit app with two windows, a labeled button (AXPress target), a text field (AXValue/type target), and a scrollable area; in-memory only.
- [ ] **Step 2 — verify** it exposes deterministic AX roles/identifiers for targeting.
- [ ] **Step 3 — commit** `test: disposable two-window acceptance fixture`.

### Task K2: opt-in runner + refusal

- [ ] **Step 1 — implement** `scripts/live-fixture.mjs`: refuses without `NUVIN_CU_LIVE=1` *and* an interactive confirmation; launches fixture, captures its exact PID/start-identity/window IDs.
- [ ] **Step 2 — commit** `test: opt-in live fixture runner`.

### Task K3: per-command acceptance matrix

- [ ] **Step 1 — run each command** against the fixture: snapshot→press/set-value, Unicode type, key, directional + ref scroll, screenshot + annotated, click/move/drag.
- [ ] **Step 2 — check** cursor feedback visible, physical-pointer/foreground behavior as documented, no leftover overlay or held input after cancellation; owned-parent-kill and drag-interruption paths.
- [ ] **Step 3 — write** sanitized report to `docs/verification/` with passed/failed/unavailable.
- [ ] **Step 4 — re-run** `npm test`, `swift test`, `test:native-protocol`.
- [ ] **Step 5 — commit** `test: live acceptance report`.

## Exit Evidence

Acceptance report with per-command results + cleanup/overlay checks + display-geometry notes; default suites still green. **No claim of live correctness without this report.**

## Carry-forward

The live evidence Stage L's release-readiness review requires to distinguish automated vs. live coverage.
