import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { makeFixture } from './helpers.mjs';
import { runCommand, hostServices, recoverInstance, resumeRemoval, latestUsage, MAX_USAGE_ACCOUNTS, MUTEX_MARK } from '../runtime.mjs';
import { execute } from '../warmup.mjs';

function prepared() {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot, poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot, switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const installationId = 'install_synthetic_01';
  fs.writeFileSync(f.markerPath, JSON.stringify({ schemaVersion: 1, installationId, phase: 'uninitialized', paths, plistPath: f.plistPath }), { mode: 0o600 });
  const sourceDigests = Object.fromEntries(Array.from({ length: 13 }, (_, i) => [`src/contract-${i}.mjs`, crypto.createHash('sha256').update(`fixture-${i}`).digest('hex')]));
  fs.writeFileSync(path.join(f.companionRoot, 'compatibility.json'), JSON.stringify({ schemaVersion: 1, reviewedRevision: 'a'.repeat(40), sourceDigests, adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'fixture', semantics: 'equivalent' }), { mode: 0o600 });
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', accounts: [], coordination: 'idle' }),
    discoverIdentity: () => ({ kind: 'blocked', reason: 'none' }),
    checkCompatibility: () => ({ kind: 'ready' }),
  };
  const context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
  return { f, context, call: command => runCommand(command, context, f.services) };
}

test('B07 initialize-boundaries and B08 repeated setup preserve frozen state', async () => {
  const { f, call } = prepared();
  try {
    const first = await call({ name: 'setup' });
    assert.equal(first.exitCode, 0, JSON.stringify(first));
    const state = fs.readFileSync(f.statePath, 'utf8');
    assert.equal((await call({ name: 'setup' })).reason, 'already_initialized');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), state);
    assert.equal((await call({ name: 'run' })).exitCode, 4);
  } finally { f.cleanup(); }
});

test('B07 setup crash after marker in_progress never rescans', async () => {
  const { f, call } = prepared();
  try {
    let scans = 0;
    f.services.reader.readRegistry = () => { scans++; throw new Error('fixture_fault'); };
    assert.equal((await call({ name: 'setup' })).exitCode, 2);
    assert.equal((await call({ name: 'setup' })).exitCode, 2);
    assert.equal(scans, 1);
    assert.equal(JSON.parse(fs.readFileSync(f.markerPath)).phase, 'in_progress');
  } finally { f.cleanup(); }
});

test('B08 missing config with surviving state blocks setup and run', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    fs.unlinkSync(f.configPath);
    assert.equal((await call({ name: 'setup' })).exitCode, 2);
    assert.equal((await call({ name: 'run' })).exitCode, 2);
  } finally { f.cleanup(); }
});

test('B10 lock contention precedes valid empty run', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    fs.mkdirSync(path.join(f.companionRoot, 'work.lock'), { mode: 0o700 });
    assert.equal((await call({ name: 'run' })).exitCode, 3);
  } finally { f.cleanup(); }
});

test('B10 persisted owner identity and lifecycle-before-work acquisition', async () => {
  const { f, call } = prepared();
  try {
    const acquired = [];
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key !== 'mkdirSync') return target[key];
      return (name, options) => {
        if (name.endsWith('.lock')) acquired.push(path.basename(name));
        return fs.mkdirSync(name, options);
      };
    } });
    f.services.reader.readRegistry = () => {
      for (const name of ['lifecycle', 'work']) {
        const dir = path.join(f.companionRoot, `${name}.lock`);
        const owner = JSON.parse(fs.readFileSync(path.join(dir, 'owner.json')));
        assert.deepEqual([owner.pid, owner.startId, owner.installationId], [f.owner.pid, f.owner.startId, 'install_synthetic_01']);
        assert.match(owner.nonce, /^[a-f0-9-]{36}$/);
        assert.equal(fs.lstatSync(dir).mode & 0o777, 0o700);
      }
      return { kind: 'ready', accounts: [], coordination: 'idle' };
    };
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    assert.deepEqual(acquired.slice(0, 2), ['lifecycle.lock', 'work.lock']);
  } finally { f.cleanup(); }
});

test('B10 old live, unknown, and reused-PID owners are never age-stolen', async () => {
  for (const status of ['alive', 'unknown', 'reused-pid']) {
    const { f, call } = prepared();
    try {
      assert.equal((await call({ name: 'setup' })).exitCode, 0);
      const dir = path.join(f.companionRoot, 'work.lock');
      fs.mkdirSync(dir, { mode: 0o700 });
      const owner = { ...f.owner, startId: status === 'reused-pid' ? 'prior-process-start' : f.owner.startId, installationId: 'install_synthetic_01' };
      fs.writeFileSync(path.join(dir, 'owner.json'), JSON.stringify(owner), { mode: 0o600 });
      fs.utimesSync(dir, new Date(0), new Date(0));
      f.services.processes.inspect = () => status === 'reused-pid' ? 'unknown' : status;
      const blocked = await call({ name: 'run' });
      assert.equal(blocked.exitCode, 3, status);
      assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, 'owner.json'))), owner, status);
    } finally { f.cleanup(); }
  }
});

test('E busy lock precedes unknown selector and no-work; compatibility precedes no-work', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const lock = path.join(f.companionRoot, 'work.lock');
    fs.mkdirSync(lock, { mode: 0o700 });
    assert.equal((await call({ name: 'run', account: 'missing_enrollment' })).exitCode, 3);
    fs.rmdirSync(lock);
    assert.equal((await call({ name: 'run', account: 'missing_enrollment' })).reason, 'unknown_enrollment');
    f.services.reader.checkCompatibility = () => ({ kind: 'blocked' });
    const blocked = await call({ name: 'run' });
    assert.equal(blocked.exitCode, 2);
    assert.deepEqual([blocked.selected, blocked.attempted, blocked.results], [0, 0, []]);
  } finally { f.cleanup(); }
});

test('B host capability factory is inert and uses only fixed command paths', () => {
  const { f } = prepared();
  try {
    const calls = [];
    const services = hostServices(f.companionRoot, (file, args) => {
      calls.push([file, args]);
      if (file === '/bin/ps') return 'Thu Nov 12 22:00:00 2026 node synthetic';
      if (file === '/bin/ls') return '-rw-------  1 user staff 1 Nov 12 12:34 synthetic';
      throw Error('unexpected host command');
    });
    assert.deepEqual(calls, []);
    assert.equal(services.processes.current.pid, process.pid);
    assert.deepEqual(calls.map(([file]) => file), ['/bin/ps']);
    assert.equal(services.acl(f.markerPath), true);
    assert.deepEqual(calls.map(([file]) => file), ['/bin/ps', '/bin/ls']);
  } finally { f.cleanup(); }
});

test('B host source inspection uses read-only fixed Git commands and narrow paths', () => {
  const { f } = prepared();
  try {
    const calls = [];
    const services = hostServices(f.companionRoot, (file, args) => {
      calls.push([file, args]);
      if (file !== '/usr/bin/git') throw Error('unexpected command');
      return args.includes('rev-parse') ? `${'a'.repeat(40)}\n` : '';
    });
    const observed = services.source.inspect(f.routerRoot, ['src/contract-0.mjs']);
    assert.deepEqual(observed, { revision: 'a'.repeat(40), dirtyPaths: [] });
    assert.equal(calls.length, 2);
    for (const [file, args] of calls) {
      assert.equal(file, '/usr/bin/git');
      assert.ok(args.includes('--no-optional-locks'));
      assert.ok(args.includes('core.fsmonitor=false'));
      assert.ok(args.includes('core.hooksPath=/dev/null'));
      assert.equal(args[args.indexOf('-C') + 1], f.routerRoot);
      assert.equal(args.includes('fetch'), false);
    }
    assert.deepEqual(calls[1][1].slice(-2), ['--', 'src/contract-0.mjs']);
  } finally { f.cleanup(); }
});

test('B host job binding writes only exact synthetic plist through stubbed launchctl', async () => {
  const { f } = prepared();
  try {
    let loaded = false;
    const calls = [];
    const services = hostServices(f.companionRoot, (file, args) => {
      calls.push([file, args]);
      if (file === '/bin/ls') return 'drwx------  1 user staff 1 Nov 12 12:34 synthetic';
      if (file !== '/bin/launchctl') throw Error('unexpected command');
      if (args[0] === 'print') {
        if (loaded) return `gui/501/local.codex-router-warmup = {\n\tpath = ${f.plistPath}\n\tprogram = ${services.context.nodePath}\n\targuments = {\n\t\t${services.context.nodePath}\n\t\t${services.context.scriptPath}\n\t\ttick\n\t}\n}`;
        throw Object.assign(Error('absent'), { stderr: 'Could not find service' });
      }
      if (args[0] === 'bootstrap') { loaded = true; return ''; }
      if (args[0] === 'bootout') { loaded = false; return ''; }
      throw Error('unexpected launchctl operation');
    }, () => true);
    const stat = fs.lstatSync(f.companionRoot);
    const binding = { root: f.companionRoot, dev: stat.dev, ino: stat.ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: services.context.nodePath, scriptPath: services.context.scriptPath };
    await services.jobs.enable(binding);
    assert.equal(await services.jobs.inspect(binding), 'loaded');
    assert.ok(fs.readFileSync(f.plistPath, 'utf8').includes('<string>tick</string>'));
    const plist = fs.readFileSync(f.plistPath, 'utf8');
    assert.ok(plist.includes(`<key>Label</key><string>${binding.label}</string>`));
    assert.ok(plist.includes(`<key>ProgramArguments</key><array><string>${binding.nodePath}</string><string>${binding.scriptPath}</string><string>tick</string></array>`));
    assert.ok(plist.includes(`<key>WorkingDirectory</key><string>${f.companionRoot}</string>`));
    assert.ok(plist.includes('<key>StartInterval</key><integer>30</integer>'));
    assert.ok(plist.includes('<key>RunAtLoad</key><true/>'));
    assert.ok(plist.includes('<key>StandardOutPath</key><string>/dev/null</string>'));
    assert.ok(plist.includes('<key>StandardErrorPath</key><string>/dev/null</string>'));
    assert.doesNotMatch(plist, /KeepAlive|EnvironmentVariables|\/bin\/(?:sh|bash|zsh)|AccessToken|Authorization/);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'launchd.log')), false);
    await services.jobs.disable(binding);
    await services.jobs.remove(binding);
    assert.equal(fs.existsSync(f.plistPath), false);
    assert.ok(calls.filter(([file]) => file === '/bin/launchctl').every(([, args]) => ['print', 'bootstrap', 'bootout'].includes(args[0])));
  } finally { f.cleanup(); }
});

