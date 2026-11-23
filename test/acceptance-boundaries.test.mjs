import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { runCommand } from '../runtime.mjs';
import { execute } from '../warmup.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

async function fixture(count = 1, clock) {
  const f = makeFixture(clock ? { clock } : {});
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  fs.writeFileSync(f.markerPath, JSON.stringify({ schemaVersion: 1, installationId: 'install_acceptance_01', phase: 'uninitialized', paths, plistPath: f.plistPath }), { mode: 0o600 });
  fs.writeFileSync(path.join(f.companionRoot, 'compatibility.json'), JSON.stringify({ schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, i) => [`src/f-${i}.mjs`, createHash('sha256').update(String(i)).digest('hex')])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic', semantics: 'equivalent' }), { mode: 0o600 });
  const identities = Array.from({ length: count }, (_, i) => ({ accountId: `workspace-${i}`, userId: `user-${i}` }));
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: identities.map((_, i) => ({ routerAccountId: `router_${i}`, eligible: true })) }),
    discoverIdentity: (_ctx, id) => ({ kind: 'ready', identity: identities[Number(id.split('_')[1])] }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  return { ...f, call, state: () => JSON.parse(fs.readFileSync(f.statePath)) };
}

test('B11 replacement after credential read cannot dispatch or attach to a new instance', async () => {
  const f = await fixture();
  const displaced = `${f.companionRoot}-old`;
  try {
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    const original = f.services.reader.readCredential;
    f.services.reader.readCredential = (...args) => {
      const credential = original(...args);
      fs.renameSync(f.companionRoot, displaced);
      fs.mkdirSync(f.companionRoot, { mode: 0o700 });
      fs.writeFileSync(f.markerPath, fs.readFileSync(path.join(displaced, 'instance.json')),
        { mode: 0o600 });
      return credential;
    };
    const result = await f.call({ name: 'run' });
    assert.equal(result.exitCode, 2);
    assert.equal(sends, 0);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'state.json')), false);
  } finally { f.cleanup(); fs.rmSync(displaced, { recursive: true, force: true }); }
});

test('D09 full durable safety state refuses another request rather than shedding reservations', async () => {
  const f = await fixture();
  try {
    const state = f.state();
    const key = 's'.repeat(16 * 1024 * 1024 - Buffer.byteLength(JSON.stringify(state)) - 200);
    state.reservations[key] = { enrollmentId: 'old', identity: { accountId: 'workspace-old', userId: 'user-old' }, at: f.services.clock.wall(), possibleSend: true };
    const before = JSON.stringify(state);
    assert.ok(Buffer.byteLength(before) < 16 * 1024 * 1024);
    assert.ok(16 * 1024 * 1024 - Buffer.byteLength(before) < 100);
    fs.writeFileSync(f.statePath, before, { mode: 0o600 });
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    const result = await f.call({ name: 'run' });
    assert.equal(result.exitCode, 2);
    assert.equal(sends, 0);
    assert.ok(Object.hasOwn(f.state().reservations, key));
  } finally { f.cleanup(); }
});

test('D09 state with room for reservation but not outcome refuses dispatch before sending', async () => {
  const f = await fixture();
  try {
    const state = f.state();
    const key = 's'.repeat(16 * 1024 * 1024 - Buffer.byteLength(JSON.stringify(state)) - 2500);
    state.reservations[key] = { enrollmentId: 'old', identity: { accountId: 'workspace-old', userId: 'user-old' }, at: f.services.clock.wall(), possibleSend: true };
    const before = JSON.stringify(state);
    const spare = 16 * 1024 * 1024 - Buffer.byteLength(before);
    assert.ok(spare > 1000 && spare < 2500);
    fs.writeFileSync(f.statePath, before, { mode: 0o600 });
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    const result = await f.call({ name: 'run' });
    assert.equal(result.exitCode, 2);
    assert.equal(sends, 0);
    assert.ok(Object.hasOwn(f.state().reservations, key));
  } finally { f.cleanup(); }
});

