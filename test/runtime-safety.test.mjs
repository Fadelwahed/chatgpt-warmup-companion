import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand } from '../runtime.mjs';
import { makeFixture, requestStub } from './helpers.mjs';

async function prepared(count = 2) {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_safety_01', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash('sha256').update(String(n)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' });
  const identity = id => ({ accountId: `workspace-${id}`, userId: `user-${id}` });
  let reads = 0, sends = 0;
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: Array.from({ length: count }, (_, n) => ({ routerAccountId: `router_${n}`, eligible: true })) }),
    discoverIdentity: (_ctx, id) => ({ kind: 'ready', identity: identity(id) }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => { reads++; return { kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }; },
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  const writeState = value => put(f.statePath, value);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  return { ...f, call, state, writeState, reads: () => reads, sends: () => sends,
    async qualify() { assert.equal((await call({ name: 'run' })).exitCode, 0); assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0); },
  };
}

test('D04 disabled/outside/already-claimed ticks are credential-free; busy leaves state untouched', async () => {
  const f = await prepared(1);
  try {
    const before = f.state();
    assert.equal((await f.call({ name: 'tick' })).reason, 'schedule_disabled');
    const after = f.state(); assert.equal(after.lastTick, f.services.clock.wall());
    for (const key of ['slots', 'pilots', 'reservations', 'history']) assert.deepEqual(after[key], before[key]);
    assert.equal(f.reads(), 0); assert.equal(f.sends(), 0);
    await f.qualify();
    f.services.clock.advance(61000);
    const reads = f.reads();
    assert.equal((await f.call({ name: 'tick' })).reason, 'outside_admission_minute');
    assert.equal(f.reads(), reads);
    const state = fs.readFileSync(f.statePath, 'utf8');
    fs.mkdirSync(path.join(f.companionRoot, 'work.lock'), { mode: 0o700 });
    assert.equal((await f.call({ name: 'tick' })).exitCode, 3);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), state);
  } finally { f.cleanup(); }
});

test('D05 validation crossing the admission minute never claims a catch-up batch', async () => {
  const f = await prepared(1);
  try {
    await f.qualify(); f.services.clock.advance(59900);
    f.services.reader.checkCompatibility = () => { f.services.clock.advance(200); return { kind: 'ready' }; };
    const sends = f.sends();
    assert.equal((await f.call({ name: 'tick' })).reason, 'outside_admission_minute');
    assert.equal(f.sends(), sends); assert.deepEqual(f.state().slots, {});
  } finally { f.cleanup(); }
});

test('D06 final validation/reservation budget expiry prevents late sends and never replays the claim', async () => {
  for (const duringReservation of [false, true]) {
    const f = await prepared(1);
    try {
      await f.qualify(); const sends = f.sends();
      if (!duringReservation) f.services.reader.readCredential = () => {
        f.services.clock.advance(75000); return { kind: 'ready', identity: { accountId: 'w', userId: 'u' }, snapshot: {}, accessToken: 'synthetic', expiresAt: 4102444800000 };
      };
      else f.services.fault = point => {
        if (point === 'after_state.json_rename' && Object.keys(f.state().reservations).some(k => !k.startsWith('manual:'))) f.services.clock.advance(75000);
      };
      const out = await f.call({ name: 'tick' });
      assert.equal(out.attempted, 0); assert.equal(f.sends(), sends);
      assert.ok(Object.keys(f.state().slots).length === 1);
      delete f.services.fault;
      await f.call({ name: 'tick' }); assert.equal(f.sends(), sends);
    } finally { f.cleanup(); }
  }
});

test('D06 one-second remaining budget is passed as the original monotonic deadline', async () => {
  const f = await prepared(1);
  try {
    await f.qualify();
    f.services.reader.readCredential = (_ctx, e) => {
      f.services.clock.advance(74000); return { kind: 'ready', identity: e.identity, snapshot: {}, accessToken: 'synthetic', expiresAt: 4102444800000 };
    };
    let calls = 0;
    f.services.probe = async options => {
      calls++; assert.equal(options.batchDeadline - f.services.clock.mono(), 1000);
      f.services.clock.advance(1000);
      return { outcome: 'uncertain', reason: 'deadline_exceeded', dispatched: true };
    };
    const out = await f.call({ name: 'tick' });
    assert.equal(calls, 1); assert.equal(out.attempted, 1); assert.equal(out.results[0].outcome, 'uncertain');
    assert.equal(f.state().activeBatch, null);
  } finally { f.cleanup(); }
});

