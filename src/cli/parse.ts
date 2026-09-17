import { parseArgs } from 'node:util';
import { DEFAULT_TIMEOUT_MS, type Command, type Direction, type Options, type Point, type Target, type TreeOptions } from '../core/protocol.js';
import { ArgumentError, pixel, recordId, safeInteger, timeout } from '../core/validate.js';

export type TextSource = { kind: 'literal'; value: string } | { kind: 'file'; path: string };
type TextCommand = Extract<Command, { command: 'type' | 'set-value' }>;
type DraftTextCommand<T = TextCommand> = T extends TextCommand ? Omit<T, 'text'> & { textSource: TextSource } : never;
type DraftRequest = { schemaVersion: 1; options: Options } & (Exclude<Command, TextCommand> | DraftTextCommand);
export type ParsedInvocation =
  | { kind: 'help'; command?: Command['command']; json: boolean }
  | { kind: 'version'; json: boolean }
  | { kind: 'command'; request: DraftRequest; json: boolean };

type ValueName = 'app' | 'pid' | 'window' | 'depth' | 'max-elements' | 'hint-mode' | 'snapshot' | 'ref' | 'text' | 'text-file' | 'key' | 'direction' | 'amount' | 'output' | 'capture' | 'x' | 'y' | 'button' | 'count' | 'from' | 'to' | 'timeout' | 'cursor';
type FlagName = 'json' | 'help' | 'version' | 'allow-clipboard-replace' | 'overwrite' | 'annotated' | 'native';
const commandNames = new Set<Command['command']>(['doctor', 'apps', 'windows', 'snapshot', 'press', 'set-value', 'type', 'key', 'scroll', 'screenshot', 'click', 'move', 'drag']);
const commonValues: ValueName[] = ['timeout', 'cursor'];
const commonFlags: FlagName[] = ['json', 'help', 'version'];

function parseFlags(argv: string[], values: ValueName[], flags: FlagName[]): Record<string, string | boolean | undefined> {
  try {
    const parsed = parseArgs({ args: argv, options: Object.fromEntries([
      ...[...new Set([...commonValues, ...values])].map(name => [name, { type: 'string' }]),
      ...[...new Set([...commonFlags, ...flags])].map(name => [name, { type: 'boolean' }]),
    ]), allowPositionals: false, strict: true }).values;
    const result: Record<string, string | boolean | undefined> = {};
    for (const [name, value] of Object.entries(parsed)) {
      if (typeof value !== 'string' && typeof value !== 'boolean' && value !== undefined) throw new ArgumentError(`--${name} may not be repeated`);
      result[name] = value;
    }
    return result;
  } catch (error) {
    throw new ArgumentError(error instanceof Error ? error.message : 'Invalid arguments');
  }
}

function stringValue(values: Record<string, string | boolean | undefined>, name: ValueName): string | undefined {
  const value = values[name];
  return typeof value === 'string' ? value : undefined;
}
function required(values: Record<string, string | boolean | undefined>, name: ValueName): string {
  const value = stringValue(values, name);
  if (value === undefined || value === '') throw new ArgumentError(`--${name} is required`);
  return value;
}
function flag(values: Record<string, string | boolean | undefined>, name: FlagName): boolean { return values[name] === true; }
function options(values: Record<string, string | boolean | undefined>): Options {
  const cursor = stringValue(values, 'cursor') ?? 'on';
  if (cursor !== 'on' && cursor !== 'off') throw new ArgumentError('--cursor must be on or off');
  return { timeoutMs: stringValue(values, 'timeout') === undefined ? DEFAULT_TIMEOUT_MS : timeout(required(values, 'timeout')), cursor };
}
function target(values: Record<string, string | boolean | undefined>): Target {
  const app = stringValue(values, 'app');
  const pid = stringValue(values, 'pid');
  if ((app === undefined) === (pid === undefined)) throw new ArgumentError('exactly one of --app or --pid is required');
  const window = stringValue(values, 'window');
  const windowId = window === undefined ? undefined : safeInteger(window, 'window');
  if (app !== undefined) {
    if (app === '') throw new ArgumentError('--app is required');
    return windowId === undefined ? { app } : { app, windowId };
  }
  const parsedPid = safeInteger(required(values, 'pid'), 'pid');
  return windowId === undefined ? { pid: parsedPid } : { pid: parsedPid, windowId };
}
function tree(values: Record<string, string | boolean | undefined>): TreeOptions {
  const hintMode = stringValue(values, 'hint-mode') ?? 'leafCompact';
  if (hintMode !== 'full' && hintMode !== 'leafOnly' && hintMode !== 'leafCompact') throw new ArgumentError('invalid --hint-mode');
  return { maxDepth: stringValue(values, 'depth') === undefined ? 8 : safeInteger(required(values, 'depth'), 'depth'), maxElements: stringValue(values, 'max-elements') === undefined ? 500 : safeInteger(required(values, 'max-elements'), 'max-elements'), hintMode };
}
function point(values: Record<string, string | boolean | undefined>, xName: ValueName, yName: ValueName): Point {
  return { x: pixel(required(values, xName), xName), y: pixel(required(values, yName), yName) };
}
function tuplePoint(values: Record<string, string | boolean | undefined>, name: 'from' | 'to'): Point {
  const parts = required(values, name).split(',');
  if (parts.length !== 2) throw new ArgumentError(`--${name} must be x,y`);
  return { x: pixel(parts[0], name), y: pixel(parts[1], name) };
}
function textSource(values: Record<string, string | boolean | undefined>): TextSource {
  const literal = stringValue(values, 'text');
  const file = stringValue(values, 'text-file');
  if ((literal === undefined) === (file === undefined)) throw new ArgumentError('exactly one of --text or --text-file is required');
  return literal === undefined ? { kind: 'file', path: required(values, 'text-file') } : { kind: 'literal', value: literal };
}

