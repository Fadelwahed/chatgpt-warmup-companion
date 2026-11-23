// Writes test/fixtures/ui/<name>.json from "# UI-FIXTURE <name> <json>" lines in the guarded
// output of test/ui-fixtures.test.mjs. Usage, from the repository root:
//   rtk proxy /opt/homebrew/opt/node@22/bin/node test/run.mjs test/ui-fixtures.test.mjs > ui.tap
//   /opt/homebrew/opt/node@22/bin/node tools/extract-ui-fixtures.mjs ui.tap
// Review the resulting diff before accepting it: fixtures are the native app's contract.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const input = process.argv[2];
if (!input) throw new Error('Pass the TAP output file');
const target = path.join(repo, 'test', 'fixtures', 'ui');
fs.mkdirSync(target, { recursive: true, mode: 0o755 });
let count = 0;
for (const line of fs.readFileSync(input, 'utf8').split('\n')) {
  const match = /^# UI-FIXTURE ([a-z0-9-]{1,64}) (\{.*\})$/.exec(line);
  if (!match) continue;
  const value = JSON.parse(match[2]);
  fs.writeFileSync(path.join(target, `${match[1]}.json`), `${JSON.stringify(value, null, 2)}\n`);
  count++;
}
if (!count) throw new Error('No UI fixtures found in input');
process.stdout.write(`wrote ${count} fixtures to ${path.relative(repo, target)}\n`);
