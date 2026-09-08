import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { access, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
const staleToolsDirectory = new URL('../dist/tools/', import.meta.url);
const staleTool = new URL('../dist/tools/stale.js', import.meta.url);
const stalePort = new URL('../dist/ports.js', import.meta.url);
const originalTool = new URL('../src/tools/ComputerUseTool.ts', import.meta.url);

async function exists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function run(command, args) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: fileURLToPath(root), stdio: 'inherit' });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)));
  });
}

await mkdir(new URL('../dist/tools/', import.meta.url), { recursive: true });
await writeFile(staleTool, 'stale\n');
await writeFile(stalePort, 'stale\n');

await run('npm', ['run', 'build:ts']);

assert.equal(await exists(staleTool), false, 'build:ts must remove stale dist/tools output');
assert.equal(await exists(staleToolsDirectory), false, 'build:ts must leave no dist/tools directory');
assert.equal(await exists(stalePort), false, 'build:ts must remove stale dist/ports.js output');
assert.equal(await exists(new URL('../dist/cli.js', import.meta.url)), true, 'build:ts must emit the CLI');
assert.equal(await exists(originalTool), true, 'build:ts must not delete original src/tools sources');

process.stdout.write('build hygiene regression passed\n');
