import { describe, expect, it, vi } from 'vitest';
import { run, type RunDependencies } from '../src/cli/run.js';
import type { Backend, Reply, Request } from '../src/core/protocol.js';

const snapshotId = '123e4567-e89b-42d3-a456-426614174000';
const target = { app: 'TextEdit' };
const tree = { elements: [] };
const mutation = { target, method: 'accessibility', verification: 'verified', visualization: 'none' };

function success(command: Request['command']): Reply {
  const data = (() => {
    switch (command) {
      case 'doctor': return { ready: true, checks: [{ name: 'accessibility', status: 'ok', message: 'Available' }] };
      case 'apps': return { apps: [{ name: 'TextEdit', pid: 42, bundleId: 'com.apple.TextEdit' }] };
      case 'windows': return { windows: [{ id: 7, title: 'Document', bounds: { x: 0, y: 0, width: 800, height: 600 }, eligible: true, reason: null }] };
      case 'snapshot': return { snapshotId, target, tree, truncated: false, createdAt: '2026-09-08T00:00:00.000Z', expiresAt: '2026-09-08T00:01:00.000Z' };
      case 'screenshot': return { captureId: snapshotId, target, path: '/tmp/capture.png', width: 800, height: 600, createdAt: '2026-09-08T00:00:00.000Z', expiresAt: '2026-09-08T00:01:00.000Z', snapshotId, tree, truncated: false };
      case 'press': case 'set-value': case 'type': case 'key': case 'scroll': case 'click': case 'move': case 'drag': return mutation;
    }
  })();
  return { schemaVersion: 1, ok: true, command, data };
}

function dependencies(backend: Backend, overrides: Partial<RunDependencies> = {}): RunDependencies & { stdout: string[]; stderr: string[] } {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return {
    backend, signal: new AbortController().signal, readText: async () => '',
    writeStdout: text => stdout.push(text), writeStderr: text => stderr.push(text), stdout, stderr, ...overrides,
  };
}

