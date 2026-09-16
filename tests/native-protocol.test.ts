import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const INVOCATION_TIMEOUT_MS = 15_000;
const CLEANUP_GRACE_MS = 2_000;
const configuredHost = process.env.NUVIN_COMPUTER_USE_TEST_HOST;
if (configuredHost === undefined || configuredHost === '') {
  throw new Error('NUVIN_COMPUTER_USE_TEST_HOST is required; run npm run test:native-protocol');
}
const host = resolve(configuredHost);

type Fixture = { name: string; valid: boolean; request: Record<string, unknown> };
type Invocation = { stdout: string; stderr: string; code: number | null };

const activeChildren = new Set<ChildProcessWithoutNullStreams>();

function waitForClose(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolveClose, reject) => {
    const timer = setTimeout(() => {
      child.removeListener('close', close);
      reject(new Error(`native protocol child did not exit within ${timeoutMs} ms`));
    }, timeoutMs);
    const close = () => {
      clearTimeout(timer);
      resolveClose();
    };
    child.once('close', close);
  });
}

async function terminateAndWait(child: ChildProcessWithoutNullStreams): Promise<void> {
  child.stdin.destroy();
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  try {
    await waitForClose(child, CLEANUP_GRACE_MS);
  } catch {
    child.kill('SIGKILL');
    await waitForClose(child, 1_000);
  }
}

async function invoke(args: string[], input?: string, closeStdin = false): Promise<Invocation> {
  const child = spawn(host, args, { shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
  activeChildren.add(child);
  child.stdin.on('error', () => {});
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });

  const completion = new Promise<Invocation>((resolveInvocation, reject) => {
    child.once('error', reject);
    child.once('close', code => resolveInvocation({ stdout, stderr, code }));
    if (input !== undefined) {
      if (closeStdin) child.stdin.end(input);
      else child.stdin.write(input);
    }
  });
  let timeoutTimer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timeoutTimer = setTimeout(
      () => reject(new Error(`native protocol invocation exceeded ${INVOCATION_TIMEOUT_MS} ms`)),
      INVOCATION_TIMEOUT_MS,
    );
  });

  try {
    return await Promise.race([completion, timeout]);
  } finally {
    if (timeoutTimer !== undefined) clearTimeout(timeoutTimer);
    await terminateAndWait(child);
    activeChildren.delete(child);
  }
}

afterEach(async () => {
  await Promise.all([...activeChildren].map(terminateAndWait));
  activeChildren.clear();
});

describe('fresh native protocol integration', { timeout: 120_000 }, () => {
  it('reports the binding protocol version without GUI work', async () => {
    await expect(invoke(['--protocol-version'])).resolves.toEqual({ stdout: '1\n', stderr: '', code: 0 });
  });

  it('rejects every invalid shared request before native command dispatch', async () => {
    const fixtures = JSON.parse(
      await readFile(new URL('../contracts/fixtures/native-protocol.json', import.meta.url), 'utf8'),
    ) as { cases: Fixture[] };
    const invalid = fixtures.cases.filter(fixture => !fixture.valid);
    expect(invalid.length).toBeGreaterThan(0);
    for (const fixture of invalid) {
      const result = await invoke([], `${JSON.stringify(fixture.request)}\n`);
      expect(result.code, fixture.name).toBe(0);
      expect(JSON.parse(result.stdout), fixture.name).toMatchObject({
        schemaVersion: 1,
        ok: false,
        error: { code: 'PROTOCOL_ERROR' },
      });
      expect(result.stderr, fixture.name).toBe('');
    }
  });

  it('rejects an unterminated request with one structured response', async () => {
    const request = JSON.stringify({ schemaVersion: 1, command: 'apps', options: { timeoutMs: 1, cursor: 'on' } });
    const result = await invoke([], request, true);
    const replies = result.stdout.trim().split('\n');
    expect(result.code).toBe(0);
    expect(replies).toHaveLength(1);
    expect(JSON.parse(replies[0])).toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    expect(result.stderr).toBe('');
  });

  it('shuts down silently on empty stdin EOF', async () => {
    const result = await invoke([], '', true);
    expect(result.code).toBe(0);
    expect(result.stdout).toBe('');
    expect(result.stderr).toBe('');
  });

  it('rejects a request line over the 1 MiB protocol limit with one structured response', async () => {
    const result = await invoke([], `${'x'.repeat(1_048_577)}\n`, true);
    const replies = result.stdout.trim().split('\n');
    expect(result.code).toBe(0);
    expect(replies).toHaveLength(1);
    expect(JSON.parse(replies[0])).toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    expect(result.stderr).toBe('');
  });
});
