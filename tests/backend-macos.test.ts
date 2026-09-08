import { chmod, copyFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { MacOSBackend } from '../src/backend/macos.js';
import { backendForPlatform } from '../src/cli.js';
import { formatReply } from '../src/cli/output.js';
import type { Request } from '../src/core/protocol.js';

const mockHost = new URL('../fixtures/cli/mock-host.mjs', import.meta.url);
const modes = [
  'valid-response', 'invalid-json', 'wrong-command', 'invalid-response-data',
  'failure-missing-command', 'failure-wrong-command', 'incompatible-version',
  'execution-spawn-failure', 'nonzero-exit', 'success-then-exit-1',
  'never-exits', 'exits-after-receiving-request', 'ignores-sigterm',
  'requires-open-stdin', 'stdout-overflow', 'stderr-overflow',
  'request-on-stderr', 'reflected-success-data', 'reflected-error-message',
  'reflected-error-details', 'slow-version',
];
let fixtureDirectory: string;

function fixture(mode: string): string { return join(fixtureDirectory, mode); }
function appsRequest(timeoutMs = 5_000): Request {
  return { schemaVersion: 1, command: 'apps', options: { timeoutMs, cursor: 'on' } };
}
function mutationRequest(text: string, timeoutMs = 5_000): Request {
  return {
    schemaVersion: 1,
    command: 'set-value',
    options: { timeoutMs, cursor: 'on' },
    snapshotId: '123e4567-e89b-42d3-a456-426614174000',
    ref: 1,
    text,
  };
}

beforeAll(async () => {
  fixtureDirectory = await mkdtemp(join(tmpdir(), 'nuvin-mock-host-'));
  await Promise.all(modes.map(async mode => {
    const path = fixture(mode);
    await copyFile(mockHost, path);
    await chmod(path, 0o755);
  }));
});

afterAll(async () => { await rm(fixtureDirectory, { recursive: true, force: true }); });

describe('MacOSBackend', () => {
  it('probes the helper and accepts a valid command response', async () => {
    const backend = new MacOSBackend({ helper: fixture('valid-response') });
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1, ok: true, command: 'apps', data: { apps: [] },
    });
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
        data: { target: { app: 'TextEdit', reflected: '' }, method: 'accessibility', verification: 'verified', visualization: 'none' },
      });
    }
    if (mode === 'reflected-error-details') {
      expect(reply).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE', message: 'Useful failure', details: { safe: 'kept' } } });
    }
  });

  it('returns UNSUPPORTED_PLATFORM for native commands on non-macOS systems', async () => {
    const backend = backendForPlatform('linux');
    await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toMatchObject({
      ok: false, error: { code: 'UNSUPPORTED_PLATFORM' },
    });
  });

});
