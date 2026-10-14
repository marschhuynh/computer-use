import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import type { Backend, JsonValue, MutationStatus, Reply, Request, SnapshotCoverage, TreeOptions } from '../core/protocol.js';
import { isRecordId } from '../core/validate.js';

const PROTOCOL_VERSION = '1';
const MAX_STDOUT_BYTES = 16 * 1024 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;
const CLEANUP_GRACE_MS = 2_000;
const STABLE_ERROR_CODES = new Set([
  'NATIVE_FAILURE', 'PROTOCOL_ERROR', 'UNSUPPORTED_ACTION', 'EXECUTION_UNCERTAIN',
  'INVALID_ARGUMENT', 'UNSUPPORTED_PLATFORM', 'MISSING_HELPER', 'HELPER_VERSION_MISMATCH',
  'MISSING_DEPENDENCY', 'PERMISSION_DENIED', 'TARGET_NOT_FOUND', 'AMBIGUOUS_TARGET',
  'INELIGIBLE_TARGET', 'STALE_SNAPSHOT', 'STALE_CAPTURE', 'TIMEOUT', 'BUSY', 'INTERRUPTED',
  'FOCUS_FAILED',
]);
const CONTROLLED_RESULT_VALUES = {
  method: new Set(['accessibility', 'cg-event']),
  verification: new Set(['verified', 'dispatched', 'unverified', 'partial']),
  visualization: new Set(['none', 'approach', 'pulse', 'drag']),
};

type ResultField = keyof typeof CONTROLLED_RESULT_VALUES;
type SuppliedValue = { text: string; parsed?: JsonValue };

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
      return projectReply(value, request, execution.requestDispatched)
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

function projectReply(value: unknown, request: Request, requestDispatched: boolean): Reply | undefined {
  if (!isRecord(value) || value.schemaVersion !== 1 || typeof value.ok !== 'boolean'
    || value.command !== request.command) return undefined;
  const supplied = suppliedValue(request);
  if (!value.ok) {
    if (!isRecord(value.error) || typeof value.error.code !== 'string' || typeof value.error.message !== 'string'
      || (value.error.details !== undefined && !isJsonRecord(value.error.details))
      || !STABLE_ERROR_CODES.has(value.error.code)) return undefined;
    const wireStatus = readMutationStatus(value.error.details);
    if (wireStatus === null) return undefined;
    const publicStatus = mutatesDesktop(request.command)
      ? (wireStatus ?? (requestDispatched ? 'potentiallyApplied' : undefined))
      : undefined;
    const details = projectDetails(value.error.details ?? {}, supplied, publicStatus);
    return {
      schemaVersion: 1,
      ok: false,
      command: request.command,
      error: {
        code: value.error.code,
        message: reflectsSuppliedValue(value.error.message, supplied) ? '' : value.error.message,
        ...(details === undefined ? {} : { details }),
      },
    };
  }
  if (!isRecord(value.data)) return undefined;
  const data = projectData(request, value.data, supplied);
  return data === undefined
    ? undefined
    : { schemaVersion: 1, ok: true, command: request.command, data };
}

