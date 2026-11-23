import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { EventEmitter } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import { runCommand } from '../runtime.mjs';
import { probe, directRequest } from '../chatgpt-probe.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

// Engine 1.2.1: TLS pinned on, a send-boundary recheck, reasoning items, bounded reservations and claims.
// Asia/Gaza is UTC+2 in November: local 08:00 is 06:00Z.
const at = (date, time) => Date.parse(`${date}T${time}Z`);
const credential = { accessToken: 'SYNTHETIC', identity: { accountId: 'workspace' }, expiresAt: 4102444800000 };
const frames = events => events.map(event => `data: ${JSON.stringify(event)}\n\n`).join('');
const reply = (output, extra = []) => [...extra, { type: 'response.completed', response: { id: 'resp_1', status: 'completed', output } }];
const message = (text = 'WARMUP_OK', id = 'msg_1') => ({ type: 'message', id, role: 'assistant', content: [{ type: 'output_text', text }] });
const reasoning = (id = 'rs_1') => ({ type: 'reasoning', id, summary: [], content: [{ type: 'reasoning_text', text: 'WARMUP_OK' }] });
const ok = events => ({ statusCode: 200, headers: {}, body: [Buffer.from(frames(events))] });
const sendWith = (response, before = () => {}) => {
  const request = async (_options, _body, control) => { before(); control.beforeSend(); control.onDispatch(); request.sends++; return response; };
  request.sends = 0;
  return request;
};

test('1.2.1 fix 1: directRequest pins certificate verification on', async () => {
  const original = https.request;
  let captured;
  try {
    https.request = (options) => {
      captured = options;
      const req = new EventEmitter();
      req.destroy = () => {};
      queueMicrotask(() => req.emit('error', new Error('synthetic_stop')));
      return req;
    };
    await assert.rejects(directRequest({ hostname: 'chatgpt.com', rejectUnauthorized: false }, '', { beforeSend() {}, onDispatch() {} }), /synthetic_stop/);
    assert.equal(captured.rejectUnauthorized, true);
    assert.equal(captured.agent, false);
  } finally { https.request = original; }
});

test('1.2.1 fix 2: probe refuses to send when the final check fails, throws or is asynchronous', async () => {
  for (const [name, finalCheck] of [['false', () => false], ['throws', () => { throw new Error('CANARY_CHECK'); }], ['promise', () => Promise.resolve(true)]]) {
    const request = sendWith(ok(reply([message()])));
    const out = await probe({ credential, finalCheck }, { clock: fakeClock(), request });
    assert.deepEqual([out.outcome, out.reason, out.dispatched, request.sends], ['blocked', 'send_check_failed', false, 0], name);
    assert.equal(JSON.stringify(out).includes('CANARY_CHECK'), false);
  }
  const request = sendWith(ok(reply([message()])));
  assert.equal((await probe({ credential, finalCheck: () => true }, { clock: fakeClock(), request })).reason, 'marker_confirmed');
  assert.equal((await probe({ credential, finalCheck: 'yes' }, { clock: fakeClock(), request })).reason, 'invalid_probe');
});

test('1.2.1 fix 3: a reasoning item before the reply confirms the marker, streamed or terminal', async () => {
  const streamed = [
    { type: 'response.output_item.done', output_index: 0, item: reasoning() },
    { type: 'response.output_item.done', output_index: 1, item: message() },
  ];
  for (const [name, events] of [['streamed', reply([], streamed)], ['terminal', reply([reasoning(), message()])], ['both', reply([reasoning(), message()], streamed)]]) {
    const out = await probe({ credential }, { clock: fakeClock(), request: sendWith(ok(events)) });
    assert.deepEqual([out.outcome, out.reason], ['success', 'marker_confirmed'], name);
  }
});

test('1.2.1 fix 3: reasoning alone never confirms and unknown item types stay rejected', async () => {
  for (const events of [reply([reasoning()]), reply([], [{ type: 'response.output_item.done', output_index: 0, item: reasoning() }])]) {
    const out = await probe({ credential }, { clock: fakeClock(), request: sendWith(ok(events)) });
    assert.notEqual(out.outcome, 'success');
    assert.ok(['output_mismatch', 'protocol_failure'].includes(out.reason), out.reason);
  }
  const call = { type: 'function_call', id: 'fc_1', name: 'x', arguments: '{}' };
  for (const events of [reply([reasoning(), call, message()]), reply([], [{ type: 'response.output_item.done', output_index: 0, item: call }])]) {
    const out = await probe({ credential }, { clock: fakeClock(), request: sendWith(ok(events)) });
    assert.notEqual(out.outcome, 'success');
    assert.equal(out.reason, 'protocol_failure');
  }
});

