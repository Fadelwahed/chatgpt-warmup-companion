import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand } from '../runtime.mjs';
import { makeFixture } from './helpers.mjs';

async function prepared() {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_boundary_01', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [0, 1].map(n => ({ routerAccountId: `router_${n}`, eligible: true })) }),
    discoverIdentity: (_ctx, id) => ({ kind: 'ready', identity: { accountId: `workspace-${id}`, userId: `user-${id}` } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'CANARY_SYNTHETIC_TOKEN', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  assert.equal((await call({ name: 'run' })).exitCode, 0);
  assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
  return { ...f, call, state };
}

const slot = '2026-11-12T08:00';
const scheduledReservations = state => Object.entries(state.reservations).filter(([key]) => !key.startsWith('manual:'));

test('D scheduler passes remaining batch budget to real streaming probe and stops on abort', async () => {
  const f = await prepared();
  try {
    const start = f.services.clock.wall(), pilots = f.state().pilots;
    const read = f.services.reader.readCredential;
    f.services.reader.readCredential = (...args) => { f.services.clock.advance(119000); return read(...args); };
    delete f.services.probe;
    let calls = 0, abortedDuringStream = false, timeout;
    f.services.request = async (_options, _body, control) => {
      calls++; timeout = control.timeoutMs; control.beforeSend(); control.onDispatch();
      return { statusCode: 200, headers: {}, body: (async function* () {
        yield Buffer.from(': partial stream\n\n');
        f.services.clock.advance(1000);
        abortedDuringStream = control.signal.aborted;
        yield Buffer.from('data: CANARY_RAW_RESPONSE\n\n');
      })() };
    };
    const out = await f.call({ name: 'tick' });
    assert.equal(timeout, 1000);
    assert.equal(abortedDuringStream, true);
    assert.equal(calls, 1);
    assert.deepEqual([out.selected, out.attempted, out.results[0].outcome, out.results[0].reason, out.results[1].reason],
      [2, 1, 'uncertain', 'deadline_exceeded', 'batch_unprocessed']);
    const saved = f.state();
    assert.deepEqual(saved.pilots, pilots);
    assert.deepEqual(saved.cooldowns, {});
    assert.equal(saved.history.at(-2).reason, 'deadline_exceeded');
    assert.equal(saved.history.at(-1).reason, 'batch_unprocessed');
    assert.equal(saved.history.at(-1).skipped, true);
    assert.equal(scheduledReservations(saved).length, 1);
    assert.ok(saved.slots[slot]);
    assert.equal(saved.activeBatch, null);
    assert.doesNotMatch(JSON.stringify([out, saved]), /CANARY_/);
    f.services.clock.setWall(start);
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(calls, 1);
  } finally { f.cleanup(); }
});

test('D outcome and final slot persistence finish under work lock after deadline', async () => {
  const f = await prepared();
  try {
    const start = f.services.clock.wall(), baseline = f.state().history.length;
    let sends = 0, delayed = false, finalPersistedWithLock = false;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    f.services.fault = point => {
      if (point !== 'after_state.json_rename') return;
      const saved = f.state();
      if (!delayed && saved.activeBatch && saved.history.length === baseline + 1) {
        assert.equal(fs.existsSync(path.join(f.companionRoot, 'work.lock')), true);
        delayed = true;
        f.services.clock.advance(121000);
      } else if (delayed && saved.activeBatch === null && saved.lastSlotOutcome?.slot === slot) {
        finalPersistedWithLock = fs.existsSync(path.join(f.companionRoot, 'work.lock'));
      }
    };
    const out = await f.call({ name: 'tick' });
    assert.equal(delayed, true); assert.equal(finalPersistedWithLock, true);
    assert.deepEqual([out.selected, out.attempted, out.results[0].outcome, out.results[1].reason], [2, 1, 'success', 'batch_unprocessed']);
    const saved = f.state();
    assert.equal(saved.history.at(-2).outcome, 'success');
    assert.equal(saved.history.at(-1).skipped, true);
    assert.equal(saved.lastSlotOutcome.slot, slot); assert.equal(saved.activeBatch, null);
    assert.equal(scheduledReservations(saved).length, 1);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'work.lock')), false);
    delete f.services.fault;
    f.services.clock.setWall(start);
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(sends, 1);
  } finally { f.cleanup(); }
});

test('D discontinuity after first success prevents later send and retains claimed slot', async () => {
  const f = await prepared();
  try {
    const start = f.services.clock.wall(), pilots = f.state().pilots;
    let sends = 0;
    f.services.probe = async () => {
      sends++;
      f.services.clock.setWall(f.services.clock.wall() + 5000);
      return { outcome: 'success', reason: 'marker_confirmed', dispatched: true };
    };
    const out = await f.call({ name: 'tick' });
    assert.deepEqual([out.selected, out.attempted, out.results[0].outcome, out.results[1].reason], [2, 1, 'success', 'batch_deadline_or_clock']);
    const saved = f.state();
    assert.ok(saved.slots[slot]); assert.equal(saved.highWater, slot);
    assert.equal(scheduledReservations(saved).length, 1);
    assert.equal(saved.history.at(-2).outcome, 'success');
    assert.equal(saved.history.at(-1).skipped, true);
    assert.equal(saved.lastSlotOutcome.slot, slot); assert.equal(saved.activeBatch, null);
    assert.deepEqual(saved.pilots, pilots); assert.deepEqual(saved.cooldowns, {});
    f.services.clock.setWall(start);
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(sends, 1);
  } finally { f.cleanup(); }
});
