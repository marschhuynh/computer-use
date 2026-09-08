import { constants } from 'node:fs';
import { access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const vitest = join(dirname(require.resolve('vitest/package.json')), 'vitest.mjs');
const COMMAND_TIMEOUT_MS = 10 * 60 * 1_000;
const CLEANUP_GRACE_MS = 2_000;

function run(command, args, { capture = false, env = process.env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      env,
      shell: false,
      stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    });
    let stdout = '';
    let timedOut = false;
    let forceTimer;
    if (capture) {
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => { stdout += chunk; });
    }
    const deadlineTimer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      forceTimer = setTimeout(() => child.kill('SIGKILL'), CLEANUP_GRACE_MS);
    }, COMMAND_TIMEOUT_MS);
    child.once('error', error => {
      clearTimeout(deadlineTimer);
      if (forceTimer !== undefined) clearTimeout(forceTimer);
      reject(error);
    });
    child.once('close', code => {
      clearTimeout(deadlineTimer);
      if (forceTimer !== undefined) clearTimeout(forceTimer);
      if (timedOut) reject(new Error(`${command} exceeded ${COMMAND_TIMEOUT_MS} ms`));
      else if (code !== 0) reject(new Error(`${command} exited with ${code}`));
      else resolve(stdout.trim());
    });
  });
}

if (process.platform !== 'darwin') {
  throw new Error('Native protocol integration requires macOS; no tests were run');
}
await run('swift', ['build', '--package-path', 'native', '--product', 'computer-use-host']);
const binPath = await run('swift', ['build', '--package-path', 'native', '--show-bin-path'], { capture: true });
const host = join(binPath, 'computer-use-host');
await access(host, constants.X_OK);
await run(process.execPath, [vitest, 'run', 'tests/native-protocol.test.ts'], {
  env: { ...process.env, NUVIN_COMPUTER_USE_TEST_HOST: host },
});
