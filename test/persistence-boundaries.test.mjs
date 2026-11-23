import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand, recoverInstance, resumeRemoval } from '../runtime.mjs';
import { makeFixture } from './helpers.mjs';

const hash = value => createHash('sha256').update(value).digest('hex');
const boundaries = ['before_create', 'after_create', 'after_write', 'after_fsync', 'before_rename', 'after_rename_before_dirsync', 'after_rename'];
const pointFor = (name, stage) => `${stage.split('_')[0]}_${name}_${stage.split('_').slice(1).join('_')}`;
function fixture() {
  const f = makeFixture();
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot, switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_persistence_01', phase: 'uninitialized', paths, plistPath: f.plistPath });
  const compatibilityPath = path.join(f.companionRoot, 'compatibility.json');
  put(compatibilityPath, { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, i) => [`src/contract-${i}.mjs`, hash(String(i))])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'persistence-review', semantics: 'equivalent' });
  let scans = 0, sends = 0;
  f.services.reader = {
    readRegistry: () => { scans++; return { kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] }; },
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: () => ({ kind: 'ready', snapshot: {}, accessToken: 'synthetic', expiresAt: 4102444800000, identity: { accountId: 'workspace', userId: 'user' } }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => { sends++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  const state = () => JSON.parse(fs.readFileSync(f.statePath));
  function inject(name, boundary, occurrence = 1) {
    let writes = 0, hit = false;
    f.services.fault = at => {
      if (at === `before_${name}_create`) writes++;
      if (!hit && writes === occurrence && at === pointFor(name, boundary)) { hit = true; throw Error('SYNTHETIC_PERSISTENCE_FAILURE'); }
    };
    return () => { assert.equal(hit, true, `${name}/${boundary}/${occurrence}`); delete f.services.fault; };
  }
  return { ...f, put, call, state, inject, compatibilityPath, context, scans: () => scans, sends: () => sends };
}

test('B07/B12 final complete-marker write faults preserve the frozen scan and a coherent disabled pair', async () => {
  for (const boundary of boundaries) {
    const f = fixture();
    try {
      const finish = f.inject('instance.json', boundary, 2);
      assert.equal((await f.call({ name: 'setup' })).exitCode, 2, boundary); finish();
      assert.equal(f.scans(), 1);
      const marker = JSON.parse(fs.readFileSync(f.markerPath));
      assert.ok(['in_progress', 'complete'].includes(marker.phase));
      const state = f.state();
      assert.equal(state.scheduleEnabled, false);
      assert.equal(state.configDigest, hash(fs.readFileSync(f.configPath)));
      assert.equal(state.compatibilityDigest, hash(fs.readFileSync(f.compatibilityPath)));
      const repeated = await f.call({ name: 'setup' });
      assert.equal(repeated.exitCode, marker.phase === 'complete' ? 0 : 2);
      assert.equal(f.scans(), 1); assert.equal(f.sends(), 0);
    } finally { f.cleanup(); }
  }
});

test('B16 every maintenance pilot/config/compatibility/digest write boundary stays disabled and never revives changed-model pilots', async () => {
  for (const [name, occurrence] of [['state.json', 1], ['config.json', 1], ['compatibility.json', 1], ['state.json', 2]]) {
    for (const boundary of boundaries) {
      const f = fixture();
      try {
        assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
        assert.equal((await f.call({ name: 'run' })).exitCode, 0);
        const old = f.state(), beforeSends = f.sends();
        const candidate = { schemaVersion: 1, config: JSON.parse(fs.readFileSync(f.configPath)),
          compatibility: JSON.parse(fs.readFileSync(f.compatibilityPath)), reviewEvidence: 'persistence-review' };
        candidate.config.enrollments[0].model = 'gpt-6-sol';
        const candidatePath = path.join(f.root, 'candidate.json'); f.put(candidatePath, candidate);
        const finish = f.inject(name, boundary, occurrence);
        assert.equal((await f.call({ name: 'maintain', file: candidatePath })).exitCode, 2, `${name}/${boundary}/${occurrence}`); finish();
        const current = f.state(), config = JSON.parse(fs.readFileSync(f.configPath));
        assert.equal(current.scheduleEnabled, false); assert.equal(f.sends(), beforeSends);
        assert.deepEqual(current.history, old.history); assert.deepEqual(current.reservations, old.reservations);
        if (config.enrollments[0].model !== 'gpt-6-luna') assert.deepEqual(current.pilots, {});
        const pairMatches = current.configDigest === hash(fs.readFileSync(f.configPath)) && current.compatibilityDigest === hash(fs.readFileSync(f.compatibilityPath));
        if (!pairMatches) {
          assert.equal((await f.call({ name: 'run' })).exitCode, 2);
          assert.equal(f.sends(), beforeSends);
        }
      } finally { f.cleanup(); }
    }
  }
});

test('B09/B16 enrollment config and digest write faults cannot silently legitimize a changed file pair', async () => {
  for (const name of ['config.json', 'state.json']) for (const boundary of boundaries) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_two', eligible: true }] });
      f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_two', userId: 'user_two' } });
      const finish = f.inject(name, boundary);
      assert.equal((await f.call({ name: 'enroll', account: 'router_two' })).exitCode, 2); finish();
      const state = f.state();
      assert.equal(state.scheduleEnabled, false); assert.deepEqual(state.pilots, {}); assert.equal(f.sends(), 0);
      if (state.configDigest !== hash(fs.readFileSync(f.configPath))) {
        assert.equal((await f.call({ name: 'setup' })).exitCode, 2);
        assert.equal((await f.call({ name: 'run' })).exitCode, 2); assert.equal(f.sends(), 0);
      }
    } finally { f.cleanup(); }
  }
});

