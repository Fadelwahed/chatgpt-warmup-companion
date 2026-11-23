import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execute } from '../warmup.mjs';
import { runCommand } from '../runtime.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

// Increment B (engine 1.2): vacations, scheduled accounts, one safe undo and daily caps.
// Asia/Gaza is UTC+2 in November: local 08:00 is 06:00Z.
const at = (date, time) => Date.parse(`${date}T${time}Z`);

async function prepared(start = at('2026-11-12', '02:40:00')) {
  const f = makeFixture({ clock: fakeClock(start) });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_increment_b', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  let sends = 0;
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_0', eligible: true }] }),
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  assert.equal((await call({ name: 'run' })).exitCode, 0);
  assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  const enrollment = (await call({ name: 'status' })).accounts[0].enrollmentId;
  const tickAt = async ms => { f.services.clock.setWall(ms); return call({ name: 'tick' }); };
  const set = (action, extra = {}) => call({ name: 'schedule', action, expectedRevision: state().scheduleRevision ?? 0, ...extra });
  return { f, call, state, enrollment, tickAt, set, sends: () => sends };
}

test('B1 a vacation range suppresses whole future days, inclusive, and can be removed', async () => {
  const { f, call, state, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('exclude', { start: '2026-11-12', end: '2026-11-12' })).reason, 'vacation_not_future');
    assert.equal((await set('exclude', { start: '2026-11-14', end: '2026-11-13' })).reason, 'invalid_vacation');
    assert.equal((await set('exclude', { start: '2026-11-13', end: '2027-11-14' })).reason, 'invalid_vacation');
    const saved = await set('exclude', { start: '2026-11-13', end: '2026-11-14' });
    assert.equal(saved.reason, 'schedule_updated', JSON.stringify(saved));
    assert.deepEqual(state().vacations, [{ start: '2026-11-13', end: '2026-11-14' }]);
    assert.equal((await set('exclude', { start: '2026-11-14', end: '2026-11-16' })).reason, 'vacation_overlap');
    // A stale revision is refused and writes nothing.
    const before = fs.readFileSync(f.statePath, 'utf8');
    assert.equal((await call({ name: 'schedule', action: 'exclude', start: '2026-11-20', end: '2026-11-21', expectedRevision: 0 })).reason, 'schedule_revision_conflict');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    const days = Object.fromEntries((await call({ name: 'schedule', action: 'inspect' })).days.map(d => [d.date, d.exclusion]));
    assert.deepEqual([days['2026-11-12'], days['2026-11-13'], days['2026-11-14'], days['2026-11-15']], [null, 'vacation', 'vacation', null]);
    // Today still runs; both vacation days send nothing; the day after the inclusive end runs.
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'run_complete');
    const sent = sends();
    assert.equal((await tickAt(at('2026-11-13', '06:00:10'))).reason, 'outside_admission_minute');
    assert.equal((await tickAt(at('2026-11-14', '11:00:10'))).reason, 'outside_admission_minute');
    assert.equal(sends(), sent);
    assert.equal((await tickAt(at('2026-11-15', '06:00:10'))).reason, 'run_complete');
    // Ended ranges are dropped on the next change; an unknown range cannot be removed.
    assert.equal((await set('include', { start: '2026-11-20', end: '2026-11-21' })).reason, 'vacation_missing');
    assert.equal((await set('exclude', { start: '2026-11-20', end: '2026-11-21' })).reason, 'schedule_updated');
    assert.deepEqual(state().vacations, [{ start: '2026-11-20', end: '2026-11-21' }]);
    assert.equal((await set('include', { start: '2026-11-20', end: '2026-11-21' })).reason, 'schedule_updated');
    assert.equal(Object.hasOwn(state(), 'vacations'), false);
  } finally { f.cleanup(); }
});