test('B18 missing runtime refuses bootstrap and leaves no owned plist', async () => {
  const { f } = prepared();
  try {
    const calls = [];
    const services = hostServices(f.companionRoot, (file, args) => {
      calls.push([file, args]);
      if (file === '/bin/ls') return 'drwx------  1 user staff 1 Nov 12 12:34 synthetic';
      if (file === '/bin/launchctl' && args[0] === 'print') throw Object.assign(Error('absent'), { stderr: 'Could not find service' });
      throw Error('unexpected host command');
    }, () => { throw Error('runtime_missing'); });
    const { dev, ino } = fs.lstatSync(f.companionRoot);
    const binding = { root: f.companionRoot, dev, ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: services.context.nodePath, scriptPath: services.context.scriptPath };
    await assert.rejects(services.jobs.enable(binding));
    assert.equal(fs.existsSync(f.plistPath), false);
    assert.equal(calls.some(([file, args]) => file === '/bin/launchctl' && args[0] === 'bootstrap'), false);
  } finally { f.cleanup(); }
});

test('B18 schedule rolls a partially loaded bootstrap back without touching unrelated jobs', async () => {
  const { f, context, call } = prepared();
  try {
    const unrelated = path.join(f.launchAgents, 'unrelated.plist');
    fs.writeFileSync(unrelated, 'keep', { mode: 0o600 });
    let loaded = false;
    const calls = [];
    const services = hostServices(f.companionRoot, (file, args) => {
      calls.push([file, args]);
      if (file === '/bin/ls') return 'drwx------  1 user staff 1 Nov 12 12:34 synthetic';
      if (file !== '/bin/launchctl') throw Error('unexpected host command');
      if (args[0] === 'print') {
        if (!loaded) throw Object.assign(Error('absent'), { stderr: 'Could not find service' });
        return `gui/501/local.codex-router-warmup = {\n\tpath = ${f.plistPath}\n\tprogram = ${services.context.nodePath}\n\targuments = {\n\t\t${services.context.nodePath}\n\t\t${services.context.scriptPath}\n\t\ttick\n\t}\n}`;
      }
      if (args[0] === 'bootstrap') { loaded = true; throw Error('synthetic_partial_bootstrap'); }
      if (args[0] === 'bootout') { loaded = false; return ''; }
      throw Error('unexpected launchctl operation');
    }, () => true);
    context.scriptPath = services.context.scriptPath;
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    f.services.reader.readCredential = () => ({ kind: 'ready', expiresAt: 4102444800000, snapshot: {} });
    f.services.reader.revalidate = () => ({ kind: 'ready' });
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    assert.equal((await call({ name: 'run' })).exitCode, 0);
    f.services.jobs = services.jobs;
    const { dev, ino } = fs.lstatSync(f.companionRoot);
    const binding = { root: f.companionRoot, dev, ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: services.context.nodePath, scriptPath: services.context.scriptPath };
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 2);
    assert.equal(loaded, false);
    assert.equal(await services.jobs.inspect(binding), 'absent');
    assert.equal(await services.jobs.runner(binding), null);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    // An inactive owned plist is not an enabled job; deleting it is explicit removal.
    await services.jobs.remove(binding);
    assert.equal(fs.existsSync(f.plistPath), false);
    assert.equal(fs.readFileSync(unrelated, 'utf8'), 'keep');
    assert.ok(calls.some(([file, args]) => file === '/bin/launchctl' && args[0] === 'bootout' && args[2] === binding.plistPath));
  } finally { f.cleanup(); }
});

test('B09 explicit enrollment retains identity and starts without pilot', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    assert.equal((await call({ name: 'enroll', account: 'router_one' })).reason, 'enrolled');
    const first = JSON.parse(fs.readFileSync(f.configPath));
    assert.equal(first.enrollments.length, 1);
    assert.equal(first.enrollments[0].model, 'gpt-6-luna');
    assert.deepEqual(JSON.parse(fs.readFileSync(f.statePath)).pilots, {});
    assert.equal((await call({ name: 'enroll', account: 'router_one' })).reason, 'already_enrolled');
    assert.equal(fs.readFileSync(f.configPath, 'utf8'), JSON.stringify(first));
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_two', userId: 'user_one' } });
    assert.equal((await call({ name: 'enroll', account: 'router_one' })).reason, 'identity_changed');
    assert.equal(fs.readFileSync(f.configPath, 'utf8'), JSON.stringify(first));
    assert.deepEqual(JSON.parse(fs.readFileSync(f.configPath)).enrollments[0].identity, { accountId: 'workspace_one', userId: 'user_one' });
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).history.length, 0);
  } finally { f.cleanup(); }
});

test('E list distinguishes Router reference from enrolled selector and never reads credentials', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }, { routerAccountId: 'router_two', eligible: false }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    const enrolled = await call({ name: 'enroll', account: 'router_one' });
    f.services.reader.readCredential = () => { throw new Error('credential_read_forbidden'); };
    const listed = await call({ name: 'list' });
    assert.equal(listed.exitCode, 0);
    assert.deepEqual(listed.rows.map(a => a.routerAccountId), ['router_one', 'router_two']);
    assert.equal(listed.rows[0].enrollmentId, enrolled.enrollmentId);
    assert.equal(listed.rows[0].runCommand, `run --account ${enrolled.enrollmentId}`);
    assert.equal(listed.rows[1].enrollmentId, null);
    assert.equal(listed.rows[0].credentialFreshness, 'unknown');
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [] });
    const stale = await call({ name: 'list' });
    assert.deepEqual([stale.rows[0].registered, stale.rows[0].enrollmentId], [false, enrolled.enrollmentId]);
  } finally { f.cleanup(); }
});

test('D Gaza slot is admitted once and reservation survives replay', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    const enrolled = await call({ name: 'enroll', account: 'router_one' });
    const config = JSON.parse(fs.readFileSync(f.configPath));
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.pilots[JSON.stringify([enrolled.enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1])] = { at: f.services.clock.wall() };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    f.services.reader.readCredential = () => ({ kind: 'ready', snapshot: {}, identity: { accountId: 'workspace_one', userId: 'user_one' }, accessToken: 'synthetic', expiresAt: 4102444800000 });
    f.services.reader.revalidate = () => ({ kind: 'ready' });
    let dispatches = 0;
    f.services.probe = async () => { dispatches++; return { outcome: 'success', reason: 'marker_confirmed', dispatched: true }; };
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    const first = await call({ name: 'tick' });
    assert.equal(first.attempted, 1, JSON.stringify(first));
    assert.equal((await call({ name: 'tick' })).reason, 'slot_already_claimed');
    assert.equal(dispatches, 1);
    assert.equal(Object.keys(JSON.parse(fs.readFileSync(f.statePath)).reservations).length, 1);
  } finally { f.cleanup(); }
});

test('D wall-clock discontinuity after credential validation stops a due batch without dispatch', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    const enrolled = await call({ name: 'enroll', account: 'router_one' });
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.pilots[JSON.stringify([enrolled.enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1])] = { at: f.services.clock.wall() };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    await call({ name: 'schedule', action: 'enable' });
    f.services.reader.readCredential = () => { f.services.clock.setWall(f.services.clock.wall() + 5000); return { kind: 'ready', snapshot: {}, identity: { accountId: 'workspace_one', userId: 'user_one' }, accessToken: 'synthetic', expiresAt: 4102444800000 }; };
    f.services.reader.revalidate = () => ({ kind: 'ready' });
    f.services.probe = () => { throw new Error('late_probe'); };
    const tick = await call({ name: 'tick' });
    assert.deepEqual([tick.selected, tick.attempted, tick.results[0].reason], [1, 0, 'batch_deadline_or_clock']);
    assert.equal((await call({ name: 'tick' })).reason, 'slot_already_claimed');
  } finally { f.cleanup(); }
});

test('B remove contention preserves instance and foreign content leaves pending safety marker', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const lock = path.join(f.companionRoot, 'work.lock');
    fs.mkdirSync(lock, { mode: 0o700 });
    const ownerFile = path.join(lock, 'owner.json');
    const ownerBytes = JSON.stringify({ ...f.owner, installationId: 'install_synthetic_01' });
    fs.writeFileSync(ownerFile, ownerBytes, { mode: 0o600 });
    const originalInspect = f.services.processes.inspect;
    f.services.processes.inspect = () => 'alive';
    assert.equal((await call({ name: 'remove' })).exitCode, 3);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).removalPending, false);
    assert.equal(fs.readFileSync(ownerFile, 'utf8'), ownerBytes);
    fs.unlinkSync(ownerFile);
    fs.rmdirSync(lock);
    f.services.processes.inspect = originalInspect;
    fs.writeFileSync(path.join(f.companionRoot, 'foreign.txt'), 'keep', { mode: 0o600 });
    assert.equal((await call({ name: 'remove' })).reason, 'foreign_installation_content');
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).removalPending, true);
    assert.equal((await call({ name: 'run' })).reason, 'removal_pending');
    assert.equal(fs.readFileSync(path.join(f.companionRoot, 'foreign.txt'), 'utf8'), 'keep');
  } finally { f.cleanup(); }
});

