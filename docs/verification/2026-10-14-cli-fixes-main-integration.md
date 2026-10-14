# CLI fixes composed-candidate verification — 2026-10-14

## Status and limits

**Candidate handoff with a recorded concern under coordinator Ruling3/E2R1:**
all seven ordered composed-tree gates passed. Built
`node ./dist/cli.js --version` exits 0 and prints **0.1.0**, while the package
version is **0.2.0**. `src/cli/run.ts:71` already hardcodes 0.1.0 at the base;
that path is outside this task's exact 21-path scope. The immutable approved
plan's current-package-version artifact expectation is explicitly **NOT
SATISFIED**; an explicit comparison exits 1. Not every artifact check is green.

Ruling3/E2R1 disposes this verified baseline artifact mismatch operationally:
preserve the 21-path scope and unchanged tested code, do not edit the version
source/test or package, and carry the residual to independent review. The
approved spec/plan and helper bindings remain unchanged. This is not a new
version feature, product-scope change, retroactive artifact pass, waiver of a
real bug or release approval. Independent review must adjudicate the residual
against the approved spec; a supported blocking requirement still stops
integration. This resume updates evidence only, without changing gate-tested
source/test/script bytes.

Fresh independent review, local-main integration and integrated-main automated
checks are **PENDING / coordinator-owned**, not proved by candidate exit 0.
Real-app acceptance (Chrome, keyboard, Shopee included) is **user-owned / NOT
RUN by workers/coordinator** and **not an automated or local-integration gate**.
No GUI/input/browser work, live readiness, actual input effect, permission
setup or release approval is claimed. No personal AX records, screenshots or
raw live logs are included.

## Frozen input identities and initial checks

- Main base: `968c958f149cd0580f85d6f893748f622e5e26d4`.
- Fallback origin: `1df5fb4a87e48f49f21e3ec9f8bfe1be93bc86d4`.
- Approved spec SHA-256: `05702e982730c40aeb7b04e715019667829725c7278b324ca03c3733ebe4a124`.
- Approved plan SHA-256: `2f3d6c3448e3bbf30f7d735326ff7aa4ea3476af270d47804413080c96620789`.
- Frozen `existing-fixes.diff`: `1b596a6549639500436c3fa92a0c5b3a726c590c50b38881fd44d38b540102a0`.
- Frozen `fallback.diff`: `da88971bd237b1fb0ac67956131aba0347a5d6c0fbdb8fdf9bac09b1cdb5fd99`.
- Frozen `baseline-hashes.json`: `6af5f55f51282d71bba266d40f2bbb75e9dce57ad190c65d99d05b14bb71625f`.

Input hashes were computed during execution. Approved local spec/plan/input
copies were byte-equal to canonical inputs; the plan task equals the brief.
The supplied W2 baseline was reused, not recreated/transferred. Initially
candidate HEAD/branch matched the assigned base and branch, the index was
empty, and exactly these 15 tracked dirty paths matched their original and
candidate hashes. `git apply --reverse --check existing-fixes.diff` passed.
Original selected index/status and fallback identity/status were recorded
read-only and preserved. The canonical progress ledger was read directly,
never copied or written. Setup/input/dependency helpers are not product paths.

| Frozen working-copy path | Initial original AND candidate SHA-256 |
| --- | --- |
| `native/Sources/ComputerUseCore/AXSnapshotPreparation.swift` | `d6735497ad6e22aaa8954eef6a7f98e8f4f75b5a38f2a5b89abda3e3a904fc1a` |
| `native/Sources/ComputerUseCore/AXTree.swift` | `320913eae4d05cc0cbce6d3c1d78c9b9c4f0d497d832f6002325b0c39cb70a91` |
| `native/Sources/ComputerUseCore/NativeInput.swift` | `b75133e0ad6fb6f0dfc10c83547ac2054088a9756d61347c2cfb3c090ca392ad` |
| `native/Sources/ComputerUseCore/NativeService.swift` | `b18d9e851bded721ac9f9cdd1735dd71609858d85c27b395035d6837437c4c58` |
| `native/Sources/ComputerUseCore/SnapshotCoverage.swift` | `1ca3d379c6d084fc60d15ad353d07084766f818d34eae1c81a7ee093c2d137bd` |
| `native/Sources/ComputerUseCore/SnapshotService.swift` | `118c327f9c8dbc4267adf34142447ef35c66f6cdf7bd9cd61868c91d6727b828` |
| `native/Sources/ComputerUseCore/TargetResolver.swift` | `2b907a624f838e190a0d786dece2a2257c607c1affa8a112e5ffa36ea56d4767` |
| `native/Tests/ComputerUseCoreTests/AXSnapshotPreparationTests.swift` | `8b359168ec4ac76d94039b327838f586c6eaa9ca05251d2bbaf5d83485af7289` |
| `native/Tests/ComputerUseCoreTests/AXTrustTests.swift` | `f81addaabff83afc0c0715159fa34c4adc52eee3a4aea8fbd15ac2afcdc869e0` |
| `native/Tests/ComputerUseCoreTests/DiscoveryTests.swift` | `10ceffe8cbd2286ca455c5103aa8c1a225df26fb4b184031f3f43c24a1d07fc7` |
| `native/Tests/ComputerUseCoreTests/SnapshotTests.swift` | `34cadd642cad1114b681afd733715f63f33c6d905b9975cc9232167851f56e63` |
| `native/Tests/ComputerUseCoreTests/TargetResolverTests.swift` | `ffff6dbe4575bfdafe97044872a5b06cf0ba93d9dfc57eb1e31124f358c9fd4a` |
| `src/backend/macos.ts` | `da43b68e6edfb03eca6825d238432f0b09d113b31500199cba334dbec960ddbe` |
| `src/core/protocol.ts` | `e8e1f6125afc5e3f180bdc822399b66ca58f66f93ff2f0a691d361ca1edce084` |
| `tests/backend-macos.test.ts` | `0a397ee6cf7219ede71eaebbf2165411ffa928bc1530a68c1658e49fed4dfbaf` |