test('B13 stale compatible backup needs a disabled conservative skip-through before schedule resumes', async () => {
  const f = await fixture();
  try {
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    assert.equal((await f.call({ name: 'run' })).exitCode, 0); // exact pilot, not scheduled history
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    const stale = f.state();
    assert.deepEqual(stale.slots, {});
    assert.equal((await f.call({ name: 'tick' })).attempted, 1);
    assert.equal(sends, 2);
    // Model the explicit disabled recovery decision; there is deliberately no automatic recovery CLI.
    stale.scheduleEnabled = false;
    stale.skipThrough = '2026-11-12T08:00';
    fs.writeFileSync(f.statePath, JSON.stringify(stale), { mode: 0o600 });
    await f.services.jobs.disable(f.services.jobs.binding);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    const recovered = await f.call({ name: 'tick' });
    assert.equal(recovered.reason, 'recovery_skip_through');
    assert.equal(sends, 2);
    assert.deepEqual(f.state().slots, {});
  } finally { f.cleanup(); }
});

test('D06 successful first probe with delayed cleanup does not send a later batch account', async () => {
  const f = await fixture(2);
  try {
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    sends = 0;
    f.services.probe = async () => {
      sends++;
      f.services.clock.advance(121000); // n*45s+30s = 120s for two selected accounts
      return { outcome: 'success', reason: 'marker_confirmed', dispatched: true };
    };
    const result = await f.call({ name: 'tick' });
    assert.deepEqual([result.selected, result.attempted, sends], [2, 1, 1]);
    assert.equal(result.results[1].reason, 'batch_unprocessed');
    assert.equal(f.state().activeBatch, null);
  } finally { f.cleanup(); }
});

test('D06 suspension-like wall/monotonic skew after first result prevents a second send', async () => {
  const f = await fixture(2);
  try {
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    let sends = 0;
    f.services.probe = async () => {
      sends++;
      f.services.clock.setWall(f.services.clock.wall() + 3600000);
      return { outcome: 'success', reason: 'marker_confirmed', dispatched: true };
    };
    const result = await f.call({ name: 'tick' });
    assert.deepEqual([result.selected, result.attempted, sends], [2, 1, 1]);
    assert.equal(result.results[1].reason, 'batch_deadline_or_clock');
  } finally { f.cleanup(); }
});

test('D07 Gaza spring gap and autumn repeated 01:30 do not invent a due slot', async () => {
  for (const [first, second] of [
    ['2026-03-27T23:30:00Z', '2026-03-28T00:30:00Z'],
    ['2026-10-23T22:30:00Z', '2026-10-23T23:30:00Z'],
  ]) {
    const clock = fakeClock(Date.parse(first));
    const f = await fixture(1, clock);
    try {
      let sends = 0;
      f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
      sends = 0;
      assert.equal((await f.call({ name: 'tick' })).reason, 'outside_admission_minute');
      clock.advance(Date.parse(second) - Date.parse(first));
      assert.equal((await f.call({ name: 'tick' })).reason, 'outside_admission_minute');
      assert.equal(sends, 0);
      assert.deepEqual(f.state().slots, {});
    } finally { f.cleanup(); }
  }
});

test('D07 changing the system display timezone cannot change a Gaza 08:00 admission', async () => {
  const f = await fixture();
  const old = process.env.TZ;
  try {
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    process.env.TZ = 'Pacific/Honolulu';
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    const result = await f.call({ name: 'tick' });
    assert.equal(result.attempted, 1);
    assert.equal(sends, 1);
    assert.ok(Object.hasOwn(f.state().slots, '2026-11-12T08:00'));
  } finally { if (old === undefined) delete process.env.TZ; else process.env.TZ = old; f.cleanup(); }
});

