import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { powerHoldArguments } from '../runtime.mjs';
import { engineVersion } from '../warmup.mjs';

// Engine 1.2.5: the batch hold adds -s (system sleep, honored on AC power only) to -i.
// No test here starts caffeinate; the 1.2.4 hold tests (fail open, released on exit, a throwing
// release does not break a tick) live in engine-1-2-4.test.mjs and run unchanged.

test('1.2.5: the engine version is 1.2.5-offline', () => {
  assert.equal(engineVersion, '1.2.5-offline');
});

test('1.2.5: the power hold arguments are exactly -s -i -w <pid>', () => {
  assert.deepEqual(powerHoldArguments(4321), ['-s', '-i', '-w', '4321']);
  assert.deepEqual(powerHoldArguments(process.pid), ['-s', '-i', '-w', String(process.pid)]);
});

test('1.2.5: power.hold spawns caffeinate with powerHoldArguments and nothing else', () => {
  // Reads the source instead of calling hold(), so caffeinate is never started.
  const source = fs.readFileSync(path.join(process.env.WARMUP_REPO, 'runtime.mjs'), 'utf8');
  const spawns = source.match(/spawn\('\/usr\/bin\/caffeinate', [^)]*\)/g) ?? [];
  assert.deepEqual(spawns, ["spawn('/usr/bin/caffeinate', powerHoldArguments(process.pid)"]);
});
