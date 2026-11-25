import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand, hostServices } from '../runtime.mjs';
import { makeFixture } from './helpers.mjs';

// Engine 1.2.4: scheduled network retry before anything was sent, and a power hold during a batch.
// The fake clock starts at 06:00Z, the 08:00 Asia/Gaza admission minute; one account's batch deadline is 75 s.
const fail = code => ({ outcome: 'blocked', reason: 'transport_before_send', dispatched: false, transportCode: code });
const ok = { outcome: 'success', reason: 'marker_confirmed', dispatched: true };

async function prepared(count = 1, { sleep = true } = {}) {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_engine_124', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  const identity = id => ({ accountId: `workspace-${id}`, userId: `user-${id}` });
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: Array.from({ length: count }, (_, n) => ({ routerAccountId: `router_${n}`, eligible: true })) }),
    discoverIdentity: (_ctx, id) => ({ kind: 'ready', identity: identity(id) }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => ok;
  const sleeps = [];
  if (sleep) f.services.clock.sleep = ms => { sleeps.push(ms); f.services.clock.advance(ms); return Promise.resolve(); };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  assert.equal((await call({ name: 'run' })).exitCode, 0);
  assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
  return { f, call, state, sleeps };
}

// A probe stub that answers from `answers` in order (the last one repeats) and records each call's mono time.
function script(f, answers, step = () => 0) {
  const calls = [];
  f.services.probe = async args => {
    const n = calls.length;
    calls.push({ mono: f.services.clock.mono(), account: args.credential.identity.accountId });
    f.services.clock.advance(step(n));
    const answer = answers[Math.min(n, answers.length - 1)];
    return typeof answer === 'function' ? answer(args) : answer;
  };
  return calls;
}
const scheduledRows = state => state().history.filter(row => row.mode === 'scheduled');
const reservationOf = (state, row) => Object.values(state().reservations).filter(r => r.reservationId === row.reservationId);
const gaps = calls => calls.slice(1).map((c, i) => c.mono - calls[i].mono);

test('1.2.4 (1): ENOTFOUND then success is one success row under one resolved reservation, 5 s apart', async () => {
  const { f, call, state, sleeps } = await prepared();
  try {
    const calls = script(f, [fail('ENOTFOUND'), ok]);
    const out = await call({ name: 'tick' });
    assert.deepEqual([out.exitCode, out.outcome, out.attempted], [0, 'success', 1]);
    assert.equal(calls.length, 2);
    assert.deepEqual(sleeps, [5000]);
    assert.deepEqual(gaps(calls), [5000]);
    const rows = scheduledRows(state);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].outcome, rows[0].reason, rows[0].dispatched, rows[0].transportCode], ['success', 'marker_confirmed', true, undefined]);
    const reservations = reservationOf(state, rows[0]);
    assert.equal(reservations.length, 1);
    assert.equal(reservations[0].resolved, true);
    // History rows keep their shape: same keys as a single-attempt success.
    const control = await prepared();
    try {
      await control.call({ name: 'tick' });
      assert.deepEqual(Object.keys(rows[0]).sort(), Object.keys(scheduledRows(control.state)[0]).sort());
    } finally { control.f.cleanup(); }
  } finally { f.cleanup(); }
});

test('1.2.4 (2): three ENOTFOUND are one blocked transport_before_send row after exactly three calls', async () => {
  const { f, call, state, sleeps } = await prepared();
  try {
    const calls = script(f, [fail('ENOTFOUND')]);
    const out = await call({ name: 'tick' });
    assert.equal(calls.length, 3);
    assert.deepEqual(sleeps, [5000, 15000]);
    assert.deepEqual(gaps(calls), [5000, 15000]);
    assert.equal(out.attempted, 0);
    assert.deepEqual(out.results.map(r => [r.reason, r.transportCode]), [['transport_before_send', 'ENOTFOUND']]);
    const rows = scheduledRows(state);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].outcome, rows[0].reason, rows[0].dispatched, rows[0].transportCode], ['blocked', 'transport_before_send', false, 'ENOTFOUND']);
    assert.equal(reservationOf(state, rows[0])[0].resolved, true);
  } finally { f.cleanup(); }
});

test('1.2.4 (2b): every listed code retries', async () => {
  for (const code of ['ENOTFOUND', 'EAI_AGAIN', 'ENETUNREACH', 'EHOSTUNREACH', 'ECONNREFUSED']) {
    const { f, call } = await prepared();
    try {
      const calls = script(f, [fail(code), ok]);
      assert.equal((await call({ name: 'tick' })).outcome, 'success');
      assert.equal(calls.length, 2, code);
    } finally { f.cleanup(); }
  }
});

