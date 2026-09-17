import { exitCode, formatReply } from './output.js';
import { parse, type ParsedInvocation, type TextSource } from './parse.js';
import { ArgumentError } from '../core/validate.js';
import type { Backend, Reply, Request } from '../core/protocol.js';

export type RunDependencies = {
  backend: Backend; signal: AbortSignal;
  readText(path: string, signal: AbortSignal): Promise<string>;
  writeStdout(text: string): void; writeStderr(text: string): void;
};

function failure(code: string, message: string, command?: Request['command']): Reply {
  return command === undefined
    ? { schemaVersion: 1, ok: false, error: { code, message } }
    : { schemaVersion: 1, ok: false, command, error: { code, message } };
}
function cancellationFailure(code: string, message: string, command: Request['command'], backendReply: Reply): Reply {
  const potentiallyApplied = !backendReply.ok && backendReply.error.details?.mutationStatus === 'potentiallyApplied';
  return {
    schemaVersion: 1, ok: false, command,
    error: { code, message, ...(potentiallyApplied ? { details: { mutationStatus: 'potentiallyApplied' } } : {}) },
  };
}
function requestedJson(argv: string[]): boolean { return argv.includes('--json'); }
function writeReply(reply: Reply, json: boolean, deps: RunDependencies): number {
  const output = formatReply(reply, json);
  if (json || reply.ok) deps.writeStdout(output); else deps.writeStderr(output);
  return exitCode(reply);
}
function commandOf(invocation: ParsedInvocation): Request['command'] | undefined {
  return invocation.kind === 'command' ? invocation.request.command : undefined;
}

const COMMAND_HELP: Record<Request['command'], string> = {
  doctor: 'doctor — report platform, helper version, dependencies, and OS permission status. Read-only.',
  apps: 'apps — list running applications (name, bundleId, pid).',
  windows: 'windows --app <name>|--pid <pid> [--window <id>] — list windows with eligibility and reason.',
  snapshot: 'snapshot --app <name>|--pid <pid> [--window <id>] [--depth N] [--max-elements N] [--hint-mode full|leafOnly|leafCompact] — capture the AX tree.',
  press: 'press --snapshot <uuid> --ref <n> — AXPress an element.',
  'set-value': 'set-value --snapshot <uuid> --ref <n> (--text <s>|--text-file <path>) — set AXValue.',
  type: 'type --app <name>|--pid <pid> (--text <s>|--text-file <path>) [--allow-clipboard-replace] — type text.',
  key: 'key [--app|--pid] --key <chord> (bare = global chord) — send a key/modifier combo.',
  scroll: 'scroll --app <name>|--pid <pid> --direction up|down|left|right [--amount n]  OR  scroll --snapshot <uuid> --ref <n>.',
  screenshot: 'screenshot [--app|--pid|--display <n>] --output <path> [--overwrite] [--annotated] [--native] — save a PNG of one window or a full display (logical size; --native for full Retina pixels).',
  click: 'click --capture <uuid> --x <n> --y <n> [--button left|right|middle] [--count 1|2|3].',
  move: 'move --capture <uuid> --x <n> --y <n> — move the pointer to an image pixel.',
  drag: 'drag --capture <uuid> --from <x,y> --to <x,y> — left-button drag between image pixels.',
};

function helpText(command: Request['command'] | undefined): string {
  const global = '\nGlobal flags: --json  --timeout <ms>  --cursor on|off  --help  --version\n';
  if (command === undefined) {
    const names = Object.keys(COMMAND_HELP).join(', ');
    return `Usage: nuvin-computer-use <command> [options]\nCommands: ${names}\n${global}`;
  }
  return `${COMMAND_HELP[command]}\n${global}`;
}