test('D06 scheduled transport uncertainty preserves the reservation and checks the next account once', async () => {
  const f = await prepared(2);
  try {
    await f.qualify();
    const reads = [], sends = [];
    const originalRead = f.services.reader.readCredential;
    f.services.reader.readCredential = (ctx, enrollment) => {
      reads.push(enrollment.identity.accountId);
      return originalRead(ctx, enrollment);
    };
    f.services.probe = async ({ credential }) => {
      const account = credential.identity.accountId;
      sends.push(account);
      if (account === 'workspace-router_0') {
        return { outcome: 'uncertain', reason: 'stream_or_transport_uncertain', dispatched: true };
      }
      assert.equal(f.state().history.at(-1).reason, 'stream_or_transport_uncertain');
      return { outcome: 'success', reason: 'marker_confirmed', dispatched: true };
    };
    const out = await f.call({ name: 'tick' });
    assert.deepEqual([out.exitCode, out.outcome, out.selected, out.attempted], [1, 'partial', 2, 2]);
    assert.deepEqual(out.results.map(entry => entry.reason), ['stream_or_transport_uncertain', 'marker_confirmed']);
    assert.deepEqual(reads, ['workspace-router_0', 'workspace-router_1']);
    assert.deepEqual(sends, reads);
    const reservations = Object.entries(f.state().reservations).filter(([key]) => !key.startsWith('manual:'));
    assert.deepEqual(reservations.map(([, entry]) => [entry.enrollmentId, entry.possibleSend]),
      out.results.map(entry => [entry.enrollmentId, true]));
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.deepEqual(sends, ['workspace-router_0', 'workspace-router_1']);
  } finally { f.cleanup(); }
});

test('D06 a scheduled probe deadline stops the batch before or after dispatch', async () => {
  for (const [reason, dispatched] of [
    ['deadline_exceeded', true],
    ['deadline_exceeded', false],
    ['deadline_before_send', false],
  ]) {
    const f = await prepared(2);
    try {
      await f.qualify();
      let calls = 0;
      f.services.probe = async () => {
        calls++;
        f.services.clock.advance(45000);
        return { outcome: dispatched ? 'uncertain' : 'blocked', reason, dispatched };
      };
      const out = await f.call({ name: 'tick' });
      assert.deepEqual(out.results.map(entry => entry.reason), [reason, 'batch_unprocessed']);
      assert.equal(calls, 1);
      assert.equal(out.attempted, Number(dispatched));
    } finally { f.cleanup(); }
  }
});

test('D08 a global reader block after the first send preserves its result and stops the batch', async () => {
  const f = await prepared(2);
  try {
    await f.qualify();
    const initialSends = f.sends();
    const originalRead = f.services.reader.readCredential;
    f.services.reader.readCredential = (ctx, enrollment) => enrollment.identity.accountId === 'workspace-router_1'
      ? { kind: 'blocked', scope: 'global', reason: 'switch_busy' }
      : originalRead(ctx, enrollment);
    const out = await f.call({ name: 'tick' });
    assert.deepEqual([out.exitCode, out.selected, out.attempted], [2, 2, 1]);
    assert.deepEqual(out.results.map(entry => entry.reason), ['marker_confirmed', 'batch_unprocessed']);
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(f.sends() - initialSends, 1);
  } finally { f.cleanup(); }
});

test('D07 rollback and conservative skip-through remain blocked without guessing a missed-slot cause', async () => {
  const f = await prepared(1);
  try {
    await f.qualify();
    const state = f.state(); state.skipThrough = '2026-11-12T08:00'; f.writeState(state);
    assert.equal((await f.call({ name: 'tick' })).reason, 'recovery_skip_through');
    assert.deepEqual(f.state().slots, {});
    f.services.clock.setWall(f.services.clock.wall() - 2000);
    assert.equal((await f.call({ name: 'tick' })).reason, 'clock_moved_backward');
  } finally { f.cleanup(); }
});

