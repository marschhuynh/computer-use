# Release-Readiness Review — 2026-09-17

Stage L ordered verification + whole-branch review separating automated from
live evidence. **Not merged/pushed/published** — awaiting separate instruction.

## Ordered verification (all green)

| Step | Command | Result |
|---|---|---|
| 1 | `npm run typecheck` | clean |
| 2 | `npm test` (vitest, mocked) | 159 passed |
| 3 | `swift test` (XCTest, fixtures) | 151 passed |
| 4 | `npm run test:native-protocol` | 5 passed |
| 5 | `npm run build` | clean (TS + release host) |
| 6 | `node scripts/package-smoke.mjs` | isolated install → bundled helper protocol 1, doctor ok |

(159 not 272: the two deleted old-surface test files carried 113 cases for the
retired `ComputerUseTool`/cliclick backend — correctly removed with it.)

## Automated evidence

- Reply projection, exit-code mapping, flag parsing, JSON purity, supplied-text
  echo-stripping — mocked, deterministic.
- AX resolution, snapshot/capture records, state store (lock, atomic write,
  expiry, sweep, fail-closed invalidation), capture geometry, cursor timeline —
  XCTest fixtures.
- Host JSON-lines protocol over real stdio — protocol suite.
- Packaging: `files` whitelist, `prepack` build, shebang+exec `dist/cli.js`,
  helper resolved from inside the package (no `~/.nuvin`).

## Live evidence (this session, authorized)

Per `docs/verification/2026-09-17-acceptance.md`: all 13 commands exercised
against the disposable `CUFixture` app. `press`/`set-value` verified via AX,
`type`/`key`/`scroll`/`click`/`move`/`drag` via CGEvent, `screenshot` +
`--annotated` produce window-tight PNGs (annotated carries ref badges).

## Live-driven fixes (committed `7cbc82a`, `faaa5d1`)

Overlay main-thread crash · PNG encode buffer · window-tight capture geometry ·
capture-record timestamp · click pointer-arrive+interval · type pacing ·
degenerate-AX-tolerance · `--annotated` ref badges.

## Review findings — resolved as *not bugs*

Both earlier findings are deliberate fail-closed/forward-compat design,
confirmed by tests:

- **`StateStore.invalidateRecords` throwing on a malformed record** — intended
  fail-closed: a record that can't be decoded can't be verified to belong to a
  safe app, so invalidation aborts rather than silently skip. Enforced by
  `testInvalidationFailsClosedForUnreadableRecognizedRecord` +
  `testTransientReadFailureCannotBeSkippedDuringInvalidation`. A poison record
  blocks mutation for *all* apps — conservative, not a defect.
- **`projectResultValue` whitelist** — `CONTROLLED_RESULT_VALUES` is not a
  membership gate; it fast-paths known values and strips any value that echoes
  supplied text. Unknown values pass through deliberately (forward-compat), per
  `future-result-values` test. Correct as-is.

## Known limitations (documented in cli.md)

Login-launched apps + `openAndSavePanelService` untargetable (no `launchDate`);
off-Space/minimized windows; `press`/`set-value` success = accepted, not
visibly confirmed; `scroll --ref` needs `AXScrollToVisible`-capable refs.

## Carry-forward / not done

- No merge, push, publish, or signing — separate instruction required.
- Multi-display/negative-origin transforms untested.
- Mid-drag interruption + parent-kill cleanup not exercised live.
- `pnpm-lock.yaml` is an untracked stray alongside `package-lock.json` — the
  project uses npm; left for the owner to remove or adopt.