test('B schedule disable --now waits without work lock and terminates only proven scheduled runner', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const data = JSON.parse(fs.readFileSync(f.statePath));
    data.scheduleEnabled = true;
    fs.writeFileSync(f.statePath, JSON.stringify(data), { mode: 0o600 });
    const binding = { root: f.companionRoot, dev: fs.lstatSync(f.companionRoot).dev, ino: fs.lstatSync(f.companionRoot).ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
    f.services.jobs.binding = binding;
    f.services.processes.setAlive(true);
    f.services.jobs.runner = async () => f.services.jobs.binding ? ({ ...f.owner, scheduled: true, installationId: 'install_synthetic_01' }) : null;
    const originalInspect = f.services.processes.inspect;
    f.services.processes.inspect = () => originalInspect(f.owner);
    const originalWait = f.services.processes.wait;
    const waits = [];
    f.services.processes.wait = async (...args) => {
      assert.equal(fs.existsSync(path.join(f.companionRoot, 'work.lock')), false);
      waits.push(args[1]);
      return originalWait(f.owner, ...args.slice(1));
    };
    const originalTerminate = f.services.processes.terminate;
    f.services.processes.terminate = () => originalTerminate(f.owner);
    const disabled = await call({ name: 'schedule', action: 'disable', now: true });
    assert.equal(disabled.exitCode, 0, JSON.stringify(disabled));
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    assert.equal(await f.services.jobs.inspect(binding), 'absent');
    assert.equal(await f.services.jobs.runner(binding), null);
    assert.deepEqual(waits, [50000, 5000]);
  } finally { f.cleanup(); }
});

test('A0 graceful pause waits for batch completion before durable disable and unload', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.scheduleEnabled = true;
    state.slots['2026-11-12T08:00'] = { enrollmentIds: ['synthetic'], claimedAt: f.services.clock.wall() };
    state.highWater = '2026-11-12T08:00';
    state.activeBatch = { slot: '2026-11-12T08:00', enrollmentIds: ['synthetic'] };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    const binding = { root: f.companionRoot, dev: fs.lstatSync(f.companionRoot).dev, ino: fs.lstatSync(f.companionRoot).ino, installationId: state.installationId, label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
    f.services.jobs.binding = binding;
    const work = path.join(f.companionRoot, 'work.lock');
    fs.mkdirSync(work, { mode: 0o700 });
    fs.writeFileSync(path.join(work, 'owner.json'), JSON.stringify({ ...f.owner, installationId: state.installationId }), { mode: 0o600 });
    let active = true;
    f.services.processes.inspect = () => active ? 'alive' : 'dead';
    f.services.jobs.runner = async () => active ? { ...f.owner, scheduled: true, installationId: state.installationId } : null;
    const disable = f.services.jobs.disable.bind(f.services.jobs);
    let unloads = 0;
    f.services.jobs.disable = async job => { assert.equal(active, false); assert.equal(fs.existsSync(work), false); unloads++; return disable(job); };
    const pause = call({ name: 'schedule', action: 'disable' });
    await new Promise(resolve => setTimeout(resolve, 70));
    assert.equal(unloads, 0);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, true);
    const done = JSON.parse(fs.readFileSync(f.statePath));
    done.activeBatch = null;
    done.lastSlotOutcome = { slot: '2026-11-12T08:00', outcome: 'success', at: f.services.clock.wall(), results: [] };
    fs.writeFileSync(f.statePath, JSON.stringify(done), { mode: 0o600 });
    fs.unlinkSync(path.join(work, 'owner.json'));
    fs.rmdirSync(work);
    active = false;
    const out = await pause;
    assert.equal(out.exitCode, 0, JSON.stringify(out));
    assert.equal(unloads, 1);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.statePath)).lastSlotOutcome, done.lastSlotOutcome);
  } finally { f.cleanup(); }
});

test('A0 graceful pause returns manual-work busy without unloading', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.scheduleEnabled = true;
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    const binding = { root: f.companionRoot, dev: fs.lstatSync(f.companionRoot).dev, ino: fs.lstatSync(f.companionRoot).ino, installationId: state.installationId, label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
    f.services.jobs.binding = binding;
    const work = path.join(f.companionRoot, 'work.lock');
    fs.mkdirSync(work, { mode: 0o700 });
    fs.writeFileSync(path.join(work, 'owner.json'), JSON.stringify({ ...f.owner, installationId: state.installationId }), { mode: 0o600 });
    f.services.processes.inspect = () => 'alive';
    const out = await call({ name: 'schedule', action: 'disable' });
    assert.equal(out.exitCode, 3);
    assert.equal(out.reason, 'lock_busy');
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, true);
    assert.equal(await f.services.jobs.inspect(binding), 'loaded');
  } finally { f.cleanup(); }
});

test('A0 CLI accepts only the explicit disable --now switch', async () => {
  assert.equal((await execute(['schedule', 'disable', '--now'])).json.reason, 'invalid_context');
  for (const argv of [['schedule', 'disable', '--bad'], ['schedule', 'disable', '--now', '--now'], ['schedule', 'enable', '--now']]) {
    assert.equal((await execute(argv)).json.reason, 'invalid_invocation');
  }
});

test('B maintenance crash after config rename blocks dispatch by old accepted digest', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    await call({ name: 'enroll', account: 'router_one' });
    const config = JSON.parse(fs.readFileSync(f.configPath));
    config.enrollments[0].model = 'gpt-6-sol';
    const compatibility = JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json')));
    const candidatePath = path.join(f.root, 'candidate.json');
    fs.writeFileSync(candidatePath, JSON.stringify({ schemaVersion: 1, config, compatibility, reviewEvidence: 'fixture' }), { mode: 0o600 });
    f.services.fault = point => { if (point === 'after_config.json_rename') throw Error('synthetic_crash'); };
    assert.equal((await call({ name: 'maintain', file: candidatePath })).exitCode, 2);
    delete f.services.fault;
    assert.equal((await call({ name: 'run' })).reason, 'digest_mismatch');
  } finally { f.cleanup(); }
});

test('B14 maintenance rejects candidate secret, request, schedule, identity, add/remove, relocation and size edits before writes', async () => {
  for (const kind of ['endpoint', 'secret', 'request', 'schedule', 'identity', 'add', 'remove', 'relocation', 'oversize', 'public']) {
    const { f, call } = prepared();
    try {
      await call({ name: 'setup' });
      f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
      f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
      assert.equal((await call({ name: 'enroll', account: 'router_one' })).exitCode, 0);
      const original = fs.readFileSync(f.configPath, 'utf8');
      const originalState = fs.readFileSync(f.statePath, 'utf8');
      const originalCompatibility = fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'), 'utf8');
      const config = JSON.parse(original);
      const compatibility = JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json')));
      if (kind === 'endpoint') config.endpoint = 'https://example.invalid';
      if (kind === 'secret') config.accessToken = 'synthetic-secret-canary';
      if (kind === 'request') config.requestContractVersion = 2;
      if (kind === 'schedule') config.schedule.times = ['09:00'];
      if (kind === 'identity') config.enrollments[0].identity.accountId = 'workspace_extra';
      if (kind === 'add') config.enrollments.push({ ...config.enrollments[0], enrollmentId: 'enr_extra', routerAccountId: 'router_extra', identity: { accountId: 'workspace_extra', userId: 'user_extra' } });
      if (kind === 'remove') config.enrollments.pop();
      if (kind === 'relocation') config.paths.sourceRoot = f.root;
      const candidate = { schemaVersion: 1, config, compatibility, reviewEvidence: 'fixture' };
      if (kind === 'oversize') candidate.padding = 'x'.repeat(1024 * 1024);
      const file = path.join(f.root, 'candidate.json');
      fs.writeFileSync(file, JSON.stringify(candidate), { mode: kind === 'public' ? 0o644 : 0o600 });
      assert.equal((await call({ name: 'maintain', file })).exitCode, 2, kind);
      assert.equal(fs.readFileSync(f.configPath, 'utf8'), original, kind);
      assert.equal(fs.readFileSync(f.statePath, 'utf8'), originalState, kind);
      assert.equal(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'), 'utf8'), originalCompatibility, kind);
    } finally { f.cleanup(); }
  }
});

test('B14 reviewed relocation still refuses companion root overlap before writes', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const before = fs.readFileSync(f.configPath, 'utf8');
    const state = fs.readFileSync(f.statePath, 'utf8');
    const config = JSON.parse(before);
    config.paths.sourceRoot = f.companionRoot;
    const compatibility = JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json')));
    compatibility.reviewEvidence = 'new explicit review';
    const candidate = path.join(f.root, 'candidate.json');
    fs.writeFileSync(candidate, JSON.stringify({ schemaVersion: 1, config, compatibility, reviewEvidence: compatibility.reviewEvidence }), { mode: 0o600 });
    assert.equal((await call({ name: 'maintain', file: candidate })).reason, 'ownership_overlap');
    assert.equal(fs.readFileSync(f.configPath, 'utf8'), before);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), state);
  } finally { f.cleanup(); }
});

test('B17 lifecycle and work contention block maintain, enable, tick and remove without mutation', async () => {
  for (const [name, lockName, command] of [
    ['maintain', 'lifecycle', { name: 'maintain', file: '/synthetic/candidate.json' }],
    ['enable', 'lifecycle', { name: 'schedule', action: 'enable' }],
    ['tick', 'work', { name: 'tick' }],
    ['remove', 'lifecycle', { name: 'remove' }],
  ]) {
    const { f, call } = prepared();
    try {
      await call({ name: 'setup' });
      const before = fs.readFileSync(f.statePath, 'utf8');
      fs.mkdirSync(path.join(f.companionRoot, `${lockName}.lock`), { mode: 0o700 });
      assert.equal((await call(command)).exitCode, 3, name);
      assert.equal(fs.readFileSync(f.statePath, 'utf8'), before, name);
    } finally { f.cleanup(); }
  }
});

