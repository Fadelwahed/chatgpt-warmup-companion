import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand, hostServices } from '../runtime.mjs';
import { fakeClock, makeFixture } from './helpers.mjs';

// Engine 1.2.2: launchctl job inspection, pause evidence across schedule edits, send_check_failed guidance, guard path checks.
// Asia/Gaza is UTC+2 in November: local 08:00 is 06:00Z.
const at = time => Date.parse(`2026-11-12T${time}Z`);
const node = '/opt/homebrew/opt/node@22/bin/node';

// launchctl print lists each argument on its own line; `shown` replaces the top-level path (null drops it).
function printed(plistPath, scriptPath, shown = plistPath) {
  return ['gui/501/local.codex-router-warmup = {', '\tactive count = 0',
    ...(shown === null ? [] : [`\tpath = ${shown}`]), '\ttype = LaunchAgent', '\tstate = not running', '',
    `\tprogram = ${node}`, '\targuments = {', `\t\t${node}`, `\t\t${scriptPath}`, '\t\ttick', '\t}', '',
    '\tendpoints = {', `\t\tpath = ${plistPath}`, '\t}', '}', ''].join('\n');
}

// A host service set rooted at `root`, with launchctl print answered by `print(binding)`.
async function hostJob(f, root, plistPath, print) {
  let loaded = false;
  const services = hostServices(root, (file, args) => {
    if (file === '/bin/ls') return 'drwx------  1 user staff 1 Nov 12 12:34 synthetic';
    if (file !== '/bin/launchctl') throw Error('unexpected command');
    if (args[0] === 'print') {
      if (loaded) return print(services.context.scriptPath);
      throw Object.assign(Error('absent'), { stderr: 'Could not find service' });
    }
    if (args[0] === 'bootstrap') { loaded = true; return ''; }
    throw Error('unexpected launchctl operation');
  }, () => true);
  const { dev, ino } = fs.lstatSync(root);
  const binding = { root, dev, ino, installationId: 'install_engine_122', label: 'local.codex-router-warmup', plistPath, nodePath: services.context.nodePath, scriptPath: services.context.scriptPath };
  await services.jobs.enable(binding);
  return { services, binding };
}

function spacedHome(f) {
  const home = path.join(f.root, 'Home With Space');
  const root = path.join(home, 'codex-router-warmup');
  const agents = path.join(home, 'LaunchAgents');
  for (const dir of [home, root, agents]) fs.mkdirSync(dir, { mode: 0o700 });
  return { root, plistPath: path.join(agents, 'local.codex-router-warmup.plist') };
}

test('1.2.2 fix A: a job whose home path has a space is owned', async () => {
  const f = makeFixture();
  try {
    const { root, plistPath } = spacedHome(f);
    const { services, binding } = await hostJob(f, root, plistPath, script => printed(plistPath, script));
    assert.ok(binding.scriptPath.includes(' '));
    assert.equal(await services.jobs.inspect(binding), 'loaded');
  } finally { f.cleanup(); }
});

test('1.2.2 fix A: the owned case without spaces still inspects as loaded', async () => {
  const f = makeFixture();
  try {
    const { services, binding } = await hostJob(f, f.companionRoot, f.plistPath, script => printed(f.plistPath, script));
    assert.equal(await services.jobs.inspect(binding), 'loaded');
  } finally { f.cleanup(); }
});

test('1.2.2 fix A: a same-label job loaded from another plist is job_ownership_unknown', async () => {
  const f = makeFixture();
  try {
    const other = path.join(f.root, 'Other', 'local.codex-router-warmup.plist');
    const { services, binding } = await hostJob(f, f.companionRoot, f.plistPath, script => printed(f.plistPath, script, other));
    await assert.rejects(services.jobs.inspect(binding), error => error.reason === 'job_ownership_unknown');
    await assert.rejects(services.jobs.runner(binding), error => error.reason === 'job_ownership_unknown');
  } finally { f.cleanup(); }
});

