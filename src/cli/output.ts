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

export function exitCode(reply: Reply): number { return reply.ok ? 0 : (exits[reply.error.code] ?? 1); }

export function formatReply(reply: Reply, json: boolean): string {
  if (json) return `${JSON.stringify(reply)}\n`;
  if (reply.ok) return `${reply.command} completed successfully\n`;
  return `${reply.error.code}: ${reply.error.message}\n`;
}