## Composition and corrections (separate origins)

The frozen existing diff has 43 hunks across all 15 paths. Six files remain
byte-identical to their frozen copies: NativeInput, NativeService,
SnapshotCoverage, SnapshotService, src/backend/macos.ts and src/core/protocol.ts.
The other paths retain their original behavior/tests except the specifically
approved safety corrections and additional proof. The prior broad-swallowing
preparation test was renamed to describe actual-write rejection tolerance;
its positive rejection/permission assertions remain. All 11 newly added frozen
Swift tests are retained (including that documented rename).

Every fallback hunk is accounted for:

| Frozen hunk | Composition |
| --- | --- |
| docs/cli.md limitations | Applied exactly before affected docs clarification; AppKit preference, validated kernel fallback, exact source transition and panel limitations retained. |
| TargetResolver.swift metadata overload | Full applicability check failed at constructor context changed by original isRegularApp. Inserted overload locally beside preserved public constructor; retained lazy AppKit-first expression. Explicit flag parameter exposed for runtime RED, then forwarding corrected. |
| TargetResolver.swift KernelProcessStart | Exact block inserted before ProcessLaunchDate, preserving PID/record-size/status/start-time validation. |
| TargetResolver.swift live metadata call | Locally composed AppKit date and kernel closure while retaining activation-policy isRegularApp argument. |
| TargetResolverTests.swift import | Applied Darwin import. |
| TargetResolverTests.swift six tests | Applied all six fallback tests at the missing-launch-date anchor; kept original tests. |
| TargetResolverTests.swift helpers | Applied raw query/invalid-record/metadata/resolver helpers in full. |

No shared source/test file was replaced wholesale and no failed hunk was
omitted or force-applied. The pre-correction composed checkpoint is retained
in local evidence, distinct from these corrections:

- Production-used raw preparation adapter: trust/PID before IPC; strict
  timeout and Boolean-read classification; only actual write statuses
  attributeUnsupported/failure/illegalArgument reject capability; no broad
  NativeFailure catch. Deadline/cancellation and existing enable delay remain.
- Production-used raw batch/cache/reader: only top-level attributeUnsupported
  permits single reads. Malformed success and all hard statuses cache and throw
  without singles; valid entries preserve errors/CFNull/scalar behavior.
- Shared selection confines regular-app tie-breaks to the exact bundle set
  when nonempty. Metadata overload/live caller preserve explicit regular flags.
- Existing publication order, whole-tree stale evidence policy, second
  observation/preflight, action invalidation and no-preparation-during-action
  behavior were not redesigned. Existing eligibility, ref projection, coverage,
  keyboard flag isolation, schema 1 and defaults remain.

## Test-first and retained-behavior proof

Temporary seam-only exposure retained old decisions for RED, with compiling,
discovered XCTest tests. RED means runtime status/call-count/publication or
selection/flag assertion failures, not missing interfaces or compiler errors.

