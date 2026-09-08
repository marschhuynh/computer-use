/**
 * Minimal type shim extracted from nuvin-cli @ commit aab1a6a
 * (packages/nuvin-core/src/ports.ts, 689 lines).
 *
 * Only the symbols needed by ComputerUseTool are included so the tool
 * compiles standalone. Definitions are verbatim; the single deviation
 * is marked inline below.
 */

export type ToolDefinition = {
  type: 'function';
  function: { name: string; description: string; parameters: object };
};

export type TextContentPart = {
  type: 'text';
  text: string;
};

export type ImageContentPart = {
  type: 'image';
  mimeType: string;
  data: string;
  altText?: string;
  source?: string;
  name?: string;
};

// Verbatim: original ports.ts line 256.
export enum ErrorReason {
  Aborted = 'aborted',
  Denied = 'denied',
  Edited = 'edited',
  Timeout = 'timeout',
  NotFound = 'not_found',
  PermissionDenied = 'permission_denied',
  InvalidInput = 'invalid_input',
  NetworkError = 'network_error',
  RateLimit = 'rate_limit',
  ToolNotFound = 'tool_not_found',
  ValidationFailed = 'validation_failed',
  Unknown = 'unknown',
}

// DEVIATION: the original signature is `emit(event: AgentEvent)` where
// AgentEvent is a large union (original ports.ts line 532, with its own
// dependency web). Loosened to `unknown` because ToolExecutionContext.eventPort
// is optional and ComputerUseTool never reads it.
export interface EventPort {
  emit(event: unknown): void | Promise<void>;
}
