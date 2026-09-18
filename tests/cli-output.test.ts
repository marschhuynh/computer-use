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
    ['PERMISSION_DENIED', 4], ['STALE_SNAPSHOT', 5], ['FOCUS_FAILED', 5], ['TIMEOUT', 6], ['INTERRUPTED', 130],
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

  it('formats apps as a readable table and escapes control characters', () => {
    const reply: Reply = {
      schemaVersion: 1, ok: true, command: 'apps',
      data: { apps: [
        { name: 'Editor\r\n', pid: 42, bundleId: 'com.example.Editor' },
        { name: 'Bad\x1B[31mApp', pid: 43, bundleId: null },
      ] },
    };
    const out = formatReply(reply, false);
    expect(out).toContain('Editor');
    // raw control characters must not reach the terminal
    expect(out).not.toMatch(/\r/);
    expect(out).not.toMatch(/\x1B\[/);
    expect(out).not.toMatch(/\n.*\n.*\n.*\n/); // no embedded newlines from the name
    expect(out).toContain('42');
    expect(out).toContain('com.example.Editor');
  });

  it('formats windows with eligibility and reason', () => {
    const reply: Reply = {
      schemaVersion: 1, ok: true, command: 'windows',
      data: { windows: [
        { id: 7, title: 'Doc', bounds: { x: 0, y: 0, width: 100, height: 100 }, eligible: true, reason: null },
        { id: 8, title: 'Min', bounds: { x: 0, y: 0, width: 100, height: 100 }, eligible: false, reason: 'minimized' },
      ] },
    };
    const out = formatReply(reply, false);
    expect(out).toContain('7');
    expect(out).toContain('Doc');
    expect(out).toContain('minimized');
    expect(out).toContain('eligible');
  });

  it('formats doctor with check statuses', () => {
    const reply: Reply = {
      schemaVersion: 1, ok: true, command: 'doctor',
      data: { ready: false, checks: [
        { name: 'accessibility', status: 'denied', message: 'no access' },
      ] },
    };
    const out = formatReply(reply, false);
    expect(out).toContain('accessibility');
    expect(out).toContain('denied');
  });

  // Status acceptance matrix: every command maps a result to the spec's exit
  // class; mutating commands surface mutationStatus when present.
  const MUTATING = ['press', 'set-value', 'type', 'key', 'scroll', 'click', 'move', 'drag'];
  it.each([
    ['apps', 'TARGET_NOT_FOUND', 5],
    ['windows', 'AMBIGUOUS_TARGET', 5],
    ['snapshot', 'STALE_SNAPSHOT', 5],
    ['press', 'STALE_SNAPSHOT', 5],
    ['set-value', 'EXECUTION_UNCERTAIN', 1],
    ['type', 'PERMISSION_DENIED', 4],
    ['key', 'TIMEOUT', 6],
    ['scroll', 'BUSY', 6],
    ['screenshot', 'PERMISSION_DENIED', 4],
    ['click', 'STALE_CAPTURE', 5],
    ['move', 'STALE_CAPTURE', 5],
    ['drag', 'EXECUTION_UNCERTAIN', 1],
  ])('maps %s/%s to exit %s', (command, code, expected) => {
    const reply: Reply = {
      schemaVersion: 1, ok: false, command: command as Reply['command'],
      error: { code, message: 'failed' },
    };
    expect(exitCode(reply)).toBe(expected);
  });

  it.each(MUTATING)('%s surfaces mutationStatus on failure', command => {
    const reply: Reply = {
      schemaVersion: 1, ok: false, command: command as Reply['command'],
      error: { code: 'NATIVE_FAILURE', message: 'x', details: { mutationStatus: 'potentiallyApplied' } },
    };
    const out = formatReply(reply, true);
    expect(JSON.parse(out).error.details.mutationStatus).toBe('potentiallyApplied');
    expect(exitCode(reply)).toBe(1);
  });
});
