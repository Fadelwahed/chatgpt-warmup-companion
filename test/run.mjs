import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const testDir = path.join(repo, 'test');
const files = process.argv.slice(2);
const selected = files.length ? files.map(file => path.resolve(file)) : fs.readdirSync(testDir).filter(file => file.endsWith('.test.mjs')).map(file => path.join(testDir, file));
if (!selected.length || selected.some(file => !file.startsWith(`${testDir}${path.sep}`) || !file.endsWith('.test.mjs') || fs.realpathSync(file) !== file || !fs.statSync(file).isFile())) {
  throw new Error('Only existing test/*.test.mjs files may run');
}

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'warmup-test-')));
fs.chmodSync(root, 0o700);
const home = path.join(root, 'home');
fs.mkdirSync(home, { mode: 0o700 });
const env = { PATH: '/usr/bin:/bin', HOME: home, TMPDIR: root, WARMUP_TEST_ROOT: root, WARMUP_REPO: repo, LANG: 'C' };
let status = 1;
try {
  const result = spawnSync(process.execPath, [
    '--import', path.join(testDir, 'guard.mjs'), '--experimental-test-isolation=none', '--test', ...selected.map(file => path.relative(repo, file)),
  ], { cwd: repo, env, stdio: 'inherit', timeout: 120000 });
  status = result.status ?? 1;
  if (result.error) process.stderr.write(`Guarded test runner failed: ${result.error.code ?? 'unknown'}\n`);
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
process.exitCode = status;
