# Stable releases

`.github/workflows/release.yml` runs macOS CI on pull requests and pushes to
`main`: typechecking, unit tests, fixture-based Swift tests, non-GUI native
protocol tests, build hygiene, TypeScript and release Swift builds, and actual
pnpm publish-archive/executable checks. These checks do not grant or verify
Accessibility or Screen Recording permissions, or prove live desktop input
delivery. `changeset status --since HEAD` validates Changesets configuration
without requiring a base branch in shallow PR checkouts. It does not validate
the pending release plan or enforce changeset coverage; consumed version PRs
are valid. This probe assumes CI's clean checkout; uncommitted local package
edits can still trigger the CLI's changed-package policy. Use plain
`pnpm exec changeset status` with a local `main` ref to inspect the full pending
release plan. All PRs and main pushes still run every test/build/package gate.

## Contributor flow

Use Node.js 24 and pnpm 10.19.0 for release tooling:

```sh
pnpm install --frozen-lockfile
pnpm changeset
```

Commit the generated changeset with the code change. On `main`, after the full
CI job succeeds for that same SHA, `changesets/action@v1` creates or updates a
single **Version Packages** PR. Its version command updates the package,
changelog, and both tracked lockfiles. The existing npm lockfile is retained
for npm users; CI installs from the pnpm lockfile.

Review and merge that PR. Full CI runs again on the merge SHA; only then can
the main-only release job publish an unpublished package version to npm
`latest`. It rebuilds the native host on macOS before publishing. There is no
RC flow, manual publish trigger, `NPM_TOKEN`, or CI bypass for version PRs.
Main runs are serialized and in-flight releases are not cancelled. Do not run
`pnpm release` locally as a verification command: it publishes.

## One-time administrator setup (not performed by this change)

1. In GitHub repository `marschhuynh/nuvin-computer-use`, enable Actions and
   allow **GitHub Actions to create and approve pull requests** under
   Settings → Actions → General → Workflow permissions. Repository policy
   must permit the workflow's explicit `contents: write` and
   `pull-requests: write` permissions. No personal access token is needed.
2. Protect `main` with the **macOS CI** required status check and require PR
   review as appropriate. Version PRs created with `GITHUB_TOKEN` do not
   automatically trigger other workflows. If their required check is absent,
   close and reopen the PR as a maintainer to trigger `pull_request` CI;
   do not bypass the check. The merge push always runs the full gate again.
3. In npm settings for **@nuvin/computer-use**, add a **GitHub Actions** trusted
   publisher with these exact values:
   - Organization or user: `marschhuynh`
   - Repository: `nuvin-computer-use`
   - Workflow filename: **`release.yml`** (not a path, and not `publish.yml`)
   - Environment name: leave blank (this workflow does not use an environment).
   - Under **Allowed actions**, enable **Allow npm publish**. New trusted
     publishers default to staged publishing; this workflow uses direct
     publishing, not `npm stage publish`. Dist-tag management permission is
     not needed for publishing a new version with `--tag latest`.
   See npm's [trusted publishing configuration documentation](https://docs.npmjs.com/trusted-publishers/#configuring-trusted-publishing).
4. Trusted publishing requires an existing npm package and permission to
   configure it. If the scoped package does not yet exist, an authorized
   maintainer must bootstrap it separately and then configure the trusted
   publisher; this workflow does not introduce a token-based fallback.
   After OIDC works, revoke obsolete publishing tokens and, where supported,
   disallow token publishing in npm's package access settings.

The release job alone receives `id-token: write`. Node 24 supplies a modern
npm; the workflow explicitly requires npm **>=11.5.1**, the trusted publishing
minimum (Node >=22.14.0). No npm auth token or registry auth setup is required.
GitHub-hosted runners provide the OIDC identity; npm automatically generates
provenance for trusted publishing. Repository and package metadata must
continue to match the trusted publisher identity. No setup above is performed
by a local build or dry run.

## Platform and local validation

The workflow uses the GitHub-hosted `macos-15` Apple Silicon runner and fails
if its architecture is not `arm64`. SwiftPM requires Swift >=5.9 and the macOS
14+ SDK/runtime APIs; the runner's Xcode supplies the compiler and SDK.
The package retains Node >=22 and macOS 14+ runtime requirements. The bundled
host is **arm64 only**, not universal: this release does not provide an Intel
host or multi-architecture packaging. CI on macOS 15 does not independently
prove execution on macOS 14. Do not claim Intel support from the npm `os`
metadata, which only restricts the operating system.

Safe local checks (none publish):

```sh
pnpm install --frozen-lockfile
pnpm exec changeset status --since HEAD
pnpm run typecheck
pnpm test
pnpm run native-tests
pnpm run test:native-protocol
pnpm run test:build-hygiene
pnpm run build
npm pack --ignore-scripts --dry-run --json
```

`--ignore-scripts` is only for the npm manifest check after the explicit build;
Swift's prepack build output otherwise mixes with JSON stdout. That manifest
is not proof of pnpm publisher permissions. Changesets detects the pnpm
lockfile and publishes via pnpm 10.19.0, which normalizes archive file modes.
`publishConfig.executableFiles` preserves the native host's executable mode.

CI also runs `pnpm pack --out "$RUNNER_TEMP/computer-use.tgz"` (including
`prepack`), extracts the actual archive into a temporary directory, asserts
both `dist/cli.js` and `dist/native/computer-use-host` have mode **0755**, and
runs their non-GUI help/version/protocol probes from that extracted package.
To repeat locally, use a temporary output directory for `pnpm pack --out`,
then inspect with `tar -tvzf` or execute the same packaging step from the
workflow. No pack command publishes.

For workflow linting, run
`actionlint .github/workflows/release.yml` when actionlint is available.
Local checks cannot exercise GitHub permissions, PR creation, branch protection,
or the npm OIDC exchange; confirm those on the first authorized GitHub run.
