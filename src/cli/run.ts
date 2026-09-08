import { formatReply, exitCode } from './output.js';
import { parse, type ParsedInvocation, type TextSource } from './parse.js';
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
function requestedJson(argv: string[]): boolean { return argv.includes('--json'); }
function writeReply(reply: Reply, json: boolean, deps: RunDependencies): number {
  const output = formatReply(reply, json);
  if (json || reply.ok) deps.writeStdout(output); else deps.writeStderr(output);
  return exitCode(reply);
}
function commandOf(invocation: ParsedInvocation): Request['command'] | undefined {
  return invocation.kind === 'command' ? invocation.request.command : undefined;
}

export async function run(argv: string[], deps: RunDependencies): Promise<number> {
  let invocation: ParsedInvocation;
  try { invocation = parse(argv); }
  catch (error) {
    return writeReply(failure('INVALID_ARGUMENT', error instanceof Error ? error.message : 'Invalid arguments'), requestedJson(argv), deps);
  }
  if (invocation.kind === 'help') {
    const text = invocation.command === undefined ? 'Usage: nuvin-computer-use <command> [options]\n' : `Usage: nuvin-computer-use ${invocation.command} [options]\n`;
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
    catch {
      const reply = deadlineController.signal.aborted
        ? failure(deps.signal.aborted ? 'INTERRUPTED' : 'TIMEOUT', deps.signal.aborted ? 'Interrupted' : 'Timed out', commandOf(invocation))
        : failure('INVALID_ARGUMENT', 'Unable to read text input', commandOf(invocation));
      return writeReply(reply, invocation.json, deps);
    }
    const remaining = Math.floor(deadline - performance.now());
    if (deps.signal.aborted) return writeReply(failure('INTERRUPTED', 'Interrupted', request.command), invocation.json, deps);
    if (remaining < 1 || deadlineController.signal.aborted) return writeReply(failure('TIMEOUT', 'Timed out', request.command), invocation.json, deps);
    request = { ...request, options: { ...request.options, timeoutMs: remaining } };
    try { return writeReply(await deps.backend.execute(request, deadlineController.signal), invocation.json, deps); }
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

async function resolveText(request: Extract<ParsedInvocation, { kind: 'command' }>['request'], deps: RunDependencies, signal: AbortSignal): Promise<Request> {
  if (!('textSource' in request)) return request;
  const source: TextSource = request.textSource;
  const text = source.kind === 'literal' ? source.value : await deps.readText(source.path, signal);
  if (request.command === 'type') {
    return { schemaVersion: request.schemaVersion, options: request.options, command: 'type', target: request.target, text, allowClipboardReplace: request.allowClipboardReplace };
  }
  return { schemaVersion: request.schemaVersion, options: request.options, command: 'set-value', snapshotId: request.snapshotId, ref: request.ref, text };
}