test('D09 thirty-day history pruning retains full reservation/high-water safety data', async () => {
  const f = await prepared(1);
  try {
    await f.qualify(); const state = f.state();
    state.history.push({ enrollmentId: 'old', outcome: 'uncertain', reason: 'unknown', at: f.services.clock.wall() - 31 * 86400000 });
    state.reservations.safety = structuredClone(Object.values(state.reservations)[0]); state.highWater = '2026-11-11T18:00';
    f.writeState(state); assert.equal((await f.call({ name: 'tick' })).exitCode, 0);
    const fresh = f.state();
    assert.equal(fresh.history.some(e => e.enrollmentId === 'old'), false);
    assert.deepEqual(fresh.reservations.safety, state.reservations.safety); assert.ok(fresh.highWater >= state.highWater);
  } finally { f.cleanup(); }
});

test('D10 manual and scheduled outcome policy agree for correction versus transient uncertainty', async () => {
  for (const reason of ['authentication_rejected', 'forbidden_or_challenged', 'unsupported_model', 'protocol_failure', 'output_mismatch', 'rate_limited', 'stream_or_transport_uncertain']) {
    const observations = [];
    for (const scheduled of [false, true]) {
      const f = await prepared(1);
      try {
        await f.qualify();
        f.services.probe = async () => ({ outcome: 'uncertain', reason, dispatched: true });
        const out = await f.call({ name: scheduled ? 'tick' : 'run', allowSlotOverlap: !scheduled }); assert.equal(out.exitCode, 1);
        const s = f.state();
        observations.push({ pilot: Object.keys(s.pilots).length, block: Object.values(s.blocks)[0] ?? null });
      } finally { f.cleanup(); }
    }
    assert.deepEqual(observations[0], observations[1], reason);
    const corrective = ['authentication_rejected', 'forbidden_or_challenged', 'unsupported_model', 'protocol_failure', 'output_mismatch'].includes(reason);
    assert.equal(observations[0].block, corrective ? reason : null, reason);
    assert.equal(observations[0].pilot, ['unsupported_model', 'protocol_failure', 'output_mismatch'].includes(reason) ? 0 : 1, reason);
  }
});

for (const scheduled of [false, true]) test(`C08 ${scheduled ? 'scheduled' : 'manual'} rate limit persists through normal slots without retry or catch-up`, async () => {
  const f = await prepared(1);
  try {
    await f.qualify();
    const initial = f.services.clock.wall();
    const notBefore = initial + 172800000;
    let sends = 0;
    f.services.probe = async () => {
      sends++;
      return sends === 1
        ? { outcome: 'blocked', reason: 'rate_limited', dispatched: true, notBefore }
        : { outcome: 'success', reason: 'marker_confirmed', dispatched: true };
    };
    const first = await f.call({ name: scheduled ? 'tick' : 'run', allowSlotOverlap: !scheduled });
    assert.equal(first.results[0].reason, 'rate_limited');
    assert.equal(sends, 1);
    const enrollmentId = first.results[0].enrollmentId;
    assert.equal(f.state().cooldowns[enrollmentId], notBefore);
    assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).results[0].reason, 'cooldown');
    assert.equal(sends, 1);
    const sameSlot = await f.call({ name: 'tick' });
    assert.equal(scheduled ? sameSlot.reason : sameSlot.results[0].reason, scheduled ? 'slot_already_claimed' : 'cooldown');
    assert.equal(sends, 1);
    for (const hours of [5, 5, 14, 5, 5]) {
      f.services.clock.advance(hours * 3600000);
      const out = await f.call({ name: 'tick' });
      assert.equal(out.results[0].reason, 'cooldown');
      assert.equal(out.attempted, 0);
      assert.equal(sends, 1);
      assert.equal(f.state().cooldowns[enrollmentId], notBefore);
    }
    f.services.clock.advance(14 * 3600000);
    assert.equal(f.services.clock.wall(), notBefore);
    const afterExpiry = await f.call({ name: 'tick' });
    assert.equal(afterExpiry.results[0].reason, 'marker_confirmed');
    assert.equal(afterExpiry.attempted, 1);
    assert.equal(sends, 2);
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(sends, 2);
  } finally { f.cleanup(); }
});

