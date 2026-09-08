import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import type { Backend, JsonValue, Reply, Request } from '../core/protocol.js';

const PROTOCOL_VERSION = '1';
const MAX_STDOUT_BYTES = 16 * 1024 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;
const CLEANUP_GRACE_MS = 2_000;

type StopReason = 'aborted' | 'timeout' | 'stdout-overflow' | 'stderr-overflow';
type Invocation = {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: Buffer;
  stderr: Buffer;
  stopReason?: StopReason;
  spawnError?: NodeJS.ErrnoException;
};

type MacOSBackendOptions = { helper?: string | URL };

export class MacOSBackend implements Backend {
  readonly #helper: string;

  constructor(options: MacOSBackendOptions = {}) {
    this.#helper = options.helper instanceof URL
      ? fileURLToPath(options.helper)
      : (options.helper ?? fileURLToPath(new URL('../native/computer-use-host', import.meta.url)));
  }

  async execute(request: Request, signal: AbortSignal): Promise<Reply> {
    if (signal.aborted) return failure(request, 'INTERRUPTED', 'Interrupted');

    const deadline = performance.now() + request.options.timeoutMs;
    const probe = await invoke(this.#helper, ['--protocol-version'], undefined, signal, deadline);
    const probeFailure = invocationFailure(request, probe, false);
    if (probeFailure !== undefined) return probeFailure;
    if (probe.code !== 0) return failure(request, 'NATIVE_FAILURE', 'Native helper version probe failed');
    if (probe.stdout.toString('utf8').trim() !== PROTOCOL_VERSION) {
      return failure(request, 'HELPER_VERSION_MISMATCH', 'Native helper protocol version is incompatible');
    }

    const remaining = Math.floor(deadline - performance.now());
    if (signal.aborted) return failure(request, 'INTERRUPTED', 'Interrupted');
    if (remaining < 1) return failure(request, 'TIMEOUT', 'Timed out');

    const nativeRequest: Request = { ...request, options: { ...request.options, timeoutMs: remaining } };
    const execution = await invoke(this.#helper, [], `${JSON.stringify(nativeRequest)}\n`, signal, deadline);
    const executionFailure = invocationFailure(request, execution, true);
    if (executionFailure !== undefined) return executionFailure;
    if (execution.code !== 0) return failure(request, 'NATIVE_FAILURE', 'Native helper execution failed');

    let value: unknown;
    try { value = JSON.parse(execution.stdout.toString('utf8')); }
    catch { return failure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response'); }
    try {
      return validReply(value, request) ? value : failure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response');
    } catch {
      return failure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response');
    }
  }
}

function invoke(helper: string, args: string[], input: string | undefined, signal: AbortSignal, deadline: number): Promise<Invocation> {
  return new Promise(resolve => {
    const child = spawn(helper, args, { shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let stopReason: StopReason | undefined;
    let spawnError: NodeJS.ErrnoException | undefined;
    let closed = false;
    let forceTimer: NodeJS.Timeout | undefined;

    const requestStop = (reason: StopReason) => {
      if (stopReason !== undefined || closed) return;
      stopReason = reason;
      child.stdin.destroy();
      child.kill('SIGTERM');
      forceTimer = setTimeout(() => {
        if (!closed) child.kill('SIGKILL');
      }, CLEANUP_GRACE_MS);
    };
    const abort = () => requestStop('aborted');
    signal.addEventListener('abort', abort, { once: true });
    const deadlineTimer = setTimeout(() => requestStop('timeout'), Math.max(0, deadline - performance.now()));

    child.stdout.on('data', (chunk: Buffer) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes > MAX_STDOUT_BYTES) requestStop('stdout-overflow');
      else stdout.push(chunk);
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderrBytes += chunk.length;
      if (stderrBytes > MAX_STDERR_BYTES) requestStop('stderr-overflow');
      else stderr.push(chunk);
    });
    child.stdin.on('error', () => {});
    child.once('error', error => { spawnError = error; });
    child.once('close', (code, exitSignal) => {
      closed = true;
      clearTimeout(deadlineTimer);
      if (forceTimer !== undefined) clearTimeout(forceTimer);
      signal.removeEventListener('abort', abort);
      child.stdin.destroy();
      resolve({
        code,
        signal: exitSignal,
        stdout: Buffer.concat(stdout),
        stderr: Buffer.concat(stderr),
        ...(stopReason === undefined ? {} : { stopReason }),
        ...(spawnError === undefined ? {} : { spawnError }),
      });
    });

    if (signal.aborted) requestStop('aborted');
    else if (input !== undefined) child.stdin.write(input);
  });
}

function invocationFailure(request: Request, invocation: Invocation, requestWasSent: boolean): Reply | undefined {
  if (invocation.spawnError !== undefined) {
    const code = invocation.spawnError.code;
    return code === 'ENOENT' || code === 'ENOTDIR'
      ? failure(request, 'MISSING_HELPER', 'Native helper was not found')
      : failure(request, 'NATIVE_FAILURE', 'Unable to start native helper');
  }
  switch (invocation.stopReason) {
    case 'aborted': return cancellationFailure(request, 'INTERRUPTED', 'Interrupted', requestWasSent);
    case 'timeout': return cancellationFailure(request, 'TIMEOUT', 'Timed out', requestWasSent);
    case 'stdout-overflow':
    case 'stderr-overflow': return failure(request, 'PROTOCOL_ERROR', 'Native helper output exceeded the protocol limit');
    case undefined: return undefined;
  }
}

function cancellationFailure(request: Request, code: string, message: string, requestWasSent: boolean): Reply {
  if (requestWasSent && mutatesDesktop(request.command)) {
    return {
      schemaVersion: 1,
      ok: false,
      command: request.command,
      error: { code, message, details: { mutationStatus: 'potentiallyApplied' } },
    };
  }
  return failure(request, code, message);
}

function mutatesDesktop(command: Request['command']): boolean {
  return command === 'press' || command === 'set-value' || command === 'type' || command === 'key'
    || command === 'scroll' || command === 'click' || command === 'move' || command === 'drag';
}

function failure(request: Request, code: string, message: string): Reply {
  return { schemaVersion: 1, ok: false, command: request.command, error: { code, message } };
}

function validReply(value: unknown, request: Request): value is Reply {
  if (!isRecord(value) || value.schemaVersion !== 1 || typeof value.ok !== 'boolean') return false;
  if (value.command !== undefined && value.command !== request.command) return false;
  if (value.ok) {
    return value.command === request.command && isRecord(value.data) && validData(request, value.data);
  }
  return isRecord(value.error)
    && typeof value.error.code === 'string'
    && typeof value.error.message === 'string'
    && (value.error.details === undefined || isJsonRecord(value.error.details));
}

function validData(request: Request, data: Record<string, unknown>): boolean {
  switch (request.command) {
    case 'doctor':
      return typeof data.ready === 'boolean' && Array.isArray(data.checks) && data.checks.every(check =>
        isRecord(check) && typeof check.name === 'string' && typeof check.message === 'string'
          && (check.status === 'ok' || check.status === 'missing' || check.status === 'denied' || check.status === 'unknown'));
    case 'apps':
      return Array.isArray(data.apps) && data.apps.every(app => isRecord(app)
        && typeof app.name === 'string' && positiveSafeInteger(app.pid)
        && (typeof app.bundleId === 'string' || app.bundleId === null));
    case 'windows':
      return Array.isArray(data.windows) && data.windows.every(window => isRecord(window)
        && positiveSafeInteger(window.id) && typeof window.title === 'string'
        && validBounds(window.bounds) && typeof window.eligible === 'boolean'
        && (typeof window.reason === 'string' || window.reason === null));
    case 'snapshot':
      return typeof data.snapshotId === 'string' && isRecord(data.target) && isJsonRecord(data.target)
        && isRecord(data.tree) && isJsonRecord(data.tree) && typeof data.truncated === 'boolean'
        && typeof data.createdAt === 'string' && typeof data.expiresAt === 'string';
    case 'screenshot':
      return typeof data.captureId === 'string' && isRecord(data.target) && isJsonRecord(data.target)
        && typeof data.path === 'string' && nonnegativeFiniteNumber(data.width) && nonnegativeFiniteNumber(data.height)
        && typeof data.createdAt === 'string' && typeof data.expiresAt === 'string'
        && (!request.annotated || (typeof data.snapshotId === 'string' && isRecord(data.tree)
          && isJsonRecord(data.tree) && typeof data.truncated === 'boolean'));
    case 'press':
    case 'set-value':
    case 'type':
    case 'key':
    case 'scroll':
    case 'click':
    case 'move':
    case 'drag':
      return isRecord(data.target) && isJsonRecord(data.target) && typeof data.method === 'string'
        && typeof data.verification === 'string' && typeof data.visualization === 'string';
  }
}

function validBounds(value: unknown): boolean {
  return isRecord(value) && finiteNumber(value.x) && finiteNumber(value.y)
    && nonnegativeFiniteNumber(value.width) && nonnegativeFiniteNumber(value.height);
}

function positiveSafeInteger(value: unknown): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}
function finiteNumber(value: unknown): boolean { return typeof value === 'number' && Number.isFinite(value); }
function nonnegativeFiniteNumber(value: unknown): boolean {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
function isJsonRecord(value: unknown): value is Record<string, JsonValue> {
  return isRecord(value) && Object.values(value).every(isJsonValue);
}
function isJsonValue(value: unknown): value is JsonValue {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return true;
  if (typeof value === 'number') return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(isJsonValue);
  return isJsonRecord(value);
}
