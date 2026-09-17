# Stage J — Package and Source-Install Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use `- [ ]` tracking.

**Goal:** Make `nuvin-computer-use` a self-contained npm executable — the installed package resolves its own Swift helper, `dist/cli.js` is executable with a shebang, the tarball contains no agent/dev artifacts, and permissions/source-build docs exist.

**Architecture:** `package.json` `bin` → `dist/cli.js`; helper resolved package-relative (not `~/.nuvin`). A `package-smoke` script builds a tarball, installs into an isolated prefix with scripts disabled, and runs help/version/doctor to prove helper discovery works without a global install.

**Tech Stack:** npm packaging, `npm pack`/`npm install --prefix`, Node 22.

**Spec:** `../specs/2026-09-08-standalone-cli-design.md` §Packaging and permissions. **Roadmap slice:** Stage J. **Shared contract:** `2026-09-16-stages-e-l-shared-contract.md`.

## Global Constraints

- Helper resolves from the installed package, **not** a pre-existing `~/.nuvin/bin/ax-helper`.
- `dist/cli.js` emitted with shebang **and** execute bit (current gap: `tsc` emits `0644`).
- Tarball contains `dist/`, `native/`, `docs/` — no `node_modules`, state, `src/tools`, `fixtures`, or tests.
- `doctor` used in smoke must be read-only and work without AX permission.
- Unsigned/source-built identity limits documented honestly; **do not publish**.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/package-smoke.mjs` | NEW — pack → isolated install → help/version/doctor smoke |
| `scripts/build-native.mjs` | ensure helper lands under `dist/native/` for packaging |
| `package.json` | `bin`, `files`, prepack build hook |
| `src/cli.ts` | shebang + exec-bit handling at build |
| `scripts/test-build-hygiene.mjs` | extend: assert shebang + `+x` on `dist/cli.js` |
| `docs/cli.md`, `docs/permissions.md`, `docs/testing.md` | user-facing docs |
| `tests/package.test.ts` | NEW — manifest/shebang/contents assertions |

## Interfaces

**Consumes:** full CLI from Stage I; `MacOSBackend` helper path resolution (`src/backend/macos.ts` `import.meta.url` — confirm it resolves to the packaged `dist/native/computer-use-host`).

**Produces:** `nuvin-computer-use` command available after `npm install`/`npm link`; documented install + permission flow.

---

### Task J1: executable CLI entry

- [ ] **Step 1 — failing test:** `dist/cli.js` starts with `#!/usr/bin/env node` and is `+x` after `npm run build`.
- [ ] **Step 2 — FAIL → Step 3 — implement** shebang already in `src/cli.ts:1`; emit `+x` via build step (clean-dist or a postbuild chmod) and assert in `test-build-hygiene.mjs`.
- [ ] **Step 4 — PASS → Step 5 — commit** `fix: emit executable cli.js with shebang`.

### Task J2: package manifest + tarball contents

- [ ] **Step 1 — failing test:** `npm pack --dry-run` lists only `dist/`, `native/`, `docs/`; no `node_modules`/`src/tools`/`fixtures`/tests.
- [ ] **Step 2 — FAIL → Step 3 — implement** `files` whitelist + `prepack` build; `bin` → `dist/cli.js`.
- [ ] **Step 4 — PASS → Step 5 — commit** `feat: package manifest and tarball contents`.

### Task J3: isolated-install package smoke

- [ ] **Step 1 — failing test/script:** `scripts/package-smoke.mjs` — pack, `npm install --prefix <tmp> --ignore-scripts`, run `<tmp>/bin/nuvin-computer-use --version`, `doctor --json`, `apps --json`; assert helper resolves and protocol version matches.
- [ ] **Step 2 — FAIL → Step 3 — implement** smoke script + fix helper-path resolution if it leaks `~/.nuvin`.
- [ ] **Step 4 — PASS → Step 5 — commit** `test: isolated-install package smoke`.

### Task J4: docs

- [ ] **Step 1 — write** `docs/permissions.md` (AX + Screen Recording attribution for terminal/launcher + helper, unsigned/source-built limits), `docs/testing.md` (suite matrix + live-acceptance gating), and refresh `docs/cli.md` to reflect all implemented commands.
- [ ] **Step 2 — commit** `docs: permissions, testing, and cli reference`.

## Exit Evidence

Installed helper discovery works with no global/home helper; tarball has no node_modules/state/legacy tool; docs state host architecture, unsigned/source-built limits, foreground-pointer warning, `--cursor off` semantics, protected-text input advice, and private evidence retention. **Do not publish.**

## Carry-forward

A package users can install + the docs Stage K's acceptance report and Stage L's release review reference.