test('B08 lost, corrupt, mismatched and unknown-version instance/config/state never rescan later accounts', async () => {
  for (const name of ['instance.json', 'config.json', 'state.json']) for (const damage of ['missing', 'invalid_json', 'wrong_id', 'unknown_version']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      const sends = f.sends(), scans = f.scans(), file = path.join(f.companionRoot, name);
      f.services.reader.readRegistry = () => { throw Error('LATER_ACCOUNT_DISCOVERY_FORBIDDEN'); };
      if (damage === 'missing') fs.unlinkSync(file);
      else if (damage === 'invalid_json') fs.writeFileSync(file, '{broken', { mode: 0o600 });
      else {
        const record = JSON.parse(fs.readFileSync(file));
        if (damage === 'wrong_id') record.installationId = 'different_installation_01'; else record.schemaVersion = 999;
        f.put(file, record);
      }
      const before = Object.fromEntries(['instance.json', 'config.json', 'state.json'].map(name => {
        const file = path.join(f.companionRoot, name); return [name, fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null];
      }));
      assert.equal((await f.call({ name: 'setup' })).exitCode, 2, `${name}/${damage}`);
      assert.equal((await f.call({ name: 'run' })).exitCode, 2, `${name}/${damage}`);
      assert.equal(f.sends(), sends); assert.equal(f.scans(), scans);
      for (const [name, bytes] of Object.entries(before)) {
        const file = path.join(f.companionRoot, name);
        assert.equal(fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null, bytes);
      }
    } finally { f.cleanup(); }
  }
});

test('B08 repeated setup preserves enabled schedule, enrollment and nonempty history without rediscovery', async () => {
  const f = fixture();
  try {
    assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    const config = fs.readFileSync(f.configPath, 'utf8');
    const state = fs.readFileSync(f.statePath, 'utf8');
    assert.ok(JSON.parse(state).history.length > 0);
    assert.equal(JSON.parse(state).scheduleEnabled, true);
    const scans = f.scans();
    f.services.reader.readRegistry = () => { throw Error('REPEATED_DISCOVERY_FORBIDDEN'); };
    assert.equal((await f.call({ name: 'setup' })).reason, 'already_initialized');
    assert.equal(f.scans(), scans);
    assert.equal(fs.readFileSync(f.configPath, 'utf8'), config);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), state);
  } finally { f.cleanup(); }
});