test('1.2.1 fix 3: firstTextMs comes from the message text delta, not the reasoning item', async () => {
  const clock = fakeClock();
  const timeline = [
    [50, { type: 'response.output_text.delta', item_id: 'rs_1', output_index: 0, content_index: 0, delta: 'WARMUP_OK' }],
    [100, { type: 'response.output_item.done', output_index: 0, item: reasoning() }],
    [300, { type: 'response.output_text.delta', item_id: 'msg_1', output_index: 1, content_index: 0, delta: 'WARMUP_OK' }],
    [400, { type: 'response.output_item.done', output_index: 1, item: message() }],
    [500, reply([reasoning(), message()])[0]],
  ];
  async function* body() {
    let now = 0;
    for (const [ms, event] of timeline) { clock.advance(ms - now); now = ms; yield Buffer.from(frames([event])); }
  }
  const out = await probe({ credential }, { clock, request: sendWith({ statusCode: 200, headers: {}, body: body() }) });
  assert.deepEqual([out.outcome, out.reason, out.firstTextMs], ['success', 'marker_confirmed', 300]);
});

async function prepared(start = at('2026-11-12', '02:40:00')) {
  const f = makeFixture({ clock: fakeClock(start) });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_engine_121', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  let sends = 0;
  const reader = { result: { kind: 'ready' } };
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_0', eligible: true }] }),
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => reader.result,
  };
  f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  assert.equal((await call({ name: 'run' })).exitCode, 0);
  assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  const save = value => fs.writeFileSync(f.statePath, JSON.stringify(value), { mode: 0o600 });
  const enrollment = (await call({ name: 'status' })).accounts[0].enrollmentId;
  const tickAt = async ms => { f.services.clock.setWall(ms); return call({ name: 'tick' }); };
  const set = (action, extra = {}) => call({ name: 'schedule', action, expectedRevision: state().scheduleRevision ?? 0, ...extra });
  return { f, call, state, save, enrollment, tickAt, set, reader, sends: () => sends };
}

// The real probe runs; `during` acts between the pre-probe checks and the send-boundary check.
function realProbe(f, during) {
  delete f.services.probe;
  f.services.request = sendWith(ok(reply([message()])), during);
  return f.services.request;
}

test('1.2.1 fix 2: Router eligibility lost before the send boundary refuses the send and resolves the reservation', async () => {
  for (const scheduled of [false, true]) {
    const { f, call, state, enrollment, tickAt, reader } = await prepared();
    try {
      const request = realProbe(f, () => { reader.result = { kind: 'blocked', reason: 'registry_ineligible' }; });
      const out = scheduled ? await tickAt(at('2026-11-12', '06:00:10')) : await call({ name: 'run' });
      const name = scheduled ? 'scheduled' : 'manual';
      assert.equal(request.sends, 0, name);
      assert.equal(out.attempted, 0, name);
      assert.deepEqual([out.results[0].reason, out.results[0].dispatched], ['send_check_failed', false], name);
      const s = state();
      const reservation = Object.values(s.reservations).find(row => row.reservationId === out.results[0].reservationId);
      assert.equal(reservation.resolved, true, name);
      assert.equal(s.history.at(-1).reason, 'send_check_failed', name);
      assert.equal(s.history.at(-1).enrollmentId, enrollment, name);
    } finally { f.cleanup(); }
  }
});

test('1.2.1 fix 2: a clock jump at the send boundary stops the scheduled batch as batch_deadline_or_clock', async () => {
  const { f, state, tickAt } = await prepared();
  try {
    const request = realProbe(f, () => f.services.clock.setWall(f.services.clock.wall() + 5000));
    const out = await tickAt(at('2026-11-12', '06:00:10'));
    assert.equal(request.sends, 0);
    assert.equal(out.attempted, 0);
    assert.deepEqual([out.results[0].reason, out.results[0].skipped], ['batch_deadline_or_clock', true]);
    const s = state();
    assert.equal(Object.values(s.reservations).find(row => row.reservationId === out.results[0].reservationId).resolved, true);
    assert.equal(s.history.at(-1).reason, 'batch_deadline_or_clock');
  } finally { f.cleanup(); }
});