test('B1 removing a vacation in progress takes effect tomorrow; today stays excluded', async () => {
  const { f, call, state, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('exclude', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    // 08:00:30 local: the 08:00 admission minute is under way when the range is removed.
    f.services.clock.setWall(at('2026-11-14', '06:00:30'));
    assert.equal((await set('include', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    assert.deepEqual(state().vacations, [{ start: '2026-11-13', end: '2026-11-14' }], 'past days and today stay');
    const sent = sends();
    assert.equal((await tickAt(at('2026-11-14', '06:00:40'))).reason, 'outside_admission_minute');
    assert.equal((await tickAt(at('2026-11-14', '11:00:10'))).reason, 'outside_admission_minute');
    assert.equal(sends(), sent);
    assert.equal((await call({ name: 'status' })).slotObservation, null, 'an excluded slot is never reported as unobserved');
    // A range ending today (or earlier) cannot be removed; tomorrow runs.
    assert.equal((await set('include', { start: '2026-11-13', end: '2026-11-14' })).reason, 'vacation_not_future');
    assert.equal((await tickAt(at('2026-11-15', '06:00:10'))).reason, 'run_complete');
  } finally { f.cleanup(); }
});

test('B2 an explicit empty selection stops scheduled sends but not manual runs; all restores', async () => {
  const { f, call, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('accounts', { all: false, only: ['enr_unknown'] })).reason, 'unknown_enrollment');
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    assert.deepEqual(state().scheduledAccounts, []);
    assert.deepEqual((await call({ name: 'status' })).scheduledAccounts, []);
    const sent = sends();
    const idle = await tickAt(at('2026-11-12', '06:00:10'));
    assert.deepEqual([idle.outcome, idle.reason], ['idle', 'no_scheduled_accounts']);
    assert.equal(sends(), sent);
    assert.equal((await call({ name: 'schedule', action: 'inspect' })).days[0].configuredAttempts, 0);
    f.services.clock.setWall(at('2026-11-12', '07:00:00'));
    assert.equal((await call({ name: 'run', account: enrollment })).exitCode, 0, 'manual runs reach every enabled account');
    assert.equal(sends(), sent + 1);
    assert.equal((await set('accounts', { all: false, only: [enrollment] })).reason, 'schedule_updated');
    assert.equal((await tickAt(at('2026-11-12', '11:00:10'))).reason, 'run_complete');
    assert.equal((await set('accounts', { all: true })).reason, 'schedule_updated');
    assert.equal(Object.hasOwn(state(), 'scheduledAccounts'), false);
  } finally { f.cleanup(); }
});

test('B3 one safe undo reverses the latest time edit only while it is current and ahead', async () => {
  const { f, call, state, tickAt, set } = await prepared();
  try {
    assert.equal((await set('undo')).reason, 'undo_unavailable');
    const original = (await call({ name: 'status' })).schedule.times;
    assert.equal((await set('add', { time: '22:00', today: false })).reason, 'schedule_updated');
    assert.equal((await call({ name: 'status' })).undoAvailable, true);
    assert.equal((await set('undo')).reason, 'schedule_updated');
    assert.deepEqual((await call({ name: 'status' })).schedule.times, original);
    assert.equal((await set('undo')).reason, 'undo_unavailable', 'one undo only');
    // A today-only move, undone before either minute passes, restores the original admission.
    assert.equal((await set('move', { time: '13:00', target: '14:00', today: true })).reason, 'schedule_updated');
    assert.equal((await set('undo')).reason, 'schedule_updated');
    assert.equal((await tickAt(at('2026-11-12', '11:00:10'))).reason, 'run_complete');
    // Once an affected minute has passed, or the slot was claimed, the undo is refused.
    assert.equal((await set('move', { time: '18:00', target: '19:00', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(at('2026-11-12', '16:30:00'));
    const before = fs.readFileSync(f.statePath, 'utf8');
    assert.equal((await set('undo')).reason, 'schedule_time_elapsed');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before, 'a refused undo writes no state');
    // Any later schedule change replaces the undo record; a new day expires it.
    assert.equal((await set('add', { time: '22:30', today: false })).reason, 'schedule_updated');
    assert.equal((await set('exclude', { start: '2026-11-20', end: '2026-11-20' })).reason, 'schedule_updated');
    assert.equal((await set('undo')).reason, 'undo_unavailable');
    assert.equal((await set('add', { time: '23:00', today: false })).reason, 'schedule_updated');
    f.services.clock.setWall(at('2026-11-13', '05:00:00'));
    assert.equal((await set('undo')).reason, 'undo_expired');
    assert.equal(Object.hasOwn(state(), 'scheduleUndo'), true);
  } finally { f.cleanup(); }
});

test('B4 a daily cap counts the durable reservations written on the local date and resets the next day', async () => {
  const { f, call, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('cap', { account: 'enr_unknown', count: 1 })).reason, 'unknown_enrollment');
    assert.equal((await set('cap', { account: enrollment, count: 49 })).reason, 'invalid_cap');
    assert.equal((await set('cap', { account: enrollment, count: 1 })).reason, 'schedule_updated');
    assert.deepEqual(state().caps, { [enrollment]: 1 });
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'run_complete');
    const sent = sends();
    const capped = await tickAt(at('2026-11-12', '11:00:10'));
    assert.equal(capped.results[0].reason, 'daily_cap_reached');
    assert.equal(sends(), sent);
    assert.equal(state().history.at(-1).reason, 'daily_cap_reached');
    // Manual runs are not capped.
    f.services.clock.setWall(at('2026-11-12', '12:00:00'));
    assert.equal((await call({ name: 'run', account: enrollment })).exitCode, 0);
    assert.equal((await tickAt(at('2026-11-13', '06:00:10'))).reason, 'run_complete');
    assert.equal((await set('cap', { account: enrollment, count: null })).reason, 'schedule_updated');
    assert.equal(Object.hasOwn(state(), 'caps'), false);
  } finally { f.cleanup(); }
});

test('B CLI parses the Increment B settings and nothing looser', async () => {
  for (const argv of [
    ['schedule', 'exclude', '2026-11-13'],
    ['schedule', 'exclude', '2026-11-13', '13-11-2026'],
    ['schedule', 'accounts'],
    ['schedule', 'accounts', 'some'],
    ['schedule', 'accounts', '--only', 'enr;rm'],
    ['schedule', 'undo', 'now'],
    ['schedule', 'cap', 'enr_01', '0'],
    ['schedule', 'cap', 'enr_01', '100'],
    ['schedule', 'cap', 'enr_01'],
    ['schedule', 'accounts', 'all', '--expected-local-date', '2026-11-12'],
  ]) assert.equal((await execute(argv)).json.reason, 'invalid_invocation', argv.join(' '));
  for (const argv of [
    ['schedule', 'exclude', '2026-11-13', '2026-11-14', '--expected-revision', '3', '--expected-local-date', '2026-11-12'],
    ['schedule', 'accounts', '--only'],
    ['schedule', 'accounts', '--only', 'enr_a', 'enr_b'],
    ['schedule', 'undo', '--expected-revision', '4'],
    ['schedule', 'cap', 'enr_01', 'off'],
    ['schedule', 'cap', 'enr_01', '3'],
  ]) assert.equal((await execute(argv)).json.reason, 'invalid_context', argv.join(' '));
});

test('B1 review fix: a recurring edit during a vacation never freezes the vacation into today', async () => {
  const { f, state, tickAt, set } = await prepared();
  try {
    assert.equal((await set('exclude', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    f.services.clock.setWall(at('2026-11-14', '04:00:00'));
    assert.equal((await set('add', { time: '22:00', today: false })).reason, 'schedule_updated');
    assert.equal(state().scheduleEdits.todayExclusion, undefined, 'no vacation value inside the frozen snapshot');
    assert.deepEqual(Object.keys(state().scheduleEdits.admissions), ['08:00', '13:00', '18:00']);
    assert.equal((await set('add', { time: '23:00', today: true })).reason, 'schedule_date_excluded');
    assert.equal((await set('include', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    assert.equal(state().scheduleEdits.todayExclusion, undefined);
    assert.equal((await tickAt(at('2026-11-15', '06:00:10'))).reason, 'run_complete', 'the day after removal runs');
  } finally { f.cleanup(); }
});

test('B1 review fix: a vacation cannot hide a too-close recurring time', async () => {
  const { f, set } = await prepared();
  try {
    assert.equal((await set('exclude', { start: '2026-11-13', end: '2026-11-22' })).reason, 'schedule_updated');
    assert.equal((await set('add', { time: '13:05', today: false })).reason, 'schedule_spacing');
  } finally { f.cleanup(); }
});

test('B2 review fix: status, inspect and the manual guard size the next admission from the scheduled set', async () => {
  const { f, call, set } = await prepared();
  try {
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    const status = await call({ name: 'status' });
    const projection = await call({ name: 'schedule', action: 'inspect' });
    assert.deepEqual(status.next, projection.next);
  } finally { f.cleanup(); }
});

test('B2 review fix: add and remove are applied under the lock to the current enrollment set', async () => {
  const { f, state, enrollment, set } = await prepared();
  try {
    assert.equal((await set('accounts', { all: false, remove: enrollment })).reason, 'schedule_updated');
    assert.deepEqual(state().scheduledAccounts, []);
    assert.equal((await set('accounts', { all: false, add: enrollment })).reason, 'schedule_updated');
    assert.deepEqual(state().scheduledAccounts, [enrollment]);
    assert.equal((await set('accounts', { all: false, add: 'enr_unknown' })).reason, 'unknown_enrollment');
    assert.equal((await execute(['schedule', 'accounts', '--add', 'enr_a', '--expected-revision', '1'])).json.reason, 'invalid_context');
    assert.equal((await execute(['schedule', 'accounts', '--add'])).json.reason, 'invalid_invocation');
  } finally { f.cleanup(); }
});

test('B4 review fix: a reservation the cap cannot classify keeps the capped account from sending', async () => {
  const { f, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('cap', { account: enrollment, count: 1 })).reason, 'schedule_updated');
    const s = state();
    s.reservations['[0]'] = { enrollmentId: enrollment, identity: { accountId: 'workspace', userId: 'user' }, at: 1, possibleSend: true };
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    const sent = sends();
    const out = await tickAt(at('2026-11-12', '06:00:10'));
    assert.equal(out.results[0].reason, 'daily_cap_reached');
    assert.equal(sends(), sent);
  } finally { f.cleanup(); }
});

test('B round 2: a reservation written after midnight counts toward the new day, whatever its slot', async () => {
  const { f, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('cap', { account: enrollment, count: 1 })).reason, 'schedule_updated');
    const s = state();
    // A 23:59 batch on 11 Nov reached this account at 00:00:10 local on 12 Nov (22:00:10Z).
    s.reservations[JSON.stringify(['2026-11-11T23:59', enrollment, 'workspace', 'user'])] = { enrollmentId: enrollment,
      identity: { accountId: 'workspace', userId: 'user' }, at: at('2026-11-11', '22:00:10'), possibleSend: true };
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    const sent = sends();
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).results[0].reason, 'daily_cap_reached');
    assert.equal(sends(), sent);
  } finally { f.cleanup(); }
});

test('B round 2: unclassifiable or mismatched keys never let a capped account or a slot send twice', async () => {
  const { f, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('cap', { account: enrollment, count: 1 })).reason, 'schedule_updated');
    let s = state();
    s.reservations['manual:garbage'] = { enrollmentId: enrollment, identity: { accountId: 'workspace', userId: 'user' }, at: 1, possibleSend: true };
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    let sent = sends();
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).results[0].reason, 'daily_cap_reached', 'a malformed manual key fails closed');
    assert.equal(sends(), sent);
    // Without a cap: a same-slot key whose identity disagrees still marks the slot as reserved.
    assert.equal((await set('cap', { account: enrollment, count: null })).reason, 'schedule_updated');
    s = state();
    delete s.reservations['manual:garbage'];
    s.reservations[JSON.stringify(['2026-11-12T13:00', enrollment, 'other', 'user'])] = { enrollmentId: enrollment,
      identity: { accountId: 'workspace', userId: 'user' }, at: 1, possibleSend: true };
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    sent = sends();
    assert.equal((await tickAt(at('2026-11-12', '11:00:10'))).results[0].reason, 'already_reserved');
    assert.equal(sends(), sent);
  } finally { f.cleanup(); }
});