test('B19 failed job unload never reports disabled or clears durable enabled flag', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const state = JSON.parse(fs.readFileSync(f.statePath)); state.scheduleEnabled = true;
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    f.services.jobs.inspect = async () => 'loaded';
    f.services.jobs.runner = async () => null;
    f.services.jobs.disable = async () => { throw Error('synthetic_unload_failed'); };
    assert.equal((await call({ name: 'schedule', action: 'disable', now: true })).exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, true);
  } finally { f.cleanup(); }
});

test('B19 ambiguous or manual runner is never terminated or reported disabled', async () => {
  for (const runner of [{ ...{ pid: 4242, startId: 'synthetic-start' }, scheduled: true, installationId: 'other-install' }, { pid: 4242, startId: 'synthetic-start', scheduled: false, installationId: 'install_synthetic_01' }]) {
    const { f, call } = prepared();
    try {
      assert.equal((await call({ name: 'setup' })).exitCode, 0);
      const state = JSON.parse(fs.readFileSync(f.statePath)); state.scheduleEnabled = true;
      fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
      f.services.jobs.runner = async () => runner;
      let terminated = 0;
      f.services.processes.terminate = async () => { terminated++; };
      const response = await call({ name: 'schedule', action: 'disable', now: true });
      assert.equal(response.exitCode, 2);
      assert.equal(terminated, 0);
      assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, true);
    } finally { f.cleanup(); }
  }
});

test('B21 partial removal after pending write cannot be reinitialized', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    let tripped = false;
    f.services.fault = point => { if (!tripped && point === 'after_state.json_rename') { tripped = true; throw Error('synthetic_removal_crash'); } };
    assert.equal((await call({ name: 'remove' })).exitCode, 2);
    delete f.services.fault;
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).removalPending, true);
    assert.equal((await call({ name: 'setup' })).reason, 'removal_pending');
    assert.equal((await call({ name: 'run' })).reason, 'removal_pending');
  } finally { f.cleanup(); }
});

test('B23 removal rejects symlinked executable after durable pending marker', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const outside = path.join(f.root, 'outside.txt');
    fs.writeFileSync(outside, 'keep', { mode: 0o600 });
    fs.symlinkSync(outside, path.join(f.companionRoot, 'warmup.mjs'));
    assert.equal((await call({ name: 'remove' })).exitCode, 2);
    assert.equal(fs.readFileSync(outside, 'utf8'), 'keep');
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).removalPending, true);
  } finally { f.cleanup(); }
});

test('B22 remove tolerates missing executable but never follows a replaced root', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    assert.equal((await call({ name: 'remove' })).exitCode, 0);
    assert.equal(fs.existsSync(f.companionRoot), false);
  } finally { f.cleanup(); }
  const second = prepared();
  const displaced = `${second.f.companionRoot}-old`;
  try {
    await second.call({ name: 'setup' });
    second.f.services.fault = point => {
      if (point !== 'before_remove_config.json') return;
      fs.renameSync(second.f.companionRoot, displaced);
      fs.mkdirSync(second.f.companionRoot, { mode: 0o700 });
      fs.writeFileSync(path.join(second.f.companionRoot, 'sentinel'), 'new', { mode: 0o600 });
    };
    assert.equal((await second.call({ name: 'remove' })).exitCode, 2);
    assert.equal(fs.readFileSync(path.join(second.f.companionRoot, 'sentinel'), 'utf8'), 'new');
  } finally { second.f.cleanup(); fs.rmSync(displaced, { recursive: true, force: true }); }
});

test('B23 removal success proves exact job, runner, root and plist absent while unrelated sentinels survive', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    fs.writeFileSync(f.plistPath, 'synthetic-owned-plist', { mode: 0o600 });
    const unrelated = path.join(f.root, 'unrelated-job-and-node');
    fs.writeFileSync(unrelated, 'keep', { mode: 0o600 });
    const binding = { root: f.companionRoot, dev: fs.lstatSync(f.companionRoot).dev, ino: fs.lstatSync(f.companionRoot).ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
    f.services.jobs.binding = binding;
    f.services.jobs.remove = async target => {
      assert.deepEqual(target, binding);
      fs.unlinkSync(f.plistPath);
    };
    const response = await call({ name: 'remove' });
    assert.equal(response.exitCode, 0, JSON.stringify(response));
    assert.equal(await f.services.jobs.inspect(binding), 'absent');
    assert.equal(await f.services.jobs.runner(binding), null);
    assert.equal(fs.existsSync(f.companionRoot), false);
    assert.equal(fs.existsSync(f.plistPath), false);
    assert.equal(fs.readFileSync(unrelated, 'utf8'), 'keep');
    assert.equal(fs.existsSync(f.routerRoot), true);
  } finally { f.cleanup(); }
});

test('B22 explicit removal resumes after executable and accepted config are gone', async () => {
  const { f, call, context } = prepared();
  try {
    await call({ name: 'setup' });
    const { dev, ino } = fs.lstatSync(f.companionRoot);
    const decision = { installationId: 'install_synthetic_01', rootDev: dev, rootIno: ino, reviewEvidence: 'synthetic reviewed removal' };
    fs.writeFileSync(path.join(f.companionRoot, 'warmup.mjs'), 'fixture', { mode: 0o600 });
    f.services.fault = point => { if (point === 'before_remove_compatibility.json') throw Error('synthetic_crash'); };
    assert.equal((await call({ name: 'remove' })).exitCode, 2);
    delete f.services.fault;
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'warmup.mjs')), false);
    assert.equal(fs.existsSync(f.configPath), false);
    for (const command of [{ name: 'setup' }, { name: 'run' }, { name: 'tick' }, { name: 'enroll', account: 'router_one' }, { name: 'schedule', action: 'enable' }]) {
      assert.equal((await call(command)).reason, 'removal_pending');
    }
    assert.equal((await call({ name: 'remove' })).reason, 'removal_pending');
    assert.equal((await resumeRemoval(context, f.services, decision)).exitCode, 0);
    assert.equal(fs.existsSync(f.companionRoot), false);
  } finally { f.cleanup(); }
});

test('B23 final state and marker deletion retain both guards and permit exact tail resume', async () => {
  for (const fault of ['before_remove_final_guard', 'before_remove_state.json', 'before_remove_instance.json']) {
    const { f, call, context } = prepared();
    try {
      await call({ name: 'setup' });
      const { dev, ino } = fs.lstatSync(f.companionRoot);
      const decision = { installationId: 'install_synthetic_01', rootDev: dev, rootIno: ino, reviewEvidence: 'synthetic reviewed removal' };
      f.services.fault = point => {
        if (point === 'before_remove_final_guard' || point === 'before_remove_state.json' || point === 'before_remove_instance.json') {
          assert.equal(fs.existsSync(path.join(f.companionRoot, 'work.lock')), true);
          assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), true);
        }
        if (point === fault) throw Error('synthetic_crash');
      };
      assert.equal((await call({ name: 'remove' })).exitCode, 2, fault);
      delete f.services.fault;
      assert.equal((await call({ name: 'setup' })).exitCode, 2);
      assert.equal((await resumeRemoval(context, f.services, decision)).exitCode, 0, fault);
      assert.equal(fs.existsSync(f.companionRoot), false);
    } finally { f.cleanup(); }
  }
});

test('B22/B23 wrong original identity, replacement and missing pending proof never delete', async () => {
  const { f, call, context } = prepared();
  const displaced = `${f.companionRoot}-old`;
  try {
    await call({ name: 'setup' });
    const { dev, ino } = fs.lstatSync(f.companionRoot);
    const decision = { installationId: 'install_synthetic_01', rootDev: dev, rootIno: ino, reviewEvidence: 'synthetic reviewed removal' };
    assert.equal((await resumeRemoval(context, f.services, decision)).reason, 'removal_not_pending');
    assert.equal((await resumeRemoval(context, f.services, { ...decision, installationId: 'wrong_id' })).reason, 'removal_identity_unknown');
    fs.renameSync(f.companionRoot, displaced);
    fs.mkdirSync(f.companionRoot, { mode: 0o700 });
    fs.writeFileSync(path.join(f.companionRoot, 'sentinel'), 'new', { mode: 0o600 });
    assert.equal((await resumeRemoval(context, f.services, decision)).reason, 'installation_replaced');
    assert.equal(fs.readFileSync(path.join(f.companionRoot, 'sentinel'), 'utf8'), 'new');
  } finally { f.cleanup(); fs.rmSync(displaced, { recursive: true, force: true }); }
});

test('B23 failed unload and repeated explicit cleanup preserve pending ownership', async () => {
  const { f, call, context } = prepared();
  try {
    await call({ name: 'setup' });
    const { dev, ino } = fs.lstatSync(f.companionRoot);
    const decision = { installationId: 'install_synthetic_01', rootDev: dev, rootIno: ino, reviewEvidence: 'synthetic reviewed removal' };
    f.services.fault = point => { if (point === 'before_remove_config.json') throw Error('synthetic_crash'); };
    assert.equal((await call({ name: 'remove' })).exitCode, 2);
    delete f.services.fault;
    f.services.jobs.inspect = async () => 'loaded';
    f.services.jobs.disable = async () => { throw Error('synthetic_unload_failure'); };
    assert.equal((await resumeRemoval(context, f.services, decision)).exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).removalPending, true);
    assert.equal(fs.existsSync(f.configPath), true);
    f.services.jobs.inspect = async () => 'absent';
    f.services.fault = point => { if (point === 'before_remove_config.json') throw Error('synthetic_repeat_failure'); };
    assert.equal((await resumeRemoval(context, f.services, decision)).exitCode, 2);
    delete f.services.fault;
    assert.equal((await resumeRemoval(context, f.services, decision)).exitCode, 0);
  } finally { f.cleanup(); }
});