test('1.2.1 fix 2: a global Router block at the send boundary stops the batch', async () => {
  for (const scheduled of [false, true]) {
    const { f, call, state, tickAt, reader } = await prepared();
    try {
      const request = realProbe(f, () => { reader.result = { kind: 'blocked', scope: 'global', reason: 'registry_ineligible' }; });
      const out = scheduled ? await tickAt(at('2026-11-12', '06:00:10')) : await call({ name: 'run' });
      const name = scheduled ? 'scheduled' : 'manual';
      assert.equal(request.sends, 0, name);
      assert.equal(out.reason, 'reader_global_block', name);
      assert.equal(out.exitCode, 2, name);
      assert.deepEqual([out.results[0].reason, out.results[0].skipped], ['reader_global_block', true], name);
      assert.equal(Object.values(state().reservations).find(row => row.reservationId === out.results[0].reservationId).resolved, true, name);
    } finally { f.cleanup(); }
  }
});

const OLD = at('2026-10-01', '06:00:05');
const reservationKey = (slot, enrollment) => JSON.stringify([slot, enrollment, 'workspace', 'user']);
const row = (enrollment, when, resolved) => ({ enrollmentId: enrollment, identity: { accountId: 'workspace', userId: 'user' }, at: when, possibleSend: true,
  reservationId: `res_${randomUUID()}`, ...(resolved ? { resolved: true } : {}) });

// Old rows that pruning may remove, plus an unresolved one it must keep.
function addOld(s, enrollment, prunable) {
  s.reservations[reservationKey('2026-10-01T13:00', enrollment)] = row(enrollment, OLD + 18000000, false);
  if (!prunable) return { pruned: [], claims: [] };
  s.slots['2026-10-01T08:00'] = { enrollmentIds: [enrollment], claimedAt: OLD, zone: 'Asia/Gaza', admission: '08:00', outcome: 'success', finishedAt: OLD + 1000 };
  s.slots['2026-10-01T13:00'] = { enrollmentIds: [enrollment], claimedAt: OLD + 18000000, zone: 'Asia/Gaza', admission: '13:00', outcome: 'partial', finishedAt: OLD + 18001000 };
  const manual = `manual:${randomUUID()}`;
  s.reservations[reservationKey('2026-10-01T08:00', enrollment)] = row(enrollment, OLD, true);
  s.reservations[manual] = row(enrollment, OLD - 3600000, true);
  return { pruned: [reservationKey('2026-10-01T08:00', enrollment), manual], claims: ['2026-10-01T08:00', '2026-10-01T13:00'] };
}

async function capScenario(prunable) {
  const { f, call, state, save, enrollment, tickAt, set, sends } = await prepared();
  try {
    assert.equal((await set('cap', { account: enrollment, count: 1 })).reason, 'schedule_updated');
    const reasons = [(await tickAt(at('2026-11-12', '06:00:10'))).results[0].reason];
    const s = state();
    const old = addOld(s, enrollment, prunable);
    save(s);
    reasons.push((await tickAt(at('2026-11-12', '11:00:10'))).results[0].reason);
    const after = state();
    for (const key of old.pruned) assert.equal(Object.hasOwn(after.reservations, key), false, key);
    for (const slot of old.claims) assert.equal(Object.hasOwn(after.slots, slot), false, slot);
    assert.equal(Object.hasOwn(after.reservations, reservationKey('2026-10-01T13:00', enrollment)), true, 'unresolved survives');
    assert.equal(after.highWater, '2026-11-12T13:00');
    assert.ok(after.slots['2026-11-12T08:00'] && after.slots['2026-11-12T13:00']);
    // Without a cap, a resolved reservation for the next slot still blocks it as already reserved.
    assert.equal((await set('cap', { account: enrollment, count: null })).reason, 'schedule_updated');
    const next = state();
    next.reservations[reservationKey('2026-11-13T08:00', enrollment)] = row(enrollment, at('2026-11-12', '12:00:00'), true);
    save(next);
    reasons.push((await tickAt(at('2026-11-13', '06:00:10'))).results[0].reason);
    assert.equal((await call({ name: 'status' })).exitCode, 0, 'pruned state still loads and validates');
    return { reasons, sends: sends() };
  } finally { f.cleanup(); }
}

