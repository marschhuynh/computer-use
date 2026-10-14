export const DEFAULT_TIMEOUT_MS = 15_000;
export const MAX_TIMEOUT_MS = 120_000;

export type Target =
  | { app: string; windowId?: number; pid?: never }
  | { pid: number; windowId?: number; app?: never };
export type Point = { x: number; y: number };
export type Options = { timeoutMs: number; cursor: 'on' | 'off' };
export type TreeOptions = { maxDepth: number; maxElements: number; hintMode: 'full' | 'leafOnly' | 'leafCompact' };
export type SnapshotBoundary = {
  path: number[];
  reason: 'maxDepth' | 'maxElements';
  observedChildren: number;
  totalChildren: number;
};
export type SnapshotCoverage = {
  scope: 'selectedWindow';
  absenceIsConclusive: false;
  observedNodes: number;
  emittedNodes: number;
  refCount: number;
  limits: { maxDepth: number; maxElements: number };
  boundaries: SnapshotBoundary[];
  omittedBoundaries?: number;
  noRefReason?: 'traversalLimited' | 'noEligibleRefs';
};
export type Direction = 'up' | 'down' | 'left' | 'right';
export type Command =
  | { command: 'doctor' | 'apps' }
  | { command: 'windows'; target: Target }
  | { command: 'snapshot'; target: Target; tree: TreeOptions }
  | { command: 'press'; snapshotId: string; ref: number }
  | { command: 'set-value'; snapshotId: string; ref: number; text: string }
  | { command: 'type'; target?: Target; text: string; allowClipboardReplace: boolean; toProcess?: boolean }
  | { command: 'key'; target?: Target; key: string; toProcess?: boolean }
  | { command: 'scroll'; snapshotId: string; ref: number }
  | { command: 'scroll'; target: Target; direction: Direction; amount: number }
  | { command: 'screenshot'; target?: Target; display?: number; output: string; overwrite: boolean; annotated: boolean; native: boolean; tree: TreeOptions }
  | { command: 'click'; captureId: string; point: Point; button: 'left' | 'right' | 'middle'; count: 1 | 2 | 3 }
  | { command: 'move'; captureId: string; point: Point }
  | { command: 'drag'; captureId: string; from: Point; to: Point };
export type Request = { schemaVersion: 1; options: Options } & Command;
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type MutationStatus = 'notStarted' | 'potentiallyApplied';
export type WireErrorDetails = Record<string, JsonValue> & { mutationStatus?: MutationStatus };
export type Reply =
  | { schemaVersion: 1; ok: true; command: Command['command']; data: Record<string, JsonValue> }
  | { schemaVersion: 1; ok: false; command?: Command['command']; error: { code: string; message: string; details?: WireErrorDetails } };
export interface Backend { execute(request: Request, signal: AbortSignal): Promise<Reply>; }