test('1.2.4 (3): unlisted codes, uncertain, dispatched and untrusted results are never retried', async () => {
  for (const answer of [
    fail('ETIMEDOUT'), fail('ECONNRESET'), fail(undefined),
    { outcome: 'uncertain', reason: 'stream_or_transport_uncertain', dispatched: true },
    { ...fail('ENOTFOUND'), dispatched: true },
    { ...fail('ENOTFOUND'), outcome: 'uncertain' },
    { ...fail('ENOTFOUND'), outcome: 'not_a_probe_outcome' },
    { outcome: 'blocked', reason: 'transport_unavailable', dispatched: false, transportCode: 'ENOTFOUND' },
  ]) {
    const { f, call, sleeps } = await prepared();
    try {
      const calls = script(f, [answer, ok]);
      await call({ name: 'tick' });
      assert.equal(calls.length, 1, JSON.stringify(answer));
      assert.deepEqual(sleeps, []);
    } finally { f.cleanup(); }
  }
});

test('1.2.4 (4): no retry when the deadline leaves under 45 s after the wait', async () => {
  const { f, call, state, sleeps } = await prepared();
  try {
    // 30 s probe + 5 s wait leaves 40 s of the 75 s deadline.
    const calls = script(f, [fail('ENOTFOUND'), ok], () => 30000);
    const out = await call({ name: 'tick' });
    assert.equal(calls.length, 1);
    assert.deepEqual(sleeps, [5000]);
    assert.deepEqual(out.results.map(r => [r.reason, r.transportCode]), [['transport_before_send', 'ENOTFOUND']]);
    assert.equal(scheduledRows(state).length, 1);
  } finally { f.cleanup(); }
});

test('1.2.4 (5): a Router block before the retry is send_check_failed as today, with no further call', async () => {
  for (const [scope, reason, outcome] of [['account', 'send_check_failed', 'partial'], ['global', 'reader_global_block', 'blocked']]) {
    const { f, call, state } = await prepared();
    try {
      let blocked = false;
      const sendChecked = ({ finalCheck }) => finalCheck() ? ok : { outcome: 'blocked', reason: 'send_check_failed', dispatched: false };
      const calls = script(f, [() => { blocked = true; return fail('ENOTFOUND'); }, sendChecked, ok]);
      f.services.reader.revalidate = () => blocked ? { kind: 'blocked', scope, reason: 'switch_busy' } : { kind: 'ready' };
      const out = await call({ name: 'tick' });
      assert.equal(calls.length, 2);
      assert.equal(out.outcome, outcome);
      assert.deepEqual(out.results.map(r => r.reason), [reason]);
      const rows = scheduledRows(state);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].reason, reason);
      assert.equal(rows[0].transportCode, undefined);
    } finally { f.cleanup(); }
  }
});

test('1.2.4 (6): the second account still runs after the first retries, or is reported by the deadline path', async () => {
  {
    const { f, call } = await prepared(2);
    try {
      const calls = script(f, [fail('ENOTFOUND'), ok, ok]);
      const out = await call({ name: 'tick' });
      assert.deepEqual(calls.map(c => c.account), ['workspace-router_0', 'workspace-router_0', 'workspace-router_1']);
      assert.deepEqual(out.results.map(r => r.reason), ['marker_confirmed', 'marker_confirmed']);
    } finally { f.cleanup(); }
  }
  {
    const { f, call, state } = await prepared(2);
    try {
      // 120 s deadline: attempts start at 0 s, 15 s and 40 s; the third ends past the deadline.
      const calls = script(f, [fail('ENOTFOUND')], n => [10000, 10000, 100000][n]);
      const out = await call({ name: 'tick' });
      assert.equal(calls.length, 3);
      assert.deepEqual(out.results.map(r => r.reason), ['transport_before_send', 'batch_unprocessed']);
      assert.equal(scheduledRows(state).length, 2);
    } finally { f.cleanup(); }
  }
});

test('1.2.4 (7): a manual run keeps a single attempt', async () => {
  const { f, call, sleeps } = await prepared();
  try {
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    const calls = script(f, [fail('ENOTFOUND'), ok]);
    const out = await call({ name: 'run' });
    assert.equal(calls.length, 1);
    assert.deepEqual(sleeps, []);
    assert.deepEqual(out.results.map(r => [r.reason, r.transportCode]), [['transport_before_send', 'ENOTFOUND']]);
  } finally { f.cleanup(); }
});

test('1.2.4 (8): a clock without sleep keeps a single attempt', async () => {
  const { f, call } = await prepared(1, { sleep: false });
  try {
    const calls = script(f, [fail('ENOTFOUND'), ok]);
    const out = await call({ name: 'tick' });
    assert.equal(calls.length, 1);
    assert.deepEqual(out.results.map(r => r.reason), ['transport_before_send']);
  } finally { f.cleanup(); }
});