test('1.2.1 fix 4: pruning old resolved reservations and claims leaves caps and already_reserved unchanged', async () => {
  const pruned = await capScenario(true);
  assert.deepEqual(pruned.reasons, ['marker_confirmed', 'daily_cap_reached', 'already_reserved']);
  assert.deepEqual(pruned, await capScenario(false));
});

test('1.2.1 fix 4: highWater, active batch and last outcome claims survive pruning, as do unclassifiable keys', async () => {
  const { f, call, state, save, enrollment } = await prepared();
  try {
    const s = state();
    const claim = (slot, claimedAt) => { s.slots[slot] = { enrollmentIds: [enrollment], claimedAt, zone: 'Asia/Gaza', admission: slot.slice(11) }; };
    claim('2026-10-01T08:00', OLD);
    claim('2026-10-02T08:00', OLD + 86400000);
    claim('2026-10-02T13:00', OLD + 86400000 + 18000000);
    claim('2026-10-03T08:00', OLD + 2 * 86400000);
    s.highWater = '2026-10-03T08:00';
    s.lastSlotOutcome = { slot: '2026-10-02T08:00', zone: 'Asia/Gaza', outcome: 'success', at: OLD + 86400000 + 1000, results: [] };
    s.activeBatch = { slot: '2026-10-02T13:00', enrollmentIds: [enrollment], zone: 'Asia/Gaza' };
    const garbage = 'manual:garbage';
    s.reservations[garbage] = row(enrollment, OLD, true);
    s.reservations[reservationKey('2026-10-01T08:00', enrollment)] = row(enrollment, OLD, true);
    s.reservations[reservationKey('2026-10-03T08:00', enrollment)] = row(enrollment, OLD + 2 * 86400000, true);
    save(s);
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    const after = state();
    assert.deepEqual(Object.keys(after.slots).sort(), ['2026-10-02T08:00', '2026-10-02T13:00', '2026-10-03T08:00']);
    assert.equal(Object.hasOwn(after.reservations, reservationKey('2026-10-01T08:00', enrollment)), false);
    assert.equal(Object.hasOwn(after.reservations, reservationKey('2026-10-03T08:00', enrollment)), true, 'the highWater slot keeps its reservation');
    assert.equal(Object.hasOwn(after.reservations, garbage), true, 'a key the cap cannot classify is never pruned');
    assert.equal((await call({ name: 'status' })).exitCode, 0, 'pruned state still loads and validates');
  } finally { f.cleanup(); }
});

test('1.2.1 review: the deadline is checked again after a final check that uses the budget', async () => {
  const clock = fakeClock();
  const request = sendWith(ok(reply([message()])));
  const out = await probe({ credential, finalCheck: () => { clock.advance(46000); return true; } }, { clock, request });
  assert.deepEqual([out.outcome, out.dispatched, request.sends], ['blocked', false, 0]);
  assert.ok(['deadline_before_send', 'deadline_exceeded'].includes(out.reason), out.reason);
});

test('1.2.1 review: a rejected asynchronous final check is refused and never left unhandled', async () => {
  const unhandled = [];
  const listener = reason => unhandled.push(reason);
  process.on('unhandledRejection', listener);
  try {
    const request = sendWith(ok(reply([message()])));
    const out = await probe({ credential, finalCheck: () => Promise.reject(new Error('CANARY_REJECT')) }, { clock: fakeClock(), request });
    assert.deepEqual([out.outcome, out.reason, out.dispatched, request.sends], ['blocked', 'send_check_failed', false, 0]);
    await new Promise(resolve => setImmediate(resolve));
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(unhandled, []);
  } finally { process.off('unhandledRejection', listener); }
});

test('1.2.1 review: a forward clock jump before any tick sees it does not prune today\'s reservations', async () => {
  const { f, call, state, save, enrollment } = await prepared();
  try {
    const s = state();
    const now = f.services.clock.wall();
    s.lastWall = now;
    // Today's 08:00 batch ran and 13:00 is the latest claim, so only the jumped clock could make 08:00 look old.
    s.slots['2026-11-12T08:00'] = { enrollmentIds: [enrollment], claimedAt: now - 60000, zone: 'Asia/Gaza', admission: '08:00', outcome: 'success', finishedAt: now - 59000 };
    s.slots['2026-11-12T13:00'] = { enrollmentIds: [enrollment], claimedAt: now - 30000, zone: 'Asia/Gaza', admission: '13:00', outcome: 'success', finishedAt: now - 29000 };
    s.highWater = '2026-11-12T13:00';
    const today = reservationKey('2026-11-12T08:00', enrollment);
    s.reservations[today] = row(enrollment, now - 60000, true);
    save(s);
    f.services.clock.setWall(now + 40 * 86400000);
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    const after = state();
    assert.equal(Object.hasOwn(after.reservations, today), true, 'pruning used the last tick time, not the jumped clock');
    assert.ok(after.slots['2026-11-12T08:00'], 'today\'s claim survives too');
  } finally { f.cleanup(); }
});

