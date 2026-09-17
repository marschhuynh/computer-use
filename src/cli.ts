#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { MacOSBackend } from './backend/macos.js';
import { run } from './cli/run.js';
import type { Backend, Reply, Request } from './core/protocol.js';

export function backendForPlatform(platform: NodeJS.Platform = process.platform): Backend {
  if (platform === 'darwin') return new MacOSBackend();
  return {
    async execute(request: Request): Promise<Reply> {
      return { schemaVersion: 1, ok: false, command: request.command, error: { code: 'UNSUPPORTED_PLATFORM', message: 'Native commands require macOS' } };
    },
  };
}

async function main(): Promise<void> {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  process.exitCode = await run(process.argv.slice(2), {
    backend: backendForPlatform(),
    signal: controller.signal,
    readText: (path, signal) => path === '-' ? readStdin(signal) : readFile(path, { encoding: 'utf8', signal }),
    writeStdout: text => process.stdout.write(text),
    writeStderr: text => process.stderr.write(text),
  });
}

function readStdin(signal: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const abort = () => { process.stdin.destroy(); reject(new Error('Interrupted')); };
    signal.addEventListener('abort', abort, { once: true });
    process.stdin.on('data', chunk => chunks.push(Buffer.from(chunk)));
    process.stdin.once('error', reject);
    process.stdin.once('end', () => { signal.removeEventListener('abort', abort); resolve(Buffer.concat(chunks).toString('utf8')); });
    process.stdin.resume();
  });
}

import { realpathSync } from 'node:fs';

function isDirectInvocation(): boolean {
  const argv1 = process.argv[1];
  if (argv1 === undefined) return false;
  // Resolve symlinks so a `.bin/nuvin-computer-use` shim (which npm creates as a
  // symlink to dist/cli.js) still counts as a direct invocation.
  try {
    const resolved = realpathSync(argv1);
    return import.meta.url === pathToFileURL(resolved).href;
  } catch {
    return false;
  }
}

if (isDirectInvocation()) void main();
