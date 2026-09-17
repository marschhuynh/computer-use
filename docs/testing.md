# Testing

How to verify `nuvin-computer-use` — and, just as important, what each layer
does *not* prove.

## Suite matrix

| Command | Layer | What it covers | Needs |
|---|---|---|---|
| `npm run typecheck` | TypeScript | static types across `src/` | nothing |
| `npm test` | vitest, `tests/*.test.ts` | CLI flag parsing, JSON stdout purity, reply projection, exit-code mapping, backend timeout/cancel/malformed-reply handling — all fully mocked, no system calls | nothing |
| `npm run native-tests` | Swift XCTest, `native/Tests/ComputerUseCoreTests` | discovery/target resolution, snapshot records, state store (locking, atomic write, expiry, sweep), capture geometry, cursor timeline — against AX **fixtures**, no live desktop | macOS + Swift toolchain |
| `npm run test:native-protocol` | `scripts/native-protocol-tests.mjs` | builds the host and exercises the JSON-lines request/reply protocol over real stdio | macOS |
| `npm run test:build-hygiene` | `scripts/test-build-hygiene.mjs` | `dist/` has no stale artifacts; `cli.js` has shebang + exec bit | after `npm run build` |
| `node scripts/package-smoke.mjs` | end-to-end packaging | `npm pack` → isolated `npm install --prefix` → installed bin runs `--version`, `--help`, `doctor`; resolves the **bundled** helper (protocol 1) with no `~/.nuvin` install | macOS, network for npm |

## What unit tests do *not* prove

Per the design spec: **unit tests alone do not prove native input routing or
permission setup.** The vitest suite mocks the helper; the XCTest suite runs
against fixtures; the protocol tests run the real host but with scripted
requests. None of them prove that a `CGEvent` actually lands in a real app's
window, that TCC granted the launcher, or that the overlay draws.

Do not report live verification as done unless it was **explicitly authorized
and run against a real app** (see Stage K live acceptance).

## Live acceptance (opt-in, macOS)

Live checks require a real desktop and explicit authorization — they move the
physical pointer, change focus, and post real input. They are **not** part of
`npm test`. To run them, see the Stage K plan
(`docs/superpowers/plans/2026-09-16-stage-k-live-acceptance.md`), which
specifies:

- `snapshot` → `press`/`set-value` against a fixture app window
- `key`, `type` (incl. Unicode), directional `scroll`
- `screenshot` + `click`/`move`/`drag` on `--capture` coordinates
- visible cursor feedback, documented physical-pointer/foreground behavior,
  and no leftover overlay or held input after cancellation

## Notes for contributors

- **Host protocol quirk:** the Swift host holds stdin open while processing.
  When scripting against `computer-use-host` directly, keep stdin open until
  the reply arrives — closing it early triggers `ParentEOFObserver` and
  cancels the command.
- **Snapshot state:** tests that write state use a temporary root; real
  invocations write to `~/Library/Application Support/nuvin-computer-use/`
  (owner-only). Snapshot/capture records contain visible text — treat as
  sensitive.
- **Timeout:** the Swift suite and native-protocol tests build the host
  first — allow several minutes on a cold build.
