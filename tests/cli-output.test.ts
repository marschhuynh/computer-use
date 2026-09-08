import { describe, expect, it } from 'vitest';
import { exitCode, formatReply } from '../src/cli/output.js';
import type { Reply } from '../src/core/protocol.js';

const success: Reply = { schemaVersion: 1, ok: true, command: 'apps', data: { apps: [] } };
const invalid: Reply = { schemaVersion: 1, ok: false, error: { code: 'INVALID_ARGUMENT', message: 'Unknown command' } };

describe('CLI output', () => {
  it('formats JSON as exactly one ANSI-free object', () => {
    const output = formatReply(invalid, true);
    expect(output).not.toMatch(/\u001B/);
    expect(output.trim().split('\n')).toHaveLength(1);
    expect(JSON.parse(output)).toEqual(invalid);
  });

  it('formats text output for success and errors', () => {
    expect(formatReply(success, false)).toContain('apps');
    expect(formatReply(invalid, false)).toContain('INVALID_ARGUMENT');
  });

  it.each([
    ['NATIVE_FAILURE', 1], ['INVALID_ARGUMENT', 2], ['MISSING_HELPER', 3],
    ['PERMISSION_DENIED', 4], ['STALE_SNAPSHOT', 5], ['TIMEOUT', 6], ['INTERRUPTED', 130],
  ])('maps %s to exit %s', (code, expected) => {
    const reply: Reply = { schemaVersion: 1, ok: false, error: { code, message: 'failed' } };
    expect(exitCode(reply)).toBe(expected);
  });

  it('maps success to zero and unknown errors to native failure', () => {
    expect(exitCode(success)).toBe(0);
    expect(exitCode({ schemaVersion: 1, ok: false, error: { code: 'NEW_ERROR', message: 'failed' } })).toBe(1);
  });
});
