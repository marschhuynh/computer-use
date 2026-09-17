# Stage I — Full Coordinator, Content Limits, and Public Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Remove the `UNSUPPORTED_ACTION` catch-all — wire a complete command dispatch table, enforce content/request size limits end-to-end, finalize per-command human output, and complete the partial-execution/status acceptance matrix.

**Architecture:** `NativeService.execute` gains one lock owner and a complete `switch` over all 13 `WireCommand`s (no `default`). TS `parse`/`run`/`output` get the 1 MiB input cap, per-command formatters, and the status matrix. This stage closes the gaps the earlier stages left (e.g. text >1 MiB reaching the host as `PROTOCOL_ERROR` instead of a clean `INVALID_ARGUMENT`).

**Tech Stack:** Swift 5.9 + Node 22 / TypeScript.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Results and exit codes. **Roadmap slice:** Stage I. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- **No generic unsupported branch** remains for a supported combination.
- **1 MiB text cap** for `--text`/`--text-file`/stdin — enforce in TS *before* the request reaches the host (fixes review finding: oversized text currently becomes `PROTOCOL_ERROR`).
- **2 MiB request / 16 MiB response caps** in both processes; reject oversize *before* unsafe parse/dispatch.
- **Absolute screenshot path**; no request text/argv in diagnostics.
- Per-command human formatting with control-char escaping; JSON purity.
- Partial-execution/timeout/`mutationStatus` acceptance matrix is complete.

## File Structure

| File | Responsibility |
|---|---|
| `native/Sources/ComputerUseCore/NativeService.swift` | complete dispatch table, single lock owner, size caps |
| `native/Sources/ComputerUseHost/HostMain.swift` | request-line cap enforcement |
| `src/cli/parse.ts` | 1 MiB text cap → `INVALID_ARGUMENT` |
| `src/cli/run.ts` | caps wiring + status matrix |
| `src/cli/output.ts` | final per-command formatters |
| `contracts/fixtures/native-replies.json` | complete per-command success/error fixtures |

## Interfaces

**Consumes:** every command implementation from Stages D–H; `CONTROLLED_RESULT_VALUES` + `projectReply` (existing); `errors.json` exit map.

**Produces:** final public result surface — no further `method`/`verification`/`visualization` vocabulary additions after this stage without a protocol-version bump.

---

### Task I1: complete dispatch table + single lock owner

- [ ] **Step 1 — failing test:** every `WireCommand` routes to its handler; none hit `default`; read-only commands (`doctor`/`apps`/`windows`) skip the lock, mutating commands hold it.
- [ ] **Step 2 — FAIL → Step 3 — implement** full `switch` + remove `default` unsupported branch.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: complete command dispatch table`.

### Task I2: 1 MiB text cap in the CLI

- [ ] **Step 1 — failing test:** `--text-file` >1 MiB → `INVALID_ARGUMENT` exit 2 (not `PROTOCOL_ERROR`); stdin `-` capped the same.
- [ ] **Step 2 — FAIL → Step 3 — implement** cap in `resolveText`/`parse` + `readStdin` bound in `cli.ts`.
- [ ] **Step 4 — PASS → Step 5 — commit** `fix: cap text input at 1 MiB`.

### Task I3: request/response caps in both processes

- [ ] **Step 1 — failing test:** >2 MiB request line rejected pre-parse; >16 MiB reply rejected; oversize fails closed.
- [ ] **Step 2 — FAIL → Step 3 — implement** `BoundedLineReader` request cap (already 1 MiB — confirm/reconcile with 2 MiB spec) + TS reply bound.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: enforce protocol size caps`.

### Task I4: human output + privacy

- [ ] **Step 1 — failing test:** absolute screenshot path required; no request text/argv in any diagnostic; control chars escaped; JSON mode pure.
- [ ] **Step 2 — FAIL → Step 3 — implement** per-command formatters + path validation + diagnostic privacy.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: final human output and privacy`.

### Task I5: status acceptance matrix

- [ ] **Step 1 — failing test:** table-driven matrix — every command × {success, each error code, timeout, interrupt} → expected exit + `mutationStatus`.
- [ ] **Step 2 — FAIL → Step 3 — implement** matrix tests; fix any mismatch surfaced.
- [ ] **Step 4 — PASS → Step 5 — commit** `test: full status acceptance matrix`.

## Exit Evidence

Every command has complete success/error fixtures through CLI→backend→native seams; negative preflight/status tests; bounded input/output tests. Trusted-only diagnostic/privacy limits documented honestly (no semantic reviewer implied).

## Carry-forward

All 13 commands behave per the public contract — the input to Stage J (package them) and Stage K (prove them live).
