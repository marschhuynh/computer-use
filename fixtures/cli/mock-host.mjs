#!/usr/bin/env node
import { unlink } from 'node:fs/promises';
import { basename } from 'node:path';

const mode = basename(process.argv[1]);
if (mode === 'ignores-sigterm') process.on('SIGTERM', () => {});

if (process.argv.slice(2).includes('--protocol-version')) {
  const writeVersion = version => process.stdout.write(`${version}\n`, () => process.exit(0));
  if (mode === 'incompatible-version') {
    writeVersion(2);
  } else if (mode === 'slow-version') {
    setTimeout(() => writeVersion(1), 100);
  } else {
    if (mode === 'execution-spawn-failure') await unlink(process.argv[1]);
    writeVersion(1);
  }
} else {
  let input = '';
  let stdinEnded = false;
  process.stdin.setEncoding('utf8');
  process.stdin.on('end', () => { stdinEnded = true; });
  process.stdin.on('data', chunk => {
    input += chunk;
    const newline = input.indexOf('\n');
    if (newline === -1) return;
    const requestText = input.slice(0, newline);
    process.stdin.pause();
    const request = JSON.parse(requestText);
    const validReply = JSON.stringify({ schemaVersion: 1, ok: true, command: request.command, data: request.command === 'apps' ? { apps: [] } : {} });
    const reflectedValue = request.text === 'true'
      ? true
      : (/^[0-9]+$/.test(request.text) ? Number(request.text) : request.text);
    const writeAndExit = (text, code = 0) => process.stdout.write(text, () => process.exit(code));

    switch (mode) {
      case 'invalid-json':
        writeAndExit('not json\n');
        break;
      case 'wrong-command':
        writeAndExit(`${JSON.stringify({ schemaVersion: 1, ok: true, command: 'doctor', data: { ready: true, checks: [] } })}\n`);
        break;
      case 'invalid-response-data':
        writeAndExit(`${JSON.stringify({ schemaVersion: 1, ok: true, command: request.command, data: { apps: 'not-an-array' } })}\n`);
        break;
      case 'failure-missing-command':
        writeAndExit(`${JSON.stringify({ schemaVersion: 1, ok: false, error: { code: 'NATIVE_FAILURE', message: 'failed' } })}\n`);
        break;
      case 'failure-wrong-command':
        writeAndExit(`${JSON.stringify({ schemaVersion: 1, ok: false, command: 'doctor', error: { code: 'NATIVE_FAILURE', message: 'failed' } })}\n`);
        break;
      case 'reflected-success-data':
        writeAndExit(`${JSON.stringify({
          schemaVersion: 1,
          ok: true,
          command: request.command,
          data: {
            target: { app: 'TextEdit', reflected: reflectedValue },
            method: 'accessibility',
            verification: 'verified',
            visualization: 'none',
            reflected: request.text,
          },
        })}\n`);
        break;
      case 'reflected-error-message':
        writeAndExit(`${JSON.stringify({ schemaVersion: 1, ok: false, command: request.command, error: { code: 'NATIVE_FAILURE', message: request.text } })}\n`);
        break;
      case 'reflected-error-details':
        writeAndExit(`${JSON.stringify({
          schemaVersion: 1,
          ok: false,
          command: request.command,
          error: { code: 'NATIVE_FAILURE', message: 'Useful failure', details: { reason: request.text, safe: 'kept' } },
        })}\n`);
        break;
      case 'stable-error-code':
        writeAndExit(`${JSON.stringify({
          schemaVersion: 1,
          ok: false,
          command: request.command,
          error: {
            code: 'UNSUPPORTED_ACTION',
            message: 'Unsupported action',
            details: { reflected: request.text, mutationStatus: 'potentiallyApplied', safe: 'kept' },
          },
        })}\n`);
        break;
      case 'nonzero-exit':
        process.exit(1);
        break;
      case 'success-then-exit-1':
        writeAndExit(`${validReply}\n`, 1);
        break;
      case 'never-exits':
        setInterval(() => {}, 1_000);
        break;
      case 'exits-after-receiving-request':
        process.exit(0);
        break;
      case 'ignores-sigterm':
        setInterval(() => {}, 1_000);
        break;
      case 'requires-open-stdin':
        setTimeout(() => {
          if (stdinEnded) process.exit(1);
          else writeAndExit(`${validReply}\n`);
        }, 30);
        break;
      case 'stdout-overflow':
        process.stdout.write(Buffer.alloc(16 * 1024 * 1024 + 1, 120));
        setInterval(() => {}, 1_000);
        break;
      case 'stderr-overflow':
        process.stderr.write(Buffer.alloc(64 * 1024 + 1, 120));
        process.stdout.write(`${validReply}\n`);
        setInterval(() => {}, 1_000);
        break;
      case 'request-on-stderr':
        process.stderr.write(requestText, () => process.exit(1));
        break;
      default:
        writeAndExit(`${validReply}\n`);
    }
  });
  process.stdin.resume();
}