test('B08 explicit lost-state recovery stays disabled and never enrolls a later Router account', async () => {
  const f = fixture();
  try {
    assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    const config = fs.readFileSync(f.configPath, 'utf8');
    const original = f.state();
    const backupPath = path.join(f.root, 'state-backup.json');
    f.put(backupPath, original);
    fs.unlinkSync(f.statePath);
    const scans = f.scans(), sends = f.sends();
    f.services.reader.readRegistry = () => { throw Error('LATER_ACCOUNT_DISCOVERY_FORBIDDEN'); };
    assert.equal((await f.call({ name: 'setup' })).exitCode, 2);
    const stat = fs.lstatSync(f.companionRoot);
    const decision = { installationId: 'install_persistence_01', rootDev: stat.dev, rootIno: stat.ino,
      skipThrough: '2026-11-12T18:00', reviewEvidence: 'explicit synthetic recovery', backupPath };
    const recovered = await recoverInstance(f.context, f.services, decision);
    assert.equal(recovered.reason, 'recovered_disabled', JSON.stringify(recovered));
    assert.equal(f.state().scheduleEnabled, false);
    assert.deepEqual(f.state().history, original.history);
    assert.equal(fs.readFileSync(f.configPath, 'utf8'), config);
    assert.deepEqual(JSON.parse(config).enrollments.map(e => e.routerAccountId), ['router_one']);
    assert.equal(f.scans(), scans); assert.equal(f.sends(), sends);
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [
      { routerAccountId: 'router_one', eligible: true }, { routerAccountId: 'router_later', eligible: true },
    ] });
    assert.equal((await f.call({ name: 'setup' })).reason, 'already_initialized');
    const later = (await f.call({ name: 'list' })).rows.find(row => row.routerAccountId === 'router_later');
    assert.deepEqual([later.enrollmentId, later.enrollmentState], [null, 'not_enrolled']);
    assert.equal(fs.readFileSync(f.configPath, 'utf8'), config);
  } finally { f.cleanup(); }
});

test('B14 maintain rejects enabled state, loaded or unknown exact job, and live or ambiguous runner before writes', async () => {
  for (const conflict of ['enabled', 'loaded', 'unknown_job', 'live_runner', 'ambiguous_runner']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      const candidatePath = path.join(f.root, 'candidate.json');
      f.put(candidatePath, { schemaVersion: 1, config: JSON.parse(fs.readFileSync(f.configPath)),
        compatibility: JSON.parse(fs.readFileSync(f.compatibilityPath)), reviewEvidence: 'persistence-review' });
      if (conflict === 'enabled') {
        const state = f.state(); state.scheduleEnabled = true; f.put(f.statePath, state);
      }
      f.services.jobs.inspect = async () => conflict === 'loaded' ? 'loaded' : conflict === 'unknown_job' ? 'unknown' : 'absent';
      f.services.jobs.runner = async () => conflict === 'live_runner' ? { pid: 4242, scheduled: false } : conflict === 'ambiguous_runner' ? { pid: 9999 } : null;
      const before = [f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
      assert.equal((await f.call({ name: 'maintain', file: candidatePath })).exitCode, 2, conflict);
      assert.deepEqual([f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before, conflict);
    } finally { f.cleanup(); }
  }
});

test('B17 active manual or tick work blocks maintain with accepted files and history unchanged', async () => {
  for (const name of ['run', 'tick']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      if (name === 'tick') assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
      const candidatePath = path.join(f.root, 'candidate.json');
      f.put(candidatePath, { schemaVersion: 1, config: JSON.parse(fs.readFileSync(f.configPath)),
        compatibility: JSON.parse(fs.readFileSync(f.compatibilityPath)), reviewEvidence: 'persistence-review' });
      let entered, release;
      const started = new Promise(resolve => { entered = resolve; });
      const held = new Promise(resolve => { release = resolve; });
      f.services.probe = async () => { entered(); await held; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
      const running = f.call({ name });
      try {
        await started;
        const before = [f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
        const history = f.state().history;
        assert.equal((await f.call({ name: 'maintain', file: candidatePath })).exitCode, 3, name);
        assert.deepEqual([f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before, name);
        assert.deepEqual(f.state().history, history, name);
      } finally { release(); }
      assert.equal((await running).exitCode, 0, name);
    } finally { f.cleanup(); }
  }
});

test('B21 every deletion boundary excludes competing mutations and permits only explicit owned continuation', async () => {
  const files = ['warmup.mjs', 'router-reader.mjs', 'chatgpt-probe.mjs', 'runtime.mjs', 'README.md', 'config.json', 'compatibility.json', 'state.json', 'instance.json'];
  for (const fault of [...files.map(name => `before_remove_${name}`), 'before_remove_final_guard']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      for (const name of files.slice(0, 5)) fs.writeFileSync(path.join(f.companionRoot, name), '// synthetic deployed file', { mode: 0o600 });
      const stat = fs.lstatSync(f.companionRoot), contenders = [];
      let hit = false, jobEnables = 0;
      f.services.jobs.enable = async () => { jobEnables++; };
      f.services.fault = point => {
        if (point !== fault || hit) return;
        hit = true;
        assert.equal(fs.existsSync(path.join(f.companionRoot, 'work.lock')), true);
        assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), true);
        for (const command of [{ name: 'setup' }, { name: 'run' }, { name: 'tick' }, { name: 'enroll', account: 'router_one' },
          { name: 'schedule', action: 'enable' }, { name: 'maintain', file: path.join(f.root, 'candidate.json') }, { name: 'remove' }]) {
          contenders.push(f.call(command));
        }
        throw Error('SYNTHETIC_DELETE_BOUNDARY_FAILURE');
      };
      assert.equal((await f.call({ name: 'remove' })).exitCode, 2, fault); assert.equal(hit, true, fault);
      delete f.services.fault;
      for (const out of await Promise.all(contenders)) assert.ok([2, 3].includes(out.exitCode), `${fault}: ${JSON.stringify(out)}`);
      assert.equal(jobEnables, 0); assert.equal(f.sends(), 0);
      const resumed = await resumeRemoval(f.context, f.services, { installationId: 'install_persistence_01', rootDev: stat.dev, rootIno: stat.ino, reviewEvidence: 'explicit synthetic cleanup decision' });
      assert.equal(resumed.exitCode, 0, `${fault}: ${JSON.stringify(resumed)}`);
      assert.equal(fs.existsSync(f.companionRoot), false);
    } finally { f.cleanup(); }
  }
});

