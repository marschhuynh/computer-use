import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { parse } from '../src/cli/parse.js';

type Fixture = { name: string; valid: boolean; argv?: string[]; request: Record<string, unknown> };
const host = fileURLToPath(new URL('../dist/native/computer-use-host', import.meta.url));

async function invoke(args: string[], input?: string, closeStdin = false): Promise<{ stdout: string; stderr: string; code: number | null }> {
  return await new Promise((resolve, reject) => {
    const child = spawn(host, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => resolve({ stdout, stderr, code }));
    if (input !== undefined) {
      if (closeStdin) child.stdin.end(input);
      else child.stdin.write(input);
    }
  });
}

describe('native protocol fixtures', () => {
  it('reports the binding protocol version without GUI work', async () => {
    const result = await invoke(['--protocol-version']);
    expect(result).toEqual({ stdout: '1\n', stderr: '', code: 0 });
  });

  it('accepts and rejects the shared fixture shapes', async () => {
    const fixtures = JSON.parse(await readFile(new URL('../contracts/fixtures/native-protocol.json', import.meta.url), 'utf8')) as { cases: Fixture[] };
    for (const fixture of fixtures.cases) {
      const result = await invoke([], `${JSON.stringify(fixture.request)}\n`);
      const reply = JSON.parse(result.stdout) as { ok: boolean; error?: { code: string } };
      if (fixture.valid) expect(reply.error?.code, fixture.name).toBe('UNSUPPORTED_ACTION');
      else expect(reply.error?.code, fixture.name).toBe('PROTOCOL_ERROR');
      expect(result.stderr, fixture.name).toBe('');
    }
  });

  it('matches TypeScript safe-integer and app validation for shared CLI fixtures', async () => {
    const fixtures = JSON.parse(await readFile(new URL('../contracts/fixtures/native-protocol.json', import.meta.url), 'utf8')) as { cases: Fixture[] };
    for (const fixture of fixtures.cases) {
      const argv = fixture.argv;
      if (argv === undefined) continue;
      const parseFixture = () => parse(argv);
      if (fixture.valid) expect(parseFixture, fixture.name).not.toThrow();
      else expect(parseFixture, fixture.name).toThrow();
    }
  });

  it('rejects an unterminated request with one structured response', async () => {
    const request = JSON.stringify({ schemaVersion: 1, command: 'apps', options: { timeoutMs: 1, cursor: 'on' } });
    const result = await invoke([], request, true);
    const replies = result.stdout.trim().split('\n');
    expect(replies).toHaveLength(1);
    expect(JSON.parse(replies[0])).toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    expect(result.stderr).toBe('');
  });

  it('rejects a request line over the 1 MiB protocol limit with one structured response', async () => {
    const result = await invoke([], `${'x'.repeat(1_048_577)}\n`, true);
    const replies = result.stdout.trim().split('\n');
    expect(replies).toHaveLength(1);
    expect(JSON.parse(replies[0])).toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    expect(result.stderr).toBe('');
  });

  it('finishes quick staged work while the parent lifecycle channel remains open', async () => {
    const request = JSON.stringify({ schemaVersion: 1, command: 'apps', options: { timeoutMs: 1, cursor: 'on' } });
    const result = await invoke([], `${request}\n`);
    expect(JSON.parse(result.stdout)).toMatchObject({ ok: false, error: { code: 'UNSUPPORTED_ACTION' } });
    expect(result.stderr).toBe('');
  });
});