test('B18 disable recovers only a proven-dead work guard after runner shutdown', async () => {
  for (const status of ['dead', 'unknown', 'alive']) {
    const { f, call } = prepared();
    try {
      await call({ name: 'setup' });
      const state = JSON.parse(fs.readFileSync(f.statePath)); state.scheduleEnabled = true;
      fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
      const dir = path.join(f.companionRoot, 'work.lock');
      fs.mkdirSync(dir, { mode: 0o700 });
      fs.writeFileSync(path.join(dir, 'owner.json'), JSON.stringify({ pid: 9999, startId: 'synthetic-old', installationId: state.installationId, nonce: 'old' }), { mode: 0o600 });
      f.services.processes.inspect = () => status;
      const result = await call({ name: 'schedule', action: 'disable' });
      assert.equal(result.exitCode, status === 'dead' ? 0 : status === 'alive' ? 3 : 2, status);
      assert.equal(fs.existsSync(dir), status !== 'dead', status);
      assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, status !== 'dead', status);
    } finally { f.cleanup(); }
  }
});

test('B19 enable rolls back a newly loaded exact job after final verification failure', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    const enrolled = await call({ name: 'enroll', account: 'router_one' });
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.pilots[JSON.stringify([enrolled.enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1])] = { at: f.services.clock.wall() };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    const inspect = f.services.jobs.inspect.bind(f.services.jobs);
    let loadedChecks = 0;
    f.services.jobs.inspect = async binding => {
      const current = await inspect(binding);
      if (current === 'loaded' && ++loadedChecks === 2) return 'absent';
      return current;
    };
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 2);
    assert.equal(await inspect(f.services.jobs.binding), 'absent');
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
  } finally { f.cleanup(); }
});

test('B18 failed enable clears its flag when the new exact job stays absent at final verification', async () => {
  const { f, call } = prepared();
  try {
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    f.services.reader.readCredential = () => ({ kind: 'ready', expiresAt: 4102444800000, snapshot: {} });
    f.services.reader.revalidate = () => ({ kind: 'ready' });
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    assert.equal((await call({ name: 'run' })).exitCode, 0);
    const inspect = f.services.jobs.inspect.bind(f.services.jobs);
    let checks = 0;
    f.services.jobs.inspect = async binding => ++checks >= 3 ? 'absent' : inspect(binding);
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
    assert.ok(checks >= 4);
  } finally { f.cleanup(); }
});

test('B18 failed repeat enable clears a vanished preloaded job without unloading it', async () => {
  const { f, call } = prepared();
  try {
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    f.services.reader.readCredential = () => ({ kind: 'ready', expiresAt: 4102444800000, snapshot: {} });
    f.services.reader.revalidate = () => ({ kind: 'ready' });
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    assert.equal((await call({ name: 'run' })).exitCode, 0);
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    let checks = 0, enables = 0, disables = 0;
    f.services.jobs.enable = async () => { enables++; };
    f.services.jobs.disable = async () => { disables++; };
    f.services.jobs.inspect = async () => ++checks >= 3 ? 'absent' : 'loaded';
    f.services.jobs.runner = async () => null;
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
    assert.equal(enables, 0); assert.equal(disables, 0);
  } finally { f.cleanup(); }
});

test('B18 failed enable reports sanitized incomplete rollback for inspection, unload and persistence faults', async () => {
  for (const failure of ['inspection', 'unload', 'persistence']) {
    const { f, call } = prepared();
    try {
      f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
      f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
      f.services.reader.readCredential = () => ({ kind: 'ready', expiresAt: 4102444800000, snapshot: {} });
      f.services.reader.revalidate = () => ({ kind: 'ready' });
      f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
      assert.equal((await call({ name: 'setup' })).exitCode, 0);
      assert.equal((await call({ name: 'run' })).exitCode, 0);
      const inspect = f.services.jobs.inspect.bind(f.services.jobs);
      const enable = f.services.jobs.enable.bind(f.services.jobs);
      let attempted = false;
      f.services.jobs.enable = async binding => {
        await enable(binding); attempted = true;
        throw new Error('CANARY_BOOTSTRAP_PRIVATE');
      };
      if (failure === 'inspection') f.services.jobs.inspect = async binding => {
        if (attempted) throw new Error('CANARY_INSPECTION_PRIVATE');
        return inspect(binding);
      };
      if (failure === 'unload') f.services.jobs.disable = async () => { throw new Error('CANARY_UNLOAD_PRIVATE'); };
      if (failure === 'persistence') f.services.fault = point => {
        if (attempted && point === 'before_state.json_create') throw new Error('CANARY_WRITE_PRIVATE');
      };
      const out = await call({ name: 'schedule', action: 'enable' });
      assert.equal(out.exitCode, 2, failure);
      assert.equal(out.reason, 'enable_rollback_incomplete', failure);
      assert.equal(JSON.stringify(out).includes('CANARY_'), false);
      assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    } finally { f.cleanup(); }
  }
});

test('B18 rollback restores a previously disabled flag without unloading a preloaded exact job', async () => {
  const { f, call } = prepared();
  try {
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    f.services.reader.readCredential = () => ({ kind: 'ready', expiresAt: 4102444800000, snapshot: {} });
    f.services.reader.revalidate = () => ({ kind: 'ready' });
    f.services.probe = async () => ({ outcome: 'success', reason: 'marker_confirmed', dispatched: true });
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    assert.equal((await call({ name: 'run' })).exitCode, 0);
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 0);
    const state = JSON.parse(fs.readFileSync(f.statePath)); state.scheduleEnabled = false;
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    let failed = false, disables = 0;
    f.services.jobs.disable = async () => { disables++; };
    f.services.fault = point => {
      if (!failed && point === 'after_state.json_rename') { failed = true; throw new Error('CANARY_AFTER_COMMIT'); }
    };
    assert.equal((await call({ name: 'schedule', action: 'enable' })).exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    assert.equal(await f.services.jobs.inspect(f.services.jobs.binding), 'loaded');
    assert.equal(disables, 0);
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
  } finally { f.cleanup(); }
});

test('B20 concurrent enable and disable serialize on lifecycle guard in both orders', async () => {
  for (const firstAction of ['enable', 'disable']) {
    const { f, call } = prepared();
    try {
      await call({ name: 'setup' });
      if (firstAction === 'enable') {
        f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
        f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
        const enrolled = await call({ name: 'enroll', account: 'router_one' });
        const state = JSON.parse(fs.readFileSync(f.statePath));
        state.pilots[JSON.stringify([enrolled.enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1])] = { at: f.services.clock.wall() };
        fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
      } else {
        const state = JSON.parse(fs.readFileSync(f.statePath)); state.scheduleEnabled = true;
        fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
      }
      let entered;
      const started = new Promise(resolve => { entered = resolve; });
      let unblock;
      const blocked = new Promise(resolve => { unblock = resolve; });
      const method = firstAction === 'enable' ? 'enable' : 'disable';
      const original = f.services.jobs[method].bind(f.services.jobs);
      f.services.jobs[method] = async binding => { entered(); await blocked; return original(binding); };
      if (firstAction === 'disable') {
        const binding = { root: f.companionRoot, dev: fs.lstatSync(f.companionRoot).dev, ino: fs.lstatSync(f.companionRoot).ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath: '/synthetic/warmup.mjs' };
        f.services.jobs.binding = binding;
      }
      const first = call({ name: 'schedule', action: firstAction });
      await started;
      assert.equal((await call({ name: 'schedule', action: firstAction === 'enable' ? 'disable' : 'enable' })).exitCode, 3);
      unblock();
      assert.equal((await first).exitCode, 0);
    } finally { f.cleanup(); }
  }
});

test('B20 repeated enable and disable preserve matching durable and job state', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    const enrolled = await call({ name: 'enroll', account: 'router_one' });
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.pilots[JSON.stringify([enrolled.enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1])] = { at: f.services.clock.wall() };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    for (const action of ['enable', 'enable', 'disable', 'disable']) {
      const response = await call({ name: 'schedule', action });
      assert.equal(response.exitCode, 0, `${action}: ${JSON.stringify(response)}`);
      assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, action === 'enable');
      assert.equal(await f.services.jobs.inspect(f.services.jobs.binding), action === 'enable' ? 'loaded' : 'absent');
    }
  } finally { f.cleanup(); }
});

test('B20 failed durable enable write does not report success or retain a new job', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    const enrolled = await call({ name: 'enroll', account: 'router_one' });
    const state = JSON.parse(fs.readFileSync(f.statePath));
    state.pilots[JSON.stringify([enrolled.enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1])] = { at: f.services.clock.wall() };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    f.services.fault = point => { if (point === 'before_state.json_rename') throw Error('synthetic_persistence_fault'); };
    const response = await call({ name: 'schedule', action: 'enable' });
    assert.equal(response.exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(f.statePath)).scheduleEnabled, false);
    assert.equal(await f.services.jobs.inspect(f.services.jobs.binding), 'absent');
  } finally { f.cleanup(); }
});

test('B13 explicit recovery preserves stale backup reservation, clears pilots and skips current day', async () => {
  const { f, call, context } = prepared();
  try {
    await call({ name: 'setup' });
    const state = JSON.parse(fs.readFileSync(f.statePath));
    const slot = '2026-11-12T08:00';
    state.slots[slot] = { enrollmentIds: ['enr_old'], claimedAt: f.services.clock.wall() };
    state.highWater = slot;
    state.reservations[JSON.stringify([slot, 'enr_old', 'workspace_old', 'user_old'])] = { enrollmentId: 'enr_old', identity: { accountId: 'workspace_old', userId: 'user_old' }, at: f.services.clock.wall(), possibleSend: true };
    state.pilots.old = { at: f.services.clock.wall() };
    const backupPath = path.join(f.root, 'stale-backup.json');
    fs.writeFileSync(backupPath, JSON.stringify(state), { mode: 0o600 });
    fs.unlinkSync(f.statePath);
    const lock = path.join(f.companionRoot, 'work.lock');
    fs.mkdirSync(lock, { mode: 0o700 });
    fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify({ pid: 9999, startId: 'dead-process', installationId: state.installationId, nonce: 'old-owner' }), { mode: 0o600 });
    const stat = fs.lstatSync(f.companionRoot);
    const decision = { installationId: state.installationId, rootDev: stat.dev, rootIno: stat.ino, skipThrough: '2026-11-12T18:00', reviewEvidence: 'explicit synthetic decision', backupPath };
    assert.equal((await recoverInstance(context, f.services, { ...decision, skipThrough: '2026-11-12T08:00' })).reason, 'recovery_boundary_too_early');
    assert.equal((await recoverInstance(context, f.services, decision)).exitCode, 0);
    const restored = JSON.parse(fs.readFileSync(f.statePath));
    assert.equal(restored.scheduleEnabled, false);
    assert.equal(restored.skipThrough, decision.skipThrough);
    assert.deepEqual(restored.pilots, {});
    assert.ok(Object.hasOwn(restored.reservations, JSON.stringify([slot, 'enr_old', 'workspace_old', 'user_old'])));
    assert.equal(fs.existsSync(lock), false);
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
  } finally { f.cleanup(); }
});