function projectData(request: Request, data: Record<string, unknown>, supplied: SuppliedValue | undefined): Record<string, JsonValue> | undefined {
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
      return projectSnapshotData(data, request.tree);
    case 'screenshot': {
      if (typeof data.captureId !== 'string' || !isJsonRecord(data.target) || typeof data.path !== 'string'
        || !nonnegativeFiniteNumber(data.width) || !nonnegativeFiniteNumber(data.height)
        || typeof data.createdAt !== 'string' || typeof data.expiresAt !== 'string') return undefined;
      const projected: Record<string, JsonValue> = {
        captureId: data.captureId, target: data.target, path: data.path, width: data.width, height: data.height,
        createdAt: data.createdAt, expiresAt: data.expiresAt,
      };
      if (request.annotated) {
        if (typeof data.snapshotId !== 'string' || typeof data.truncated !== 'boolean') return undefined;
        const tree = projectSnapshotTree(data.tree);
        if (tree === undefined) return undefined;
        const coverage = data.coverage === undefined ? undefined
          : projectSnapshotCoverage(data.coverage, request.tree, tree, data.truncated);
        if (data.coverage !== undefined && coverage === undefined) return undefined;
        projected.snapshotId = data.snapshotId;
        projected.tree = tree.tree;
        projected.truncated = data.truncated;
        if (coverage !== undefined) projected.coverage = coverage;
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
    case 'drag': {
      if (!isJsonRecord(data.target)) return undefined;
      const target = projectFreeFormRecord(data.target, supplied);
      const method = projectResultValue('method', data.method, supplied);
      const verification = projectResultValue('verification', data.verification, supplied);
      const visualization = projectResultValue('visualization', data.visualization, supplied);
      if (target === undefined || method === undefined || verification === undefined || visualization === undefined) return undefined;
      const projected: Record<string, JsonValue> = { target, method, verification, visualization };
      if (request.command === 'type' && data.clipboardReplaced !== undefined) {
        if (typeof data.clipboardReplaced !== 'boolean') return undefined;
        projected.clipboardReplaced = data.clipboardReplaced;
      }
      return projected;
    }
  }
}

function projectSnapshotData(data: Record<string, unknown>, options: TreeOptions): Record<string, JsonValue> | undefined {
  if (typeof data.createdAt !== 'string' || typeof data.expiresAt !== 'string') return undefined;
  const target = projectSnapshotTarget(data.target);
  const tree = projectSnapshotTree(data.tree);
  const createdAt = parseWireTimestamp(data.createdAt);
  const expiresAt = parseWireTimestamp(data.expiresAt);
  if (!isRecordId(data.snapshotId) || target === undefined || tree === undefined
    || typeof data.truncated !== 'boolean' || createdAt === undefined || expiresAt === undefined
    || expiresAt.seconds !== createdAt.seconds + 10 * 60
    || expiresAt.nanoseconds !== createdAt.nanoseconds) return undefined;
  const coverage = data.coverage === undefined ? undefined
    : projectSnapshotCoverage(data.coverage, options, tree, data.truncated);
  if (data.coverage !== undefined && coverage === undefined) return undefined;
  return {
    snapshotId: data.snapshotId,
    target,
    tree: tree.tree,
    ...(coverage === undefined ? {} : { coverage }),
    truncated: data.truncated,
    createdAt: data.createdAt,
    expiresAt: data.expiresAt,
  };
}

function projectSnapshotCoverage(
  value: unknown, options: TreeOptions, tree: ProjectedSnapshotTree, truncated: boolean,
): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || value.scope !== 'selectedWindow' || value.absenceIsConclusive !== false
    || !positiveSafeInteger(value.observedNodes) || !positiveSafeInteger(value.emittedNodes)
    || !nonnegativeSafeInteger(value.refCount) || value.emittedNodes > value.observedNodes
    || value.refCount > value.emittedNodes || tree.nodeCount !== value.emittedNodes
    || tree.refCount !== value.refCount || tree.rootCount !== 1) return undefined;
  const limits = value.limits;
  if (!isRecord(limits) || !positiveSafeInteger(limits.maxDepth) || !positiveSafeInteger(limits.maxElements)
    || limits.maxDepth !== options.maxDepth || limits.maxElements !== options.maxElements
    || value.observedNodes > limits.maxElements
    || (options.hintMode !== 'leafCompact' && value.emittedNodes !== value.observedNodes)) return undefined;
  if (!Array.isArray(value.boundaries) || value.boundaries.length > value.observedNodes
    || truncated !== (value.boundaries.length > 0)) return undefined;
  if (value.omittedBoundaries !== undefined
    && (!positiveSafeInteger(value.omittedBoundaries)
      || value.boundaries.length === 0
      || value.boundaries.length + value.omittedBoundaries > value.observedNodes)) return undefined;
  const noRefReason = value.boundaries.length > 0 ? 'traversalLimited' : 'noEligibleRefs';
  if (value.refCount === 0 ? value.noRefReason !== noRefReason : value.noRefReason !== undefined) return undefined;

  // Paths describe original evidence, not child indexes in the compact tree.
  // Only independently checkable wire invariants belong here; native validation
  // remains authoritative for complete evidence topology and boundary order.
  const observedNodes = value.observedNodes;
  const paths = new Set<string>();
  const boundaries: SnapshotCoverage['boundaries'] = [];
  for (const boundary of value.boundaries) {
    if (!isRecord(boundary) || !Array.isArray(boundary.path)
      || boundary.path.length > limits.maxDepth || boundary.path.length >= value.observedNodes
      || !boundary.path.every(index => nonnegativeSafeInteger(index) && index < observedNodes)
      || !nonnegativeSafeInteger(boundary.observedChildren) || !nonnegativeSafeInteger(boundary.totalChildren)
      || boundary.observedChildren >= boundary.totalChildren || boundary.observedChildren >= value.observedNodes
      || (boundary.path.length === 0 && (tree.rootHasRef || (boundary.observedChildren === 0 && value.refCount !== 0)))) return undefined;
    const pathKey = JSON.stringify(boundary.path);
    if (paths.has(pathKey)) return undefined;
    paths.add(pathKey);
    switch (boundary.reason) {
      case 'maxDepth':
        if (boundary.path.length !== limits.maxDepth || boundary.observedChildren !== 0) return undefined;
        break;
      case 'maxElements':
        if (boundary.path.length >= limits.maxDepth || value.observedNodes !== limits.maxElements) return undefined;
        break;
      default: return undefined;
    }
    boundaries.push({
      path: [...boundary.path], reason: boundary.reason,
      observedChildren: boundary.observedChildren, totalChildren: boundary.totalChildren,
    });
  }
  const coverage: SnapshotCoverage = {
    scope: 'selectedWindow', absenceIsConclusive: false,
    observedNodes: value.observedNodes, emittedNodes: value.emittedNodes, refCount: value.refCount,
    limits: { maxDepth: limits.maxDepth, maxElements: limits.maxElements }, boundaries,
    ...(value.omittedBoundaries === undefined ? {} : { omittedBoundaries: value.omittedBoundaries }),
    ...(value.refCount === 0 ? { noRefReason } : {}),
  };
  return coverage;
}

