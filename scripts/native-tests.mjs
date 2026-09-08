import { spawn } from 'node:child_process';

const child = spawn('swift', ['test', '--package-path', 'native'], { cwd: new URL('..', import.meta.url), stdio: 'inherit' });
child.on('error', error => { throw error; });
child.on('close', code => { process.exitCode = code ?? 1; });
