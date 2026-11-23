import test from 'node:test';
import assert from 'node:assert/strict';
import { execute, engineVersion, fitStatusOutput } from '../warmup.mjs';

test('E protocol parser rejects unknown flags before any service IO', async () => {
  const services = new Proxy({}, { get() { throw new Error('unexpected_service_io'); } });
  const response = await execute(['run', '--bad'], services);
  assert.equal(response.exitCode, 2);
  assert.equal(response.json.protocolVersion, 1);
  assert.equal(response.json.engineVersion, engineVersion);
  assert.equal(response.json.reason, 'invalid_invocation');
  assert.deepEqual([response.json.selected, response.json.attempted, response.json.results], [0, 0, []]);
});

test('E strict account namespaces and command arity', async () => {
  for (const argv of [['enroll'], ['run', '--account', ''], ['schedule'], ['schedule', 'enable', 'extra'], ['maintain', '--file', 'relative'], ['status', '--account', 'x']]) {
    assert.equal((await execute(argv)).exitCode, 2, argv.join(' '));
  }
});

test('E unknown command text is not echoed in JSON', async () => {
  const response = await execute(['Bearer_secret_canary']);
  assert.equal(response.exitCode, 2);
  assert.equal(response.json.command, 'unknown');
  assert.equal(JSON.stringify(response).includes('secret_canary'), false);
});

test('R3 a status reply drops optional usage before it would pass the output limit', () => {
  const usage = { primary: { usedPercent: 40, windowMinutes: 300, resetsAt: 1 }, observedAt: 1 };
  const json = () => ({ command: 'status', accounts: Array.from({ length: 20 }, (_, i) => ({ enrollmentId: `enr_${i}`, usage })), usageTruncated: false });
  const small = fitStatusOutput(json(), 1 << 20);
  assert.equal(small.usageTruncated, false);
  assert.ok(small.accounts.every(account => account.usage));
  const full = Buffer.byteLength(JSON.stringify(json()));
  const fitted = fitStatusOutput(json(), full - 1);
  assert.equal(fitted.usageTruncated, true);
  assert.ok(fitted.accounts.every(account => account.usage === null));
  assert.ok(Buffer.byteLength(JSON.stringify(fitted)) < full - 1);
  assert.deepEqual(fitStatusOutput({ command: 'list', rows: [] }, 1), { command: 'list', rows: [] });
  // Nested evidence in the last batch's results is dropped too, and the whole envelope then fits.
  const nested = () => ({ ...json(), lastSlotOutcome: { slot: '2026-11-12T08:00', results: Array.from({ length: 20 }, () => ({ enrollmentId: 'enr', outcome: 'success', usage })) } });
  const accountsOnly = Buffer.byteLength(JSON.stringify({ ...nested(), accounts: nested().accounts.map(a => ({ ...a, usage: null })), usageTruncated: true }));
  const both = fitStatusOutput(nested(), accountsOnly - 1);
  assert.ok(both.lastSlotOutcome.results.every(row => !('usage' in row)));
  assert.ok(Buffer.byteLength(JSON.stringify(both)) <= accountsOnly - 1);
});
