import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand } from '../runtime.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

// Engine 1.2.3: slot ledger rows expire by their admission date, not by when they were written.
// Asia/Gaza is UTC+2 in November: local 08:00 is 06:00Z.
const at = time => Date.parse(`2026-11-12T${time}Z`);
const DAY = 86400000;
const node = '/opt/homebrew/opt/node@22/bin/node';
const utcDate = ms => new Date(ms).toISOString().slice(0, 10);

async function prepared(start = at('02:40:00'), zone = 'Asia/Gaza') {
  const f = makeFixture({ clock: fakeClock(start) });
  f.services.clock.zone = () => zone;
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_engine_123', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_0', eligible: true }] }),
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
  const context = { root: f.companionRoot, nodePath: node, scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  assert.equal((await call({ name: 'run' })).exitCode, 0);
  assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  const save = value => fs.writeFileSync(f.statePath, JSON.stringify(value), { mode: 0o600 });
  return { f, call, state, save };
}

// A valid hand-seeded ledger row written at `written` (evidence tick = at = written).
function seed(s, slot, { cause = 'schedule_disabled', zone = 'Asia/Gaza', written }) {
  s.slotLedger = { ...(s.slotLedger ?? {}), [slot]: { admission: slot.slice(11), verdict: 'not_admitted', cause, zone, at: written,
    evidence: { previousTick: s.lastTick, tick: written, previousZone: 'Asia/Gaza' } } };
  return s;
}
const ledgerKeys = state => Object.keys(state().slotLedger ?? {});

// 2026-10-10 is 33 days before 2026-11-12; 2026-11-01 is inside retention.
for (const [label, write] of [['a tick', { name: 'tick' }], ['a state write (schedule disable)', { name: 'schedule', action: 'disable' }]]) {
  test(`1.2.3: a row written now for an admission 33 days ago is pruned by ${label}`, async () => {
    const { f, call, state, save } = await prepared();
    try {
      const now = at('03:00:00');
      f.services.clock.setWall(now);
      save(seed(seed(state(), '2026-10-10T08:00', { written: now }), '2026-11-01T08:00', { written: now }));
      f.services.clock.setWall(now + 30000);
      assert.equal((await call(write)).exitCode, 0);
      const keys = ledgerKeys(state);
      assert.equal(keys.includes('2026-10-10T08:00'), false);
      assert.equal(keys.includes('2026-11-01T08:00'), true);
    } finally { f.cleanup(); }
  });
}

test('1.2.3: rows written by a late enable expire by admission date', async () => {
  const { f, call, state } = await prepared();
  try {
    f.services.clock.setWall(at('05:55:00'));
    assert.equal((await call({ name: 'schedule', action: 'disable' })).reason, 'schedule_disabled');
    f.services.clock.setWall(at('05:55:00') + 40 * DAY);
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    assert.ok(ledgerKeys(state).length > 0, 'enable recorded paused slots');
    const now = at('05:55:00') + 43 * DAY;  // local 07:55: outside an admission minute
    f.services.clock.setWall(now);
    const ticked = await call({ name: 'tick' });
    assert.equal(ticked.exitCode, 0);
    const keys = ledgerKeys(state);
    assert.ok(keys.length > 0, 'rows inside retention remain');
    const oldest = utcDate(now - 31 * DAY);
    assert.deepEqual(keys.filter(slot => slot.slice(0, 10) < oldest), []);
  } finally { f.cleanup(); }
});

test('1.2.3: a row with an unknown but well-formed zone does not throw and is pruned by date', async () => {
  const { f, call, state, save } = await prepared();
  try {
    const now = at('03:00:00');
    f.services.clock.setWall(now);
    const opts = { cause: 'no_tick_between', zone: 'Mars/Base', written: now };
    save(seed(seed(state(), '2026-10-10T13:00', opts), '2026-11-10T13:00', opts));
    f.services.clock.setWall(now + 30000);
    assert.equal((await call({ name: 'tick' })).exitCode, 0);
    assert.deepEqual([ledgerKeys(state).includes('2026-10-10T13:00'), ledgerKeys(state).includes('2026-11-10T13:00')], [false, true]);
    f.services.clock.setWall(now + 60000);
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    assert.equal(state().slotLedger['2026-11-10T13:00'].zone, 'Mars/Base');
  } finally { f.cleanup(); }
});

// Real rows always have `at` at or after the admission; this hand-seeded one checks `at` no longer decides.
test('1.2.3: a row inside retention whose at is older than 30 days is kept', async () => {
  const { f, call, state, save } = await prepared();
  try {
    const now = at('03:00:00');
    f.services.clock.setWall(now);
    save(seed(state(), '2026-11-01T08:00', { written: now - 40 * DAY }));
    f.services.clock.setWall(now + 30000);
    assert.equal((await call({ name: 'tick' })).exitCode, 0);
    assert.equal(ledgerKeys(state).includes('2026-11-01T08:00'), true);
    f.services.clock.setWall(now + 60000);
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    assert.equal(ledgerKeys(state).includes('2026-11-01T08:00'), true);
  } finally { f.cleanup(); }
});

// Prune cutoff is now - 30 days. From 2026-11-12T03:00Z that is 2026-10-13T03:00Z (UTC date D = 10-13):
// dates before D-1 go, so 10-11 is the newest date deleted and 10-12 the oldest kept. 10-12 must stay:
// in Pacific/Pago_Pago (UTC-11) the cutoff is local 10-12 16:00, so status still shows that date.
test('1.2.3: boundary: the date two days before the cutoff UTC date goes, the day before stays and inspect still reads it', async () => {
  const { f, call, state, save } = await prepared();
  try {
    const now = at('03:00:00');
    f.services.clock.setWall(now);
    save(seed(seed(state(), '2026-10-11T18:00', { written: now }), '2026-10-12T08:00', { written: now }));
    f.services.clock.setWall(now + 30000);
    assert.equal((await call({ name: 'tick' })).exitCode, 0);
    assert.deepEqual([ledgerKeys(state).includes('2026-10-11T18:00'), ledgerKeys(state).includes('2026-10-12T08:00')], [false, true]);
    const inspected = await call({ name: 'schedule', action: 'inspect', slot: '2026-10-12T08:00' });
    assert.equal(inspected.exitCode, 0);
    assert.equal(inspected.explanation.verdict, 'not_admitted');
  } finally { f.cleanup(); }
});
test('1.2.3: zones: Kiritimati and Pago_Pago rows on the kept boundary date stay, and both go a day later', async () => {
  const { f, call, state, save } = await prepared();
  try {
    const now = at('03:00:00');
    f.services.clock.setWall(now);
    save(seed(seed(state(), '2026-10-12T08:00', { zone: 'Pacific/Kiritimati', written: now }),
      '2026-10-12T13:00', { zone: 'Pacific/Pago_Pago', written: now }));
    f.services.clock.setWall(now + 30000);
    assert.equal((await call({ name: 'tick' })).exitCode, 0);
    assert.deepEqual(['2026-10-12T08:00', '2026-10-12T13:00'].map(slot => ledgerKeys(state).includes(slot)), [true, true]);
    f.services.clock.setWall(now + DAY);
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    assert.deepEqual(['2026-10-12T08:00', '2026-10-12T13:00'].map(slot => ledgerKeys(state).includes(slot)), [false, false]);
  } finally { f.cleanup(); }
});
