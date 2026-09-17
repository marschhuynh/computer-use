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

  it('exits 0 for a ready doctor', () => {
    const reply: Reply = { schemaVersion: 1, ok: true, command: 'doctor', data: { ready: true, checks: [] } };
    expect(exitCode(reply)).toBe(0);
  });

  it('maps a denied doctor check to the permission exit', () => {
    const reply: Reply = {
      schemaVersion: 1, ok: true, command: 'doctor',
      data: { ready: false, checks: [
        { name: 'helper-protocol', status: 'ok', message: 'ok' },
        { name: 'accessibility', status: 'denied', message: 'no access' },
      ] },
    };
    expect(exitCode(reply)).toBe(4);
  });

  it('maps a missing doctor check to the missing-dependency exit', () => {
    const reply: Reply = {
      schemaVersion: 1, ok: true, command: 'doctor',
      data: { ready: false, checks: [{ name: 'native-dependencies', status: 'missing', message: 'absent' }] },
    };
    expect(exitCode(reply)).toBe(3);
  });

  it('maps an unknown-status doctor check to a generic failure exit', () => {
    const reply: Reply = {
      schemaVersion: 1, ok: true, command: 'doctor',
      data: { ready: false, checks: [{ name: 'accessibility', status: 'unknown', message: 'indeterminate' }] },
    };
    expect(exitCode(reply)).toBe(1);
  });
});