test('B07 a global failure during later identity discovery never completes or rescans a partial cohort', async () => {
  const f = fixture();
  try {
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [
      { routerAccountId: 'router_one', eligible: true }, { routerAccountId: 'router_two', eligible: true },
    ] });
    let calls = 0;
    f.services.reader.discoverIdentity = () => ++calls === 1 ? { kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }
      : { kind: 'blocked', scope: 'global', reason: 'SOURCE_SWITCH_CANARY' };
    const out = await f.call({ name: 'setup' });
    assert.equal(out.exitCode, 2); assert.equal(JSON.stringify(out).includes('SOURCE_SWITCH_CANARY'), false);
    assert.equal(JSON.parse(fs.readFileSync(f.markerPath)).phase, 'in_progress');
    assert.equal(fs.existsSync(f.configPath), false); assert.equal(fs.existsSync(f.statePath), false);
    assert.equal((await f.call({ name: 'setup' })).exitCode, 2); assert.equal(calls, 2); assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});

test('B07 first setup rejects loaded/unknown jobs, runner or existing plist before discovery or marker mutation', async () => {
  for (const conflict of ['loaded', 'unknown', 'runner', 'plist']) {
    const f = fixture();
    try {
      const marker = fs.readFileSync(f.markerPath, 'utf8');
      let mutations = 0;
      f.services.jobs.inspect = async () => ['loaded', 'unknown'].includes(conflict) ? conflict : 'absent';
      f.services.jobs.runner = async () => conflict === 'runner' ? { pid: 1234 } : null;
      f.services.jobs.enable = f.services.jobs.disable = async () => { mutations++; };
      if (conflict === 'plist') fs.writeFileSync(f.plistPath, 'KEEP_FOREIGN_PLIST', { mode: 0o600 });
      assert.equal((await f.call({ name: 'setup' })).exitCode, 2, conflict);
      assert.equal(f.scans(), 0); assert.equal(mutations, 0);
      assert.equal(fs.readFileSync(f.markerPath, 'utf8'), marker);
      assert.equal(fs.existsSync(f.configPath), false); assert.equal(fs.existsSync(f.statePath), false);
      if (conflict === 'plist') assert.equal(fs.readFileSync(f.plistPath, 'utf8'), 'KEEP_FOREIGN_PLIST');
    } finally { f.cleanup(); }
  }
});

test('B02 setup exposes bounded account-scoped exclusion reasons without treating them as global failure', async () => {
  const f = fixture();
  try {
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [
      { routerAccountId: 'router_one', eligible: true }, { routerAccountId: 'router_two', eligible: true },
      { routerAccountId: 'router_paused', eligible: false, state: 'paused', paused: true },
    ] });
    f.services.reader.discoverIdentity = (_ctx, id) => id === 'router_one' ? { kind: 'ready', identity: { accountId: 'workspace', userId: 'user' } }
      : { kind: 'blocked', scope: 'account', reason: 'identity_ambiguous' };
    const out = await f.call({ name: 'setup' });
    assert.equal(out.exitCode, 0); assert.equal(out.enrolled, 1);
    assert.deepEqual(out.excluded, [
      { routerAccountId: 'router_two', reason: 'identity_ambiguous' }, { routerAccountId: 'router_paused', reason: 'registry_ineligible' },
    ]);
  } finally { f.cleanup(); }
});


