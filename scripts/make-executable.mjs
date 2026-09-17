import { chmod } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

// tsc emits 0644; the CLI entry must be executable for the `nuvin-computer-use`
// bin to launch directly.
await chmod(new URL('../dist/cli.js', import.meta.url), 0o755);