test('C08 overflow cooldown sentinel persists and excludes manual and scheduled admission', async () => {
  const f = await prepared(1);
  try {
    await f.qualify();
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'blocked', reason: 'rate_limited', dispatched: true, notBefore: Number.MAX_VALUE }; };
    const first = await f.call({ name: 'run', allowSlotOverlap: true });
    assert.equal(first.results[0].reason, 'rate_limited');
    assert.equal(f.state().cooldowns[first.results[0].enrollmentId], Number.MAX_VALUE);
    assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).results[0].reason, 'cooldown');
    assert.equal((await f.call({ name: 'tick' })).results[0].reason, 'cooldown');
    f.services.clock.advance(5 * 3600000);
    const later = await f.call({ name: 'tick' });
    assert.equal(later.results[0].reason, 'cooldown');
    assert.equal(later.attempted, 0);
    assert.equal(sends, 1);
  } finally { f.cleanup(); }
});

test('E03 same-schema semantic change needs a new contract and invalidates pilots; reviewed equivalent keeps them', async () => {
  const f = await prepared(1);
  try {
    await f.qualify(); assert.equal((await f.call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    const candidatePath = path.join(f.root, 'candidate.json');
    const candidate = { schemaVersion: 1, config: JSON.parse(fs.readFileSync(f.configPath)),
      compatibility: JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'))), reviewEvidence: 'semantic-review-2' };
    candidate.compatibility.semantics = 'changed'; candidate.compatibility.reviewEvidence = candidate.reviewEvidence;
    const write = () => fs.writeFileSync(candidatePath, JSON.stringify(candidate), { mode: 0o600 });
    write();
    assert.equal((await f.call({ name: 'maintain', file: candidatePath })).reason, 'contract_version_required');
    assert.equal(Object.keys(f.state().pilots).length, 1);
    candidate.compatibility.adapterVersion = 2; write();
    assert.equal((await f.call({ name: 'maintain', file: candidatePath })).exitCode, 0);
    assert.deepEqual(f.state().pilots, {});
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).reason, 'pilot_required');
    assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).exitCode, 0);
    const freshPilots = f.state().pilots;
    candidate.compatibility.reviewedRevision = 'b'.repeat(40);
    candidate.compatibility.semantics = 'equivalent';
    candidate.reviewEvidence = 'equivalent-review-3'; candidate.compatibility.reviewEvidence = candidate.reviewEvidence; write();
    assert.equal((await f.call({ name: 'maintain', file: candidatePath })).exitCode, 0);
    assert.deepEqual(f.state().pilots, freshPilots);
  } finally { f.cleanup(); }
});

test('D09 a replacement enrollment for the same full identity cannot repeat a claimed slot', async () => {
  const f = await prepared(1);
  try {
    await f.qualify(); assert.equal((await f.call({ name: 'tick' })).exitCode, 0);
    const sends = f.sends(), old = f.state();
    assert.equal((await f.call({ name: 'schedule', action: 'disable' })).exitCode, 0);
    // Model an explicit reviewed identity-recovery decision, preserving all safety records.
    const config = JSON.parse(fs.readFileSync(f.configPath));
    config.enrollments[0].enrollmentId = 'enr_reviewed_replacement';
    const bytes = JSON.stringify(config); fs.writeFileSync(f.configPath, bytes, { mode: 0o600 });
    const state = f.state(); state.configDigest = createHash('sha256').update(bytes).digest('hex'); state.pilots = {}; f.writeState(state);
    assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).exitCode, 0);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(f.sends(), sends + 1); // Only the new deliberate manual pilot sent.
    for (const [key, value] of Object.entries(old.reservations)) assert.deepEqual(f.state().reservations[key], value);
    assert.equal(f.state().highWater, old.highWater);
  } finally { f.cleanup(); }
});