function projectSnapshotTarget(value: unknown): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || !positiveSafeInteger(value.pid) || !isWireTimestamp(value.launchDate)
    || (typeof value.bundleId !== 'string' && value.bundleId !== null)
    || !positiveSafeInteger(value.windowId) || typeof value.title !== 'string') return undefined;
  const bounds = projectBounds(value.bounds);
  if (bounds === undefined) return undefined;
  return {
    pid: value.pid,
    launchDate: value.launchDate,
    bundleId: value.bundleId,
    windowId: value.windowId,
    title: value.title,
    bounds,
  };
}

type ProjectedSnapshotTree = {
  tree: Record<string, JsonValue>; nodeCount: number; refCount: number; rootCount: number; rootHasRef: boolean;
};
type SnapshotTreeCounts = { refs: Set<number>; nodeCount: number };

function projectSnapshotTree(value: unknown): ProjectedSnapshotTree | undefined {
  if (!isRecord(value) || !Array.isArray(value.elements) || value.elements.length > 1) return undefined;
  const counts: SnapshotTreeCounts = { refs: new Set(), nodeCount: 0 };
  const elements: JsonValue[] = [];
  let rootHasRef = false;
  for (const element of value.elements) {
    const projected = projectSnapshotNode(element, counts);
    if (projected === undefined) return undefined;
    if (projected.ref !== undefined) rootHasRef = true;
    elements.push(projected);
  }
  for (let ref = 1; ref <= counts.refs.size; ref += 1) {
    if (!counts.refs.has(ref)) return undefined;
  }
  return {
    tree: { elements }, nodeCount: counts.nodeCount, refCount: counts.refs.size, rootCount: elements.length, rootHasRef,
  };
}

function projectSnapshotNode(value: unknown, counts: SnapshotTreeCounts): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || typeof value.role !== 'string' || value.role.length === 0) return undefined;
  counts.nodeCount += 1;
  const projected: Record<string, JsonValue> = { role: value.role };
  if (value.ref !== undefined) {
    if (!positiveSafeInteger(value.ref) || counts.refs.has(value.ref)) return undefined;
    counts.refs.add(value.ref);
    projected.ref = value.ref;
  }
  for (const field of ['subrole', 'identifier', 'title', 'label', 'value'] as const) {
    const item = value[field];
    if (item !== undefined) {
      if (typeof item !== 'string') return undefined;
      projected[field] = item;
    }
  }
  if (value.actions !== undefined) {
    if (!Array.isArray(value.actions) || !value.actions.every(item => typeof item === 'string')) return undefined;
    projected.actions = value.actions;
  }
  for (const field of ['enabled', 'focused', 'selected'] as const) {
    const item = value[field];
    if (item !== undefined) {
      if (typeof item !== 'boolean') return undefined;
      projected[field] = item;
    }
  }
  if (value.bounds !== undefined) {
    const bounds = projectBounds(value.bounds);
    if (bounds === undefined) return undefined;
    projected.bounds = bounds;
  }
  if (value.children !== undefined) {
    if (!Array.isArray(value.children)) return undefined;
    const children: JsonValue[] = [];
    for (const child of value.children) {
      const projectedChild = projectSnapshotNode(child, counts);
      if (projectedChild === undefined) return undefined;
      children.push(projectedChild);
    }
    projected.children = children;
  }
  return projected;
}

function projectBounds(value: unknown): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || !finiteNumber(value.x) || !finiteNumber(value.y)
    || !nonnegativeFiniteNumber(value.width) || !nonnegativeFiniteNumber(value.height)) return undefined;
  return { x: value.x, y: value.y, width: value.width, height: value.height };
}

type WireTimestamp = { seconds: number; nanoseconds: number };