test('B round 2: an account delta that would exceed the list limit is refused and writes nothing', async () => {
  const { f, state, enrollment, set } = await prepared();
  try {
    const s = state();
    s.scheduledAccounts = Array.from({ length: 1000 }, (_, n) => `aaa_${String(n).padStart(4, '0')}`).sort();
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    const before = fs.readFileSync(f.statePath, 'utf8');
    assert.equal((await set('accounts', { all: false, add: enrollment })).reason, 'invalid_account_selection');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
  } finally { f.cleanup(); }
});

test('B round 2: with no scheduled accounts a manual run near an admission is not refused', async () => {
  const { f, call, set } = await prepared();
  try {
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    f.services.clock.setWall(at('2026-11-12', '05:59:30'));
    const out = await call({ name: 'run' });
    assert.notEqual(out.reason, 'slot_overlap_risk');
    assert.equal(out.exitCode, 0);
  } finally { f.cleanup(); }
});

test('B round 2: undo is refused in a fall-back fold once the first occurrence has passed', async () => {
  // Asia/Gaza falls back at 01:00 local on 24 Oct 2026: 01:00-01:59 runs at 22:00Z and again at 23:00Z.
  const { f, set } = await prepared(at('2026-10-22', '10:00:00'));
  try {
    assert.equal((await set('add', { time: '01:30', today: false })).reason, 'schedule_updated');
    f.services.clock.setWall(at('2026-10-23', '22:10:00'));  // first 01:10
    assert.equal((await set('remove', { time: '01:30', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(at('2026-10-23', '23:10:00'));  // second 01:10, after the first 01:30
    assert.equal((await set('undo')).reason, 'schedule_time_elapsed');
  } finally { f.cleanup(); }
});

test('B round 3: a reservation whose record breaks the writer constraints keeps a capped account from sending', async () => {
  const { f, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('cap', { account: enrollment, count: 1 })).reason, 'schedule_updated');
    const s = state();
    s.reservations[JSON.stringify(['2026-11-11T08:00', enrollment, null, null])] = { enrollmentId: enrollment,
      identity: { accountId: null, userId: null }, at: 1, possibleSend: true };
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    const sent = sends();
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).results[0].reason, 'daily_cap_reached');
    assert.equal(sends(), sent);
  } finally { f.cleanup(); }
});