test('D08 fault after transport dispatch retains possible-send reservation and never replays slot', async () => {
  const f = await fixture();
  try {
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    let sends = 0, armed = false, injected = false;
    f.services.probe = async () => { sends++; armed = true; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    f.services.fault = point => {
      if (armed && !injected && point === 'before_state.json_create') {
        injected = true; throw Error('synthetic_result_persistence_fault');
      }
    };
    const result = await f.call({ name: 'tick' });
    delete f.services.fault;
    assert.equal(injected, true);
    assert.equal(result.exitCode, 2);
    assert.equal(result.attempted, 1);
    assert.equal(sends, 1);
    assert.ok(Object.values(f.state().reservations).some(r => r.possibleSend === true));
    assert.equal((await f.call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(sends, 1);
  } finally { f.cleanup(); }
});

test('D12 oversized all-account result is rejected before any manual dispatch', async () => {
  const f = await fixture(1025);
  try {
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    const result = await f.call({ name: 'run' });
    assert.equal(result.exitCode, 2);
    assert.equal(result.reason, 'output_capacity');
    assert.equal(result.attempted, 0);
    assert.equal(sends, 0);
    assert.deepEqual(f.state().reservations, {});
  } finally { f.cleanup(); }
});

test('E04 reported source drift after first account stops the second dispatch without losing first result', async () => {
  const f = await fixture(2);
  try {
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    f.services.reader.revalidate = (_ctx, e) => e.routerAccountId === 'router_1'
      ? { kind: 'blocked', scope: 'global', reason: 'compatibility_unavailable' }
      : { kind: 'ready' };
    const result = await f.call({ name: 'run' });
    assert.equal(result.exitCode, 2);
    assert.equal(result.selected, 2);
    assert.equal(result.attempted, 1);
    assert.equal(sends, 1);
    assert.equal(result.results[0].outcome, 'success');
    assert.equal(result.results[1].reason, 'batch_unprocessed');
  } finally { f.cleanup(); }
});

test('D13 a probe result cannot persist or emit an upstream secret as its reason', async () => {
  const f = await fixture();
  try {
    const canary = 'Bearer_DO_NOT_PERSIST_SECRET_CANARY';
    f.services.probe = async () => ({ outcome: 'uncertain', reason: canary, dispatched: true });
    const result = await f.call({ name: 'run' });
    assert.equal(JSON.stringify(result).includes(canary), false);
    assert.equal(fs.readFileSync(f.statePath, 'utf8').includes(canary), false);
  } finally { f.cleanup(); }
});

test('D10 untrusted success cannot grant a pilot or clear a correction block', async () => {
  const f = await fixture();
  try {
    const config = JSON.parse(fs.readFileSync(f.configPath)), id = config.enrollments[0].enrollmentId;
    const state = f.state(); state.blocks[id] = 'authentication_rejected';
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    f.services.probe = async () => ({ outcome: 'success', reason: 'output_mismatch', dispatched: true });
    const out = await f.call({ name: 'run' });
    assert.equal(out.exitCode, 1); assert.equal(out.results[0].reason, 'probe_result_untrusted');
    assert.deepEqual(f.state().pilots, {});
    assert.equal(f.state().blocks[id], 'authentication_rejected');
  } finally { f.cleanup(); }
});

test('D02 post-dispatch guard-release faults preserve actual run counts and outcomes through the CLI', async () => {
  for (const fault of ['unlink', 'rmdir']) for (const cli of [false, true]) {
    const f = await fixture();
    try {
      let sends = 0;
      const item = { id: 'item', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'WARMUP_OK' }] };
      f.services.request = async (_options, _body, control) => {
        control.beforeSend(); sends++; control.onDispatch();
        return { statusCode: 200, headers: {}, body: (async function* () { yield Buffer.from(`data: ${JSON.stringify({ type: 'response.completed', response: { status: 'completed', output: [item] } })}\n\n`); })() };
      };
      const work = path.join(f.companionRoot, 'work.lock');
      f.services.files = { ...fs,
        unlinkSync(file) { if (fault === 'unlink' && sends && file === path.join(work, 'owner.json')) throw Error('GUARD_RELEASE_SECRET_CANARY'); return fs.unlinkSync(file); },
        rmdirSync(file) { if (fault === 'rmdir' && sends && file === work) throw Error('GUARD_RELEASE_SECRET_CANARY'); return fs.rmdirSync(file); },
      };
      f.services.context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: fileURLToPath(new URL('../warmup.mjs', import.meta.url)) };
      const response = cli ? await execute(['run'], f.services) : await f.call({ name: 'run' });
      const out = cli ? response.json : response;
      assert.equal(response.exitCode, 2); assert.equal(out.selected, 1); assert.equal(out.attempted, 1); assert.equal(out.results.length, 1);
      assert.equal(out.results[0].outcome, 'success'); assert.equal(sends, 1);
      assert.equal(JSON.stringify(out).includes('GUARD_RELEASE_SECRET_CANARY'), false); assert.equal(fs.existsSync(work), true);
    } finally { f.cleanup(); }
  }
});