test('B17 paused enable excludes maintain without changing accepted files or history', async () => {
  const f = fixture();
  let release, running;
  try {
    assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
    assert.equal((await f.call({ name: 'run' })).exitCode, 0);
    const candidate = path.join(f.root, 'candidate.json');
    f.put(candidate, { schemaVersion: 1, config: JSON.parse(fs.readFileSync(f.configPath)), compatibility: JSON.parse(fs.readFileSync(f.compatibilityPath)), reviewEvidence: 'persistence-review' });
    const enable = f.services.jobs.enable.bind(f.services.jobs);
    let entered;
    const started = new Promise(resolve => { entered = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    f.services.jobs.enable = async binding => { entered(); await held; await enable(binding); };
    running = f.call({ name: 'schedule', action: 'enable' });
    await started;
    const before = [f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
    assert.ok(f.state().history.length > 0);
    assert.equal((await f.call({ name: 'maintain', file: candidate })).exitCode, 3);
    assert.deepEqual([f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before);
    release();
    assert.equal((await running).exitCode, 0);
  } finally { release?.(); if (running) await running; f.cleanup(); }
});

test('B04 duplicate Router references are rejected independently of enrollment and full identity uniqueness', async () => {
  const f = fixture();
  try {
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [
      { routerAccountId: 'router_one', eligible: true }, { routerAccountId: 'router_two', eligible: true },
    ] });
    f.services.reader.discoverIdentity = (_ctx, id) => ({ kind: 'ready', identity: { accountId: 'shared-workspace', userId: id } });
    assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
    const config = JSON.parse(fs.readFileSync(f.configPath));
    assert.equal(config.enrollments.length, 2);
    assert.notEqual(config.enrollments[0].enrollmentId, config.enrollments[1].enrollmentId);
    assert.notDeepEqual(config.enrollments[0].identity, config.enrollments[1].identity);
    config.enrollments[1].routerAccountId = config.enrollments[0].routerAccountId;
    const file = path.join(f.root, 'candidate.json');
    f.put(file, { schemaVersion: 1, config, compatibility: JSON.parse(fs.readFileSync(f.compatibilityPath)), reviewEvidence: 'persistence-review' });
    const before = [f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
    const out = await f.call({ name: 'maintain', file });
    assert.equal(out.reason, 'invalid_enrollment'); assert.equal(out.exitCode, 2);
    assert.deepEqual([f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before);
  } finally { f.cleanup(); }
});


test('B21 removal acquires lifecycle then work and syncs pending intent before the first deletion', async () => {
  const f = fixture();
  try {
    assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
    fs.writeFileSync(path.join(f.companionRoot, 'warmup.mjs'), '// synthetic', { mode: 0o600 });
    const rootStat = fs.lstatSync(f.companionRoot), acquired = [];
    let pendingSynced = false, reached = false;
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'mkdirSync') return (file, options) => { if (file.endsWith('.lock')) acquired.push(path.basename(file)); return fs.mkdirSync(file, options); };
      if (key === 'fsyncSync') return fd => {
        fs.fsyncSync(fd);
        const stat = fs.fstatSync(fd);
        if (stat.isDirectory() && stat.dev === rootStat.dev && stat.ino === rootStat.ino && f.state().removalPending) pendingSynced = true;
      };
      return target[key];
    } });
    f.services.fault = point => {
      if (point !== 'before_remove_warmup.mjs') return;
      reached = true;
      assert.deepEqual(acquired, ['lifecycle.lock', 'work.lock']);
      assert.equal(pendingSynced, true);
      assert.equal(f.state().removalPending, true);
      throw Error('SYNTHETIC_STOP_BEFORE_DELETE');
    };
    assert.equal((await f.call({ name: 'remove' })).exitCode, 2);
    assert.equal(reached, true);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'warmup.mjs')), true);
  } finally { f.cleanup(); }
});

test('B23 ambiguous scheduled or manual removal runner never permits termination or deletion', async () => {
  for (const runner of [{ pid: 9999, startId: 'unknown', scheduled: true, installationId: 'other-install' }, { pid: 4242, startId: 'synthetic-start', scheduled: false, installationId: 'install_persistence_01' }]) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      const before = [f.markerPath, f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
      f.services.jobs.runner = async () => runner;
      let terminations = 0;
      f.services.processes.terminate = async () => { terminations++; };
      const out = await f.call({ name: 'remove' });
      assert.equal(out.exitCode, 2); assert.equal(out.reason, 'runner_ownership_unknown');
      assert.equal(terminations, 0);
      assert.deepEqual([f.markerPath, f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before);
    } finally { f.cleanup(); }
  }
});

