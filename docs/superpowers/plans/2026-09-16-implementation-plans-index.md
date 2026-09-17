# Standalone CLI — Implementation Plan Index (D–L)

> Execution order and dependencies for the staged implementation of
> `nuvin-computer-use`. Read `2026-09-16-stages-e-l-shared-contract.md` first.

## Prerequisites

Read in this order before any stage:
1. `../specs/2026-09-08-standalone-cli-design.md` — the contract.
2. `../specs/2026-09-08-foundation-recovery-design.md` — the foundation amendment.
3. `2026-09-08-standalone-cli-continuation-roadmap.md` — stage definitions + gates.
4. `2026-09-16-stages-e-l-shared-contract.md` — shared vocabulary + the
   **interface-confirmation rule** (proposed vs. existing types).

## Stage plans

| # | Plan | Commands delivered | Depends on |
|---|---|---|---|
| D | `2026-09-16-stage-d-discovery.md` | `apps`, `windows`, truthful `doctor` | foundation (done) |
| E | `2026-09-16-stage-e-capture-geometry.md` | `screenshot` (+annotated), `CaptureRecord`, `Geometry` | D |
| F | `2026-09-16-stage-f-foreground-execution.md` | `press`, `set-value`, `type`, `key`, `scroll` | D |
| G | `2026-09-16-stage-g-mouse-routes.md` | `click`, `move`, `drag` | E + F |
| H | `2026-09-16-stage-h-cursor-lifecycle.md` | cursor overlay + full lifecycle | F + G |
| I | `2026-09-16-stage-i-coordinator-output.md` | full dispatch, caps, human output | D–H |
| J | `2026-09-16-stage-j-package-docs.md` | npm package + docs | I |
| K | `2026-09-16-stage-k-live-acceptance.md` | authorized live acceptance | J |
| L | `2026-09-16-stage-l-retirement.md` | retire old tool surface + release review | K |

```
foundation ──► D ──► E ──┐
              └─► F ──► G ──► H ──► I ──► J ──► K ──► L
                  (F needs D only; G needs E+F; H needs F+G)
```

## Carried interfaces (the seams between stages)

- **D → all:** `listApplications`, `listWindows`, `AppSummary`/`WindowSummary`, lock-free `doctor`.
- **E → G:** `CaptureRecord`, `CaptureGeometry`, `imageToScreen`/`screenToImage`, `kind:"capture"` in `StateStore`.
- **F → G,H:** `NativeInputDriver`, `ForegroundExecutor`, `ExecutionResult`, `KeyChord`, `MouseButton`.
- **H → I:** `CursorRenderer`, `ActionTimeline`, `Visualization` (`approach`/`pulse`/`drag`).
- **G → I:** `resolveCapturePoint`, mouse `click`/`move`/`drag` driver methods.

## ⚠️ Two caveats on this plan set

1. **Written ahead of gates.** The roadmap intends each stage plan to be
   generated only when its entry evidence exists. Stages D is entry-ready;
   E–L are pre-written so the whole sequence is visible — but their proposed
   types (`CaptureGeometry`, `NativeInputDriver`, `CursorRenderer`, …) are marked
   `CONFIRM AT GATE` and must be reconciled with actual source at that stage's
   entry, not assumed.
2. **Granularity.** D is detailed to per-task test-code level (entry-ready).
   E–L are one notch coarser — each task has files/interfaces/RED→GREEN→commit
   and literal test intent, but exact fixture bodies and full test code are left
   to that stage's own gate-derived detail, to avoid inventing interfaces the
   prior stage hasn't yet frozen. If you want E–L at the same literal-code
   depth as D, that's a follow-up pass.

## Verification floor (applies to every stage)

`npm run typecheck` · `npm test` · `swift test --package-path native` ·
`npm run test:native-protocol` · `npm run build` — all green before a stage is
called done. Live input never runs without Stage K's explicit authorization.
