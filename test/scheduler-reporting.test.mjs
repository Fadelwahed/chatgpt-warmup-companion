import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { runCommand } from '../runtime.mjs';
import { execute } from '../warmup.mjs';
import { makeFixture } from './helpers.mjs';

async function prepared() {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_reporting_01', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  let reads = 0, sends = 0;
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_1', eligible: true }] }),
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace_1', userId: 'user_1' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => { reads++; return { kind: 'ready', identity: e.identity, accessToken: 'CANARY_TOKEN', expiresAt: 4102444800000, snapshot: {} }; },
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: fileURLToPath(new URL('../warmup.mjs', import.meta.url)) };
  f.services.context = context;
  const call = command => runCommand(command, context, f.services);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  const write = value => put(f.statePath, value);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  return { ...f, call, state, write, reads: () => reads, sends: () => sends };
}
const instant = time => Date.parse(`2026-11-12T${time}Z`);
const history = (id, n) => Array.from({ length: n }, (_, i) => ({ enrollmentId: id, outcome: 'success', reason: 'marker_confirmed', at: i }));

test('idle heartbeat preserves aged history and all safety records; busy writes nothing', async () => {
  const f = await prepared();
  try {
    const initial = f.state();
    initial.history = history('old', 1);
    initial.pilots.keep = { at: 1 };
    f.write(initial);
    for (const branch of ['disabled', 'outside', 'claimed']) {
      const s = f.state(); s.scheduleEnabled = branch !== 'disabled';
      s.slots = branch === 'claimed' ? { '2026-11-12T08:00': { enrollmentIds: [], claimedAt: instant('06:00:00') } } : {};
      s.highWater = branch === 'claimed' ? '2026-11-12T08:00' : null;
      f.services.clock.setWall(instant(branch === 'outside' ? '06:02:00' : '06:00:00'));
      s.lastWall = null; f.write(s);
      const before = f.state();
      assert.equal((await f.call({ name: 'tick' })).reason, { disabled: 'schedule_disabled', outside: 'outside_admission_minute', claimed: 'slot_already_claimed' }[branch]);
      const after = f.state();
      for (const key of ['history', 'slots', 'pilots', 'reservations']) assert.deepEqual(after[key], before[key], `${branch} ${key}`);
      assert.equal(after.lastTick, f.services.clock.wall()); assert.equal(after.lastWall, f.services.clock.wall());
    }
    const before = fs.readFileSync(f.statePath, 'utf8');
    fs.mkdirSync(path.join(f.companionRoot, 'work.lock'), { mode: 0o700 });
    assert.equal((await f.call({ name: 'tick' })).exitCode, 3);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(f.reads(), 0); assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});

test('status exposes bounded filtered history and explicit truncation through execute', async () => {
  const f = await prepared();
  try {
    const id = JSON.parse(fs.readFileSync(f.configPath)).enrollments[0].enrollmentId;
    for (const n of [0, 10, 11]) {
      const s = f.state(); s.history = history(id, n); f.write(s);
      const before = fs.readFileSync(f.statePath, 'utf8');
      const out = await execute(['status'], f.services);
      assert.equal(out.exitCode, 0); assert.equal(out.json.historyTruncated, n > 10);
      assert.deepEqual(out.json.recent.map(x => x.at), history(id, n).slice(-10).map(x => x.at));
      assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    }
    const s = f.state(); s.history = [...history(id, 2), ...history('removed_CANARY_SECRET', 10), { enrollmentId: id, outcome: 'CANARY_SECRET', reason: 'CANARY_SECRET', at: 23 }]; f.write(s);
    const before = fs.readFileSync(f.statePath, 'utf8');
    const out = (await execute(['status'], f.services)).json;
    assert.equal(out.historyTruncated, true);
    assert.deepEqual(out.recent.map(x => x.at), [0, 1, 23]);
    assert.deepEqual([out.recent.at(-1).outcome, out.recent.at(-1).reason], ['unknown', 'unknown']);
    assert.doesNotMatch(JSON.stringify(out), /CANARY_SECRET|CANARY_TOKEN/);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(f.reads(), 0); assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});

test('status derives only fully elapsed slots from the dated heartbeat, including stale and disabled', async () => {
  const f = await prepared();
  try {
    const status = async () => (await f.call({ name: 'status' })).slotObservation;
    assert.equal(await status(), null);
    for (const [time, expected] of [['05:59:59', null], ['06:00:00', null], ['06:00:59.999', null], ['06:01:00', '08:00'], ['11:01:00', '13:00'], ['16:01:00', '18:00']]) {
      const s = f.state(); s.lastTick = instant(time); s.lastWall = s.lastTick; f.write(s);
      f.services.clock.setWall(s.lastTick);
      assert.deepEqual(await status(), expected ? { slot: `2026-11-12T${expected}`, observation: 'unobserved', asOf: s.lastTick } : null);
    }
    const s = f.state(); s.scheduleEnabled = false; s.lastSlotOutcome = { slot: '2026-11-11T18:00', outcome: 'success', at: instant('05:00:00') }; f.write(s);
    f.services.clock.setWall(instant('16:01:00') + 86400000);
    const before = fs.readFileSync(f.statePath, 'utf8');
    const out = await f.call({ name: 'status' });
    assert.equal(out.scheduleEnabled, false); assert.equal(out.slotObservation.slot, '2026-11-12T18:00');
    assert.deepEqual(out.lastSlotOutcome, s.lastSlotOutcome);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(f.reads(), 0); assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});

test('status suppresses unobserved when claim, incomplete work, recovery or clock evidence conflicts', async () => {
  const f = await prepared();
  try {
    const at = instant('06:01:00'); f.services.clock.setWall(at);
    const baseline = f.state(); baseline.lastTick = at; baseline.lastWall = at;
    const slot = '2026-11-12T08:00';
    const cases = [
      s => { s.slots[slot] = { enrollmentIds: [], claimedAt: at }; s.highWater = slot; },
      s => { s.activeBatch = { slot, enrollmentIds: [] }; },
      s => { s.lastSlotOutcome = { slot, outcome: 'success', at }; },
      s => { s.reservations[JSON.stringify([slot, 'e', 'a', 'u'])] = { enrollmentId: 'e', identity: { accountId: 'a', userId: 'u' }, at, possibleSend: true }; },
      s => { s.reservations.ambiguous = { enrollmentId: 'e', identity: { accountId: 'a', userId: 'u' }, at, possibleSend: true }; },
      s => { s.skipThrough = slot; },
      s => { s.highWater = slot; },
      s => { s.lastTick = at + 1; s.lastWall = at + 1; },
      s => { s.lastWall = at - 1; },
    ];
    for (const mutate of cases) {
      const s = structuredClone(baseline); mutate(s); f.write(s);
      const before = fs.readFileSync(f.statePath, 'utf8');
      const out = await f.call({ name: 'status' });
      assert.equal(out.exitCode, 0); assert.equal(out.slotObservation, null);
      assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    }
    assert.equal(f.reads(), 0); assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});

test('normal claimed work still prunes aged history and crossing admission waits for later heartbeat', async () => {
  const f = await prepared();
  try {
    const s = f.state(); s.scheduleEnabled = true; s.history = history('old', 1); f.write(s);
    f.services.clock.setWall(instant('06:00:59.900'));
    f.services.reader.checkCompatibility = () => { f.services.clock.advance(200); return { kind: 'ready' }; };
    assert.equal((await f.call({ name: 'tick' })).reason, 'outside_admission_minute');
    let out = await f.call({ name: 'status' });
    assert.equal(out.slotObservation, null);
    assert.equal(f.state().history.length, 1);
    f.services.reader.checkCompatibility = () => ({ kind: 'ready' });
    assert.equal((await f.call({ name: 'tick' })).reason, 'outside_admission_minute');
    out = await f.call({ name: 'status' });
    assert.equal(out.slotObservation.slot, '2026-11-12T08:00');
    f.services.clock.setWall(instant('11:00:00'));
    const claimed = await f.call({ name: 'tick' });
    assert.equal(claimed.reason, 'run_complete');
    assert.deepEqual(f.state().history.map(row => [row.skipped, row.reason]), [[true, 'pilot_required']]);
    assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});
