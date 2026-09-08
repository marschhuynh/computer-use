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
  requestDispatched: boolean;
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
    const probeFailure = invocationFailure(request, probe);
    if (probeFailure !== undefined) return probeFailure;
    if (probe.code !== 0) return syntheticFailure(request, 'NATIVE_FAILURE', 'Native helper version probe failed', false);
    if (probe.stdout.toString('utf8').trim() !== PROTOCOL_VERSION) {
      return failure(request, 'HELPER_VERSION_MISMATCH', 'Native helper protocol version is incompatible');
    }

    const remaining = Math.floor(deadline - performance.now());
    if (signal.aborted) return failure(request, 'INTERRUPTED', 'Interrupted');
    if (remaining < 1) return failure(request, 'TIMEOUT', 'Timed out');

    const nativeRequest: Request = { ...request, options: { ...request.options, timeoutMs: remaining } };
    const execution = await invoke(this.#helper, [], `${JSON.stringify(nativeRequest)}\n`, signal, deadline);
    const executionFailure = invocationFailure(request, execution);
    if (executionFailure !== undefined) return executionFailure;
    if (execution.code !== 0) {
      return syntheticFailure(request, 'NATIVE_FAILURE', 'Native helper execution failed', execution.requestDispatched);
    }

    let value: unknown;
    try { value = JSON.parse(execution.stdout.toString('utf8')); }
    catch {
      return syntheticFailure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response', execution.requestDispatched);
    }
    try {
      return projectReply(value, request)
        ?? syntheticFailure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response', execution.requestDispatched);
    } catch {
      return syntheticFailure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response', execution.requestDispatched);
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
    let requestDispatched = false;

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
    child.once('spawn', () => {
      if (input !== undefined && stopReason === undefined) {
        requestDispatched = true;
        child.stdin.write(input);
      }
    });
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
        requestDispatched,
        ...(stopReason === undefined ? {} : { stopReason }),
        ...(spawnError === undefined ? {} : { spawnError }),
      });
    });

    if (signal.aborted) requestStop('aborted');
  });
}

function invocationFailure(request: Request, invocation: Invocation): Reply | undefined {
  if (invocation.spawnError !== undefined) {
    const code = invocation.spawnError.code;
    return code === 'ENOENT' || code === 'ENOTDIR'
      ? syntheticFailure(request, 'MISSING_HELPER', 'Native helper was not found', invocation.requestDispatched)
      : syntheticFailure(request, 'NATIVE_FAILURE', 'Unable to start native helper', invocation.requestDispatched);
  }
  switch (invocation.stopReason) {
    case 'aborted': return syntheticFailure(request, 'INTERRUPTED', 'Interrupted', invocation.requestDispatched);
    case 'timeout': return syntheticFailure(request, 'TIMEOUT', 'Timed out', invocation.requestDispatched);
    case 'stdout-overflow':
    case 'stderr-overflow':
      return syntheticFailure(request, 'PROTOCOL_ERROR', 'Native helper output exceeded the protocol limit', invocation.requestDispatched);
    case undefined: return undefined;
  }
}