test('B07 interrupted initialization retains its original ID and never adopts a replacement ID by rescanning', async () => {
  const f = fixture();
  try {
    const originalId = JSON.parse(fs.readFileSync(f.markerPath)).installationId;
    f.services.fault = point => { if (point === 'after_instance.json_rename') throw Error('SYNTHETIC_INITIALIZATION_STOP'); };
    assert.equal((await f.call({ name: 'setup' })).exitCode, 2);
    delete f.services.fault;
    const marker = JSON.parse(fs.readFileSync(f.markerPath));
    assert.equal(marker.installationId, originalId); assert.equal(marker.phase, 'in_progress');
    const scans = f.scans();
    marker.installationId = 'replacement_install_01'; f.put(f.markerPath, marker);
    const replaced = fs.readFileSync(f.markerPath, 'utf8');
    assert.equal((await f.call({ name: 'setup' })).exitCode, 2);
    assert.equal(f.scans(), scans); assert.equal(fs.readFileSync(f.markerPath, 'utf8'), replaced);
    assert.equal(fs.existsSync(f.configPath), false); assert.equal(fs.existsSync(f.statePath), false);
  } finally { f.cleanup(); }
});


test('B16 tick and enable reject changed accepted bytes or missing digests before dispatch or job mutation', async () => {
  for (const command of [{ name: 'tick' }, { name: 'schedule', action: 'enable' }]) for (const damage of ['config_bytes', 'compatibility_bytes', 'config_digest', 'compatibility_digest']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      if (command.name === 'tick') assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
      if (damage.endsWith('_bytes')) fs.appendFileSync(damage === 'config_bytes' ? f.configPath : f.compatibilityPath, ' ');
      else { const state = f.state(); delete state[damage === 'config_digest' ? 'configDigest' : 'compatibilityDigest']; f.put(f.statePath, state); }
      const before = [f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
      const sends = f.sends(); let mutations = 0;
      f.services.jobs.enable = f.services.jobs.disable = async () => { mutations++; };
      const out = await f.call(command);
      assert.equal(out.exitCode, 2, `${command.name}/${damage}`);
      assert.equal(out.reason, damage.endsWith('_bytes') ? 'digest_mismatch' : 'invalid_state');
      assert.equal(f.sends(), sends); assert.equal(mutations, 0);
      assert.deepEqual([f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before);
    } finally { f.cleanup(); }
  }
});

test('B12 unavailable accepted-config reader cannot authorize recovery or repair', async () => {
  const f = fixture();
  try {
    assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
    const before = [f.markerPath, f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8'));
    const stat = fs.lstatSync(f.companionRoot); let reads = 0, repairs = 0;
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'openSync') return (file, flags, mode) => {
        if (file === f.configPath) { reads++; throw Object.assign(Error('SYNTHETIC_UNAVAILABLE'), { code: 'EACCES' }); }
        return fs.openSync(file, flags, mode);
      };
      if (key === 'renameSync') return (from, to) => { if ([f.configPath, f.compatibilityPath, f.statePath].includes(to)) repairs++; return fs.renameSync(from, to); };
      return target[key];
    } });
    const out = await recoverInstance(f.context, f.services, { installationId: 'install_persistence_01', rootDev: stat.dev, rootIno: stat.ino, skipThrough: '2026-11-12T18:00', reviewEvidence: 'synthetic explicit recovery', backupPath: null });
    assert.equal(out.exitCode, 2); assert.ok(reads > 0); assert.equal(repairs, 0);
    assert.deepEqual([f.markerPath, f.configPath, f.compatibilityPath, f.statePath].map(file => fs.readFileSync(file, 'utf8')), before);
  } finally { f.cleanup(); }
});


test('B20 lifecycle orphans block normal work and only proven-dead ownership permits explicit disabled recovery', async () => {
  for (const status of ['dead', 'unknown', 'alive']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      const dir = path.join(f.companionRoot, 'lifecycle.lock'); fs.mkdirSync(dir, { mode: 0o700 });
      const owner = { pid: 9999, startId: 'prior-start', nonce: 'owned-orphan', installationId: 'install_persistence_01' };
      const file = path.join(dir, 'owner.json'); f.put(file, owner); const bytes = fs.readFileSync(file, 'utf8');
      f.services.processes.inspect = () => status;
      assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 3);
      assert.equal(fs.readFileSync(file, 'utf8'), bytes);
      const root = fs.lstatSync(f.companionRoot);
      const out = await recoverInstance(f.context, f.services, { installationId: 'install_persistence_01', rootDev: root.dev, rootIno: root.ino, skipThrough: '2026-11-12T18:00', reviewEvidence: 'explicit synthetic orphan review', backupPath: null });
      if (status === 'dead') {
        assert.equal(out.reason, 'recovered_disabled'); assert.equal(fs.existsSync(dir), false);
        assert.equal(f.state().scheduleEnabled, false); assert.deepEqual(f.state().pilots, {});
      } else {
        assert.equal(out.exitCode, 2); assert.equal(out.reason, 'lock_owner_not_proven_dead');
        assert.equal(fs.readFileSync(file, 'utf8'), bytes);
      }
    } finally { f.cleanup(); }
  }
});