function parseWireTimestamp(value: unknown): WireTimestamp | undefined {
  if (typeof value !== 'string') return undefined;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$/.exec(value);
  if (match === null) return undefined;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, fractionText = ''] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1
    || date.getUTCDate() !== day || date.getUTCHours() !== hour
    || date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second) return undefined;
  return {
    seconds: Math.floor(date.getTime() / 1_000),
    nanoseconds: Number(fractionText.padEnd(9, '0')),
  };
}

function isWireTimestamp(value: unknown): value is string {
  return parseWireTimestamp(value) !== undefined;
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

function suppliedValue(request: Request): SuppliedValue | undefined {
  if ((request.command !== 'type' && request.command !== 'set-value') || request.text.length === 0) return undefined;
  try {
    const parsed: unknown = JSON.parse(request.text);
    return isJsonValue(parsed) ? { text: request.text, parsed } : { text: request.text };
  } catch {
    return { text: request.text };
  }
}

function reflectsSuppliedValue(value: JsonValue, supplied: SuppliedValue | undefined): boolean {
  if (supplied === undefined) return false;
  if (typeof value === 'string' && value.includes(supplied.text)) return true;
  if ((value === null || typeof value === 'boolean' || typeof value === 'number')
    && (JSON.stringify(value)?.includes(supplied.text) ?? false)) return true;
  return supplied.parsed !== undefined && equalJsonValues(value, supplied.parsed);
}

function equalJsonValues(left: JsonValue, right: JsonValue): boolean {
  if (left === right) return true;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) && left.length === right.length
      && left.every((item, index) => equalJsonValues(item, right[index]));
  }
  if (left === null || right === null || typeof left !== 'object' || typeof right !== 'object') return false;
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);
  return leftKeys.length === rightKeys.length
    && leftKeys.every(key => Object.hasOwn(right, key) && equalJsonValues(left[key], right[key]));
}

function projectResultValue(field: ResultField, value: unknown, supplied: SuppliedValue | undefined): string | undefined {
  if (typeof value !== 'string' || value.length === 0) return undefined;
  if (CONTROLLED_RESULT_VALUES[field].has(value)) return value;
  return reflectsSuppliedValue(value, supplied) ? undefined : value;
}

function readMutationStatus(value: Record<string, JsonValue> | undefined): MutationStatus | undefined | null {
  if (value === undefined || !Object.hasOwn(value, 'mutationStatus')) return undefined;
  if (value.mutationStatus === 'notStarted' || value.mutationStatus === 'potentiallyApplied') {
    return value.mutationStatus;
  }
  return null;
}

function projectDetails(
  value: Record<string, JsonValue>,
  supplied: SuppliedValue | undefined,
  mutationStatus: MutationStatus | undefined,
): Record<string, JsonValue> | undefined {
  const freeForm: Record<string, JsonValue> = {};
  for (const [key, item] of Object.entries(value)) {
    if (key !== 'mutationStatus') freeForm[key] = item;
  }
  const contaminatedRoot = reflectsSuppliedValue(value, supplied) || reflectsSuppliedValue(freeForm, supplied);
  const projected = contaminatedRoot ? undefined : projectFreeFormRecord(freeForm, supplied);
  if (projected === undefined) return mutationStatus === undefined ? undefined : { mutationStatus };
  if (mutationStatus !== undefined) projected.mutationStatus = mutationStatus;
  return Object.keys(projected).length === 0 ? undefined : projected;
}

function projectFreeFormRecord(value: Record<string, JsonValue>, supplied: SuppliedValue | undefined): Record<string, JsonValue> | undefined {
  if (reflectsSuppliedValue(value, supplied)) return undefined;
  const projected: Record<string, JsonValue> = {};
  for (const [key, item] of Object.entries(value)) {
    const projectedItem = projectFreeFormValue(item, supplied);
    if (projectedItem !== undefined) projected[key] = projectedItem;
  }
  return projected;
}

function projectFreeFormValue(value: JsonValue, supplied: SuppliedValue | undefined): JsonValue | undefined {
  if (reflectsSuppliedValue(value, supplied)) return undefined;
  if (Array.isArray(value)) {
    return value.flatMap(item => {
      const projected = projectFreeFormValue(item, supplied);
      return projected === undefined ? [] : [projected];
    });
  }
  if (value !== null && typeof value === 'object') return projectFreeFormRecord(value, supplied);
  return value;
}

function validBounds(value: unknown): value is Bounds {
  return isRecord(value) && finiteNumber(value.x) && finiteNumber(value.y)
    && nonnegativeFiniteNumber(value.width) && nonnegativeFiniteNumber(value.height);
}

function positiveSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}
function nonnegativeSafeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}
function finiteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}
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
