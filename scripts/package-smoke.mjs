// Package smoke: pack the tarball, install it into an isolated prefix with
// scripts disabled, and prove the installed `nuvin-computer-use` resolves its
// bundled helper and runs help/version/doctor — all without a global or
// ~/.nuvin helper present.
import { mkdtemp, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';

const root = new URL('..', import.meta.url);

function run(command, args, { cwd, env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: cwd ?? fileURLToPathSafe(root), env: env ?? process.env, shell: false, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => stdout += d);
    child.stderr.on('data', d => stderr += d);
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve(stdout.trim()) : reject(new Error(`${command} ${args.join(' ')} exited ${code}\n${stderr}`)));
  });
}
function fileURLToPathSafe(url) { return url.pathname; }

const work = await mkdtemp(join(tmpdir(), 'nuvin-cu-pack-'));
try {
  // 1. Build the tarball (prepack runs the build).
  const packed = await run('npm', ['pack', '--pack-destination', work], { cwd: fileURLToPathSafe(root) });
  const tarball = packed.split('\n').filter(l => l.endsWith('.tgz')).pop()
    ?? (await run('ls', [work])).split('\n').find(f => f.endsWith('.tgz'));
  if (!tarball) throw new Error('npm pack produced no tarball');
  const tarballPath = join(work, tarball);

  // 2. Install into an isolated prefix, scripts disabled.
  const prefix = join(work, 'install');
  await run('npm', ['install', '--prefix', prefix, '--ignore-scripts', '--no-audit', '--no-fund', tarballPath]);

  const bin = join(prefix, 'node_modules', '.bin', 'nuvin-computer-use');
  if (!existsSync(bin)) throw new Error(`installed bin not found at ${bin}`);

  // 3. Smoke: version + help + doctor (read-only) through the installed bin.
  const version = await run(bin, ['--version']);
  if (!version) throw new Error('--version produced no output');

  const help = await run(bin, ['--help']);
  if (!help.includes('nuvin-computer-use')) throw new Error('--help missing usage');

  const doctorJson = await run(bin, ['doctor', '--json']);
  const doctor = JSON.parse(doctorJson);
  if (doctor.schemaVersion !== 1 || doctor.command !== 'doctor') throw new Error('doctor reply malformed');

  // 4. Helper resolved from the package, not ~/.nuvin.
  const installedHost = join(prefix, 'node_modules', 'nuvin-computer-use', 'dist', 'native', 'computer-use-host');
  const hostPath = await realpath(installedHost).catch(() => null);
  if (!hostPath) throw new Error('bundled helper not found in installed package');
  const probe = await run(hostPath, ['--protocol-version']);
  if (probe !== '1') throw new Error(`helper protocol mismatch: ${probe}`);

  console.log('package smoke passed');
  console.log(`  bin:      ${bin}`);
  console.log(`  helper:   ${hostPath} (protocol ${probe})`);
  console.log(`  version:  ${version}`);
} finally {
  await rm(work, { recursive: true, force: true });
}
