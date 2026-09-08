import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

type Fixture = { name: string; valid: boolean; request: Record<string, unknown> };
const host = fileURLToPath(new URL('../dist/native/computer-use-host', import.meta.url));

async function invoke(args: string[], input?: unknown): Promise<{ stdout: string; stderr: string; code: number | null }> {
  return await new Promise((resolve, reject) => {
    const child = spawn(host, args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => resolve({ stdout, stderr, code }));
    if (input !== undefined) child.stdin.write(`${JSON.stringify(input)}\n`);
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
      const result = await invoke([], fixture.request);
      const reply = JSON.parse(result.stdout) as { ok: boolean; error?: { code: string } };
      if (fixture.valid) expect(reply.error?.code, fixture.name).toBe('UNSUPPORTED_ACTION');
      else expect(reply.error?.code, fixture.name).toBe('PROTOCOL_ERROR');
      expect(result.stderr, fixture.name).toBe('');
    }
  });
});