test('B13 ambiguous orphan owner cannot be cleared by explicit recovery', async () => {
  const { f, call, context } = prepared();
  try {
    await call({ name: 'setup' });
    const lock = path.join(f.companionRoot, 'work.lock');
    fs.mkdirSync(lock, { mode: 0o700 });
    fs.writeFileSync(path.join(lock, 'owner.json'), JSON.stringify({ pid: 9999, startId: 'unknown-process', installationId: 'install_synthetic_01', nonce: 'unknown' }), { mode: 0o600 });
    f.services.processes.inspect = () => 'unknown';
    const stat = fs.lstatSync(f.companionRoot);
    const response = await recoverInstance(context, f.services, { installationId: 'install_synthetic_01', rootDev: stat.dev, rootIno: stat.ino, skipThrough: '2026-11-12T18:00', reviewEvidence: 'synthetic decision', backupPath: null });
    assert.equal(response.reason, 'lock_owner_not_proven_dead');
    assert.equal(fs.existsSync(lock), true);
  } finally { f.cleanup(); }
});

test('B08 accepted digests reject unlocked config edits and lost marker', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    const config = JSON.parse(fs.readFileSync(f.configPath));
    config.schedule.times = ['09:00'];
    fs.writeFileSync(f.configPath, JSON.stringify(config), { mode: 0o600 });
    assert.equal((await call({ name: 'run' })).exitCode, 2);
    fs.unlinkSync(f.markerPath);
    assert.equal((await call({ name: 'setup' })).exitCode, 2);
    assert.equal((await call({ name: 'run' })).exitCode, 2);
  } finally { f.cleanup(); }
});

test('B10 owner tamper prevents lock release of another owner', async () => {
  const { f, call } = prepared();
  try {
    f.services.reader.readRegistry = () => {
      const ownerPath = path.join(f.companionRoot, 'work.lock', 'owner.json');
      const owner = JSON.parse(fs.readFileSync(ownerPath));
      fs.writeFileSync(ownerPath, JSON.stringify({ ...owner, nonce: 'replacement' }), { mode: 0o600 });
      return { kind: 'ready', accounts: [], coordination: 'idle' };
    };
    assert.equal((await call({ name: 'setup' })).exitCode, 2);
    assert.equal(JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'work.lock', 'owner.json'))).nonce, 'replacement');
  } finally { f.cleanup(); }
});

test('B15 maintenance model A-B-A removes historical pilot, enabled-only preserves it', async () => {
  const { f, call } = prepared();
  try {
    await call({ name: 'setup' });
    f.services.reader.readRegistry = () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_one', eligible: true }] });
    f.services.reader.discoverIdentity = () => ({ kind: 'ready', identity: { accountId: 'workspace_one', userId: 'user_one' } });
    await call({ name: 'enroll', account: 'router_one' });
    const old = JSON.parse(fs.readFileSync(f.configPath));
    const state = JSON.parse(fs.readFileSync(f.statePath));
    const pilot = JSON.stringify([old.enrollments[0].enrollmentId, 'workspace_one', 'user_one', 'gpt-6-luna', 1, 1]);
    state.pilots[pilot] = { at: f.services.clock.wall() };
    fs.writeFileSync(f.statePath, JSON.stringify(state), { mode: 0o600 });
    const compatibility = JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json')));
    const candidatePath = path.join(f.root, 'candidate.json');
    const apply = async (model, enabled) => {
      const config = JSON.parse(fs.readFileSync(f.configPath));
      config.enrollments[0].model = model;
      config.enrollments[0].enabled = enabled;
      fs.writeFileSync(candidatePath, JSON.stringify({ schemaVersion: 1, config, compatibility, reviewEvidence: 'fixture' }), { mode: 0o600 });
      return call({ name: 'maintain', file: candidatePath });
    };
    assert.equal((await apply('gpt-6-luna', false)).exitCode, 0);
    assert.ok(JSON.parse(fs.readFileSync(f.statePath)).pilots[pilot]);
    assert.equal((await apply('gpt-6-sol', false)).exitCode, 0);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.statePath)).pilots, {});
    assert.equal((await apply('gpt-6-luna', true)).exitCode, 0);
    assert.deepEqual(JSON.parse(fs.readFileSync(f.statePath)).pilots, {});
  } finally { f.cleanup(); }
});

test('B07/B12 setup write faults never permit a second discovery scan', async () => {
  for (const point of ['before_instance.json_create', 'after_instance.json_create', 'after_instance.json_write', 'after_instance.json_fsync', 'before_instance.json_rename', 'after_instance.json_rename_before_dirsync', 'after_instance.json_rename']) {
    const { f, call } = prepared();
    try {
      let scans = 0;
      f.services.reader.readRegistry = () => { scans++; return { kind: 'ready', coordination: 'idle', accounts: [] }; };
      let injected = false;
      f.services.fault = at => { if (!injected && at === point) { injected = true; throw new Error('fixture_fault'); } };
      assert.equal((await call({ name: 'setup' })).exitCode, 2, point);
      delete f.services.fault;
      const phase = JSON.parse(fs.readFileSync(f.markerPath)).phase;
      if (phase === 'uninitialized') assert.equal(scans, 0, point);
      else assert.equal(phase, 'in_progress', point);
      if (phase !== 'uninitialized') assert.equal((await call({ name: 'setup' })).exitCode, 2, point);
      assert.equal(scans, 0, point);
    } finally { f.cleanup(); }
  }
});

test('B12 atomic records use private same-directory temporary files', async () => {
  const { f, call } = prepared();
  try {
    const seen = new Set();
    f.services.fault = point => {
      const match = /^after_(instance|config|state)\.json_create$/.exec(point);
      if (!match) return;
      const name = `${match[1]}.json`;
      const temps = fs.readdirSync(f.companionRoot).filter(file => file.startsWith(`.${name}.`) && file.endsWith('.tmp'));
      assert.equal(temps.length, 1, point);
      const temp = path.join(f.companionRoot, temps[0]);
      assert.equal(path.dirname(temp), f.companionRoot);
      assert.equal(fs.lstatSync(temp).mode & 0o777, 0o600);
      seen.add(name);
    };
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    assert.deepEqual([...seen].sort(), ['config.json', 'instance.json', 'state.json']);
    assert.equal(fs.readdirSync(f.companionRoot).some(name => name.endsWith('.tmp')), false);
  } finally { f.cleanup(); }
});

test('B07/B12 config/state write faults leave in-progress marker and frozen discovery', async () => {
  for (const name of ['config.json', 'state.json']) for (const stage of ['after_write', 'after_fsync', 'before_rename', 'after_rename_before_dirsync', 'after_rename']) {
    const { f, call } = prepared();
    try {
      let scans = 0;
      f.services.reader.readRegistry = () => { scans++; return { kind: 'ready', coordination: 'idle', accounts: [] }; };
      let injected = false;
      const point = stage.startsWith('after_') ? `after_${name}_${stage.slice(6)}` : stage === 'before_rename' ? `before_${name}_rename` : `${stage}_${name}`;
      f.services.fault = at => { if (!injected && at === point) { injected = true; throw new Error('fixture_fault'); } };
      assert.equal((await call({ name: 'setup' })).exitCode, 2, `${name}/${stage}`);
      delete f.services.fault;
      assert.equal(JSON.parse(fs.readFileSync(f.markerPath)).phase, 'in_progress');
      assert.equal((await call({ name: 'setup' })).exitCode, 2);
      assert.equal(scans, 1);
    } finally { f.cleanup(); }
  }
});


test('B11 host enable rejects root disappearance or replacement during runtime qualification before plist or bootstrap', async () => {
  for (const replacement of [false, true]) {
    const { f } = prepared(); const displaced = `${f.companionRoot}-old`;
    try {
      const calls = [];
      const services = hostServices(f.companionRoot, (file, args) => {
        calls.push([file, args]);
        if (file === '/bin/ls') return 'drwx------  1 user staff 1 Nov 12 12:34 synthetic';
        if (file === '/bin/launchctl' && args[0] === 'bootstrap') return '';
        throw Error('unexpected synthetic command');
      }, () => {
        fs.renameSync(f.companionRoot, displaced);
        if (replacement) {
          fs.mkdirSync(f.companionRoot, { mode: 0o700 });
          fs.writeFileSync(path.join(f.companionRoot, 'sentinel'), 'replacement', { mode: 0o600 });
        }
      });
      const { dev, ino } = fs.lstatSync(f.companionRoot);
      const binding = { root: f.companionRoot, dev, ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: services.context.nodePath, scriptPath: services.context.scriptPath };
      await assert.rejects(services.jobs.enable(binding));
      assert.equal(fs.existsSync(f.plistPath), false);
      assert.equal(calls.some(([file]) => file === '/bin/launchctl'), false);
      if (replacement) assert.deepEqual(fs.readdirSync(f.companionRoot), ['sentinel']);
      else assert.equal(fs.existsSync(f.companionRoot), false);
    } finally { f.cleanup(); fs.rmSync(displaced, { recursive: true, force: true }); }
  }
});