| Focused evidence label | Exit | Discovered result |
| --- | --- | --- |
| preparation-red | 1 | 27 tests, 93 assertions/errors, 4 unexpected throws |
| preparation-green | 0 | 27 tests, 0 assertions/errors, 0 unexpected throws |
| preparation-publication-red | 1 | 18 tests, 128 assertions/errors, 0 unexpected throws |
| preparation-publication-green | 0 | 18 tests, 0 assertions/errors, 0 unexpected throws |
| batch-red | 1 | 23 tests, 40 assertions/errors, 0 unexpected throws |
| batch-green | 0 | 23 tests, 0 assertions/errors, 0 unexpected throws |
| batch-publication-red | 1 | 19 tests, 30 assertions/errors, 0 unexpected throws |
| batch-publication-green | 0 | 19 tests, 0 assertions/errors, 0 unexpected throws |
| flag-red | 1 | 29 tests, 4 assertions/errors, 1 unexpected throws |
| flag-green | 0 | 29 tests, 0 assertions/errors, 0 unexpected throws |
| bundle-red | 1 | 30 tests, 4 assertions/errors, 1 unexpected throws |
| bundle-green | 0 | 30 tests, 0 assertions/errors, 0 unexpected throws |
| discovery-red | 1 | 10 tests, 7 assertions/errors, 0 unexpected throws |
| discovery-green-oracle-corrected | 0 | 10 tests, 0 assertions/errors, 0 unexpected throws |
| retained-final-focused | 0 | 48 tests, 0 assertions/errors, 0 unexpected throws |
| preparation-final-focused | 0 | 28 tests, 0 assertions/errors, 0 unexpected throws |
| ts-coverage-green | 0 | 287 passed |
| hygiene-red | 1 | obsolete source assertion failed after build checks |
| hygiene-green | 0 | all hygiene assertions passed |

Focused commands: `swift test --package-path native --filter` followed by
AXSnapshotPreparationTests, AXTrustTests, TargetResolverTests, DiscoveryTests,
SnapshotTransactionTests or SnapshotTests; TS used
`npm test -- tests/backend-macos.test.ts`; hygiene used
`npm run test:build-hygiene`. Full commands/output/status/counts are in excluded
local evidence, not raw live logs.

Preparation RED exposed swallowed setup/hard writes, ignored timeout status,
read-nil degradation and read-before-validation. Batch RED exposed hard or
malformed success hidden by individually successful reads. Both actual
transaction paths published records after those hidden failures in RED;
GREEN preserves failure, releases the lock and publishes nothing. Rejected
actual-write and complete batch controls publish readable records.

Flag RED observed explicit false becoming true on AppKit/kernel/missing-start
paths and kernel collision ambiguity. Bundle RED selected/queried the
wrong-bundle PID 99. The decoded dispatcher test initially had a separate
**test-oracle defect** (`windowId` instead of existing windows field `id`);
it was diagnosed, paused, and corrected under coordinator resume direction.
That oracle correction is not evidence of a production wire defect or a new
schema requirement. The corrected 10-test Discovery suite is GREEN.

Retained coverage was GREEN on arrival, not fabricated RED: an actual action
transaction dispatches a fresh ref under a completed sibling subtree after a
root maxElements cut (two observations/two preflights/one dispatch, prior
invalidation, zero snapshot preparations). Changed first/fresh evidence rejects
with the existing early-valid/late-invalidated record semantics. Incomplete
and depth-excluded zero-ref evidence rejects before preflight/dispatch.
Forty depth cuts preserve 40 persisted cuts but emit 32 with omitted count 8;
a mixed cut preserves 41, emits 31 depth plus the root element cut and omitted
count 9. TS mock-host replies preserve positive counts and reject malformed
known fields. Keyboard source assertions are supplemental source retention
only, not real event delivery proof.

Hygiene RED reached only the obsolete source assertion after all preceding
build/dist/shebang/executable checks. Exactly two script lines changed: the
originalTool URL to src/cli.ts and its source-preservation message. All checks
then passed unchanged.

## Ordered composed-tree gates

Executed separately and in this exact order against frozen source identities:

| Order | Command | Exit | Result |
| --- | --- | --- | --- |
| 1 | `npm run native-tests` | 0 | 282 Swift tests, 0 failures |
| 2 | `npm run typecheck` | 0 | No TypeScript diagnostics |
| 3 | `npm test` | 0 | 4 files / 395 tests passed |
| 4 | `npm run test:native-protocol` | 0 | 1 file / 5 tests passed; protocol 1 |
| 5 | `npm run test:build-hygiene` | 0 | All hygiene assertions passed |
| 6 | `npm run build` | 0 | TS + release Swift build; both artifacts executable; 8 compiler warnings |
| 7 | `npm test` | 0 | 4 files / 395 tests passed |

The full Swift/TS package suites ran, not only focused filters. Normal generated
dist cleanup occurred only through authorized build scripts. No installation,
package smoke, manual cleanup or live desktop commands ran. Release build
warnings concern existing forced AXValue casts, unused MainActor result,
StateStore trailing closures and DisplayMetadata Sendable conformance; they
were reported, not repaired outside this scope.