test('B round 3: shrinking a vacation after sleeping through it never backfills its past days as missed', async () => {
  const { f, state, tickAt, set } = await prepared();
  try {
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'run_complete');
    assert.equal((await set('exclude', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    // The Mac sleeps from 12 Nov 08:00 until 14 Nov 07:00 local; the range is shortened before any tick.
    f.services.clock.setWall(at('2026-11-14', '05:00:00'));
    assert.equal((await set('include', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    await tickAt(at('2026-11-14', '05:30:00'));
    const ledger = state().slotLedger ?? {};
    assert.deepEqual(Object.keys(ledger).filter(slot => slot.startsWith('2026-11-13') || slot.startsWith('2026-11-14')), []);
    assert.equal(ledger['2026-11-12T13:00']?.cause, 'no_tick_between', 'real misses before the vacation are still recorded');
  } finally { f.cleanup(); }
});

test('B round 3: with no scheduled account there is no countdown and slept-through slots are not misses', async () => {
  const { f, call, state, tickAt, set } = await prepared();
  try {
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'run_complete');
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    assert.equal((await call({ name: 'status' })).next, null);
    assert.equal((await call({ name: 'schedule', action: 'inspect' })).next, null);
    // Asleep through 13:00 and 18:00, then the selection is restored before the next tick.
    f.services.clock.setWall(at('2026-11-12', '20:00:00'));
    assert.equal((await set('accounts', { all: true })).reason, 'schedule_updated');
    await tickAt(at('2026-11-12', '20:30:00'));
    const ledger = state().slotLedger;
    assert.deepEqual([ledger['2026-11-12T13:00'].cause, ledger['2026-11-12T18:00'].cause], ['no_scheduled_accounts', 'no_scheduled_accounts']);
    assert.notEqual((await call({ name: 'status' })).next, null);
  } finally { f.cleanup(); }
});

test('B round 3: history rows carry the outcome of the batch that wrote them, so a stopped batch stays visible', async () => {
  const { f, call, tickAt } = await prepared();
  try {
    f.services.reader.readCredential = () => ({ kind: 'blocked', scope: 'global', reason: 'synthetic' });
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).outcome, 'blocked');
    f.services.reader.readCredential = (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} });
    assert.equal((await tickAt(at('2026-11-12', '11:00:10'))).reason, 'run_complete');
    const rows = (await call({ name: 'history' })).rows.filter(row => row.mode === 'scheduled');
    assert.deepEqual(rows.filter(row => row.slot === '2026-11-12T08:00').map(row => row.batchOutcome), ['blocked']);
    assert.deepEqual(rows.filter(row => row.slot === '2026-11-12T13:00').map(row => row.batchOutcome), ['success']);
  } finally { f.cleanup(); }
});

