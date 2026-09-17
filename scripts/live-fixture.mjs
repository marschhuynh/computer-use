// Opt-in live acceptance runner for Stage K.
// Builds + launches the disposable CUFixture app, then drives every command
// against it. Requires BOTH:
//   NUVIN_CU_LIVE=1            — env gate
//   interactive "yes"          — human confirmation (this does real input)
// Refuses otherwise. The fixture is in-memory only; nothing touches disk,
// clipboard, or your real apps' data.
import { spawn, execSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url)) + '/..';
const cli = join(root, 'dist', 'cli.js');
const fixtureApp = join(root, 'fixtures', 'app', 'CUFixture.app');
const BUNDLE = 'com.nuvin.cu-fixture';

function fail(msg) { console.error(`refuse: ${msg}`); process.exit(2); }
function run(args, opts = {}) {
  const r = spawn('node', [cli, ...args, '--json'], { stdio: ['ignore', 'pipe', 'pipe'] });
  return new Promise(res => {
    let out = '';
    r.stdout.on('data', d => out += d);
    r.on('close', code => {
      let json = null;
      try { json = JSON.parse(out.trim()); } catch {}
      res({ code, json, raw: out.trim() });
    });
    r.on('error', e => res({ code: -1, json: null, raw: String(e) }));
  });
}

if (process.env.NUVIN_CU_LIVE !== '1') {
  fail('NUVIN_CU_LIVE=1 not set. Live input is real foreground input — set it deliberately.');
}
if (!existsSync(cli)) fail('dist/cli.js missing — run npm run build first');

// Interactive confirmation — automated gates are not authorization.
const rl = createInterface({ input: process.stdin, output: process.stdout });
const answer = await new Promise(r => rl.question(
  'This will move the pointer and post real input to a disposable fixture app. Proceed? [yes/no] ', r));
rl.close();
if (answer.trim() !== 'yes') fail('not confirmed');

// Build + launch fixture.
if (!existsSync(fixtureApp)) {
  console.log('building fixture…');
  execSync(join(root, 'fixtures', 'app', 'build.sh'), { stdio: 'inherit' });
}
execSync(`open "${fixtureApp}"`);
await new Promise(r => setTimeout(r, 1500));

const matrix = [];
async function check(name, args, pred) {
  const r = await run(args);
  const ok = r.json?.ok === true;
  const pass = ok && (!pred || pred(r.json.data ?? {}));
  matrix.push({ command: name, result: pass ? 'pass' : ok ? 'partial' : 'fail', code: r.json?.error?.code });
  return r.json?.data ?? {};
}

// Resolve the fixture's primary window id.
const wins = await run(['windows', '--app', 'CUFixture']);
const primary = (wins.json?.data?.windows ?? []).find(w => /Primary/.test(w.title));
if (!primary) fail('fixture primary window not found — is it running?');
const W = String(primary.id);

await check('doctor', ['doctor'], d => d.ready === true);
await check('apps', ['apps'], d => (d.apps ?? []).some(a => a.bundleId === BUNDLE));
await check('windows', ['windows', '--app', 'CUFixture'], d => (d.windows ?? []).length >= 2);

const snap = await check('snapshot', ['snapshot', '--app', 'CUFixture', '--window', W],
  d => typeof d.snapshotId === 'string' && (d.tree?.elements ?? []).length > 0);
const sid = snap.snapshotId;

await check('press', ['press', '--snapshot', sid, '--ref', '1']);
await check('set-value', ['set-value', '--snapshot', sid, '--ref', '2', '--text', 'live']);
await check('type', ['type', '--app', 'CUFixture', '--window', W, '--text', 'hi ✓']);
await check('key', ['key', '--app', 'CUFixture', '--window', W, '--key', 'cmd+a']);
await check('scroll', ['scroll', '--app', 'CUFixture', '--window', W, '--direction', 'down', '--amount', '3']);

const shot = await check('screenshot', ['screenshot', '--app', 'CUFixture', '--window', W,
  '--output', '/tmp/cu-live.png', '--overwrite'], d => typeof d.captureId === 'string');
await check('screenshot --annotated', ['screenshot', '--app', 'CUFixture', '--window', W,
  '--output', '/tmp/cu-live-a.png', '--overwrite', '--annotated'], d => typeof d.snapshotId === 'string');

if (shot.captureId) {
  await check('click', ['click', '--capture', shot.captureId, '--x', '100', '--y', '100']);
  await check('move', ['move', '--capture', shot.captureId, '--x', '200', '--y', '200']);
  await check('drag', ['drag', '--capture', shot.captureId, '--from', '200,200', '--to', '300,300']);
}

console.log('\n=== acceptance matrix ===');
for (const m of matrix) console.log(`  ${m.result.padEnd(8)} ${m.command}${m.code ? `  (${m.code})` : ''}`);

execSync(`osascript -e 'tell application "CUFixture" to quit' 2>/dev/null || true`);
const failed = matrix.filter(m => m.result === 'fail').length;
console.log(`\n${matrix.length - failed}/${matrix.length} commands passed`);
process.exit(failed ? 1 : 0);
