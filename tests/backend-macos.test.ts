import { chmod, copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { MacOSBackend } from '../src/backend/macos.js';
import { backendForPlatform } from '../src/cli.js';
import { formatReply } from '../src/cli/output.js';
import { DEFAULT_TIMEOUT_MS, type Request } from '../src/core/protocol.js';

const mockHost = new URL('../fixtures/cli/mock-host.mjs', import.meta.url);
const snapshotReplyModes = [
  'snapshot-reply-invalid-id',
  'snapshot-reply-invalid-target',
  'snapshot-reply-invalid-tree',
  'snapshot-reply-invalid-created-at',
  'snapshot-reply-invalid-lifetime',
];
const modes = [
  'valid-response', 'invalid-json', 'wrong-command', 'invalid-response-data',
  'failure-missing-command', 'failure-wrong-command', 'incompatible-version',
  'execution-spawn-failure', 'nonzero-exit', 'success-then-exit-1',
  'never-exits', 'exits-after-receiving-request', 'ignores-sigterm',
  'requires-open-stdin', 'stdout-overflow', 'stderr-overflow',
  'request-on-stderr', 'reflected-success-data', 'reflected-root-target',
  'reflected-reordered-subtree', 'reflected-method', 'reflected-verification',
  'reflected-visualization', 'future-result-values', 'type-result', 'invalid-type-result',
  'reflected-error-message', 'reflected-error-details', 'reflected-root-error-details',
  'stable-error-code', 'unknown-error-code', 'slow-version', 'mutation-status',
  'target-not-found', 'focus-failed',
  'snapshot-reply-valid', ...snapshotReplyModes,
];
let fixtureDirectory: string;

function fixture(mode: string): string { return join(fixtureDirectory, mode); }
function appsRequest(timeoutMs = DEFAULT_TIMEOUT_MS): Request {
  return { schemaVersion: 1, command: 'apps', options: { timeoutMs, cursor: 'on' } };
}
function mutationRequest(text: string, timeoutMs = DEFAULT_TIMEOUT_MS): Request {
  return {
    schemaVersion: 1,
    command: 'set-value',
    options: { timeoutMs, cursor: 'on' },
    snapshotId: '123e4567-e89b-42d3-a456-426614174000',
    ref: 1,
    text,
  };
}
function typeRequest(text: string, timeoutMs = DEFAULT_TIMEOUT_MS): Request {
  return {
    schemaVersion: 1,
    command: 'type',
    options: { timeoutMs, cursor: 'on' },
    target: { app: 'TextEdit' },
    text,
    allowClipboardReplace: true,
  };
}
function keyRequest(timeoutMs = DEFAULT_TIMEOUT_MS): Request {
  return {
    schemaVersion: 1,
    command: 'key',
    options: { timeoutMs, cursor: 'on' },
    target: { app: 'Editor' },
    key: 'cmd+s',
  };
}
function snapshotRequest(): Request {
  return {
    schemaVersion: 1,
    command: 'snapshot',
    options: { timeoutMs: DEFAULT_TIMEOUT_MS, cursor: 'on' },
    target: { app: 'Editor', windowId: 7 },
    tree: { maxDepth: 8, maxElements: 500, hintMode: 'full' },
  };
}

let replyFixtureSequence = 0;
async function executeSnapshotReply(reply: unknown, request = snapshotRequest()) {
  const helper = fixture(`snapshot-reply-case-${replyFixtureSequence++}`);
  await copyFile(mockHost, helper);
  await chmod(helper, 0o755);
  await writeFile(`${helper}.json`, `${JSON.stringify(reply)}\n`, { mode: 0o600 });
  return new MacOSBackend({ helper }).execute(request, new AbortController().signal);
}

async function readSnapshotReply(compact = false) {
  return JSON.parse(await readFile(new URL(
    compact ? '../contracts/fixtures/snapshot-compact-reply.json' : '../contracts/fixtures/snapshot-reply.json',
    import.meta.url,
  ), 'utf8'));
}

function screenshotRequest(annotated = true): Request {
  return {
    schemaVersion: 1, command: 'screenshot', options: { timeoutMs: DEFAULT_TIMEOUT_MS, cursor: 'on' },
    target: { app: 'Editor', windowId: 7 }, output: '/tmp/capture.png',
    overwrite: false, native: false, annotated,
    tree: { maxDepth: 8, maxElements: 500, hintMode: 'full' },
  };
}

async function annotatedReply() {
  const reply = await readSnapshotReply();
  reply.command = 'screenshot';
  Object.assign(reply.data, {
    captureId: '123e4567-e89b-42d3-a456-426614174001', path: '/tmp/capture.png', width: 600, height: 400,
    createdAt: '2026-09-08T10:00:01.123Z', expiresAt: '2026-09-08T10:10:01.123Z',
  });
  return reply;
}

async function depthBoundaryReply() {
  const reply = await readSnapshotReply(true);
  reply.data.tree = { elements: [{ role: 'AXWindow', children: [{ role: 'AXStaticText', title: 'Loading' }] }] };
  reply.data.truncated = true;
  reply.data.coverage = {
    scope: 'selectedWindow', absenceIsConclusive: false,
    observedNodes: 3, emittedNodes: 2, refCount: 0,
    limits: { maxDepth: 2, maxElements: 500 },
    boundaries: [{ path: [0, 0], reason: 'maxDepth', observedChildren: 0, totalChildren: 1 }],
    noRefReason: 'traversalLimited',
  };
  return reply;
}

async function elementBoundaryReply() {
  const reply = await depthBoundaryReply();
  reply.data.coverage.observedNodes = 2;
  reply.data.coverage.limits = { maxDepth: 8, maxElements: 2 };
  reply.data.coverage.boundaries = [
    { path: [0], reason: 'maxElements', observedChildren: 0, totalChildren: 1 },
    { path: [], reason: 'maxElements', observedChildren: 1, totalChildren: 2 },
  ];
  return reply;
}

// Test only: mutate untrusted wire fields, including removal, before JSON serialization.
function setWireField(value: unknown, path: string, replacement: unknown) {
  const keys = path.split('.');
  const field = keys.pop()!;
  let parent = value as Record<string, unknown>;
  for (const key of keys) parent = parent[key] as Record<string, unknown>;
  if (replacement === undefined) delete parent[field];
  else parent[field] = replacement;
}

beforeAll(async () => {
  fixtureDirectory = await mkdtemp(join(tmpdir(), 'nuvin-mock-host-'));
  await Promise.all(modes.map(async mode => {
    const path = fixture(mode);
    await copyFile(mockHost, path);
    await chmod(path, 0o755);
  }));
  const validSnapshotReply = JSON.parse(
    await readFile(new URL('../contracts/fixtures/snapshot-reply.json', import.meta.url), 'utf8'),
  ) as Record<string, unknown>;
  const snapshotReplies: Record<string, Record<string, unknown>> = {
    'snapshot-reply-valid': structuredClone(validSnapshotReply),
    'snapshot-reply-invalid-id': structuredClone(validSnapshotReply),
    'snapshot-reply-invalid-target': structuredClone(validSnapshotReply),
    'snapshot-reply-invalid-tree': structuredClone(validSnapshotReply),
    'snapshot-reply-invalid-created-at': structuredClone(validSnapshotReply),
    'snapshot-reply-invalid-lifetime': structuredClone(validSnapshotReply),
  };
  const dataFor = (mode: string) => (snapshotReplies[mode].data as Record<string, unknown>);
  dataFor('snapshot-reply-invalid-id').snapshotId = 'not-a-uuid';
  (dataFor('snapshot-reply-invalid-target').target as Record<string, unknown>).pid = 0;
  const tree = dataFor('snapshot-reply-invalid-tree').tree as { elements: Array<{ children: Array<Record<string, unknown>> }> };
  tree.elements[0].children[0].ref = 0;
  dataFor('snapshot-reply-invalid-created-at').createdAt = '2026-09-08 10:00:00';
  dataFor('snapshot-reply-invalid-lifetime').expiresAt = '2026-09-08T10:11:00.000Z';
  await Promise.all(Object.entries(snapshotReplies).map(([mode, reply]) =>
    writeFile(`${fixture(mode)}.json`, `${JSON.stringify(reply)}\n`, { mode: 0o600 }),
  ));
});

afterAll(async () => { await rm(fixtureDirectory, { recursive: true, force: true }); });

describe('MacOSBackend', { timeout: 25_000 }, () => {
  it('probes the helper and accepts a valid command response', async () => {
    const backend = new MacOSBackend({ helper: fixture('valid-response') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1, ok: true, command: 'apps', data: { apps: [] },
    });
  });

  it('accepts the shared snapshot reply emitted by the Swift producer shape', async () => {
    const expected = JSON.parse(
      await readFile(new URL('../contracts/fixtures/snapshot-reply.json', import.meta.url), 'utf8'),
    );
    const backend = new MacOSBackend({ helper: fixture('snapshot-reply-valid') });
    await expect(backend.execute(snapshotRequest(), new AbortController().signal)).resolves.toEqual(expected);
  });

  it('rejects a malformed known coverage count in an annotated screenshot', async () => {
    const reply = await annotatedReply();
    reply.data.coverage.refCount = 0;
    await expect(executeSnapshotReply(reply, screenshotRequest())).resolves.toMatchObject({
      ok: false, error: { code: 'PROTOCOL_ERROR' },
    });
  });

  it('preserves original boundary paths after a compact wrapper is collapsed', async () => {
    const expected = await depthBoundaryReply();
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('accepts omittedBoundaries when positive integer and boundaries + omittedBoundaries <= observedNodes', async () => {
    const expected = await depthBoundaryReply();
    expected.data.coverage.omittedBoundaries = 2;
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it.each([false, true])('accepts 40 original depth cuts with summarized diagnostics (mixed cap: %s)', async mixed => {
    const expected = await readSnapshotReply(true);
    expected.data.tree = { elements: [{ role: 'AXWindow', children: Array.from({ length: 40 }, () => ({ role: 'AXGroup' })) }] };
    expected.data.truncated = true;
    expected.data.coverage = {
      scope: 'selectedWindow', absenceIsConclusive: false,
      observedNodes: 41, emittedNodes: 41, refCount: 0,
      limits: { maxDepth: 1, maxElements: mixed ? 41 : 500 },
      boundaries: [
        ...Array.from({ length: mixed ? 31 : 32 }, (_, index) => ({
          path: [index], reason: 'maxDepth', observedChildren: 0, totalChildren: 1,
        })),
        ...(mixed ? [{ path: [], reason: 'maxElements', observedChildren: 40, totalChildren: 41 }] : []),
      ],
      omittedBoundaries: mixed ? 9 : 8, noRefReason: 'traversalLimited',
    };
    const request = { ...snapshotRequest(), tree: {
      maxDepth: 1, maxElements: mixed ? 41 : 500, hintMode: 'leafCompact' as const,
    } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it.each([
    ['zero omittedBoundaries', 0],
    ['negative omittedBoundaries', -1],
    ['fractional omittedBoundaries', 1.5],
    ['unsafe omittedBoundaries', Number.MAX_SAFE_INTEGER + 1],
    ['non-number omittedBoundaries', '2'],
    ['null omittedBoundaries', null],
    ['boundaries + omittedBoundaries exceeds observedNodes', 3],
  ] as const)('rejects malformed omittedBoundaries: %s', async (_label, omittedBoundaries) => {
    const reply = await depthBoundaryReply();
    setWireField(reply, 'data.coverage.omittedBoundaries', omittedBoundaries);
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('rejects omittedBoundaries when boundaries is empty', async () => {
    const reply = await readSnapshotReply();
    setWireField(reply, 'data.coverage.omittedBoundaries', 1);
    await expect(executeSnapshotReply(reply)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('rejects a known coverage count that disagrees with the projected tree', async () => {
    const helper = fixture('snapshot-reply-coverage-count-mismatch');
    await copyFile(mockHost, helper);
    await chmod(helper, 0o755);
    const reply = JSON.parse(await readFile(
      new URL('../contracts/fixtures/snapshot-reply.json', import.meta.url), 'utf8',
    ));
    reply.data.coverage.emittedNodes = 2; // The full fixture has three tree nodes.
    await writeFile(`${helper}.json`, `${JSON.stringify(reply)}\n`, { mode: 0o600 });
    const backend = new MacOSBackend({ helper });
    await expect(backend.execute(snapshotRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'PROTOCOL_ERROR' },
    });
  });

  it.each(snapshotReplyModes)(
    'rejects malformed snapshot data from %s',
    async mode => {
      const backend = new MacOSBackend({ helper: fixture(mode) });
      await expect(backend.execute(snapshotRequest(), new AbortController().signal)).resolves.toEqual({
        schemaVersion: 1,
        ok: false,
        command: 'snapshot',
        error: { code: 'PROTOCOL_ERROR', message: 'Native helper returned an invalid response' },
      });
    },
  );

  it('accepts the exact compact Swift fixture with all original fields and refs', async () => {
    const expected = await readSnapshotReply(true);
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it.each(['full', 'leafCompact'] as const)('accepts a legacy %s reply without inventing coverage', async hintMode => {
    const expected = await readSnapshotReply(hintMode === 'leafCompact');
    delete expected.data.coverage;
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 500, hintMode } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('retains legacy empty-root behavior only when coverage is absent', async () => {
    const expected = await readSnapshotReply();
    delete expected.data.coverage;
    expected.data.tree.elements = [];
    await expect(executeSnapshotReply(expected)).resolves.toEqual(expected);
    expected.data.coverage = {
      scope: 'selectedWindow', absenceIsConclusive: false, observedNodes: 1, emittedNodes: 0, refCount: 0,
      limits: { maxDepth: 8, maxElements: 500 }, boundaries: [], noRefReason: 'noEligibleRefs',
    };
    await expect(executeSnapshotReply(expected)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it.each(['full', 'leafOnly', 'leafCompact'] as const)('accepts truthful zero-ref root-cap coverage in %s', async hintMode => {
    const expected = await elementBoundaryReply();
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 2, hintMode } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('accepts a zero-ref tree with no boundaries and noEligibleRefs', async () => {
    const expected = await depthBoundaryReply();
    expected.data.coverage.observedNodes = 2;
    expected.data.coverage.boundaries = [];
    expected.data.coverage.noRefReason = 'noEligibleRefs';
    expected.data.truncated = false;
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafOnly' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it.each(['full', 'leafOnly'] as const)('rejects compact count savings when %s was requested', async hintMode => {
    const reply = await readSnapshotReply(true);
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 500, hintMode } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  const missingOrNullCoverageFields = [
    'scope', 'absenceIsConclusive', 'observedNodes', 'emittedNodes', 'refCount',
    'limits', 'limits.maxDepth', 'limits.maxElements', 'boundaries',
  ].flatMap(field => [
    [`missing ${field}`, `data.coverage.${field}`, undefined],
    [`null ${field}`, `data.coverage.${field}`, null],
  ] as const);
  const invalidNumericCoverageFields = ['observedNodes', 'emittedNodes', 'refCount', 'limits.maxDepth', 'limits.maxElements']
    .flatMap(field => [-1, 1.5, Number.MAX_SAFE_INTEGER + 1, '3'].map(value =>
      [`invalid ${field}=${value}`, `data.coverage.${field}`, value] as const));
  it.each([
    ...missingOrNullCoverageFields, ...invalidNumericCoverageFields,
    ['null coverage', 'data.coverage', null],
    ['array coverage', 'data.coverage', []],
    ['wrong scope', 'data.coverage.scope', 'wholeDesktop'],
    ['conclusive absence', 'data.coverage.absenceIsConclusive', true],
    ['nonboolean absence', 'data.coverage.absenceIsConclusive', 0],
    ['zero observed', 'data.coverage.observedNodes', 0],
    ['zero emitted', 'data.coverage.emittedNodes', 0],
    ['zero depth', 'data.coverage.limits.maxDepth', 0],
    ['zero cap', 'data.coverage.limits.maxElements', 0],
    ['depth request mismatch', 'data.coverage.limits.maxDepth', 7],
    ['cap request mismatch', 'data.coverage.limits.maxElements', 499],
    ['emitted exceeds observed', 'data.coverage.observedNodes', 2],
    ['observed exceeds cap', 'data.coverage.observedNodes', 501],
    ['ref count mismatch', 'data.coverage.refCount', 2],
    ['refs exceed emitted', 'data.coverage.refCount', 4],
    ['non-array boundaries', 'data.coverage.boundaries', {}],
    ['truncated without boundaries', 'data.truncated', true],
    ['nonboolean truncated', 'data.truncated', 1],
    ['noRefReason with refs', 'data.coverage.noRefReason', 'noEligibleRefs'],
    ['null noRefReason with refs', 'data.coverage.noRefReason', null],
    ['unknown noRefReason with refs', 'data.coverage.noRefReason', 'unknown'],
  ] as const)('rejects malformed coverage: %s', async (_label, path, replacement) => {
    const reply = await readSnapshotReply();
    setWireField(reply, path, replacement);
    await expect(executeSnapshotReply(reply)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it.each([undefined, null, 'noEligibleRefs', 'unknown'])('rejects zero-ref limited coverage with noRefReason=%s', async reason => {
    const reply = await depthBoundaryReply();
    reply.data.coverage.noRefReason = reason;
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it.each([undefined, null, 'traversalLimited', 'unknown'])('rejects zero-ref unlimited coverage with noRefReason=%s', async reason => {
    const reply = await depthBoundaryReply();
    reply.data.truncated = false;
    reply.data.coverage.boundaries = [];
    reply.data.coverage.noRefReason = reason;
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  const invalidBoundaryFields = ['path', 'reason', 'observedChildren', 'totalChildren'].flatMap(field => [
    [`missing ${field}`, `data.coverage.boundaries.0.${field}`, undefined],
    [`null ${field}`, `data.coverage.boundaries.0.${field}`, null],
  ] as const);
  const invalidBoundaryCounts = ['observedChildren', 'totalChildren'].flatMap(field =>
    [-1, 0.5, Number.MAX_SAFE_INTEGER + 1, '1'].map(value =>
      [`invalid ${field}=${value}`, `data.coverage.boundaries.0.${field}`, value] as const));
  it.each([
    ...invalidBoundaryFields, ...invalidBoundaryCounts,
    ['null boundary', 'data.coverage.boundaries.0', null],
    ['non-array path', 'data.coverage.boundaries.0.path', '0'],
    ['negative index', 'data.coverage.boundaries.0.path', [-1]],
    ['fractional index', 'data.coverage.boundaries.0.path', [0.5]],
    ['unsafe index', 'data.coverage.boundaries.0.path', [Number.MAX_SAFE_INTEGER + 1]],
    ['non-number index', 'data.coverage.boundaries.0.path', ['0']],
    ['index equals observedNodes', 'data.coverage.boundaries.0.path', [3]],
    ['path exceeds maxDepth', 'data.coverage.boundaries.0.path', [0, 0, 0]],
    ['depth boundary above maxDepth', 'data.coverage.boundaries.0.path', [0]],
    ['depth boundary observed a child', 'data.coverage.boundaries.0',
      { path: [0, 0], reason: 'maxDepth', observedChildren: 1, totalChildren: 2 }],
    ['no unobserved children', 'data.coverage.boundaries.0.totalChildren', 0],
    ['unknown reason', 'data.coverage.boundaries.0.reason', 'timeout'],
    ['element boundary at maxDepth', 'data.coverage.boundaries.0.reason', 'maxElements'],
    ['boundary without truncated', 'data.truncated', false],
  ] as const)('rejects malformed depth boundary: %s', async (_label, path, replacement) => {
    const reply = await depthBoundaryReply();
    setWireField(reply, path, replacement);
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it.each([
    ['duplicate paths', 'data.coverage.boundaries.0.path', []],
    ['path length equals observedNodes', 'data.coverage.boundaries.0.path', [0, 0]],
    ['observedChildren equals observedNodes', 'data.coverage.boundaries.0',
      { path: [0], reason: 'maxElements', observedChildren: 2, totalChildren: 3 }],
    ['observedChildren exceeds totalChildren', 'data.coverage.boundaries.0.observedChildren', 2],
    ['boundary count exceeds observedNodes', 'data.coverage.boundaries', [
      { path: [0], reason: 'maxElements', observedChildren: 0, totalChildren: 1 },
      { path: [1], reason: 'maxElements', observedChildren: 0, totalChildren: 1 },
      { path: [], reason: 'maxElements', observedChildren: 1, totalChildren: 2 },
    ]],
  ] as const)('rejects malformed element boundary: %s', async (_label, path, replacement) => {
    const reply = await elementBoundaryReply();
    setWireField(reply, path, replacement);
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 2, hintMode: 'full' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('rejects an element boundary when the observed node budget was not exhausted', async () => {
    const reply = await elementBoundaryReply();
    reply.data.coverage.limits.maxElements = 500;
    await expect(executeSnapshotReply(reply)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('rejects an element boundary at maxDepth even when the element budget is exhausted', async () => {
    const reply = await elementBoundaryReply();
    reply.data.coverage.limits.maxDepth = 1;
    const request = { ...snapshotRequest(), tree: { maxDepth: 1, maxElements: 2, hintMode: 'full' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('rejects refs under a root boundary even when tree and ref counts agree', async () => {
    const reply = await elementBoundaryReply();
    reply.data.tree.elements[0].ref = 1;
    reply.data.coverage.refCount = 1;
    delete reply.data.coverage.noRefReason;
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 2, hintMode: 'full' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('accepts refs on completed sibling subtrees when a later root child hits maxElements', async () => {
    const expected = await elementBoundaryReply();
    expected.data.tree = {
      elements: [{ role: 'AXWindow', children: [{ role: 'AXButton', ref: 1, actions: ['AXPress'] }] }],
    };
    expected.data.coverage.observedNodes = 2;
    expected.data.coverage.emittedNodes = 2;
    expected.data.coverage.refCount = 1;
    expected.data.coverage.boundaries = [
      { path: [], reason: 'maxElements', observedChildren: 1, totalChildren: 2 },
    ];
    delete expected.data.coverage.noRefReason;
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 2, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('strips unknown fields at every snapshot, tree, and coverage object level', async () => {
    const expected = await depthBoundaryReply();
    const reply = structuredClone(expected);
    for (const path of [
      'future', 'data.future', 'data.target.future', 'data.target.bounds.future',
      'data.tree.future', 'data.tree.elements.0.future', 'data.tree.elements.0.children.0.future',
      'data.coverage.future', 'data.coverage.limits.future', 'data.coverage.boundaries.0.future',
    ]) setWireField(reply, path, { secret: ['must not leak'] });
    const request = { ...snapshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toEqual(expected);
  });

  it('preserves refs in a separate branch from a non-root traversal boundary', async () => {
    const expected = await readSnapshotReply();
    expected.data.tree = { elements: [{ role: 'AXWindow', children: [
      { role: 'AXButton', ref: 1, actions: ['AXPress'] }, { role: 'AXGroup' },
    ] }] };
    expected.data.truncated = true;
    expected.data.coverage.refCount = 1;
    expected.data.coverage.limits.maxDepth = 1;
    expected.data.coverage.boundaries = [{ path: [1], reason: 'maxDepth', observedChildren: 0, totalChildren: 100 }];
    const request = { ...snapshotRequest(), tree: { maxDepth: 1, maxElements: 500, hintMode: 'full' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('allows a complete traversal that exactly used the element budget', async () => {
    const expected = await readSnapshotReply();
    expected.data.coverage.limits.maxElements = 3;
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 3, hintMode: 'full' as const } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('rejects an emitted tree count mismatch even when all coverage counts agree', async () => {
    const reply = await readSnapshotReply();
    reply.data.coverage.emittedNodes = 4;
    reply.data.coverage.observedNodes = 4;
    await expect(executeSnapshotReply(reply)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it('rejects a compact observed count exceeding the request budget', async () => {
    const reply = await readSnapshotReply(true);
    reply.data.coverage.observedNodes = 501;
    const request = { ...snapshotRequest(), tree: { maxDepth: 8, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  describe.each(['snapshot', 'legacy snapshot', 'annotated', 'legacy annotated'])('%s tree safety', kind => {
    it.each([
      ['missing role', 'data.tree.elements.0.role', undefined],
      ['empty role', 'data.tree.elements.0.children.0.role', ''],
      ['null role', 'data.tree.elements.0.role', null],
      ['duplicate ref', 'data.tree.elements.0.children.0.ref', 1],
      ['sparse refs', 'data.tree.elements.0.children.1.ref', 4],
      ['zero ref', 'data.tree.elements.0.children.0.ref', 0],
      ['unsafe ref', 'data.tree.elements.0.ref', Number.MAX_SAFE_INTEGER + 1],
      ['fractional ref', 'data.tree.elements.0.ref', 1.5],
      ['two roots', 'data.tree.elements', [{ role: 'AXWindow' }, { role: 'AXWindow' }]],
      ['malformed children', 'data.tree.elements.0.children', {}],
      ['malformed known boolean', 'data.tree.elements.0.focused', 1],
      ['malformed known actions', 'data.tree.elements.0.actions', [1]],
    ] as const)('rejects %s', async (_label, path, replacement) => {
      const annotated = kind.includes('annotated');
      const reply = annotated ? await annotatedReply() : await readSnapshotReply();
      if (kind.startsWith('legacy')) delete reply.data.coverage;
      setWireField(reply, path, replacement);
      await expect(executeSnapshotReply(reply, annotated ? screenshotRequest() : snapshotRequest()))
        .resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    });
  });

  describe.each([false, true])('snapshot timestamps (legacy=%s)', legacy => {
    it.each([
      ['invalid calendar date', 'createdAt', '2026-02-30T10:00:00Z'],
      ['non-wire timestamp', 'expiresAt', '2026-09-08 10:10:00'],
      ['missing timestamp', 'createdAt', undefined],
      ['null timestamp', 'expiresAt', null],
      ['long lifetime', 'expiresAt', '2026-09-08T10:11:00.000Z'],
      ['short lifetime', 'expiresAt', '2026-09-08T10:09:59.999Z'],
      ['nanosecond lifetime mismatch', 'expiresAt', '2026-09-08T10:10:00.000000001Z'],
    ] as const)('rejects %s', async (_label, field, replacement) => {
      const reply = await readSnapshotReply();
      if (legacy) delete reply.data.coverage;
      setWireField(reply, `data.${field}`, replacement);
      await expect(executeSnapshotReply(reply)).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    });
    it('preserves valid exact nanosecond lifetime timestamps', async () => {
      const expected = await readSnapshotReply();
      if (legacy) delete expected.data.coverage;
      expected.data.createdAt = '2026-09-08T10:00:00.123456789Z';
      expected.data.expiresAt = '2026-09-08T10:10:00.123456789Z';
      await expect(executeSnapshotReply(expected)).resolves.toEqual(expected);
    });
  });

  it.each(['full', 'leafCompact'] as const)('preserves %s annotated coverage and the capture metadata envelope', async hintMode => {
    const expected = await annotatedReply();
    const snapshot = await readSnapshotReply(hintMode === 'leafCompact');
    expected.data.tree = snapshot.data.tree;
    expected.data.coverage = snapshot.data.coverage;
    // Capture fields stay on their existing path, not the snapshot lifetime validator.
    expected.data.expiresAt = '2026-09-08T10:10:00.000Z';
    const request = { ...screenshotRequest(), tree: { maxDepth: 8, maxElements: 500, hintMode } };
    await expect(executeSnapshotReply(expected, request)).resolves.toEqual(expected);
  });

  it('accepts legacy annotated replies without coverage or a fabricated root', async () => {
    const expected = await annotatedReply();
    delete expected.data.coverage;
    expected.data.tree.elements = [];
    await expect(executeSnapshotReply(expected, screenshotRequest())).resolves.toEqual(expected);
  });

  it('strips unknown annotated tree and coverage fields while retaining known data', async () => {
    const expected = await annotatedReply();
    const boundary = await depthBoundaryReply();
    Object.assign(expected.data, { tree: boundary.data.tree, coverage: boundary.data.coverage, truncated: true });
    const reply = structuredClone(expected);
    for (const path of [
      'data.future', 'data.tree.future', 'data.tree.elements.0.future',
      'data.tree.elements.0.children.0.future', 'data.coverage.future',
      'data.coverage.limits.future', 'data.coverage.boundaries.0.future',
    ]) setWireField(reply, path, { secret: 'must not leak' });
    const request = { ...screenshotRequest(), tree: { maxDepth: 2, maxElements: 500, hintMode: 'leafCompact' as const } };
    await expect(executeSnapshotReply(reply, request)).resolves.toEqual(expected);
  });

  it.each([
    ['null coverage', 'data.coverage', null],
    ['empty tree with coverage', 'data.tree.elements', []],
    ['boundary/truncated mismatch', 'data.truncated', true],
    ['request limits mismatch', 'data.coverage.limits.maxElements', 499],
  ] as const)('rejects annotated %s', async (_label, path, replacement) => {
    const reply = await annotatedReply();
    setWireField(reply, path, replacement);
    await expect(executeSnapshotReply(reply, screenshotRequest())).resolves.toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
  });

  it.each([false, true])('does not expose unrequested screenshot annotation data (malformed=%s)', async malformed => {
    const reply = await annotatedReply();
    const expected = structuredClone(reply);
    for (const field of ['tree', 'snapshotId', 'truncated', 'coverage']) delete expected.data[field];
    if (malformed) Object.assign(reply.data, { tree: null, coverage: null, truncated: null });
    await expect(executeSnapshotReply(reply, screenshotRequest(false))).resolves.toEqual(expected);
  });

  it('keeps request stdin open until the host completes', async () => {
    const backend = new MacOSBackend({ helper: fixture('requires-open-stdin') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({ ok: true });
  });

  it.each([
    ['invalid JSON', 'invalid-json'],
    ['a response for the wrong command', 'wrong-command'],
    ['invalid command data', 'invalid-response-data'],
  ])('rejects %s as a protocol failure', async (_label, mode) => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'PROTOCOL_ERROR' },
    });
  });

  it.each(['failure-missing-command', 'failure-wrong-command'])('rejects an uncorrelated failure reply from %s', async mode => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, command: 'apps', error: { code: 'PROTOCOL_ERROR' },
    });
  });

  it('rejects an incompatible helper before sending a request', async () => {
    const backend = new MacOSBackend({ helper: fixture('incompatible-version') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'HELPER_VERSION_MISMATCH' },
    });
  });

  it('reports a missing helper without an environment lookup fallback', async () => {
    const backend = new MacOSBackend({ helper: fixture('does-not-exist') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'MISSING_HELPER' },
    });
  });

  it.each([
    ['version mismatch', 'incompatible-version', 'HELPER_VERSION_MISMATCH', 5_000],
    ['version-probe spawn failure', 'does-not-exist', 'MISSING_HELPER', 5_000],
    ['version-probe timeout', 'slow-version', 'TIMEOUT', 30],
    ['execution spawn failure', 'execution-spawn-failure', 'MISSING_HELPER', 5_000],
  ])('does not mark a mutation potentially applied after a pre-dispatch %s', async (_label, mode, code, timeoutMs) => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    const reply = await backend.execute(mutationRequest('private pre-dispatch value', timeoutMs), new AbortController().signal);
    expect(reply).toMatchObject({ ok: false, error: { code } });
    if (!reply.ok) expect(reply.error.details).toBeUndefined();
  });

  it('reports a nonzero request exit', async () => {
    const backend = new MacOSBackend({ helper: fixture('nonzero-exit') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'NATIVE_FAILURE' },
    });
  });

  it('never accepts a success JSON followed by a failing exit', async () => {
    const backend = new MacOSBackend({ helper: fixture('success-then-exit-1') });
    const reply = await backend.execute(appsRequest(), new AbortController().signal);
    expect(reply).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE' } });
  });

  it.each([
    'nonzero-exit',
    'success-then-exit-1',
    'invalid-json',
    'wrong-command',
    'invalid-response-data',
    'failure-missing-command',
    'failure-wrong-command',
    'exits-after-receiving-request',
    'stdout-overflow',
    'stderr-overflow',
  ])('marks a synthetic post-dispatch mutation failure from %s as potentially applied', async mode => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    const reply = await backend.execute(mutationRequest('private uncertain value'), new AbortController().signal);
    expect(reply).toMatchObject({ ok: false });
    if (reply.ok) throw new Error('Expected failure');
    expect(reply.error.details).toEqual({ mutationStatus: 'potentiallyApplied' });
  });

  it('projects exactly the shared native mutation-status spellings', async () => {
    const fixtures = JSON.parse(
      await readFile(new URL('../contracts/fixtures/native-replies.json', import.meta.url), 'utf8'),
    ) as {
      mutationStatuses: Array<{ name: string; wire: string; public: string | null }>;
      invalidMutationStatuses: string[];
    };
    const backend = new MacOSBackend({ helper: fixture('mutation-status') });
    for (const status of fixtures.mutationStatuses) {
      const reply = await backend.execute(mutationRequest(status.wire), new AbortController().signal);
      expect(reply, status.name).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE' } });
      if (reply.ok) throw new Error('Expected failure');
      expect(reply.error.details, status.name).toEqual(
        status.public === null
          ? { safe: 'kept' }
          : { safe: 'kept', mutationStatus: status.public },
      );
    }
    for (const status of fixtures.invalidMutationStatuses) {
      const reply = await backend.execute(mutationRequest(status), new AbortController().signal);
      expect(reply, status).toEqual({
        schemaVersion: 1,
        ok: false,
        command: 'set-value',
        error: {
          code: 'PROTOCOL_ERROR',
          message: 'Native helper returned an invalid response',
          details: { mutationStatus: 'potentiallyApplied' },
        },
      });
    }
  });

  it('projects notStarted for a pre-dispatch target failure', async () => {
    // The native side reports TARGET_NOT_FOUND before dispatch begins and marks
    // it notStarted; the boundary must emit that status, not drop it.
    const backend = new MacOSBackend({ helper: fixture('target-not-found') });
    const reply = await backend.execute(keyRequest(), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'key',
      error: {
        code: 'TARGET_NOT_FOUND',
        message: 'Application selection is not unique',
        details: { mutationStatus: 'notStarted' },
      },
    });
  });

  it('projects a wire FOCUS_FAILED reply with its notStarted status', async () => {
    // Guards the STABLE_ERROR_CODES entry: a focus failure must reach the
    // reply intact, not be reclassified as a protocol error.
    const backend = new MacOSBackend({ helper: fixture('focus-failed') });
    const reply = await backend.execute(keyRequest(), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'key',
      error: {
        code: 'FOCUS_FAILED',
        message: 'App could not be brought to the front',
        details: { mutationStatus: 'notStarted' },
      },
    });
  });

  it('conservatively marks a structured mutation failure with missing status', async () => {
    const backend = new MacOSBackend({ helper: fixture('mutation-status') });
    const reply = await backend.execute(mutationRequest('__missing__'), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'NATIVE_FAILURE',
        message: 'Mutation failed',
        details: { safe: 'kept', mutationStatus: 'potentiallyApplied' },
      },
    });
  });

  it('does not project mutation status for a non-mutating command', async () => {
    const backend = new MacOSBackend({ helper: fixture('mutation-status') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'apps',
      error: { code: 'NATIVE_FAILURE', message: 'Mutation failed', details: { safe: 'kept' } },
    });
  });

  it('preserves bounded AX diagnostics on non-mutating errors without mutation status', async () => {
    const ax = { phase: 'observation', operation: 'copyMultipleAttributes', attribute: 'AXRole',
      statusCode: -25204, statusName: 'cannotComplete', statusScope: 'batchEntry', reason: 'statusFailure' };
    const reply = await executeSnapshotReply({ schemaVersion: 1, ok: false, command: 'snapshot',
      error: { code: 'NATIVE_FAILURE', message: 'Accessibility data could not be read reliably',
        details: { ax, mutationStatus: 'notStarted' } } });
    expect(reply).toEqual({ schemaVersion: 1, ok: false, command: 'snapshot',
      error: { code: 'NATIVE_FAILURE', message: 'Accessibility data could not be read reliably', details: { ax } } });
  });

  it.each(['sentinel', 'scalar', 'object'])('supplied-value redaction wins over AX diagnostics: %s', async mode => {
    const ax = { phase: 'preparation', operation: 'setAttribute', attribute: 'AXManualAccessibility',
      statusCode: -25204, statusName: 'cannotComplete', statusScope: 'direct', reason: 'statusFailure' };
    const text = mode === 'sentinel' ? 'PRIVATE-supplied-value-9731' : mode === 'scalar' ? ax.operation : JSON.stringify(ax);
    const reply = await executeSnapshotReply({ schemaVersion: 1, ok: false, command: 'set-value',
      error: { code: 'NATIVE_FAILURE', message: 'Accessibility data could not be read reliably',
        details: { ax, reflection: text, safe: 'kept', mutationStatus: 'potentiallyApplied' } } }, mutationRequest(text));
    const expectedAX = mode === 'object' ? {} : { ax: mode === 'scalar'
      ? { phase: ax.phase, attribute: ax.attribute, statusCode: ax.statusCode, statusName: ax.statusName,
          statusScope: ax.statusScope, reason: ax.reason }
      : ax };
    expect(reply).toEqual({ schemaVersion: 1, ok: false, command: 'set-value',
      error: { code: 'NATIVE_FAILURE', message: 'Accessibility data could not be read reliably',
        details: { ...expectedAX, safe: 'kept', mutationStatus: 'potentiallyApplied' } } });
    expect(formatReply(reply, true)).not.toContain(text);
    expect(formatReply(reply, false)).not.toContain(text);
  });

  it('rejects a zero exit without a response', async () => {
    const backend = new MacOSBackend({ helper: fixture('exits-after-receiving-request') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'PROTOCOL_ERROR' },
    });
  });

  it('bounds the version probe and request under one deadline', async () => {
    const backend = new MacOSBackend({ helper: fixture('slow-version') });
    await expect(backend.execute(appsRequest(30), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'TIMEOUT' },
    });
  });

  it('terminates a host that never exits at the deadline', async () => {
    const backend = new MacOSBackend({ helper: fixture('never-exits') });
    await expect(backend.execute(appsRequest(100), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'TIMEOUT' },
    });
  });

  it('returns only after forcing an owned child that ignores SIGTERM', async () => {
    const backend = new MacOSBackend({ helper: fixture('ignores-sigterm') });
    const started = performance.now();
    const reply = await backend.execute(appsRequest(2_000), new AbortController().signal);
    expect(reply).toMatchObject({ ok: false, error: { code: 'TIMEOUT' } });
    expect(performance.now() - started).toBeGreaterThanOrEqual(3_800);
  }, 8_000);

  it('terminates and waits for the child on caller cancellation', async () => {
    const controller = new AbortController();
    const backend = new MacOSBackend({ helper: fixture('never-exits') });
    const execution = backend.execute(appsRequest(2_000), controller.signal);
    setTimeout(() => controller.abort(), 100);
    await expect(execution).resolves.toMatchObject({ ok: false, error: { code: 'INTERRUPTED' } });
  });

  it('forces a SIGTERM-resistant child to exit after caller cancellation', async () => {
    const controller = new AbortController();
    const backend = new MacOSBackend({ helper: fixture('ignores-sigterm') });
    const started = performance.now();
    const execution = backend.execute(appsRequest(5_000), controller.signal);
    setTimeout(() => controller.abort(), 1_000);
    await expect(execution).resolves.toMatchObject({ ok: false, error: { code: 'INTERRUPTED' } });
    expect(performance.now() - started).toBeGreaterThanOrEqual(2_900);
  }, 8_000);

  it.each(['stdout-overflow', 'stderr-overflow'])('treats %s as protocol failure instead of truncated success', async mode => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'PROTOCOL_ERROR' },
    });
  });

  it('does not expose request text in native failure or mutation uncertainty details', async () => {
    const text = 'private value 8472';
    const backend = new MacOSBackend({ helper: fixture('request-on-stderr') });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(reply).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE' } });
    expect(JSON.stringify(reply)).not.toContain(text);
  });

  it('marks a cancelled mutation as potentially applied without exposing text', async () => {
    const text = 'private value 5931';
    const backend = new MacOSBackend({ helper: fixture('ignores-sigterm') });
    const reply = await backend.execute(mutationRequest(text, 1_000), new AbortController().signal);
    expect(reply).toMatchObject({
      ok: false,
      error: { code: 'TIMEOUT', details: { mutationStatus: 'potentiallyApplied' } },
    });
    expect(JSON.stringify(reply)).not.toContain(text);
  }, 8_000);

  it.each([
    ['reflected success data', 'reflected-success-data'],
    ['reflected error message', 'reflected-error-message'],
    ['reflected error details', 'reflected-error-details'],
  ])('does not expose supplied text from %s at the CLI reply boundary', async (_label, mode) => {
    const text = `private reflected value ${mode}`;
    const backend = new MacOSBackend({ helper: fixture(mode) });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(formatReply(reply, true)).not.toContain(text);
    expect(formatReply(reply, false)).not.toContain(text);
    if (mode === 'reflected-success-data') {
      expect(reply).toEqual({
        schemaVersion: 1,
        ok: true,
        command: 'set-value',
        data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
      });
    }
    if (mode === 'reflected-error-message') {
      expect(reply).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE', message: '' } });
    }
    if (mode === 'reflected-error-details') {
      expect(reply).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE', message: 'Useful failure' } });
      if (reply.ok) throw new Error('Expected failure');
      expect(reply.error.details).toEqual({ safe: 'kept', mutationStatus: 'potentiallyApplied' });
    }
  });

  it.each([
    ['numeric', '8472'],
    ['boolean', 'true'],
  ])('removes a %s representation of supplied text from nested free-form success data', async (_label, text) => {
    const backend = new MacOSBackend({ helper: fixture('reflected-success-data') });
    await expect(backend.execute(mutationRequest(text), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it.each([
    ['null', 'null'],
    ['an empty array', '[]'],
    ['a composite array', '[{"pin":8472}]'],
    ['structured JSON', '{"pin":8472}'],
  ])('omits supplied text represented as JSON %s from nested free-form target data', async (_label, text) => {
    const backend = new MacOSBackend({ helper: fixture('reflected-success-data') });
    await expect(backend.execute(mutationRequest(text), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it.each([
    ['null', 'null'],
    ['an empty array', '[]'],
    ['a composite array', '[{"pin":8472}]'],
    ['structured JSON', '{"pin":8472}'],
  ])('omits supplied text represented as JSON %s from free-form error details', async (_label, text) => {
    const backend = new MacOSBackend({ helper: fixture('reflected-error-details') });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(reply).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE', message: 'Useful failure' } });
    if (reply.ok) throw new Error('Expected failure');
    expect(reply.error.details).toEqual({ safe: 'kept', mutationStatus: 'potentiallyApplied' });
  });

  it('rejects structured supplied text reflected as the complete mutation target', async () => {
    const text = '{"pin":8472}';
    const backend = new MacOSBackend({ helper: fixture('reflected-root-target') });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'PROTOCOL_ERROR',
        message: 'Native helper returned an invalid response',
        details: { mutationStatus: 'potentiallyApplied' },
      },
    });
    expect(JSON.stringify(reply)).not.toContain('8472');
  });

  it('omits structured supplied text reflected across complete error details but preserves exact mutation status', async () => {
    const text = '{"pin":8472}';
    const backend = new MacOSBackend({ helper: fixture('reflected-root-error-details') });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'NATIVE_FAILURE',
        message: 'Useful failure',
        details: { mutationStatus: 'potentiallyApplied' },
      },
    });
    expect(JSON.stringify(reply)).not.toContain('8472');
  });

  it('omits a canonical parsed JSON match from a nested subtree regardless of object key order', async () => {
    const backend = new MacOSBackend({ helper: fixture('reflected-reordered-subtree') });
    await expect(backend.execute(
      mutationRequest('{"pin":8472,"label":"private"}'),
      new AbortController().signal,
    )).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it('does not treat a free-form object key alone as reflected supplied text', async () => {
    const backend = new MacOSBackend({ helper: fixture('reflected-success-data') });
    await expect(backend.execute(mutationRequest('app'), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it.each(['target', 'method'])('preserves the required %s field when supplied text collides with its key', async text => {
    const backend = new MacOSBackend({ helper: fixture('reflected-success-data') });
    await expect(backend.execute(mutationRequest(text), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it.each([
    ['method', 'accessibility'],
    ['verification', 'verified'],
    ['visualization', 'none'],
  ])('preserves the known %s value when supplied text collides with it', async (_field, text) => {
    const backend = new MacOSBackend({ helper: fixture('reflected-success-data') });
    await expect(backend.execute(mutationRequest(text), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it.each([
    ['method', 'reflected-method', 'private-method-secret-4312'],
    ['verification', 'reflected-verification', 'private-verification-secret-5823'],
    ['visualization', 'reflected-visualization', 'private-visualization-secret-7964'],
  ])('rejects supplied text in the %s success field', async (_field, mode, text) => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'PROTOCOL_ERROR',
        message: 'Native helper returned an invalid response',
        details: { mutationStatus: 'potentiallyApplied' },
      },
    });
    expect(JSON.stringify(reply)).not.toContain(text);
  });

  it('accepts and projects future non-placeholder mutation result values', async () => {
    const backend = new MacOSBackend({ helper: fixture('future-result-values') });
    await expect(backend.execute(mutationRequest('private future value'), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: {
        target: { app: 'TextEdit' },
        method: 'unicode-events',
        verification: 'dispatch-completed',
        visualization: 'cursor-disabled',
      },
    });
  });

  it('preserves validated clipboard replacement metadata only for type results', async () => {
    const backend = new MacOSBackend({ helper: fixture('type-result') });
    await expect(backend.execute(typeRequest('true'), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'type',
      data: {
        target: { app: 'TextEdit' },
        method: 'accessibility',
        verification: 'verified',
        visualization: 'none',
        clipboardReplaced: true,
      },
    });
    await expect(backend.execute(mutationRequest('private'), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: true,
      command: 'set-value',
      data: { target: { app: 'TextEdit' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
    });
  });

  it('rejects a non-boolean clipboard replacement value for a type result', async () => {
    const backend = new MacOSBackend({ helper: fixture('invalid-type-result') });
    await expect(backend.execute(typeRequest('private'), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'type',
      error: {
        code: 'PROTOCOL_ERROR',
        message: 'Native helper returned an invalid response',
        details: { mutationStatus: 'potentiallyApplied' },
      },
    });
  });

  it('rejects an unknown helper error code', async () => {
    const backend = new MacOSBackend({ helper: fixture('unknown-error-code') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'apps',
      error: { code: 'PROTOCOL_ERROR', message: 'Native helper returned an invalid response' },
    });
  });

  it('rejects a supplied-text helper error code with post-dispatch mutation uncertainty', async () => {
    const text = 'private-error-code-secret-9185';
    const backend = new MacOSBackend({ helper: fixture('unknown-error-code') });
    const reply = await backend.execute(mutationRequest(text), new AbortController().signal);
    expect(reply).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'PROTOCOL_ERROR',
        message: 'Native helper returned an invalid response',
        details: { mutationStatus: 'potentiallyApplied' },
      },
    });
    expect(JSON.stringify(reply)).not.toContain(text);
  });

  it('preserves a stable error code and exact mutation status when supplied text collides with the code', async () => {
    const backend = new MacOSBackend({ helper: fixture('stable-error-code') });
    await expect(backend.execute(mutationRequest('UNSUPPORTED_ACTION'), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'UNSUPPORTED_ACTION',
        message: 'Unsupported action',
        details: { mutationStatus: 'potentiallyApplied', safe: 'kept' },
      },
    });
  });

  it('returns UNSUPPORTED_PLATFORM for native commands on non-macOS systems', async () => {
    const backend = backendForPlatform('linux');
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'UNSUPPORTED_PLATFORM' },
    });
  });

});