test('1.2.4 (9): a clock jump during the wait keeps transport_before_send and stops the batch', async () => {
  const { f, call, state } = await prepared(2);
  try {
    f.services.clock.sleep = ms => { f.services.clock.advance(ms); f.services.clock.setWall(f.services.clock.wall() + 3600000); return Promise.resolve(); };
    const calls = script(f, [fail('ENOTFOUND'), ok]);
    const out = await call({ name: 'tick' });
    assert.equal(calls.length, 1);
    assert.deepEqual(out.results.map(r => [r.reason, r.transportCode]), [['transport_before_send', 'ENOTFOUND'], ['batch_unprocessed', undefined]]);
    const rows = scheduledRows(state);
    assert.deepEqual(rows.map(r => r.reason), ['transport_before_send', 'batch_unprocessed']);
    assert.equal(reservationOf(state, rows[0])[0].resolved, true);
  } finally { f.cleanup(); }
});

test('1.2.4: a credential that runs short during the wait is recorded as today, with no retry', async () => {
  const { f, call, state } = await prepared();
  try {
    f.services.reader.readCredential = (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: f.services.clock.wall() + 122000, snapshot: {} });
    const calls = script(f, [fail('ENOTFOUND'), ok]);
    const out = await call({ name: 'tick' });
    assert.equal(calls.length, 1);
    assert.deepEqual(out.results.map(r => [r.reason, r.skipped]), [['credential_expired_or_unknown', true]]);
    const rows = scheduledRows(state);
    assert.equal(rows.length, 1);
    assert.equal(reservationOf(state, rows[0])[0].resolved, true);
  } finally { f.cleanup(); }
});

function powerStub() {
  const log = { holds: 0, releases: 0 };
  return { log, power: { hold() { log.holds++; return () => { log.releases++; }; } } };
}

test('1.2.4: the power hold is taken once per batch and released once on success, error and stopBatch', async () => {
  for (const [label, arrange, reason] of [
    ['success', () => {}, 'run_complete'],
    ['thrown error', f => { f.services.probe = async () => { throw new Error('synthetic'); }; }, 'internal_error'],
    ['stopBatch', f => { f.services.reader.readCredential = () => ({ kind: 'blocked', scope: 'global', reason: 'switch_busy' }); }, 'reader_global_block'],
  ]) {
    const { f, call } = await prepared(2);
    try {
      const { log, power } = powerStub();
      f.services.power = power;
      arrange(f);
      assert.equal((await call({ name: 'tick' })).reason, reason, label);
      assert.deepEqual(log, { holds: 1, releases: 1 }, label);
    } finally { f.cleanup(); }
  }
});

test('1.2.4: a manual run holds power too; an idle tick takes no hold', async () => {
  const { f, call } = await prepared();
  try {
    const { log, power } = powerStub();
    f.services.power = power;
    assert.equal((await call({ name: 'tick' })).outcome, 'success');
    assert.deepEqual(log, { holds: 1, releases: 1 });
    assert.equal((await call({ name: 'tick' })).reason, 'slot_already_claimed');
    f.services.clock.advance(120000);
    assert.equal((await call({ name: 'tick' })).reason, 'outside_admission_minute');
    assert.deepEqual(log, { holds: 1, releases: 1 });
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    assert.equal((await call({ name: 'run' })).exitCode, 0);
    assert.deepEqual(log, { holds: 2, releases: 2 });
  } finally { f.cleanup(); }
});

test('1.2.4: a hold that throws or returns no release does not change the batch result', async () => {
  for (const hold of [() => { throw new Error('synthetic'); }, () => undefined]) {
    const { f, call, state } = await prepared();
    try {
      f.services.power = { hold };
      const out = await call({ name: 'tick' });
      assert.deepEqual([out.exitCode, out.outcome, out.attempted], [0, 'success', 1]);
      assert.equal(scheduledRows(state)[0].reason, 'marker_confirmed');
    } finally { f.cleanup(); }
  }
  const { f, call } = await prepared();
  try {
    f.services.power = { hold: () => () => { throw new Error('synthetic'); } };
    assert.equal((await call({ name: 'tick' })).outcome, 'success');
  } finally { f.cleanup(); }
});

test('1.2.4: hostServices exposes clock.sleep and power.hold without starting anything', async () => {
  const services = hostServices(path.join(process.env.WARMUP_TEST_ROOT, 'host-124'), () => { throw new Error('unexpected command'); });
  assert.equal(typeof services.clock.sleep, 'function');
  assert.equal(typeof services.power.hold, 'function');  // never called: tests must not run caffeinate
  await services.clock.sleep(1);
});