describe('run', () => {
  it('dispatches explicit snapshot targeting', async () => {
    const requests: Request[] = [];
    const backend: Backend = { execute: async request => { requests.push(request); return success('snapshot'); } };
    const code = await run(['snapshot', '--pid', '42', '--window', '7', '--json'], dependencies(backend));
    expect(code).toBe(0);
    expect(requests[0]).toMatchObject({ command: 'snapshot', target: { pid: 42, windowId: 7 } });
  });

  it('loads text-file stdin only before dispatching and never echoes text', async () => {
    const execute = vi.fn(async (request: Request) => success(request.command));
    const deps = dependencies({ execute }, { readText: async path => {
      expect(path).toBe('-');
      return 'sensitive input';
    } });
    await expect(run(['type', '--app', 'TextEdit', '--text-file', '-', '--json'], deps)).resolves.toBe(0);
    expect(execute).toHaveBeenCalledWith(expect.objectContaining({ command: 'type', text: 'sensitive input' }), expect.any(AbortSignal));
    expect(deps.stdout.join('')).not.toContain('sensitive input');
    expect(deps.stderr.join('')).not.toContain('sensitive input');
  });

  it('returns one structured JSON error for unknown commands', async () => {
    const deps = dependencies({ execute: async () => success('apps') });
    await expect(run(['unknown', '--json'], deps)).resolves.toBe(2);
    expect(deps.stderr).toEqual([]);
    expect(deps.stdout).toHaveLength(1);
    expect(deps.stdout[0]).not.toMatch(/\u001B/);
    expect(JSON.parse(deps.stdout[0])).toMatchObject({ ok: false, error: { code: 'INVALID_ARGUMENT' } });
  });

  it('returns a structured error when text loading fails without calling the backend', async () => {
    const execute = vi.fn(async (request: Request) => success(request.command));
    const deps = dependencies({ execute }, { readText: async () => { throw new Error('unreadable'); } });
    await expect(run(['type', '--app', 'TextEdit', '--text-file', 'missing.txt', '--json'], deps)).resolves.toBe(2);
    expect(execute).not.toHaveBeenCalled();
    expect(JSON.parse(deps.stdout[0])).toMatchObject({ error: { code: 'INVALID_ARGUMENT' } });
  });

  it('writes help and version without dispatching', async () => {
    const execute = vi.fn();
    const deps = dependencies({ execute });
    await expect(run(['--help'], deps)).resolves.toBe(0);
    await expect(run(['--version'], deps)).resolves.toBe(0);
    expect(execute).not.toHaveBeenCalled();
  });

  it('does not spawn backend after an already-aborted signal', async () => {
    const controller = new AbortController();
    controller.abort();
    const execute = vi.fn(async (request: Request) => success(request.command));
    const deps = dependencies({ execute }, { signal: controller.signal });
    await expect(run(['apps', '--json'], deps)).resolves.toBe(130);
    expect(execute).not.toHaveBeenCalled();
  });

  it('passes only remaining timeout budget to backend', async () => {
    const execute = vi.fn(async (request: Request) => success(request.command));
    const deps = dependencies({ execute }, { readText: async () => {
      await new Promise(resolve => setTimeout(resolve, 15));
      return 'input';
    } });
    await run(['type', '--app', 'TextEdit', '--text-file', '-', '--timeout', '100', '--json'], deps);
    expect(execute.mock.calls[0][0].options.timeoutMs).toBeLessThan(100);
  });

  it('returns TIMEOUT when a backend ignores the deadline signal', async () => {
    let backendSignal: AbortSignal | undefined;
    const backend: Backend = { execute: async (_request, signal) => {
      backendSignal = signal;
      await new Promise(resolve => setTimeout(resolve, 30));
      return success('apps');
    } };
    const deps = dependencies(backend);

    await expect(run(['apps', '--timeout', '10', '--json'], deps)).resolves.toBe(6);
    expect(backendSignal?.aborted).toBe(true);
    expect(JSON.parse(deps.stdout[0])).toMatchObject({ ok: false, error: { code: 'TIMEOUT' } });
  });

  it('waits for deadline cleanup and preserves mutation uncertainty', async () => {
    let cleaned = false;
    const backend: Backend = { execute: async (request, signal) => {
      await new Promise<void>(resolve => signal.addEventListener('abort', () => {
        setTimeout(() => { cleaned = true; resolve(); }, 5);
      }, { once: true }));
      return {
        schemaVersion: 1, ok: false, command: request.command,
        error: { code: 'INTERRUPTED', message: 'Interrupted', details: { mutationStatus: 'potentiallyApplied' } },
      };
    } };
    const deps = dependencies(backend);

    await expect(run(['type', '--app', 'TextEdit', '--text', 'private', '--timeout', '10', '--json'], deps)).resolves.toBe(6);
    expect(cleaned).toBe(true);
    expect(JSON.parse(deps.stdout[0])).toMatchObject({
      error: { code: 'TIMEOUT', details: { mutationStatus: 'potentiallyApplied' } },
    });
  });

  it('validates strict record IDs before reading input', async () => {
    const readText = vi.fn(async () => 'input');
    const deps = dependencies({ execute: async request => success(request.command) }, { readText });
    await run(['set-value', '--snapshot', snapshotId, '--ref', '1', '--text', 'input', '--json'], deps);
    expect(readText).not.toHaveBeenCalled();
  });

  it('rejects text input over 1 MiB as INVALID_ARGUMENT before dispatch', async () => {
    const execute = vi.fn(async (request: Request) => success(request.command));
    const deps = dependencies({ execute }, { readText: async () => 'x'.repeat(1_048_577) });
    await expect(run(['type', '--app', 'TextEdit', '--text-file', 'big.txt', '--json'], deps)).resolves.toBe(2);
    expect(execute).not.toHaveBeenCalled();
    expect(JSON.parse(deps.stdout[0])).toMatchObject({ error: { code: 'INVALID_ARGUMENT' } });
  });

  it('accepts text at exactly 1 MiB', async () => {
    const execute = vi.fn(async (request: Request) => success(request.command));
    const deps = dependencies({ execute }, { readText: async () => 'x'.repeat(1_048_576) });
    await expect(run(['type', '--app', 'TextEdit', '--text-file', 'big.txt', '--json'], deps)).resolves.toBe(0);
  });
});
