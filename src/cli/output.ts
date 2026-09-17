import type { Reply } from '../core/protocol.js';

const exits: Record<string, number> = {
  NATIVE_FAILURE: 1, PROTOCOL_ERROR: 1, UNSUPPORTED_ACTION: 1, EXECUTION_UNCERTAIN: 1,
  INVALID_ARGUMENT: 2,
  UNSUPPORTED_PLATFORM: 3, MISSING_HELPER: 3, HELPER_VERSION_MISMATCH: 3, MISSING_DEPENDENCY: 3,
  PERMISSION_DENIED: 4,
  TARGET_NOT_FOUND: 5, AMBIGUOUS_TARGET: 5, INELIGIBLE_TARGET: 5, STALE_SNAPSHOT: 5, STALE_CAPTURE: 5,
  TIMEOUT: 6, BUSY: 6,
  INTERRUPTED: 130,
};

export function exitCode(reply: Reply): number {
  if (!reply.ok) return exits[reply.error.code] ?? 1;
  // doctor is a read-only diagnostic: a truthful "not ready" result maps to the
  // first failing check's category rather than a blanket success exit.
  if (reply.command === 'doctor' && reply.data.ready === false) {
    const checks = Array.isArray(reply.data.checks) ? reply.data.checks : [];
    for (const check of checks) {
      if (typeof check === 'object' && check !== null && 'status' in check) {
        const status = (check as { status?: unknown }).status;
        if (status !== 'ok') {
          if (status === 'denied') return exits.PERMISSION_DENIED;
          if (status === 'missing') return exits.MISSING_DEPENDENCY;
          return 1;
        }
      }
    }
    return 1;
  }
  return 0;
}

export function formatReply(reply: Reply, json: boolean): string {
  if (json) return `${JSON.stringify(reply)}\n`;
  if (!reply.ok) return `${reply.error.code}: ${reply.error.message}\n`;
  switch (reply.command) {
    case 'apps': return formatApps(reply.data.apps);
    case 'windows': return formatWindows(reply.data.windows);
    case 'doctor': return formatDoctor(reply.data);
    default: return `${reply.command} completed successfully\n`;
  }
}

// Escape terminal control characters so observed text (window titles, app
// names) cannot inject ANSI/CR into the user's terminal. Keeps the output a
// single readable line per record.
function escapeControl(value: unknown): string {
  return String(value ?? '')
    // C0 controls + DEL: escape so observed text can't inject ANSI/CR/newlines.
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, ch => `\\x${ch.charCodeAt(0).toString(16).padStart(2, '0')}`);
}

function formatApps(apps: unknown): string {
  if (!Array.isArray(apps)) return 'apps completed successfully\n';
  const lines = apps.map(app => {
    const a = (app ?? {}) as Record<string, unknown>;
    const bundle = a.bundleId == null ? '' : `  ${escapeControl(a.bundleId)}`;
    return `  ${escapeControl(a.name)}  (pid ${escapeControl(a.pid)})${bundle}`;
  });
  return `apps (${lines.length})\n${lines.join('\n')}\n`;
}

function formatWindows(windows: unknown): string {
  if (!Array.isArray(windows)) return 'windows completed successfully\n';
  const lines = windows.map(w => {
    const win = (w ?? {}) as Record<string, unknown>;
    const bounds = (win.bounds ?? {}) as Record<string, unknown>;
    const eligibility = win.eligible === true ? 'eligible' : `ineligible (${escapeControl(win.reason)})`;
    return `  ${escapeControl(win.id)}  ${escapeControl(win.title)}  ${escapeControl(bounds.width)}x${escapeControl(bounds.height)}  ${eligibility}`;
  });
  return `windows (${lines.length})\n${lines.join('\n')}\n`;
}

function formatDoctor(data: Record<string, unknown>): string {
  const checks = Array.isArray(data.checks) ? data.checks : [];
  const lines = checks.map(c => {
    const check = (c ?? {}) as Record<string, unknown>;
    return `  [${escapeControl(check.status)}] ${escapeControl(check.name)}: ${escapeControl(check.message)}`;
  });
  const ready = data.ready === true;
  return `doctor ${ready ? 'ready' : 'not ready'}\n${lines.join('\n')}\n`;
}