test('B round 4: on-time ticks with no account chosen leave a durable skip per slot, not an empty claim', async () => {
  const { f, call, state, tickAt, set } = await prepared();
  try {
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'no_scheduled_accounts');
    assert.equal((await tickAt(at('2026-11-12', '11:00:10'))).reason, 'no_scheduled_accounts');
    const s = state();
    assert.deepEqual([s.slotLedger['2026-11-12T08:00'].cause, s.slotLedger['2026-11-12T13:00'].cause], ['no_scheduled_accounts', 'no_scheduled_accounts']);
    assert.equal(Object.hasOwn(s.slots, '2026-11-12T08:00'), false);
    // Restoring the selection within the admission minute still lets that slot run.
    assert.equal((await set('accounts', { all: true })).reason, 'schedule_updated');
    assert.equal((await tickAt(at('2026-11-12', '11:00:30'))).reason, 'run_complete');
    assert.equal(state().slotLedger['2026-11-12T13:00'], undefined);
    assert.equal((await call({ name: 'status' })).blockedSlots.length, 0);
  } finally { f.cleanup(); }
});

test('B round 4: a time edit settles elapsed slots under the old schedule before saving', async () => {
  const { f, state, tickAt, set } = await prepared();
  try {
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'run_complete');
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    // Asleep through 13:00 and 18:00; the next morning the recurring times change, then accounts return.
    f.services.clock.setWall(at('2026-11-13', '04:00:00'));
    assert.equal((await set('remove', { time: '13:00', today: false })).reason, 'schedule_updated');
    assert.equal((await set('accounts', { all: true })).reason, 'schedule_updated');
    await tickAt(at('2026-11-13', '05:00:00'));
    const ledger = state().slotLedger;
    assert.deepEqual([ledger['2026-11-12T13:00']?.cause, ledger['2026-11-12T18:00']?.cause], ['no_scheduled_accounts', 'no_scheduled_accounts']);
  } finally { f.cleanup(); }
});