for (const resuming of [false, true]) test(`B21/B22 ${resuming ? 'resumed' : 'ordinary'} removal recovers a terminated runner guard only under lifecycle exclusion`, async () => {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      if (resuming) { const state = f.state(); state.removalPending = true; f.put(f.statePath, state); }
      const root = fs.lstatSync(f.companionRoot);
      const runner = { pid: 9999, startId: 'scheduled-start', nonce: 'scheduled-owner', installationId: 'install_persistence_01', scheduled: true };
      const dir = path.join(f.companionRoot, 'work.lock'); fs.mkdirSync(dir, { mode: 0o700 }); f.put(path.join(dir, 'owner.json'), runner);
      let ended = false, inspected = false;
      f.services.jobs.inspect = async () => {
        if (!inspected) { assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), true); assert.equal(fs.existsSync(dir), true); inspected = true; }
        return 'absent';
      };
      f.services.jobs.runner = async () => ended ? null : runner;
      f.services.processes.inspect = owner => owner.pid === runner.pid ? ended ? 'dead' : 'alive' : 'alive';
      f.services.processes.wait = async (_owner, ms) => ms === 5000 && ended;
      f.services.processes.terminate = async owner => { assert.equal(owner.pid, runner.pid); ended = true; };
      const out = resuming ? await resumeRemoval(f.context, f.services, { installationId: 'install_persistence_01', rootDev: root.dev, rootIno: root.ino, reviewEvidence: 'explicit synthetic continuation' }) : await f.call({ name: 'remove' });
      assert.equal(out.exitCode, 0, JSON.stringify(out)); assert.equal(inspected, true); assert.equal(ended, true);
      assert.equal(fs.existsSync(f.companionRoot), false);
    } finally { f.cleanup(); }
});


test('B21 removal preserves live, unknown and malformed manual work guards after scheduled runner shutdown', async () => {
  for (const status of ['alive', 'unknown', 'malformed']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      const runner = { pid: 9999, startId: 'scheduled-start', installationId: 'install_persistence_01', scheduled: true };
      const dir = path.join(f.companionRoot, 'work.lock'); fs.mkdirSync(dir, { mode: 0o700 });
      const ownerFile = path.join(dir, 'owner.json');
      f.put(ownerFile, status === 'malformed' ? {} : { pid: 9998, startId: 'manual-start', nonce: 'manual-owner', installationId: 'install_persistence_01' });
      const bytes = fs.readFileSync(ownerFile, 'utf8');
      let ended = false;
      f.services.jobs.runner = async () => ended ? null : runner;
      f.services.processes.inspect = owner => owner.pid === runner.pid ? ended ? 'dead' : 'alive' : status;
      f.services.processes.wait = async (_owner, ms) => ms === 5000 && ended;
      f.services.processes.terminate = async owner => { assert.equal(owner.pid, runner.pid); ended = true; };
      const out = await f.call({ name: 'remove' });
      assert.equal(ended, true);
      assert.equal(out.exitCode, status === 'alive' ? 3 : 2, JSON.stringify(out));
      assert.equal(out.reason, status === 'alive' ? 'lock_busy' : status === 'unknown' ? 'lock_owner_not_proven_dead' : 'lock_owner_unknown');
      assert.equal(fs.readFileSync(ownerFile, 'utf8'), bytes);
      assert.equal(f.state().removalPending, false);
      assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), false);
    } finally { f.cleanup(); }
  }
});