function syntheticFailure(request: Request, code: string, message: string, requestDispatched: boolean): Reply {
  if (requestDispatched && mutatesDesktop(request.command)) {
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

function projectReply(value: unknown, request: Request): Reply | undefined {
  if (!isRecord(value) || value.schemaVersion !== 1 || typeof value.ok !== 'boolean'
    || value.command !== request.command) return undefined;
  const text = suppliedText(request);
  if (!value.ok) {
    if (!isRecord(value.error) || typeof value.error.code !== 'string' || typeof value.error.message !== 'string'
      || (value.error.details !== undefined && !isJsonRecord(value.error.details))) return undefined;
    return {
      schemaVersion: 1,
      ok: false,
      command: request.command,
      error: {
        code: sanitizeString(value.error.code, text),
        message: sanitizeString(value.error.message, text),
        ...(value.error.details === undefined ? {} : { details: sanitizeRecord(value.error.details, text) }),
      },
    };
  }
  if (!isRecord(value.data)) return undefined;
  const data = projectData(request, value.data);
  return data === undefined
    ? undefined
    : { schemaVersion: 1, ok: true, command: request.command, data: sanitizeRecord(data, text) };
}

function projectData(request: Request, data: Record<string, unknown>): Record<string, JsonValue> | undefined {
  switch (request.command) {
    case 'doctor': {
      const checks = data.checks;
      if (typeof data.ready !== 'boolean' || !Array.isArray(checks) || !checks.every(isDoctorCheck)) return undefined;
      return { ready: data.ready, checks: checks.map(check => ({ name: check.name, status: check.status, message: check.message })) };
    }
    case 'apps': {
      const apps = data.apps;
      if (!Array.isArray(apps) || !apps.every(isApp)) return undefined;
      return { apps: apps.map(app => ({ name: app.name, pid: app.pid, bundleId: app.bundleId })) };
    }
    case 'windows': {
      const windows = data.windows;
      if (!Array.isArray(windows) || !windows.every(isWindow)) return undefined;
      return { windows: windows.map(window => ({
        id: window.id,
        title: window.title,
        bounds: { x: window.bounds.x, y: window.bounds.y, width: window.bounds.width, height: window.bounds.height },
        eligible: window.eligible,
        reason: window.reason,
      })) };
    }
    case 'snapshot':
      if (typeof data.snapshotId !== 'string' || !isJsonRecord(data.target) || !isJsonRecord(data.tree)
        || typeof data.truncated !== 'boolean' || typeof data.createdAt !== 'string' || typeof data.expiresAt !== 'string') return undefined;
      return {
        snapshotId: data.snapshotId, target: data.target, tree: data.tree, truncated: data.truncated,
        createdAt: data.createdAt, expiresAt: data.expiresAt,
      };
    case 'screenshot': {
      if (typeof data.captureId !== 'string' || !isJsonRecord(data.target) || typeof data.path !== 'string'
        || !nonnegativeFiniteNumber(data.width) || !nonnegativeFiniteNumber(data.height)
        || typeof data.createdAt !== 'string' || typeof data.expiresAt !== 'string') return undefined;
      const projected: Record<string, JsonValue> = {
        captureId: data.captureId, target: data.target, path: data.path, width: data.width, height: data.height,
        createdAt: data.createdAt, expiresAt: data.expiresAt,
      };
      if (request.annotated) {
        if (typeof data.snapshotId !== 'string' || !isJsonRecord(data.tree) || typeof data.truncated !== 'boolean') return undefined;
        projected.snapshotId = data.snapshotId;
        projected.tree = data.tree;
        projected.truncated = data.truncated;
      }
      return projected;
    }
    case 'press':
    case 'set-value':
    case 'type':
    case 'key':
    case 'scroll':
    case 'click':
    case 'move':
    case 'drag':
      if (!isJsonRecord(data.target) || typeof data.method !== 'string'
        || typeof data.verification !== 'string' || typeof data.visualization !== 'string') return undefined;
      return { target: data.target, method: data.method, verification: data.verification, visualization: data.visualization };
  }
}

type DoctorCheck = { name: string; status: 'ok' | 'missing' | 'denied' | 'unknown'; message: string };
type App = { name: string; pid: number; bundleId: string | null };
type Bounds = { x: number; y: number; width: number; height: number };
type Window = { id: number; title: string; bounds: Bounds; eligible: boolean; reason: string | null };

function isDoctorCheck(value: unknown): value is DoctorCheck {
  return isRecord(value) && typeof value.name === 'string' && typeof value.message === 'string'
    && (value.status === 'ok' || value.status === 'missing' || value.status === 'denied' || value.status === 'unknown');
}
function isApp(value: unknown): value is App {
  return isRecord(value) && typeof value.name === 'string' && positiveSafeInteger(value.pid)
    && (typeof value.bundleId === 'string' || value.bundleId === null);
}
function isWindow(value: unknown): value is Window {
  return isRecord(value) && positiveSafeInteger(value.id) && typeof value.title === 'string'
    && validBounds(value.bounds) && typeof value.eligible === 'boolean'
    && (typeof value.reason === 'string' || value.reason === null);
}

function suppliedText(request: Request): string | undefined {
  return (request.command === 'type' || request.command === 'set-value') && request.text.length > 0
    ? request.text
    : undefined;
}
function sanitizeString(value: string, text: string | undefined): string {
  return text === undefined ? value : value.split(text).join('');
}
function sanitizeRecord(value: Record<string, JsonValue>, text: string | undefined): Record<string, JsonValue> {
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [sanitizeString(key, text), sanitizeJson(item, text)]));
}
function sanitizeJson(value: JsonValue, text: string | undefined): JsonValue {
  if (typeof value === 'string') return sanitizeString(value, text);
  if (Array.isArray(value)) return value.map(item => sanitizeJson(item, text));
  if (value !== null && typeof value === 'object') return sanitizeRecord(value, text);
  return value;
}

function validBounds(value: unknown): value is Bounds {
  return isRecord(value) && finiteNumber(value.x) && finiteNumber(value.y)
    && nonnegativeFiniteNumber(value.width) && nonnegativeFiniteNumber(value.height);
}

function positiveSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}
function finiteNumber(value: unknown): boolean { return typeof value === 'number' && Number.isFinite(value); }
function nonnegativeFiniteNumber(value: unknown): value is number {
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