Post-build commands: CLI `--help` exits 0 with all 13 commands; native helper
`--protocol-version` exits 0 with `1`; both artifacts have executable bits.
CLI `--version` exits 0 with `0.1.0`, while package.json is `0.2.0`;
the plan's current-package-version expectation is **NOT SATISFIED** and the
explicit comparison exits 1. Ruling3/E2R1 records it as a known, unchanged,
out-of-scope baseline artifact residual for independent review—not as one of
the seven automated gates, an artifact pass or release readiness.

## Tested identities

The excluded local manifest hashes all 72 tracked source/test/script/config/
contract/fixture paths used by the gates (base anchors all other tracked
inputs); its SHA-256 is `ef26a49537781716d2db3d7061dcaff0ed9c9c7a6750fee43df4065f78bef72e`.
All 72 were rechecked after build/artifact checks and still match. Changed
source/test/script paths are listed below; documentation/evidence edits do not
alter them. No self-referential candidate commit identity is embedded here.

| Tested changed path | SHA-256 |
| --- | --- |
| `native/Sources/ComputerUseCore/AXSnapshotPreparation.swift` | `b8a61bc7e09de83f5ac76c42f9674c27c4a5cca6a1ebf73166ed0b09bc15f15d` |
| `native/Sources/ComputerUseCore/AXTree.swift` | `5cee7cfc137e81c24a30c3b0eced8ed33736c0255175500396c9362a5d88f4d6` |
| `native/Sources/ComputerUseCore/NativeInput.swift` | `b75133e0ad6fb6f0dfc10c83547ac2054088a9756d61347c2cfb3c090ca392ad` |
| `native/Sources/ComputerUseCore/NativeService.swift` | `b18d9e851bded721ac9f9cdd1735dd71609858d85c27b395035d6837437c4c58` |
| `native/Sources/ComputerUseCore/SnapshotCoverage.swift` | `1ca3d379c6d084fc60d15ad353d07084766f818d34eae1c81a7ee093c2d137bd` |
| `native/Sources/ComputerUseCore/SnapshotService.swift` | `118c327f9c8dbc4267adf34142447ef35c66f6cdf7bd9cd61868c91d6727b828` |
| `native/Sources/ComputerUseCore/TargetResolver.swift` | `0b728c32e1b4228cac7279237469c778eb44954c084f24b59a5781970defdb40` |
| `native/Tests/ComputerUseCoreTests/AXSnapshotPreparationTests.swift` | `64f41140e5d1020fa3b82e79ce80f584d92f5b607dbbf7f3525bcb9b91e247f5` |
| `native/Tests/ComputerUseCoreTests/AXTrustTests.swift` | `03722ae8c2ff1b97ed8f7189cdf96b5cc245b4fd12ddfb899e4647d5f70bc669` |
| `native/Tests/ComputerUseCoreTests/DiscoveryTests.swift` | `0c561a851f82497fe241d4e8164a2b08f67620de19923a55feaaeaa76028d1bd` |
| `native/Tests/ComputerUseCoreTests/SnapshotTests.swift` | `2bb52b8543d70690f0ba2a7c1f2c72e85a116ece1ffb97eaa2f8fe88824a2fca` |
| `native/Tests/ComputerUseCoreTests/SnapshotTransactionTests.swift` | `e629f765859bcd31b48a4ed4adcecae4385cfd132075846aafccc2081c8b30b3` |
| `native/Tests/ComputerUseCoreTests/TargetResolverTests.swift` | `bf7d3760ca86c342056ef4253ef7e6eeb98deb1b07326e391a3827a3b6353833` |
| `scripts/test-build-hygiene.mjs` | `9a625e5a1b6eb9b6600f926efea2f063b6bddab55f340779ec86f6f5b017a876` |
| `src/backend/macos.ts` | `da43b68e6edfb03eca6825d238432f0b09d113b31500199cba334dbec960ddbe` |
| `src/core/protocol.ts` | `e8e1f6125afc5e3f180bdc822399b66ca58f66f93ff2f0a691d361ca1edce084` |
| `tests/backend-macos.test.ts` | `46ea00ddd8c66f251e051de9cd88ba00bf94837c5c5bd692530b634ee51a1ce2` |

## Handoff

Only the exact 21 authorized product paths are eligible for the checked local
candidate commit; copied inputs, helpers, dependency symlink, generated output,
configuration and pre.json remain excluded. The resulting commit identity is
recorded in the excluded local report, not self-referentially in this note.
Original 15 byte hashes and original/fallback HEAD/index/status were rechecked
unchanged. The same 72 tested input identities remain bound to the seven gate
results after this evidence-only update.

The known baseline version residual remains explicit under Ruling3/E2R1 and
requires independent review's adjudication against the approved spec. Fresh
review and main automated delivery remain **PENDING / coordinator-owned**;
user-owned real-app acceptance stays **NOT RUN** and is not an integration
gate. This note and compact patch changeset do not grant independent review,
live acceptance or release approval.