test('B20 captured lifecycle crash checkpoints require explicit disabled recovery without replay', async () => {
  for (const cut of ['enable_locked', 'enable_loaded', 'enable_durable', 'disable_locked', 'disable_unloaded', 'disable_runner_ended', 'disable_durable']) {
    const f = fixture();
    try {
      assert.equal((await f.call({ name: 'setup' })).exitCode, 0);
      assert.equal((await f.call({ name: 'run' })).exitCode, 0);
      const disabling = cut.startsWith('disable_');
      if (disabling) assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 0);
      const saved = path.join(f.root, 'crash-snapshot');
      let captured = false, savedJob, runnerAlive = disabling;
      const capture = at => {
        if (cut !== at || captured) return;
        assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock', 'owner.json')), true);
        for (const name of ['lifecycle', 'work']) {
          const dir = path.join(f.companionRoot, `${name}.lock`);
          if (fs.existsSync(dir)) {
            assert.equal(fs.lstatSync(dir).mode & 0o777, 0o700);
            assert.equal(fs.lstatSync(path.join(dir, 'owner.json')).mode & 0o777, 0o600);
          }
        }
        assert.equal(f.state().scheduleEnabled, ['enable_durable', 'disable_locked', 'disable_unloaded', 'disable_runner_ended'].includes(cut), cut);
        assert.equal(jobs.binding !== null, ['enable_loaded', 'enable_durable', 'disable_locked'].includes(cut), cut);
        fs.cpSync(f.companionRoot, saved, { recursive: true });
        savedJob = structuredClone(f.services.jobs.binding); captured = true;
      };
      const jobs = f.services.jobs;
      const inspect = jobs.inspect.bind(jobs), enable = jobs.enable.bind(jobs), disable = jobs.disable.bind(jobs);
      jobs.inspect = async binding => { capture(disabling ? 'disable_locked' : 'enable_locked'); return inspect(binding); };
      jobs.enable = async binding => { await enable(binding); capture('enable_loaded'); };
      jobs.disable = async binding => { await disable(binding); capture('disable_unloaded'); };
      const runner = { pid: 9999, startId: 'scheduled-start', nonce: 'scheduled-nonce', installationId: 'install_persistence_01', scheduled: true };
      jobs.runner = async () => runnerAlive ? runner : null;
      f.services.processes.inspect = owner => owner.pid === runner.pid && runnerAlive ? 'alive' : 'dead';
      f.services.processes.wait = async () => { runnerAlive = false; capture('disable_runner_ended'); return true; };
      f.services.fault = at => { if (at === 'after_state.json_rename') capture(disabling ? 'disable_durable' : 'enable_durable'); };
      assert.equal((await f.call({ name: 'schedule', action: disabling ? 'disable' : 'enable', now: disabling })).exitCode, 0, cut);
      assert.equal(captured, true, cut);
      delete f.services.fault;
      jobs.inspect = inspect; jobs.enable = enable; jobs.disable = disable;
      // Restore captured durable bytes and orphan guards, not a real process-kill or host launchd trial.
      for (const name of fs.readdirSync(f.companionRoot)) fs.rmSync(path.join(f.companionRoot, name), { recursive: true });
      for (const name of fs.readdirSync(saved)) fs.cpSync(path.join(saved, name), path.join(f.companionRoot, name), { recursive: true });
      for (const name of ['lifecycle', 'work']) {
        const dir = path.join(f.companionRoot, `${name}.lock`);
        if (fs.existsSync(dir)) fs.chmodSync(dir, 0o700);
      }
      jobs.binding = savedJob; runnerAlive = false;
      const before = f.state(), sends = f.sends(), scans = f.scans();
      const lockFile = path.join(f.companionRoot, 'lifecycle.lock', 'owner.json'), ownerBytes = fs.readFileSync(lockFile, 'utf8');
      assert.equal((await f.call({ name: 'schedule', action: 'enable' })).exitCode, 3, cut);
      assert.equal(fs.readFileSync(lockFile, 'utf8'), ownerBytes, cut);
      assert.deepEqual(f.state(), before, cut);
      const root = fs.lstatSync(f.companionRoot);
      const result = await recoverInstance(f.context, f.services, { installationId: 'install_persistence_01', rootDev: root.dev, rootIno: root.ino,
        skipThrough: '2026-11-12T18:00', reviewEvidence: `synthetic captured checkpoint ${cut}`, backupPath: null });
      assert.equal(result.reason, 'recovered_disabled', `${cut}: ${JSON.stringify(result)}`);
      assert.equal(f.state().scheduleEnabled, false, cut); assert.equal(jobs.binding, null, cut);
      assert.deepEqual(f.state().history, before.history, cut);
      assert.deepEqual(f.state().reservations, before.reservations, cut);
      assert.deepEqual(f.state().pilots, {}, cut);
      assert.equal(f.sends(), sends, cut); assert.equal(f.scans(), scans, cut);
      for (const name of ['lifecycle', 'work']) assert.equal(fs.existsSync(path.join(f.companionRoot, `${name}.lock`)), false, cut);
    } finally { f.cleanup(); }
  }
});
