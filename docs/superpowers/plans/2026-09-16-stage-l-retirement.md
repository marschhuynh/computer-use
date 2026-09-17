# Stage L — Authorized Retirement and Release-Readiness Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Retire the restored `src/tools/`/`src/ports.ts`/`ComputerUseTool` surface and its tests — the old agent-tool API — after the new CLI has full behavioral counterparts and live acceptance evidence, then run the ordered release-readiness review.

**Architecture:** Produce an exact old-source/test replacement inventory, get **explicit deletion authorization**, remove the dead surface, and run the final verification sequence in order. Historical plans and `integration-reference/` stay as archival references, not supported surfaces.

**Tech Stack:** TypeScript + git cleanup.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md`. **Roadmap slice:** Stage L. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **Deletion requires explicit user authorization** — produce the inventory first, ask permission, then delete.
- Removal only *after* every old behavior has a new-CLI counterpart and Stage K's live report exists.
- `integration-reference/` and historical plans remain **archival**, clearly marked.
- Final verification runs in a fixed order; the whole-branch review distinguishes automated evidence from live evidence.
- **No merge/push/publish/signed distribution** without separate instruction.

## File Structure (removed, not created)

| Path | Action |
|---|---|
| `src/tools/ComputerUseTool.ts`, `src/tools/types.ts`, `src/tools/computer/*`, `src/tools/computer/ax-helper/*` | delete (after authorization) |
| `src/ports.ts` | delete (after authorization) |
| `tests/computer-use-tool.test.ts`, `tests/computer-use-backend.test.ts`, `tests/backend-macos.test.ts` (old-surface parts) | delete/trim obsolete cases |
| `README.md`, `docs/` references to the old tool | update to CLI-first |

## Interfaces

**Consumes:** the entire new CLI (Stages D–K). The old `FunctionTool`/`ComputerBackend`/`ExecResult` contract is deleted, not ported — hosts adapt the CLI, not a tool interface.

**Produces:** a repo whose only computer-use surface is the standalone CLI.

---

### Task L1: replacement inventory + authorization

- [ ] **Step 1 — enumerate** every old-source/test file and map each to its new-CLI counterpart (e.g. `ComputerUseTool.press` → `nuvin-computer-use press`).
- [ ] **Step 2 — present inventory** to the user and get explicit deletion authorization.

### Task L2: delete old surface

- [ ] **Step 1 — remove** `src/tools/**`, `src/ports.ts`, obsolete tests.
- [ ] **Step 2 — confirm** no runtime import of the old surface remains (`grep -r "tools/ComputerUseTool\|ports.js\|FunctionTool" src dist`).
- [ ] **Step 3 — commit** `chore: retire restored agent-tool surface`.

### Task L3: ordered release-readiness review

- [ ] **Step 1 — run in order:** `npm run typecheck` → `npm test` (mocked) → `swift test --package-path native` (pure) → `npm run test:native-protocol` (fresh) → `npm run build` → `node scripts/package-smoke.mjs`.
- [ ] **Step 2 — assert** no old-runtime imports, home-helper lookup, base64 tool envelope, unchecked AppleScript, semantic-coordinate fallback, or full-desktop recovery remains.
- [ ] **Step 3 — whole-branch review** distinguishing automated vs. live evidence.
- [ ] **Step 4 — commit** `chore: release-readiness verification`.

## Exit Evidence

Ordered suite output green; no residual old-surface references; a review note separating what was proven automatically vs. live (Stage K). **Nothing is merged/pushed/published without explicit instruction.**

## Carry-forward

Repo is v1-clean: single CLI surface, full test evidence, documented live acceptance.