test('1.2.1 review: a terminal reasoning item without an ID is rejected like a streamed one', async () => {
  const { id: _id, ...noId } = reasoning();
  const request = sendWith(ok(reply([noId, message()])));
  const out = await probe({ credential }, { clock: fakeClock(), request });
  assert.notEqual(out.reason, 'marker_confirmed');
  assert.equal(out.reason, 'protocol_failure');
});

test('1.2.1 review: resolved manual reservations age out on the wall clock while the schedule is paused', async () => {
  const { f, call, state, save, enrollment } = await prepared();
  try {
    const s = state();
    const now = f.services.clock.wall();
    s.lastWall = now - 40 * 86400000;  // the last tick was long ago; scheduling has been paused since
    const stale = `manual:${randomUUID()}`, recent = `manual:${randomUUID()}`, open = `manual:${randomUUID()}`;
    s.reservations[stale] = row(enrollment, now - 31 * 86400000, true);
    s.reservations[recent] = row(enrollment, now - 29 * 86400000, true);
    s.reservations[open] = row(enrollment, now - 31 * 86400000, false);
    save(s);
    assert.equal((await call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    const after = state();
    assert.equal(Object.hasOwn(after.reservations, stale), false, 'resolved and older than 30 days');
    assert.equal(Object.hasOwn(after.reservations, recent), true, 'younger than 30 days');
    assert.equal(Object.hasOwn(after.reservations, open), true, 'unresolved is never pruned');
  } finally { f.cleanup(); }
});

test('1.2.1 review: streamed and terminal copies of an item may list their keys in a different order', async () => {
  const streamed = reasoning();
  const reordered = Object.fromEntries(Object.entries(streamed).reverse());
  const events = [{ type: 'response.output_item.done', output_index: 0, item: streamed }, { type: 'response.output_item.done', output_index: 1, item: message() }];
  const request = sendWith(ok(reply([reordered, message()], events)));
  assert.equal((await probe({ credential }, { clock: fakeClock(), request })).reason, 'marker_confirmed');
  const changed = { ...reordered, summary: [{ type: 'summary_text', text: 'different' }] };
  const conflict = sendWith(ok(reply([changed, message()], events)));
  assert.notEqual((await probe({ credential }, { clock: fakeClock(), request: conflict })).reason, 'marker_confirmed');
});

test('1.2.1 review: an idle tick on a jumped clock does not let pruning drop today\'s reservations', async () => {
  const { f, call, state, save, enrollment, tickAt } = await prepared();
  try {
    const s = state();
    const now = f.services.clock.wall();
    s.slots['2026-11-12T08:00'] = { enrollmentIds: [enrollment], claimedAt: now - 60000, zone: 'Asia/Gaza', admission: '08:00', outcome: 'success', finishedAt: now - 59000 };
    s.slots['2026-11-12T13:00'] = { enrollmentIds: [enrollment], claimedAt: now - 30000, zone: 'Asia/Gaza', admission: '13:00', outcome: 'success', finishedAt: now - 29000 };
    s.highWater = '2026-11-12T13:00';
    const today = reservationKey('2026-11-12T08:00', enrollment);
    s.reservations[today] = row(enrollment, now - 60000, true);
    save(s);
    await tickAt(now + 40 * 86400000 + 2 * 3600000);  // idle minute on the jumped clock; it raises lastWall
    assert.ok(state().lastWall > now + 30 * 86400000, 'the tick recorded the jumped time');
    await call({ name: 'schedule', action: 'disable' });
    const after = state();
    assert.equal(Object.hasOwn(after.reservations, today), true, 'today\'s reservation survives');
    assert.ok(after.slots['2026-11-12T08:00'], 'today\'s claim survives');
  } finally { f.cleanup(); }
});