test('B round 4: a zone change before accounts return keeps the old-zone no-account skips', async () => {
  const { f, state, tickAt, set } = await prepared();
  try {
    let zone = 'Asia/Gaza';
    f.services.clock.zone = () => zone;
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).reason, 'no_scheduled_accounts');
    // Asleep through 13:00 Gaza (11:00Z); the Mac moves to UTC+0, then accounts return before any tick.
    zone = 'Europe/London';
    f.services.clock.setWall(at('2026-11-12', '11:30:00'));
    assert.equal((await set('accounts', { all: true })).reason, 'schedule_updated');
    assert.equal(state().slotLedger['2026-11-12T13:00']?.cause, 'no_scheduled_accounts');
  } finally { f.cleanup(); }
});

test('B round 4: status lists a stopped batch even after a later batch replaces the last outcome', async () => {
  const { f, call, tickAt } = await prepared();
  try {
    f.services.reader.readCredential = () => ({ kind: 'blocked', scope: 'global', reason: 'synthetic' });
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).outcome, 'blocked');
    f.services.reader.readCredential = (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} });
    assert.equal((await tickAt(at('2026-11-12', '11:00:10'))).reason, 'run_complete');
    const status = await call({ name: 'status' });
    assert.equal(status.lastSlotOutcome.slot, '2026-11-12T13:00');
    assert.deepEqual(status.blockedSlots.map(row => row.slot), ['2026-11-12T08:00']);
  } finally { f.cleanup(); }
});