test('B11 host enable revalidates the root after plist persistence before bootstrap', async () => {
  const { f } = prepared(); const displaced = `${f.companionRoot}-old`;
  const fsync = fs.fsyncSync;
  try {
    let moved = false;
    const calls = [];
    const services = hostServices(f.companionRoot, (file, args) => {
      calls.push([file, args]);
      if (file === '/bin/ls') return 'drwx------  1 user staff 1 Nov 12 12:34 synthetic';
      if (file === '/bin/launchctl' && args[0] === 'bootstrap') return '';
      throw Error('unexpected synthetic command');
    }, () => true);
    const { dev, ino } = fs.lstatSync(f.companionRoot);
    const binding = { root: f.companionRoot, dev, ino, installationId: 'install_synthetic_01', label: 'local.codex-router-warmup', plistPath: f.plistPath, nodePath: services.context.nodePath, scriptPath: services.context.scriptPath };
    fs.fsyncSync = fd => {
      fsync(fd);
      if (!moved && fs.fstatSync(fd).isFile()) { fs.renameSync(f.companionRoot, displaced); moved = true; }
    };
    await assert.rejects(services.jobs.enable(binding));
    assert.equal(moved, true);
    assert.equal(fs.existsSync(f.plistPath), true);
    assert.equal(fs.existsSync(f.companionRoot), false);
    assert.equal(calls.some(([file]) => file === '/bin/launchctl'), false);
  } finally { fs.fsyncSync = fsync; f.cleanup(); fs.rmSync(displaced, { recursive: true, force: true }); }
});

// Backlog item 0 (21 Nov 2026 host incident): a work lock whose owner is proven dead must not
// block every later tick, and status must say what holds the lock.
function plantWorkLock(f, owner) {
  const dir = path.join(f.companionRoot, 'work.lock');
  fs.mkdirSync(dir, { mode: 0o700 });
  if (owner) fs.writeFileSync(path.join(dir, 'owner.json'), JSON.stringify(owner), { mode: 0o600 });
  return dir;
}
const foreignOwner = { pid: 1862, startId: 'Sat Nov 21 11:20:01 2026', installationId: 'install_synthetic_01', nonce: 'dead-owner' };

test('R3 tick clears a work lock whose owner is proven dead and then runs', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const dir = plantWorkLock(f, foreignOwner);
    const inspected = [];
    f.services.processes.inspect = owner => { inspected.push(owner.pid); return owner.pid === 1862 ? 'dead' : 'alive'; };
    const status = await call({ name: 'status' });
    assert.deepEqual(status.workLock.state, 'stale');
    assert.equal(Number.isSafeInteger(status.workLock.since), true);
    assert.equal(fs.existsSync(dir), true, 'status never clears a lock');
    const out = await call({ name: 'tick' });
    assert.equal(out.exitCode, 0, JSON.stringify(out));
    assert.equal(out.reason, 'schedule_disabled');
    assert.equal(fs.existsSync(dir), false);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), false);
    assert.ok(inspected.includes(1862));
    assert.deepEqual((await call({ name: 'status' })).workLock, { state: 'free', since: null });
  } finally { f.cleanup(); }
});

test('R3 tick keeps alive, unknown, ownerless and malformed work locks and reports lock_busy', async () => {
  for (const [label, owner, verdict, expectedState] of [
    ['alive', foreignOwner, 'alive', 'held'],
    ['unknown', foreignOwner, 'unknown', 'unknown'],
    ['ownerless', null, 'dead', 'unknown'],
    ['other installation', { ...foreignOwner, installationId: 'install_other' }, 'dead', 'unknown'],
    // Status uses recovery's own proof: a malformed owner is unknown, never "stale".
    ['no nonce', { pid: 1862, startId: 'x', installationId: 'install_synthetic_01' }, 'dead', 'unknown'],
  ]) {
    const { f, call } = prepared();
    try {
      assert.equal((await call({ name: 'setup' })).exitCode, 0);
      const dir = plantWorkLock(f, owner);
      const bytes = owner ? fs.readFileSync(path.join(dir, 'owner.json'), 'utf8') : null;
      f.services.processes.inspect = () => verdict;
      const stateBefore = fs.readFileSync(f.statePath, 'utf8');
      const out = await call({ name: 'tick' });
      assert.deepEqual([out.exitCode, out.reason], [3, 'lock_busy'], label);
      assert.equal(fs.existsSync(dir), true, label);
      if (owner) assert.equal(fs.readFileSync(path.join(dir, 'owner.json'), 'utf8'), bytes, label);
      assert.equal(fs.readFileSync(f.statePath, 'utf8'), stateBefore, label);
      assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), false, label);
      assert.equal((await call({ name: 'status' })).workLock.state, expectedState, label);
    } finally { f.cleanup(); }
  }
});

// The recovery mutex is a kernel file lock (O_EXLOCK); a second open description conflicts even
// inside this process, which stands in for a concurrent recoverer.
const O_EXLOCK = 0x20, O_NONBLOCK = 0x4;
const mutexFile = f => path.join(path.dirname(f.companionRoot), `.${path.basename(f.companionRoot)}.recovery.lock`);
function holdRecoveryMutex(f) {
  if (!fs.existsSync(mutexFile(f))) fs.writeFileSync(mutexFile(f), MUTEX_MARK, { mode: 0o600 });
  return fs.openSync(mutexFile(f), fs.constants.O_RDWR | O_EXLOCK | O_NONBLOCK);
}

test('R3 a concurrent recoverer holding the recovery mutex leaves the dead lock for the next check', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const dir = plantWorkLock(f, foreignOwner);
    f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
    const held = holdRecoveryMutex(f);
    try {
      const out = await call({ name: 'tick' });
      assert.deepEqual([out.exitCode, out.reason], [3, 'lock_busy']);
      assert.equal(fs.existsSync(dir), true);
      // Status still reports what recovery would do once the mutex is free.
      assert.equal((await call({ name: 'status' })).workLock.state, 'stale');
    } finally { fs.closeSync(held); }
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
    assert.equal(fs.existsSync(dir), false);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'lifecycle.lock')), false, 'recovery never takes the lifecycle lock');
  } finally { f.cleanup(); }
});

test('R3 a recovery that fails part-way releases the mutex for the next check', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const dir = plantWorkLock(f, foreignOwner);
    f.services.processes.inspect = () => { throw new Error('inspection crashed'); };
    assert.deepEqual([(await call({ name: 'tick' })).reason, fs.existsSync(dir)], ['lock_busy', true]);
    f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
    assert.equal(fs.existsSync(dir), false);
  } finally { f.cleanup(); }
});

test('R3 a dead lifecycle lock does not stop tick recovery, and remove deletes recovery.lock', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const dir = plantWorkLock(f, foreignOwner);
    const life = path.join(f.companionRoot, 'lifecycle.lock');
    fs.mkdirSync(life, { mode: 0o700 });
    fs.writeFileSync(path.join(life, 'owner.json'), JSON.stringify({ ...foreignOwner, pid: 1863, nonce: 'dead-life' }), { mode: 0o600 });
    f.services.processes.inspect = owner => owner.pid === 1862 || owner.pid === 1863 ? 'dead' : 'alive';
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
    assert.equal(fs.existsSync(dir), false);
    assert.equal(fs.existsSync(life), true, 'the tick leaves the lifecycle lock to the operator commands');
    assert.equal(fs.statSync(mutexFile(f)).mode & 0o777, 0o600);
    assert.equal(fs.existsSync(path.join(f.companionRoot, 'recovery.lock')), false, 'nothing is added inside the installation');
    fs.rmSync(life, { recursive: true });
    assert.equal((await call({ name: 'remove' })).exitCode, 0);
    assert.equal(fs.existsSync(f.companionRoot), false);
  } finally { f.cleanup(); }
});

test('R3 a process never clears a work lock it holds itself', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const dir = plantWorkLock(f, { ...f.owner, installationId: 'install_synthetic_01', nonce: 'self-held' });
    f.services.processes.inspect = () => 'dead';
    const out = await call({ name: 'run' });
    assert.deepEqual([out.exitCode, out.reason], [3, 'lock_busy']);
    assert.equal(fs.existsSync(dir), true);
  } finally { f.cleanup(); }
});

test('R3 CLI scopes the overlap override to one adjacent, well-formed admission instant', async () => {
  const at = '1794463200000';
  for (const argv of [
    ['run', '--overlap-at', at],
    ['run', '--allow-slot-overlap', '--overlap-at'],
    ['run', '--allow-slot-overlap', '--overlap-at', '2026-11-12T08:00'],
    ['run', '--allow-slot-overlap', '--overlap-at', '99999999999999999999'],
    ['run', '--allow-slot-overlap', '--overlap-at', at, '--overlap-at', at],
    ['run', '--allow-slot-overlap', '--allow-slot-overlap'],
    // A guard pair between the flag and its value is refused, not silently re-joined.
    ['run', '--allow-slot-overlap', '--overlap-at', '--expected-installation-id', 'install_synthetic_01', at],
    ['status', '--allow-slot-overlap', '--overlap-at', at],
  ]) assert.equal((await execute(argv)).json.reason, 'invalid_invocation', argv.join(' '));
  // Guards before or after the scoped override parse normally (the command then fails later,
  // on the missing context, not on its arguments).
  for (const argv of [
    ['run', '--allow-slot-overlap', '--overlap-at', at, '--expected-installation-id', 'install_synthetic_01'],
    ['run', '--expected-installation-id', 'install_synthetic_01', '--overlap-at', at, '--allow-slot-overlap', '--account', 'enr_01'],
  ]) assert.equal((await execute(argv)).json.reason, 'invalid_context', argv.join(' '));
});

