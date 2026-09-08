import { copyFile, mkdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { join } from 'node:path';

const root = new URL('..', import.meta.url);

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: 'inherit' });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)));
  });
}

function output(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: ['ignore', 'pipe', 'inherit'] });
    let stdout = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve(stdout.trim()) : reject(new Error(`${command} exited with ${code}`)));
  });
}

await run('swift', ['build', '-c', 'release', '--package-path', 'native']);
const binPath = await output('swift', ['build', '-c', 'release', '--package-path', 'native', '--show-bin-path']);
const destination = new URL('../dist/native/computer-use-host', import.meta.url);
await mkdir(new URL('../dist/native/', import.meta.url), { recursive: true });
await copyFile(join(binPath, 'computer-use-host'), destination);