test('B round 5: a stopped batch is listed with the time it stopped', async () => {
  const { f, call, state, tickAt } = await prepared();
  try {
    f.services.reader.readCredential = () => { f.services.clock.setWall(f.services.clock.wall() + 400); return { kind: 'blocked', scope: 'global', reason: 'synthetic' }; };
    assert.equal((await tickAt(at('2026-11-12', '06:00:10'))).outcome, 'blocked');
    const claim = state().slots['2026-11-12T08:00'];
    assert.ok(claim.finishedAt > claim.claimedAt);
    assert.equal((await call({ name: 'status' })).blockedSlots[0].at, claim.finishedAt);
  } finally { f.cleanup(); }
});

test('B round 5: clearing the selection after travel keeps the misses made while accounts were chosen', async () => {
  const { f, state, tickAt, set } = await prepared();
  try {
    let zone = 'Europe/London';
    f.services.clock.zone = () => zone;
    assert.equal((await tickAt(at('2026-11-12', '08:00:10'))).reason, 'run_complete');
    // Asleep through London's 13:00 with accounts chosen; the Mac moves to Gaza; the selection is cleared.
    zone = 'Asia/Gaza';
    f.services.clock.setWall(at('2026-11-12', '13:30:00'));
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    await tickAt(at('2026-11-12', '13:31:00'));
    assert.equal(state().slotLedger['2026-11-12T13:00']?.cause, 'no_tick_between');
  } finally { f.cleanup(); }
});

test('B round 5: a vacation edit after travel keeps the vacation the last tick was on', async () => {
  const { f, state, tickAt, set } = await prepared(at('2026-11-11', '10:00:00'));
  try {
    let zone = 'Europe/London';
    f.services.clock.zone = () => zone;
    assert.equal((await set('exclude', { start: '2026-11-12', end: '2026-11-12' })).reason, 'schedule_updated');
    assert.equal((await set('accounts', { all: false, only: [] })).reason, 'schedule_updated');
    await tickAt(at('2026-11-12', '17:30:00'));  // Thursday 17:30 London, on vacation
    zone = 'Asia/Singapore';                     // 18:30Z is already Friday 02:30 there
    f.services.clock.setWall(at('2026-11-12', '18:30:00'));
    assert.equal((await set('exclude', { start: '2026-11-20', end: '2026-11-20' })).reason, 'schedule_updated');
    assert.deepEqual(state().vacations.map(range => range.start), ['2026-11-12', '2026-11-20']);
    await tickAt(at('2026-11-12', '18:31:00'));
    assert.equal(state().slotLedger?.['2026-11-12T18:00'], undefined, 'no slot is invented on the vacation day');
  } finally { f.cleanup(); }
});

test('B round 5: a spacing refusal replaces a provisional no-account row for the same minute', async () => {
  const { f, state, enrollment, tickAt } = await prepared();
  try {
    const s = state();
    s.slots['2026-11-12T12:55'] = { enrollmentIds: [enrollment], claimedAt: at('2026-11-12', '10:55:00'), zone: 'Asia/Gaza', admission: '12:55' };
    s.highWater = '2026-11-12T12:55';
    s.slotLedger = { '2026-11-12T13:00': { admission: '13:00', verdict: 'not_admitted', cause: 'no_scheduled_accounts', zone: 'Asia/Gaza',
      at: at('2026-11-12', '11:00:05'), evidence: { previousTick: at('2026-11-12', '10:59:00'), tick: at('2026-11-12', '11:00:05'), previousZone: 'Asia/Gaza' } } };
    fs.writeFileSync(f.statePath, JSON.stringify(s), { mode: 0o600 });
    assert.equal((await tickAt(at('2026-11-12', '11:00:20'))).reason, 'schedule_spacing');
    assert.equal(state().slotLedger['2026-11-12T13:00'].cause, 'schedule_spacing');
  } finally { f.cleanup(); }
});