test('B15/D10 invalidation matches the enrollment tuple position, not another enrollment identity string', async () => {
  const f = await prepared(2);
  try {
    const config = JSON.parse(fs.readFileSync(f.configPath)), firstId = config.enrollments[0].enrollmentId, secondId = config.enrollments[1].enrollmentId;
    config.enrollments[1].identity.accountId = firstId;
    const bytes = JSON.stringify(config); fs.writeFileSync(f.configPath, bytes, { mode: 0o600 });
    const state = f.state(); state.configDigest = createHash('sha256').update(bytes).digest('hex'); f.writeState(state);
    assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).exitCode, 0);
    const hasSecond = () => Object.keys(f.state().pilots).some(key => JSON.parse(key)[0] === secondId);
    assert.equal(hasSecond(), true);
    config.enrollments[0].model = 'gpt-6-sol';
    const candidate = path.join(f.root, 'candidate.json');
    fs.writeFileSync(candidate, JSON.stringify({ schemaVersion: 1, config, compatibility: JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'))), reviewEvidence: 'synthetic' }), { mode: 0o600 });
    assert.equal((await f.call({ name: 'maintain', file: candidate })).exitCode, 0);
    assert.equal(hasSecond(), true);
    assert.equal((await f.call({ name: 'run', account: firstId })).exitCode, 0);
    f.services.probe = async () => ({ outcome: 'blocked', reason: 'unsupported_model', dispatched: true });
    assert.equal((await f.call({ name: 'run', account: firstId })).exitCode, 1);
    assert.equal(hasSecond(), true);
    assert.equal(Object.keys(f.state().pilots).some(key => JSON.parse(key)[0] === firstId), false);
  } finally { f.cleanup(); }
});


test('C02 actual probe model failures invalidate pilots identically for manual and scheduled dispatch', async () => {
  for (const scheduled of [false, true]) {
    for (const envelope of ['http', 'error', 'response.failed']) {
      const f = await prepared(1);
      try {
        await f.qualify();
        delete f.services.probe;
        const event = envelope === 'error' ? { type: 'error', error: { code: 'model_not_found', message: 'CANARY_BODY' } }
          : { type: 'response.failed', response: { error: { code: 'model_not_found', message: 'CANARY_BODY' } } };
        const text = envelope === 'http' ? JSON.stringify({ error: { code: 'model_not_found', message: 'CANARY_BODY' } })
          : `data: ${JSON.stringify(event)}\n\n`;
        f.services.request = requestStub({ statusCode: envelope === 'http' ? 400 : 200, headers: {}, body: [Buffer.from(text)] });
        const out = await f.call({ name: scheduled ? 'tick' : 'run', allowSlotOverlap: !scheduled });
        assert.equal(out.exitCode, 1); assert.equal(out.attempted, 1);
        assert.equal(out.results[0].reason, 'unsupported_model');
        assert.equal(Object.keys(f.state().pilots).length, 0);
        assert.equal(f.state().blocks[out.results[0].enrollmentId], 'unsupported_model');
        assert.equal(JSON.stringify([out, f.state()]).includes('CANARY'), false);
        assert.equal(f.services.request.calls.length, 1);
        f.services.clock.advance(5 * 3600000);
        const later = await f.call({ name: 'tick' });
        assert.equal(later.attempted, 0); assert.equal(f.services.request.calls.length, 1);
        const item = { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'WARMUP_OK' }] };
        const completed = { type: 'response.completed', response: { status: 'completed', output: [item] } };
        f.services.request = requestStub({ statusCode: 200, headers: {}, body: [Buffer.from(`data: ${JSON.stringify(completed)}\n\n`)] });
        assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).exitCode, 0);
        assert.equal(f.services.request.calls.length, 1);
        assert.equal(Object.keys(f.state().pilots).length, 1);
        assert.deepEqual(f.state().blocks, {});
      } finally { f.cleanup(); }
    }
  }
});


test('C02/C08 actual HTTP body failure cannot bypass a validated cooldown through manual requalification', async () => {
  for (const scheduled of [false, true]) {
    const f = await prepared(1);
    try {
      await f.qualify(); delete f.services.probe;
      const notBefore = f.services.clock.wall() + 172800000;
      f.services.request = requestStub({ statusCode: 403, headers: { 'retry-after': '172800' }, body: [Buffer.from([255])] });
      const first = await f.call({ name: scheduled ? 'tick' : 'run', allowSlotOverlap: !scheduled });
      assert.equal(first.attempted, 1); assert.equal(first.results[0].reason, 'protocol_failure');
      assert.equal(f.state().cooldowns[first.results[0].enrollmentId], notBefore);
      assert.equal(Object.keys(f.state().pilots).length, 0);
      assert.equal((await f.call({ name: 'run', allowSlotOverlap: true })).results[0].reason, 'cooldown');
      f.services.clock.advance(5 * 3600000);
      const later = await f.call({ name: 'tick' });
      assert.equal(later.attempted, 0); assert.equal(f.services.request.calls.length, 1);
      assert.equal(f.state().cooldowns[first.results[0].enrollmentId], notBefore);
    } finally { f.cleanup(); }
  }
});
