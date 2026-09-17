# Stages E–L — Shared Contract & Interface-Vocabulary Preamble

> Read this before any Stage E–L plan. It defines the shared types, invariants,
> and the interface-confirmation rule that applies to every stage.

## Authority

`../specs/2026-09-08-standalone-cli-design.md`,
`../specs/2026-09-08-foundation-recovery-design.md`, and the
`2026-09-08-standalone-cli-continuation-roadmap.md`.

## ⚠️ Gate / interface-confirmation rule (applies to E–L)

These plans are written **ahead of their entry evidence** (the roadmap intends
each stage plan to be generated only when the prior stage is approved). Two
consequences:

1. **New type/function names in Stages E–L are *proposed*, not existing.** They
   are the minimal surface needed to satisfy the spec; a stage implementer must
   confirm them against the then-current source before writing code. Where the
   exact signature is uncertain, the plan says `// CONFIRM AT GATE:` and states
   the required *behavior*, not a fabricated signature.
2. **Existing surfaces are cited with `file:line` and marked `(existing)`.**
   Anything marked `(proposed)` does not exist yet and is frozen by that stage's
   own contract decision, not by fiat here.

## Invariants every stage must preserve (public floors)

- Node 22+, Swift 5.9 / language v5, macOS 14+.
- Default deadline 15,000 ms; accepted timeout integer 1–120,000 ms (TS + Swift).
- Cancellation cleanup grace 2,000 ms.
- State records: 10-minute lifetime, root `~/Library/Application Support/nuvin-computer-use/`, dirs `0700`, files `0600`.
- Request line ≤ 1 MiB (HostSupport.swift:5), reply ≤ 16 MiB (macos.ts), stderr ≤ 64 KiB.
- No daemon, no private SkyLight APIs, no automatic mutation retry, no
  semantic→coordinate fallback, no implicit last-target state.

## Shared wire vocabulary (existing — `Protocol.swift`, `src/core/protocol.ts`)

- `WireCommand`: `doctor, apps, windows, snapshot, press, set-value, type, key, scroll, screenshot, click, move, drag`.
- `MutationStatus`: `notStarted | potentiallyApplied`.
- `JSONValue` (Swift) ↔ `JsonValue` (TS). Reply envelope `{schemaVersion:1, ok, command, data|error}`.
- Error codes + exit classes: `contracts/errors.json`.
- Snapshot record shape: `SnapshotRecord` (StateStore.swift:7-16) — `version, kind, id, createdAt, expiresAt, target, treeOptions, evidence, invalidated`.

## Shared target/AX vocabulary (existing)

- `TargetSelector` (`.app(name,windowId)` / `.pid(pid,windowId)`), `ResolvedTarget{identity,title,bounds}`, `TargetIdentity{pid,launchDate,bundleId,windowId}` — `TargetResolver.swift`.
- `TreeOptions{maxDepth,maxElements,hintMode}`, `HintMode{full,leafOnly,leafCompact}` — `AXTree.swift`.
- `CommandContext` deadline/cancellation — `CommandContext.swift`.
- `DesktopLock.withLock` — `DesktopLock.swift`.
- `SnapshotService.withValidatedSnapshotAction` — `SnapshotService.swift:107` — the seam every ref-action goes through.

## Cross-cutting result vocabulary

Every mutation reply carries `{target, method, verification, visualization}`:
- `method` ∈ controlled set (currently `{"accessibility"}`; Stage F/G add `{"cg-event","screen-capture"}` — update `CONTROLLED_RESULT_VALUES` in `macos.ts` **and** the matching Swift emission in the same commit).
- `verification` ∈ `{"verified","unverified","partial"}` (extend with Stage F).
- `visualization` ∈ `{"none","approach","pulse","drag"}` (Stage H).
- `type` may add `clipboardReplaced: Bool`.
- Every mutation error must include `details.mutationStatus` ∈ `{notStarted, potentiallyApplied}` internally; the TS projector re-derives the public value.

## Record kinds (unified in Stage E)

`SnapshotRecord.kind` already exists (`StateStore.swift:9`). Stage E adds
`"capture"` records; `invalidateRecords` invalidates *both* kinds for the target
app. One StateStore — do not fork per kind.