test('B round 6: an edit before the first tick after travel never lifts the zone-change hold', async () => {
  const { f, state, enrollment, tickAt, set, sends } = await prepared();
  try {
    let zone = 'Europe/London';
    f.services.clock.zone = () => zone;
    assert.equal((await tickAt(at('2026-11-12', '08:00:10'))).reason, 'run_complete');
    // London's 13:00 is missed; the Mac moves to New York and a cap is edited before any tick there.
    zone = 'America/New_York';
    f.services.clock.setWall(at('2026-11-12', '17:50:00'));
    assert.equal((await set('cap', { account: enrollment, count: 4 })).reason, 'schedule_updated');
    const sent = sends();
    await tickAt(at('2026-11-12', '18:00:05'));  // New York 13:00, first tick in the new zone
    const second = await tickAt(at('2026-11-12', '18:00:35'));
    assert.notEqual(second.reason, 'run_complete');
    assert.equal(sends(), sent, 'nothing is sent in the held minute');
    assert.equal(state().slotLedger['2026-11-12T13:00'].cause, 'zone_changed');
  } finally { f.cleanup(); }
});

test('B round 6: a second edit never replays an interval the first edit already settled', async () => {
  const { f, state, enrollment, tickAt, set } = await prepared();
  try {
    let zone = 'Asia/Tokyo';
    f.services.clock.zone = () => zone;
    assert.equal((await set('exclude', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    await tickAt(at('2026-11-12', '22:00:00'));     // Friday 07:00 Tokyo, a vacation day
    zone = 'America/Los_Angeles';                    // Friday 15:00 Tokyo is still Thursday here
    f.services.clock.setWall(at('2026-11-13', '06:00:00'));
    assert.equal((await set('include', { start: '2026-11-13', end: '2026-11-15' })).reason, 'schedule_updated');
    assert.equal((await set('cap', { account: enrollment, count: 4 })).reason, 'schedule_updated');
    const ledger = state().slotLedger ?? {};
    assert.deepEqual(Object.keys(ledger).filter(slot => slot.startsWith('2026-11-13')), [], 'no false misses on the old vacation day');
  } finally { f.cleanup(); }
});

test('B round 7: an edit during an open admission minute does not erase that slot\'s missed report', async () => {
  const { f, state, enrollment, tickAt, set } = await prepared();
  try {
    await tickAt(at('2026-11-12', '10:58:00'));     // 12:58 local
    f.services.clock.setWall(at('2026-11-12', '11:00:30'));  // 13:00:30, inside the 13:00 minute, no tick yet
    assert.equal((await set('cap', { account: enrollment, count: 4 })).reason, 'schedule_updated');
    await tickAt(at('2026-11-12', '11:02:00'));
    assert.equal(state().slotLedger?.['2026-11-12T13:00']?.cause, 'no_tick_between');
  } finally { f.cleanup(); }
});

test('B round 8: settledAt never moves backward when the clock is set back', async () => {
  const { f, state, enrollment, tickAt, set } = await prepared();
  try {
    await tickAt(at('2026-11-12', '06:30:00'));
    f.services.clock.setWall(at('2026-11-12', '09:00:00'));
    assert.equal((await set('cap', { account: enrollment, count: 4 })).reason, 'schedule_updated');
    const first = state().settledAt;
    f.services.clock.setWall(at('2026-11-12', '08:30:00'));  // set back, still after the last tick
    assert.equal((await set('cap', { account: enrollment, count: 3 })).reason, 'schedule_updated');
    assert.equal(state().settledAt, first);
  } finally { f.cleanup(); }
});