// Review round 3: only launchctl's indentation is removed, so a live argument with an extra trailing blank differs.
test('1.2.2 fix A: an argument that differs only by a trailing blank is job_ownership_unknown', async () => {
  const f = makeFixture();
  try {
    const { root, plistPath } = spacedHome(f);
    const { services, binding } = await hostJob(f, root, plistPath, script => printed(plistPath, `${script} `));
    await assert.rejects(services.jobs.inspect(binding), error => error.reason === 'job_ownership_unknown');
  } finally { f.cleanup(); }
});

test('1.2.2 fix A: a missing top-level path line is job_ownership_unknown, even with a nested path', async () => {
  const f = makeFixture();
  try {
    const { services, binding } = await hostJob(f, f.companionRoot, f.plistPath, script => printed(f.plistPath, script, null));
    await assert.rejects(services.jobs.inspect(binding), error => error.reason === 'job_ownership_unknown');
  } finally { f.cleanup(); }
});

async function prepared(start = at('02:40:00'), zone = 'Asia/Gaza') {
  const f = makeFixture({ clock: fakeClock(start) });
  f.services.clock.zone = () => zone;
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_engine_122', phase: 'uninitialized', paths, plistPath: f.plistPath });
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

// Pause at 07:55 local, then resume at 08:05 local: the 08:00 slot was missed while paused.
async function pauseAt(f, call) {
  f.services.clock.setWall(at('05:55:00'));
  assert.equal((await call({ name: 'schedule', action: 'disable' })).reason, 'schedule_disabled');
}
const slot0800 = async call => (await call({ name: 'status' })).slotLedger.find(row => row.slot === '2026-11-12T08:00');

for (const [label, edit] of [['add', { action: 'add', time: '10:30', today: true }], ['remove', { action: 'remove', time: '13:00', today: true }]]) {
  test(`1.2.2 fix B: a schedule ${label} while paused keeps the pause evidence for resume`, async () => {
    const { f, call, state } = await prepared();
    try {
      await pauseAt(f, call);
      assert.equal((await call({ name: 'schedule', ...edit })).reason, 'schedule_updated');
      assert.deepEqual(state().schedulePause, { at: at('05:55:00'), zone: 'Asia/Gaza', revision: state().scheduleRevision });
      f.services.clock.setWall(at('06:05:00'));
      assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
      const ledger = await slot0800(call);
      assert.equal(ledger?.cause, 'schedule_disabled');
      assert.equal(ledger.evidence.pauseStartedAt, at('05:55:00'));
      assert.equal(state().schedulePause, undefined);
    } finally { f.cleanup(); }
  });
}

// Review round 1: an edit on a later day must not lose the earlier paused days, which the edited
// schedule no longer offers to resume.
test('1.2.2 fix B: an edit on a later day keeps the earlier paused slots', async () => {
  const { f, call } = await prepared();
  try {
    await pauseAt(f, call);
    f.services.clock.setWall(Date.parse('2026-11-13T05:00:00Z'));
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(Date.parse('2026-11-13T06:05:00Z'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    const ledger = (await call({ name: 'status' })).slotLedger;
    for (const slot of ['2026-11-12T08:00', '2026-11-12T13:00', '2026-11-12T18:00', '2026-11-13T08:00']) {
      const row = ledger.find(r => r.slot === slot);
      assert.deepEqual([slot, row?.cause, row?.evidence.pauseStartedAt], [slot, 'schedule_disabled', at('05:55:00')]);
    }
  } finally { f.cleanup(); }
});

test('1.2.2 fix B: pause then resume without an edit still records the paused slot', async () => {
  const { f, call } = await prepared();
  try {
    await pauseAt(f, call);
    f.services.clock.setWall(at('06:05:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    const ledger = await slot0800(call);
    assert.deepEqual([ledger?.cause, ledger?.evidence.pauseStartedAt], ['schedule_disabled', at('05:55:00')]);
  } finally { f.cleanup(); }
});

test('1.2.2 fix B: a failed resume after an edit rolls back with the pause intact and current', async () => {
  const { f, call, state } = await prepared();
  try {
    await pauseAt(f, call);
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(at('06:05:00'));
    let faulted = false;
    f.services.fault = point => {
      if (!faulted && point === 'after_state.json_rename' && state().scheduleEnabled) { faulted = true; throw new Error('synthetic resume failure'); }
    };
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 2);
    assert.equal(faulted, true);
    delete f.services.fault;
    const s = state();
    assert.equal(s.scheduleEnabled, false);
    assert.deepEqual(s.schedulePause, { at: at('05:55:00'), zone: 'Asia/Gaza', revision: s.scheduleRevision });
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    const ledger = await slot0800(call);
    assert.deepEqual([ledger?.cause, ledger?.evidence.pauseStartedAt], ['schedule_disabled', at('05:55:00')]);
  } finally { f.cleanup(); }
});

test('1.2.2 fix B: an edit never refreshes a stale pause and never creates one', async () => {
  const { f, call, state, save } = await prepared();
  try {
    await pauseAt(f, call);
    const stale = { ...state().schedulePause, revision: state().scheduleRevision - 1 };
    save({ ...state(), schedulePause: stale });
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    assert.deepEqual(state().schedulePause, stale);
    const { schedulePause, ...withoutPause } = state();
    save(withoutPause);
    assert.equal((await call({ name: 'schedule', action: 'remove', time: '10:30', today: true })).reason, 'schedule_updated');
    assert.equal(Object.hasOwn(state(), 'schedulePause'), false);
  } finally { f.cleanup(); }
});

// Review round 2: a pause row an edit wrote must not pre-empt the zone-change hold for the same key.
test('1.2.2 fix B: a time-zone hold replaces a paused-slot row for the same minute', async () => {
  const { f, call, state, save } = await prepared();
  try {
    let zone = 'Asia/Gaza';
    f.services.clock.zone = () => zone;
    f.services.clock.setWall(at('05:00:05'));
    await call({ name: 'tick' });
    const s = state(), tick = at('05:00:05');
    s.slotLedger = { ...(s.slotLedger ?? {}), '2026-11-12T08:00': { admission: '08:00', verdict: 'not_admitted', cause: 'schedule_disabled', zone: 'Asia/Gaza', at: tick,
      evidence: { previousTick: s.lastTick, tick, previousZone: 'Asia/Gaza', pauseStartedAt: at('04:00:00') } } };
    save(s);
    zone = 'Europe/London';
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    f.services.clock.setWall(at('08:00:05'));
    await call({ name: 'tick' });
    f.services.clock.setWall(at('08:00:35'));
    await call({ name: 'tick' });
    assert.equal(sends, 0, 'nothing is sent in the held minute');
    assert.equal(state().slotLedger['2026-11-12T08:00'].cause, 'zone_changed');
  } finally { f.cleanup(); }
});

test('1.2.2 fix C: send_check_failed guidance is review_router_state', async () => {
  const { f, call } = await prepared();
  try {
    f.services.probe = async () => ({ outcome: 'blocked', reason: 'send_check_failed', dispatched: false });
    f.services.clock.setWall(at('06:00:05'));
    await call({ name: 'tick' });
    const account = (await call({ name: 'schedule', action: 'inspect', slot: '2026-11-12T08:00' })).explanation.accounts[0];
    assert.deepEqual([account.reason, account.guidance], ['send_check_failed', 'review_router_state']);
  } finally { f.cleanup(); }
});

// A symlink to outside the guard root cannot be made from a guarded test (the guard denies the
// link), so an in-root link stands in: the guard must not check `link/..` as if `link` were a plain directory.
test('1.2.2 fix D: the guard denies a path whose `..` would be resolved through a symlink', async () => {
  const base = fs.mkdtempSync(path.join(process.env.WARMUP_TEST_ROOT, 'guard-'));
  try {
    const inner = path.join(base, 'inner'), elsewhere = path.join(base, 'elsewhere');
    fs.mkdirSync(path.join(elsewhere, 'deep'), { recursive: true, mode: 0o700 });
    fs.mkdirSync(inner, { mode: 0o700 });
    fs.writeFileSync(path.join(elsewhere, 'file'), 'ELSEWHERE', { mode: 0o600 });
    fs.symlinkSync(path.join(elsewhere, 'deep'), path.join(inner, 'link'));
    const sneaky = `${inner}/link/../file`;
    assert.throws(() => fs.readFileSync(sneaky, 'utf8'), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.readFileSync(Buffer.from(sneaky)), /TEST_GUARD_DENIED/);
    assert.throws(() => fs.writeFileSync(sneaky, 'x'), /TEST_GUARD_DENIED/);
    await assert.rejects(async () => fs.promises.readFile(sneaky), /TEST_GUARD_DENIED/);
    assert.equal(fs.readFileSync(path.join(elsewhere, 'file'), 'utf8'), 'ELSEWHERE');
  } finally { fs.rmSync(base, { recursive: true, force: true }); }
});

// Review round 3: in the New York fall-back hour (06:00Z: 02:00 EDT becomes 01:00 EST), 01:35 added at the
// second 01:15 did not exist when the first 01:35 passed, so it is not reported as paused, and the second one still runs.
test('1.2.2 fix B: a time added after its first occurrence passed is not reported as paused', async () => {
  const nyc = time => Date.parse(`2026-11-01T${time}Z`);
  const { f, call, state } = await prepared(nyc('04:40:00'), 'America/New_York');
  try {
    f.services.clock.setWall(nyc('05:30:00'));
    assert.equal((await call({ name: 'schedule', action: 'disable' })).reason, 'schedule_disabled');
    f.services.clock.setWall(nyc('06:15:00'));
    assert.equal((await call({ name: 'schedule', action: 'add', time: '01:35', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(nyc('06:20:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    assert.equal(state().slotLedger?.['2026-11-01T01:35'], undefined);
    let sends = 0;
    f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    f.services.clock.setWall(nyc('06:35:05'));
    await call({ name: 'tick' });
    assert.equal(sends, 1, 'the second 01:35 runs');
  } finally { f.cleanup(); }
});

// Review round 3: an edit while the clock ran ahead (08:05) wrote a paused row for 08:00; after the clock is
// corrected to 07:57, resume drops it, so 08:00 runs, or is reported missed if no tick comes.
for (const ticked of [true, false]) {
  test(`1.2.2 fix B: resume drops a paused row written while the clock ran ahead (${ticked ? 'tick at 08:00' : 'no tick at 08:00'})`, async () => {
    const { f, call, state } = await prepared();
    try {
      await pauseAt(f, call);
      f.services.clock.setWall(at('06:05:00'));
      assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
      assert.equal(state().slotLedger['2026-11-12T08:00'].cause, 'schedule_disabled');
      f.services.clock.setWall(at('05:57:00'));
      assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
      assert.equal(state().slotLedger?.['2026-11-12T08:00'], undefined);
      let sends = 0;
      f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
      f.services.clock.setWall(at('05:58:05'));
      await call({ name: 'tick' });
      f.services.clock.setWall(at(ticked ? '06:00:05' : '06:10:05'));
      await call({ name: 'tick' });
      if (ticked) assert.equal(sends, 1, '08:00 runs');
      else assert.equal(state().slotLedger['2026-11-12T08:00']?.cause, 'no_tick_between');
    } finally { f.cleanup(); }
  });
}

// Review round 4: the edit's settled mark must not hide a slot missed before the pause (last tick 07:55,
// no tick at 08:00, pause 08:10, edit 08:15); it is still reported as no_tick_between.
test('1.2.2 fix B: a paused edit keeps a slot missed before the pause', async () => {
  const { f, call, state } = await prepared();
  try {
    f.services.clock.setWall(at('05:55:05'));
    await call({ name: 'tick' });
    f.services.clock.setWall(at('06:10:00'));
    assert.equal((await call({ name: 'schedule', action: 'disable' })).reason, 'schedule_disabled');
    f.services.clock.setWall(at('06:15:00'));
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(at('06:20:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    f.services.clock.setWall(at('06:20:05'));
    await call({ name: 'tick' });
    assert.equal(state().slotLedger['2026-11-12T08:00']?.cause, 'no_tick_between');
  } finally { f.cleanup(); }
});

// Review round 4: a clock correction that still leaves 08:00 behind keeps its paused row (edit at 08:10,
// corrected to 08:05), because the row is judged by the slot's minute, not by when it was written.
test('1.2.2 fix B: a clock correction keeps a paused row whose minute had closed', async () => {
  const { f, call, state } = await prepared();
  try {
    await pauseAt(f, call);
    f.services.clock.setWall(at('06:10:00'));
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(at('06:05:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    assert.equal(state().slotLedger['2026-11-12T08:00']?.cause, 'schedule_disabled');
  } finally { f.cleanup(); }
});

// Review round 4: after the clock is corrected to 07:57, a second paused edit that removes 08:00 drops the
// row the first edit wrote at 08:05, so resuming later does not report a removed slot as paused.
test('1.2.2 fix B: a paused edit after a clock correction drops rows for minutes still open', async () => {
  const { f, call, state } = await prepared();
  try {
    await pauseAt(f, call);
    f.services.clock.setWall(at('06:05:00'));
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    assert.equal(state().slotLedger['2026-11-12T08:00']?.cause, 'schedule_disabled');
    f.services.clock.setWall(at('05:57:00'));
    assert.equal((await call({ name: 'schedule', action: 'remove', time: '08:00', today: true })).reason, 'schedule_updated');
    assert.equal(state().slotLedger?.['2026-11-12T08:00'], undefined);
    f.services.clock.setWall(at('06:06:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    assert.equal(state().slotLedger?.['2026-11-12T08:00'], undefined);
  } finally { f.cleanup(); }
});

// Review round 5: once scheduling has resumed and a tick has passed the slot, a repeated enable after the
// clock is set back keeps the confirmed pause row; only the pause being resumed is reconsidered.
test('1.2.2 fix B: a repeated enable after a clock rollback keeps resumed pause history', async () => {
  const { f, call, state } = await prepared();
  try {
    await pauseAt(f, call);
    f.services.clock.setWall(at('06:05:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    f.services.clock.setWall(at('06:06:05'));
    await call({ name: 'tick' });
    f.services.clock.setWall(at('05:57:00'));
    await call({ name: 'schedule', action: 'enable' });
    assert.equal(state().slotLedger['2026-11-12T08:00']?.cause, 'schedule_disabled');
  } finally { f.cleanup(); }
});

// Review round 5: in the New York fall-back hour, a pause that began after the first 01:35 recorded the
// second one (edit at the second 01:40); after the clock is corrected to the second 01:30, resume drops the
// row, because only the occurrence inside the pause counts.
test('1.2.2 fix B: a clock rollback judges a repeated minute by its occurrence inside the pause', async () => {
  const nyc = time => Date.parse(`2026-11-01T${time}Z`);
  const { f, call, state } = await prepared(nyc('04:40:00'), 'America/New_York');
  try {
    assert.equal((await call({ name: 'schedule', action: 'add', time: '01:35', today: true })).reason, 'schedule_updated');
    f.services.clock.setWall(nyc('05:40:00'));
    assert.equal((await call({ name: 'schedule', action: 'disable' })).reason, 'schedule_disabled');
    f.services.clock.setWall(nyc('06:40:00'));
    assert.equal((await call({ name: 'schedule', action: 'add', time: '10:30', today: true })).reason, 'schedule_updated');
    assert.equal(state().slotLedger['2026-11-01T01:35']?.cause, 'schedule_disabled');
    f.services.clock.setWall(nyc('06:30:00'));
    assert.equal((await call({ name: 'schedule', action: 'enable' })).reason, 'schedule_enabled');
    assert.equal(state().slotLedger?.['2026-11-01T01:35'], undefined);
  } finally { f.cleanup(); }
});