export async function run(argv: string[], deps: RunDependencies): Promise<number> {
  let invocation: ParsedInvocation;
  try { invocation = parse(argv); }
  catch (error) {
    return writeReply(failure('INVALID_ARGUMENT', error instanceof Error ? error.message : 'Invalid arguments'), requestedJson(argv), deps);
  }
  if (invocation.kind === 'help') {
    const text = helpText(invocation.command);
    deps.writeStdout(invocation.json ? `${JSON.stringify({ schemaVersion: 1, ok: true, data: { help: text } })}\n` : text);
    return 0;
  }
  if (invocation.kind === 'version') {
    const version = '0.1.0';
    deps.writeStdout(invocation.json ? `${JSON.stringify({ schemaVersion: 1, ok: true, data: { version } })}\n` : `${version}\n`);
    return 0;
  }

  const started = performance.now();
  const deadline = started + invocation.request.options.timeoutMs;
  const deadlineController = new AbortController();
  const onAbort = () => deadlineController.abort();
  deps.signal.addEventListener('abort', onAbort, { once: true });
  const timer = setTimeout(() => deadlineController.abort(), Math.max(0, deadline - performance.now()));
  try {
    if (deps.signal.aborted) return writeReply(failure('INTERRUPTED', 'Interrupted', commandOf(invocation)), invocation.json, deps);
    let request: Request;
    try { request = await resolveText(invocation.request, deps, deadlineController.signal); }
    catch (error) {
      const message = error instanceof ArgumentError ? error.message : 'Unable to read text input';
      const reply = deadlineController.signal.aborted
        ? failure(deps.signal.aborted ? 'INTERRUPTED' : 'TIMEOUT', deps.signal.aborted ? 'Interrupted' : 'Timed out', commandOf(invocation))
        : failure('INVALID_ARGUMENT', message, commandOf(invocation));
      return writeReply(reply, invocation.json, deps);
    }
    const remaining = Math.floor(deadline - performance.now());
    if (deps.signal.aborted) return writeReply(failure('INTERRUPTED', 'Interrupted', request.command), invocation.json, deps);
    if (remaining < 1 || deadlineController.signal.aborted) return writeReply(failure('TIMEOUT', 'Timed out', request.command), invocation.json, deps);
    request = { ...request, options: { ...request.options, timeoutMs: remaining } };
    try {
      const reply = await deps.backend.execute(request, deadlineController.signal);
      if (deps.signal.aborted) return writeReply(cancellationFailure('INTERRUPTED', 'Interrupted', request.command, reply), invocation.json, deps);
      if (deadlineController.signal.aborted) return writeReply(cancellationFailure('TIMEOUT', 'Timed out', request.command, reply), invocation.json, deps);
      return writeReply(reply, invocation.json, deps);
    }
    catch {
      if (deps.signal.aborted) return writeReply(failure('INTERRUPTED', 'Interrupted', request.command), invocation.json, deps);
      if (deadlineController.signal.aborted) return writeReply(failure('TIMEOUT', 'Timed out', request.command), invocation.json, deps);
      return writeReply(failure('NATIVE_FAILURE', 'Backend execution failed', request.command), invocation.json, deps);
    }
  } finally {
    clearTimeout(timer);
    deps.signal.removeEventListener('abort', onAbort);
  }
}

const MAX_TEXT_BYTES = 1_048_576; // 1 MiB

async function resolveText(request: Extract<ParsedInvocation, { kind: 'command' }>['request'], deps: RunDependencies, signal: AbortSignal): Promise<Request> {
  if (!('textSource' in request)) return request;
  const source: TextSource = request.textSource;
  const text = source.kind === 'literal' ? source.value : await deps.readText(source.path, signal);
  if (Buffer.byteLength(text, 'utf8') > MAX_TEXT_BYTES) {
    throw new ArgumentError('Text input exceeds the 1 MiB limit');
  }
  if (request.command === 'type') {
    return { schemaVersion: request.schemaVersion, options: request.options, command: 'type', target: request.target, text, allowClipboardReplace: request.allowClipboardReplace, ...(request.toProcess ? { toProcess: true } : {}) };
  }
  return { schemaVersion: request.schemaVersion, options: request.options, command: 'set-value', snapshotId: request.snapshotId, ref: request.ref, text };
}
