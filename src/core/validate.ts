import { MAX_TIMEOUT_MS } from './protocol.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class ArgumentError extends Error {
  constructor(message: string) { super(message); this.name = 'ArgumentError'; }
}

export function safeInteger(value: string, name: string, minimum = 1): number {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum) throw new ArgumentError(`${name} must be a safe integer of at least ${minimum}`);
  return number;
}

export function timeout(value: string): number {
  const milliseconds = Number(value);
  if (!Number.isSafeInteger(milliseconds) || milliseconds < 1 || milliseconds > MAX_TIMEOUT_MS) {
    throw new ArgumentError(`timeout must be a safe integer from 1 through ${MAX_TIMEOUT_MS}`);
  }
  return milliseconds;
}

export function pixel(value: string, name: string): number {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw new ArgumentError(`${name} must be a nonnegative finite number`);
  return number;
}

export function recordId(value: string, name: string): string {
  if (!UUID_PATTERN.test(value)) throw new ArgumentError(`${name} must be a strict UUID`);
  return value;
}
