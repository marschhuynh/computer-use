import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';
import { parse } from '../src/cli/parse.js';

const snapshotId = '123e4567-e89b-42d3-a456-426614174000';
const captureId = '123e4567-e89b-42d3-a456-426614174001';

type ProtocolFixture = { name: string; valid: boolean; argv?: string[] };
const protocolFixtures = (JSON.parse(
  readFileSync(new URL('../contracts/fixtures/native-protocol.json', import.meta.url), 'utf8'),
) as { cases: ProtocolFixture[] }).cases.filter(
  (fixture): fixture is ProtocolFixture & { argv: string[] } => fixture.argv !== undefined,
);

describe('parse', () => {
  it.each([
    [['doctor'], 'doctor'],
    [['apps'], 'apps'],
    [['windows', '--app', 'Safari'], 'windows'],
    [['snapshot', '--pid', '42'], 'snapshot'],
    [['press', '--snapshot', snapshotId, '--ref', '2'], 'press'],
    [['set-value', '--snapshot', snapshotId, '--ref', '2', '--text', 'value'], 'set-value'],
    [['type', '--app', 'TextEdit', '--text-file', '-'], 'type'],
    [['key', '--pid', '42', '--key', 'cmd+s'], 'key'],
    [['scroll', '--app', 'Safari', '--direction', 'down'], 'scroll'],
    [['scroll', '--snapshot', snapshotId, '--ref', '2'], 'scroll'],
    [['screenshot', '--app', 'Safari', '--output', 'image.png'], 'screenshot'],
    [['click', '--capture', captureId, '--x', '1', '--y', '2'], 'click'],
    [['move', '--capture', captureId, '--x', '1', '--y', '2'], 'move'],
    [['drag', '--capture', captureId, '--from', '1,2', '--to', '3,4'], 'drag'],
  ])('parses %j', (argv, command) => {
    const parsed = parse(argv);
    expect(parsed).toMatchObject({ kind: 'command', request: { command } });
  });

  it('parses targetless key and screenshot', () => {
    expect(parse(['key', '--key', 'cmd+space'])).toMatchObject({ request: { command: 'key', target: undefined } });
    expect(parse(['screenshot', '--output', '/tmp/x.png'])).toMatchObject({ request: { command: 'screenshot', target: undefined } });
    expect(parse(['screenshot', '--output', '/tmp/x.png', '--display', '1']))
      .toMatchObject({ request: { command: 'screenshot', display: 1 } });
  });

  it('rejects screenshot target+display', () => {
    expect(() => parse(['screenshot', '--app', 'X', '--display', '0', '--output', '/tmp/x.png'])).toThrow();
  });

  it('uses documented defaults and explicit snapshot targeting', () => {
    expect(parse(['snapshot', '--pid', '42', '--window', '7', '--json'])).toMatchObject({
      kind: 'command', json: true,
      request: { options: { timeoutMs: 15_000, cursor: 'on' }, target: { pid: 42, windowId: 7 }, tree: { maxDepth: 8, maxElements: 500, hintMode: 'leafCompact' } },
    });
  });

  it.each([
    [['snapshot', '--wat'], /Unknown option/],
    [['snapshot', '--app', 'Safari', '--pid', '42'], /exactly one/],
    [['click', '--capture', captureId, '--x=-1', '--y', '0'], /nonnegative/],
    [['click', '--capture', captureId, '--x', 'NaN', '--y', '0'], /finite/],
    [['screenshot', '--app', 'Safari'], /--output/],
    [['type', '--app', 'TextEdit', '--text', 'x', '--text-file', 'x.txt'], /exactly one/],
    [['set-value', '--snapshot', snapshotId, '--ref', '1'], /exactly one/],
    [['press', '--snapshot', 'not-an-id', '--ref', '1'], /UUID/],
    [['click', '--capture', 'not-an-id', '--x', '0', '--y', '0'], /UUID/],
    [['scroll', '--snapshot', snapshotId, '--ref', '1', '--app', 'Safari', '--direction', 'down'], /mutually exclusive/],
  ])('rejects invalid arguments %j', (argv, message) => {
    expect(() => parse(argv)).toThrow(message);
  });

  it.each([['1', true], ['120000', true], ['0', false], ['-1', false], ['1.5', false], ['120001', false], ['9007199254740992', false]])('enforces timeout %s', (timeout, valid) => {
    const invoke = () => parse(['apps', '--timeout', timeout]);
    if (valid) expect(invoke).not.toThrow();
    else expect(invoke).toThrow(/timeout/i);
  });

  it('supports help and version without a command', () => {
    expect(parse(['--help'])).toEqual({ kind: 'help', json: false });
    expect(parse(['--version', '--json'])).toEqual({ kind: 'version', json: true });
  });

  it('matches shared request-fixture validity for every CLI-backed case', () => {
    for (const fixture of protocolFixtures) {
      const parseFixture = () => parse(fixture.argv);
      if (fixture.valid) expect(parseFixture, fixture.name).not.toThrow();
      else expect(parseFixture, fixture.name).toThrow();
    }
  });

});