export function parse(argv: string[]): ParsedInvocation {
  if (argv.length === 0) return { kind: 'help', json: false };
  if (argv[0].startsWith('-')) {
    const values = parseFlags(argv, [], []);
    const json = flag(values, 'json');
    if (flag(values, 'version')) return { kind: 'version', json };
    if (flag(values, 'help')) return { kind: 'help', json };
    throw new ArgumentError('A command is required');
  }
  const command = argv[0] as Command['command'];
  if (!commandNames.has(command)) throw new ArgumentError(`Unknown command: ${argv[0]}`);
  const commandArgs = argv.slice(1);
  const valuesFor: Record<Command['command'], [ValueName[], FlagName[]]> = {
    doctor: [[], []], apps: [[], []], windows: [['app', 'pid', 'window'], []],
    snapshot: [['app', 'pid', 'window', 'depth', 'max-elements', 'hint-mode'], []],
    press: [['snapshot', 'ref'], []], 'set-value': [['snapshot', 'ref', 'text', 'text-file'], []],
    type: [['app', 'pid', 'window', 'text', 'text-file'], ['allow-clipboard-replace']], key: [['app', 'pid', 'window', 'key'], []],
    scroll: [['app', 'pid', 'window', 'snapshot', 'ref', 'direction', 'amount'], []],
    screenshot: [['app', 'pid', 'window', 'output', 'depth', 'max-elements', 'hint-mode'], ['overwrite', 'annotated', 'native']],
    click: [['capture', 'x', 'y', 'button', 'count'], []], move: [['capture', 'x', 'y'], []], drag: [['capture', 'from', 'to'], []],
  };
  const [valueNames, flagNames] = valuesFor[command];
  const values = parseFlags(commandArgs, valueNames, flagNames);
  const json = flag(values, 'json');
  if (flag(values, 'version')) return { kind: 'version', json };
  if (flag(values, 'help')) return { kind: 'help', command, json };
  const base = { schemaVersion: 1 as const, options: options(values) };
  let request: DraftRequest;
  switch (command) {
    case 'doctor': case 'apps': request = { ...base, command }; break;
    case 'windows': request = { ...base, command, target: target(values) }; break;
    case 'snapshot': request = { ...base, command, target: target(values), tree: tree(values) }; break;
    case 'press': request = { ...base, command, snapshotId: recordId(required(values, 'snapshot'), 'snapshot'), ref: safeInteger(required(values, 'ref'), 'ref') }; break;
    case 'set-value': request = { ...base, command, snapshotId: recordId(required(values, 'snapshot'), 'snapshot'), ref: safeInteger(required(values, 'ref'), 'ref'), textSource: textSource(values) }; break;
    case 'type': request = { ...base, command, target: target(values), textSource: textSource(values), allowClipboardReplace: flag(values, 'allow-clipboard-replace') }; break;
    case 'key': request = { ...base, command, target: target(values), key: required(values, 'key') }; break;
    case 'scroll': {
      const snapshot = stringValue(values, 'snapshot');
      const ref = stringValue(values, 'ref');
      const direction = stringValue(values, 'direction');
      const amount = stringValue(values, 'amount');
      if (snapshot !== undefined || ref !== undefined) {
        if (direction !== undefined || amount !== undefined || stringValue(values, 'app') !== undefined
          || stringValue(values, 'pid') !== undefined || stringValue(values, 'window') !== undefined) {
          throw new ArgumentError('scroll forms are mutually exclusive');
        }
        request = {
          ...base,
          command,
          snapshotId: recordId(required(values, 'snapshot'), 'snapshot'),
          ref: safeInteger(required(values, 'ref'), 'ref'),
        };
      } else {
        if (direction !== 'up' && direction !== 'down' && direction !== 'left' && direction !== 'right') {
          throw new ArgumentError('--direction is required and must be valid');
        }
        request = {
          ...base,
          command,
          target: target(values),
          direction: direction as Direction,
          amount: amount === undefined ? 3 : safeInteger(required(values, 'amount'), 'amount'),
        };
      }
      break;
    }
    case 'screenshot': request = { ...base, command, target: target(values), output: required(values, 'output'), overwrite: flag(values, 'overwrite'), annotated: flag(values, 'annotated'), native: flag(values, 'native'), tree: tree(values) }; break;
    case 'click': {
      const button = stringValue(values, 'button') ?? 'left'; const count = stringValue(values, 'count') === undefined ? 1 : safeInteger(required(values, 'count'), 'count');
      if (button !== 'left' && button !== 'right' && button !== 'middle') throw new ArgumentError('invalid --button');
      if (count !== 1 && count !== 2 && count !== 3) throw new ArgumentError('--count must be 1, 2, or 3');
      request = { ...base, command, captureId: recordId(required(values, 'capture'), 'capture'), point: point(values, 'x', 'y'), button, count }; break;
    }
    case 'move': request = { ...base, command, captureId: recordId(required(values, 'capture'), 'capture'), point: point(values, 'x', 'y') }; break;
    case 'drag': request = { ...base, command, captureId: recordId(required(values, 'capture'), 'capture'), from: tuplePoint(values, 'from'), to: tuplePoint(values, 'to') }; break;
  }
  return { kind: 'command', request, json };
}
