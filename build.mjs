import { cp, mkdir, rm } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const output = resolve(root, 'dist');
if (dirname(output) !== root) throw new Error('Unexpected build destination');
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const file of ['index.html', 'config.js', 'formula.js', 'estimate-pdf.js', 'assets', 'help.html', 'help.css', 'help.js', 'spravochnik']) {
  await cp(resolve(root, file), resolve(output, file), { recursive: true });
}
console.log('Static site built in dist/');