test('D11 invalid huge command never echoes argument canary or breaks JSON cap', async () => {
  const canary = 'Bearer_DO_NOT_ECHO_COMMAND_CANARY';
  const result = await execute([`${canary}${'x'.repeat(2 * 1024 * 1024)}`], new Proxy({}, {
    get() { throw Error('invalid argument must not access services'); },
  }));
  assert.equal(result.exitCode, 2);
  assert.equal(result.json.command, 'unknown');
  assert.equal(JSON.stringify(result.json).includes(canary), false);
  assert.ok(Buffer.byteLength(JSON.stringify(result.json)) <= 1024 * 1024);
});

test('D11/D12 list output-capacity error keeps a trustworthy installation identity', async () => {
  const f = await fixture();
  try {
    f.services.context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node',
      scriptPath: fileURLToPath(new URL('../warmup.mjs', import.meta.url)) };
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: Array.from({ length: 5000 }, (_, i) => ({
      routerAccountId: `router_${String(i).padStart(5, '0')}_${'x'.repeat(80)}`, eligible: false,
    })) });
    const result = await execute(['list'], f.services);
    assert.equal(result.exitCode, 2);
    assert.equal(result.json.reason, 'output_capacity');
    assert.equal(result.json.installationId, 'install_acceptance_01');
    assert.ok(Buffer.byteLength(JSON.stringify(result.json)) <= 1024 * 1024);
  } finally { f.cleanup(); }
});


test('B11 root disappearance at lock acquisition, compatibility, credential read or post-dispatch never recreates the root', async () => {
  for (const boundary of ['work_acquire', 'compatibility', 'credential', 'post_dispatch']) {
    const f = await fixture(); const displaced = `${f.companionRoot}-displaced`;
    try {
      let moved = false, sends = 0, credentialReads = 0, revalidations = 0;
      const move = () => { if (!moved) { fs.renameSync(f.companionRoot, displaced); moved = true; } };
      f.services.probe = async () => { sends++; if (boundary === 'post_dispatch') move(); return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
      if (boundary === 'work_acquire') f.services.files = new Proxy(fs, { get(target, key) {
        if (key === 'mkdirSync') return (file, options) => { if (file === path.join(f.companionRoot, 'work.lock')) move(); return fs.mkdirSync(file, options); };
        return target[key];
      } });
      if (boundary === 'compatibility') f.services.reader.checkCompatibility = () => { move(); return { kind: 'ready' }; };
      f.services.reader.revalidate = () => { revalidations++; return { kind: 'ready' }; };
      const read = f.services.reader.readCredential;
      f.services.reader.readCredential = (...args) => { credentialReads++; const out = read(...args); if (boundary === 'credential') move(); return out; };
      const out = await f.call({ name: 'run' });
      assert.equal(moved, true, boundary); assert.equal(out.exitCode, 2, boundary);
      assert.equal(fs.existsSync(f.companionRoot), false, boundary);
      assert.equal(sends, boundary === 'post_dispatch' ? 1 : 0, boundary);
      assert.equal(credentialReads, ['work_acquire', 'compatibility'].includes(boundary) ? 0 : 1, boundary);
      assert.equal(revalidations, boundary === 'post_dispatch' ? 2 : 0, boundary);
      if (boundary === 'post_dispatch') { assert.equal(out.attempted, 1); assert.equal(out.results[0].reason, 'marker_confirmed'); }
    } finally { f.cleanup(); fs.rmSync(displaced, { recursive: true, force: true }); }
  }
});