test('R3 status reports usage for at most MAX_USAGE_ACCOUNTS accounts and says when it stopped', () => {
  const ids = Array.from({ length: MAX_USAGE_ACCOUNTS + 6 }, (_, i) => `enr_${String(i).padStart(3, '0')}`);
  const history = ids.map((enrollmentId, i) => ({ enrollmentId, at: i, usage: { primary: { usedPercent: 10, windowMinutes: 300 }, observedAt: i } }));
  history.push({ enrollmentId: 'enr_000', at: 999, usage: { primary: { usedPercent: 'CANARY' }, observedAt: 999 } });
  const { found, truncated } = latestUsage({ history }, new Set(ids));
  assert.equal(found.size, MAX_USAGE_ACCOUNTS);
  assert.equal(truncated, true);
  assert.equal(found.has(ids.at(-1)), true, 'newest observations win');
  assert.equal(found.get('enr_000'), undefined, 'an invalid newest row is skipped, and the cap was reached before older rows');
  const few = latestUsage({ history: history.slice(0, 3) }, new Set(ids));
  assert.deepEqual([few.found.size, few.truncated], [3, false]);
  // About 200 bytes per account keeps the capped usage far below the 1 MiB output limit.
  assert.ok(Buffer.byteLength(JSON.stringify([...found.values()])) < 64 * 1024);
});

test('R3 a crash after the dead lock is renamed leaves a tombstone that the next recovery clears', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const dir = plantWorkLock(f, foreignOwner);
    f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
    f.services.fault = point => { if (point === 'after_dead_lock_rename') throw new Error('crash'); };
    // The interrupted recovery leaves the lock path free (never ownerless) and one tombstone.
    await call({ name: 'tick' });
    assert.equal(fs.existsSync(dir), false);
    const tombstones = () => fs.readdirSync(f.companionRoot).filter(name => name.startsWith('work.lock.dead-'));
    assert.equal(tombstones().length, 1);
    f.services.fault = undefined;
    // A new dead lock: the next recovery sweeps the old tombstone and its own.
    plantWorkLock(f, { ...foreignOwner, nonce: 'dead-again' });
    assert.equal((await call({ name: 'tick' })).reason, 'schedule_disabled');
    assert.deepEqual(tombstones(), []);
    // Removal also tolerates a tombstone left behind.
    fs.mkdirSync(path.join(f.companionRoot, 'work.lock.dead-00000000-0000-4000-8000-000000000000'), { mode: 0o700 });
    assert.equal((await call({ name: 'remove' })).exitCode, 0);
    assert.equal(fs.existsSync(f.companionRoot), false);
  } finally { f.cleanup(); }
});

test('R3 recovery never recreates recovery.lock once the installation marker is gone', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    plantWorkLock(f, foreignOwner);
    f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
    const marker = path.join(f.companionRoot, 'instance.json');
    const bytes = fs.readFileSync(marker);
    // Simulate the removal window: the marker is gone while a command is already running.
    // Armed only once recovery has looked for recovery.lock, so loading the state still works.
    let armed = false;
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'openSync') return (file, ...rest) => { if (String(file).endsWith('.recovery.lock')) armed = true; return target.openSync(file, ...rest); };
      if (key === 'lstatSync') return (file, ...rest) => { if (armed && file === marker) { const e = new Error('gone'); e.code = 'ENOENT'; throw e; } return target.lstatSync(file, ...rest); };
      return target[key];
    } });
    const out = await call({ name: 'tick' });
    f.services.files = fs;
    assert.equal(armed, true);
    assert.deepEqual([out.exitCode, out.reason], [3, 'lock_busy']);
    assert.equal(fs.existsSync(mutexFile(f)), false);
    assert.deepEqual(fs.readFileSync(marker), bytes);
  } finally { f.cleanup(); }
});

test('R3 removal waits for a recovery in progress and then changes nothing', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    const held = holdRecoveryMutex(f);
    try {
      const out = await call({ name: 'remove' });
      assert.deepEqual([out.exitCode, out.reason], [3, 'lock_busy']);
      assert.equal(fs.existsSync(path.join(f.companionRoot, 'instance.json')), true);
      assert.equal(JSON.parse(fs.readFileSync(f.statePath)).removalPending, false);
    } finally { fs.closeSync(held); }
    assert.equal((await call({ name: 'remove' })).exitCode, 0);
    assert.equal(fs.existsSync(f.companionRoot), false);
  } finally { f.cleanup(); }
});

test('R3 a recoverer that recreates the sibling mutex during removal cannot block the rmdir', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    f.services.fault = point => { if (point === 'before_remove_rmdir') fs.writeFileSync(mutexFile(f), '', { mode: 0o600 }); };
    assert.equal((await call({ name: 'remove' })).exitCode, 0);
    assert.equal(fs.existsSync(f.companionRoot), false);
    // The held file lost its marker, so it is no longer provably the engine's: it is left alone.
    assert.equal(fs.readFileSync(mutexFile(f), 'utf8'), '');
  } finally { try { fs.unlinkSync(mutexFile(f)); } catch { /* cleaned */ } f.cleanup(); }
});

test('R3h removal is clean when the sibling vanishes between its check and its unlink', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'unlinkSync') return (file, ...rest) => { if (String(file) === mutexFile(f)) target.unlinkSync(file); return target.unlinkSync(file, ...rest); };
      return target[key];
    } });
    const out = await call({ name: 'remove' });
    f.services.files = fs;
    assert.deepEqual([out.exitCode, out.reason], [0, 'removed']);
  } finally { f.services.files = fs; f.cleanup(); }
});

test('R3i a read error on the held mutex after rmdir leaves it in place and still finishes removal', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    let armed = false;
    f.services.fault = point => { if (point === 'before_remove_rmdir') armed = true; };
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'readSync') return (...args) => { if (armed) { const e = new Error('io'); e.code = 'EIO'; throw e; } return target.readSync(...args); };
      return target[key];
    } });
    const out = await call({ name: 'remove' });
    f.services.files = fs;
    assert.deepEqual([out.exitCode, out.reason], [0, 'removed']);
    assert.equal(fs.existsSync(f.companionRoot), false);
    assert.equal(fs.readFileSync(mutexFile(f), 'utf8'), MUTEX_MARK, 'an unverifiable sibling is left, not deleted');
  } finally { f.services.files = fs; try { fs.unlinkSync(mutexFile(f)); } catch { /* cleaned */ } f.cleanup(); }
});

test('R3j a sibling swapped in while the held mutex is validated is never deleted', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    let armed = false, swapped = false;
    f.services.fault = point => { if (point === 'before_remove_rmdir') armed = true; };
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'readSync') return (...args) => {
        const n = target.readSync(...args);
        if (armed && !swapped) { swapped = true; target.renameSync(mutexFile(f), `${mutexFile(f)}.old`); target.writeFileSync(mutexFile(f), 'replacement', { mode: 0o600 }); }
        return n;
      };
      return target[key];
    } });
    const out = await call({ name: 'remove' });
    f.services.files = fs;
    assert.deepEqual([out.exitCode, out.reason], [0, 'removed']);
    assert.equal(swapped, true);
    assert.equal(fs.readFileSync(mutexFile(f), 'utf8'), 'replacement');
  } finally {
    f.services.files = fs;
    for (const file of [mutexFile(f), `${mutexFile(f)}.old`]) try { fs.unlinkSync(file); } catch { /* cleaned */ }
    f.cleanup();
  }
});

test('R3h a short write never publishes a mutex and leaves no temporary file', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    plantWorkLock(f, foreignOwner);
    f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
    f.services.files = new Proxy(fs, { get(target, key) {
      if (key === 'writeSync') return (fd, data, ...rest) => (data === MUTEX_MARK ? 3 : target.writeSync(fd, data, ...rest));
      return target[key];
    } });
    assert.equal((await call({ name: 'tick' })).reason, 'lock_busy');
    f.services.files = fs;
    const dir = path.dirname(mutexFile(f));
    assert.equal(fs.existsSync(mutexFile(f)), false);
    assert.deepEqual(fs.readdirSync(dir).filter(name => name.includes('.recovery.lock.new-')), []);
  } finally { f.services.files = fs; f.cleanup(); }
});

test('R3g only the marked 0600 mutex is used: an empty file or a wider mode is left alone', async () => {
  for (const [content, mode] of [['', 0o600], [MUTEX_MARK, 0o700], [MUTEX_MARK, 0o4600]]) {
    const { f, call } = prepared();
    try {
      assert.equal((await call({ name: 'setup' })).exitCode, 0);
      fs.writeFileSync(mutexFile(f), content, { mode });
      fs.chmodSync(mutexFile(f), mode);
      plantWorkLock(f, foreignOwner);
      f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
      assert.equal((await call({ name: 'tick' })).reason, 'lock_busy');
      assert.notEqual((await call({ name: 'remove' })).exitCode, 0);
      assert.equal(fs.readFileSync(mutexFile(f), 'utf8'), content);
      assert.equal(fs.statSync(mutexFile(f)).mode & 0o7777, mode);
    } finally { try { fs.unlinkSync(mutexFile(f)); } catch { /* cleaned */ } f.cleanup(); }
  }
});

test('R3g removal finishes cleanly when the sibling mutex is already gone after the rmdir', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    f.services.fault = point => { if (point === 'before_remove_rmdir') fs.unlinkSync(mutexFile(f)); };
    const out = await call({ name: 'remove' });
    assert.deepEqual([out.exitCode, out.reason], [0, 'removed']);
    assert.equal(fs.existsSync(f.companionRoot), false);
  } finally { f.cleanup(); }
});

test('R3 an unrelated file at the mutex path is never used as the lock or deleted', async () => {
  const { f, call } = prepared();
  try {
    assert.equal((await call({ name: 'setup' })).exitCode, 0);
    fs.writeFileSync(mutexFile(f), 'unrelated data', { mode: 0o600 });
    plantWorkLock(f, foreignOwner);
    f.services.processes.inspect = owner => owner.pid === 1862 ? 'dead' : 'alive';
    assert.equal((await call({ name: 'tick' })).reason, 'lock_busy');
    assert.notEqual((await call({ name: 'remove' })).exitCode, 0);
    assert.equal(fs.readFileSync(mutexFile(f), 'utf8'), 'unrelated data');
  } finally { try { fs.unlinkSync(mutexFile(f)); } catch { /* cleaned */ } f.cleanup(); }
});
