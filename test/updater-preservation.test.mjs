import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { makeFixture } from './helpers.mjs';
import { runCommand } from '../runtime.mjs';

const fixtureDir = fileURLToPath(new URL('./fixtures/updater/', import.meta.url));
const manifest = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'manifest.json'), 'utf8'));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
function frozen(name) {
  const text = fs.readFileSync(path.join(fixtureDir, name), 'utf8');
  assert.equal(digest(text), manifest.files[name].sha256);
  return text;
}

// Run unchanged upstream function bodies; imports, CLI entry and host operations are isolated.
function evaluate(name, bindings, exports) {
  let source = frozen(name).replace(/^import\s[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  if (name === 'src-update.mjs.txt') {
    const end = source.indexOf('\nasync function main()');
    assert.ok(end > 0);
    source = source.slice(0, end);
  } else {
    assert.ok(source.includes('const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");'));
    source = source.replace('const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");', '');
  }
  assert.ok(!source.includes('import.meta'));
  return vm.runInNewContext(`${source}\n;({${exports.join(',')}})`, bindings,
    { timeout: 1000, contextCodeGeneration: { strings: false, wasm: false } });
}

function isolatedUpdater({ same = false, dirty = false, failInstall = false, failTray = false, compatibility = true } = {}) {
  const f = makeFixture();
  const sourceRoot = f.routerRoot;
  fs.mkdirSync(path.join(sourceRoot, '.git'), { mode: 0o700 });
  fs.mkdirSync(path.join(sourceRoot, 'dist'), { mode: 0o700 });
  fs.mkdirSync(path.join(sourceRoot, 'dist', 'Model Router.app'), { mode: 0o700 });
  fs.writeFileSync(path.join(f.companionRoot, 'sentinel'), 'companion unchanged', { mode: 0o600 });
  fs.writeFileSync(f.plistPath, 'external companion job sentinel', { mode: 0o600 });
  let head = manifest.baseline, installed = head, rollback = manifest.baseline;
  let tracked = dirty ? ' M src/example.mjs' : '';
  const available = same ? head : manifest.candidate, calls = [], installs = [];
  const before = [path.join(f.companionRoot, 'sentinel'), f.plistPath].map(p => digest(fs.readFileSync(p)));
  const execFileSync = (command, args) => {
    calls.push([command, ...args]);
    if (command === 'defaults') return '';
    assert.equal(command, 'git');
    assert.equal(args[0], '-C'); assert.equal(args[1], sourceRoot);
    const a = args.slice(2), key = a.join(' ');
    if (key === 'remote get-url origin') return 'https://github.com/duolahypercho/codex-router.git';
    if (key === 'fetch --quiet origin main') return '';
    if (key === 'rev-parse HEAD') return head;
    if (key === 'rev-parse origin/main') return available;
    if (key === 'rev-parse refs/codex-router/rollback') return rollback;
    if (key === 'status --porcelain --untracked-files=no') return tracked;
    if (key === 'branch --show-current') return 'main';
    if (key === 'reset --hard HEAD') { tracked = ''; return ''; }
    if (a[0] === 'cat-file') { if (!compatibility) throw Error('unsupported candidate'); return ''; }
    if (a[0] === 'update-ref') { rollback = a[2]; return ''; }
    if (a[0] === 'merge') { head = a[2]; return ''; }
    if (a[0] === 'switch' && a[1] === '--detach') { head = a[2]; return ''; }
    throw Error(`Unstubbed git operation: ${key}`);
  };
  const spawnSync = (command, args, options) => {
    calls.push([command, ...args]);
    assert.equal(options.cwd, sourceRoot);
    if (command === path.join(sourceRoot, 'bin', 'install')) {
      installs.push(head);
      if (failInstall && head === manifest.candidate) return { status: 1 };
      installed = head;
      // Installer/build boundaries are modeled writes confined to the synthetic Router tree.
      fs.writeFileSync(path.join(sourceRoot, 'dependency-build'), head, { mode: 0o600 });
      fs.writeFileSync(path.join(sourceRoot, 'dist', 'Model Router.app', 'binary'), head, { mode: 0o600 });
      return { status: 0 };
    }
    assert.equal(command, path.join(sourceRoot, 'bin', 'model-router-tray'));
    assert.deepEqual(Array.from(args), ['--preserve-window']);
    return { status: failTray ? 1 : 0 };
  };
  const bindings = { SOURCE_ROOT: sourceRoot, TARGET: 'codex', path, existsSync: fs.existsSync,
    execFileSync, spawnSync, readInstallManifest: () => ({ current: { commit: same ? null : installed } }),
    readCompatibilityLayerSettings: () => ({ enabled: false }),
    automaticTraySupervisionAllowed: () => true, readTraySupervisionPreference: () => 'enabled',
    traySupervisionPreferencePath: () => path.join(f.root, 'preference'), os: { homedir: () => f.root },
    process: { platform: 'darwin', env: {}, stderr: { write() {} } } };
  const api = evaluate('src-update.mjs.txt', bindings, ['updateCheckout', 'rollbackCheckout']);
  return { ...f, api, calls, installs, head: () => head,
    assertPreserved() { assert.deepEqual([path.join(f.companionRoot, 'sentinel'), f.plistPath].map(p => digest(fs.readFileSync(p))), before); },
  };
}

test('E named actual-source update and reinstall preserve sibling companion/plist while build/tray steps stay stubbed', () => {
  assert.match(manifest.baseline, /^[a-f0-9]{40}$/); assert.match(manifest.candidate, /^[a-f0-9]{40}$/);
  frozen('bin-install.txt');
  for (const same of [false, true]) for (const locked of [false, true]) {
    const f = isolatedUpdater({ same });
    try {
      if (locked) fs.mkdirSync(path.join(f.companionRoot, 'work.lock'), { mode: 0o700 });
      const result = f.api.updateCheckout();
      assert.equal(result.updated, !same); assert.equal(result.reinstalled, true);
      assert.equal(f.installs.length, 1); f.assertPreserved();
      assert.ok(f.calls.some(c => c[0].endsWith('model-router-tray')));
      assert.ok(f.calls.filter(c => c[0] === 'git').every(c => c[2] === f.routerRoot));
    } finally { f.cleanup(); }
  }
});

test('E actual updater refuses tracked edits, force-resets only its checkout, and preserves companion locks', () => {
  const f = isolatedUpdater({ dirty: true });
  try {
    fs.mkdirSync(path.join(f.companionRoot, 'lifecycle.lock'), { mode: 0o700 });
    assert.throws(() => f.api.updateCheckout(), /tracked file/);
    assert.equal(f.installs.length, 0); assert.equal(f.head(), manifest.baseline);
    assert.equal(f.api.updateCheckout({ force: true }).updated, true);
    assert.ok(f.calls.some(c => c.slice(3).join(' ') === 'reset --hard HEAD'));
    assert.ok(fs.statSync(path.join(f.companionRoot, 'lifecycle.lock')).isDirectory());
    f.assertPreserved();
  } finally { f.cleanup(); }
});

test('E actual updater rolls installer failure back; tray failure does not roll successful update back', () => {
  for (const failInstall of [true, false]) {
    const f = isolatedUpdater({ failInstall, failTray: !failInstall });
    try {
      if (failInstall) {
        assert.throws(() => f.api.updateCheckout(), /restored to/);
        assert.equal(f.head(), manifest.baseline);
        assert.deepEqual(f.installs, [manifest.candidate, manifest.baseline]);
      } else {
        assert.equal(f.api.updateCheckout().updated, true);
        assert.equal(f.head(), manifest.candidate);
        assert.equal(f.api.rollbackCheckout().to, manifest.baseline);
      }
      f.assertPreserved();
    } finally { f.cleanup(); }
  }
});

test('E actual compatibility-policy refusal leaves checkout and companion untouched', () => {
  const f = isolatedUpdater({ compatibility: false });
  try {
    assert.throws(() => f.api.updateCheckout(), /cannot honor/);
    assert.equal(f.head(), manifest.baseline); assert.equal(f.installs.length, 0); f.assertPreserved();
  } finally { f.cleanup(); }
});

test('E actual maintenance selects recorded owner and invokes update then doctor, never doctor --fix', () => {
  const f = makeFixture();
  try {
    const owner = path.join(f.root, 'recorded-owner');
    fs.mkdirSync(owner, { mode: 0o700 }); fs.mkdirSync(path.join(owner, '.git'), { mode: 0o700 });
    const api = evaluate('src-codex-maintenance.mjs.txt', { SOURCE_ROOT: f.routerRoot, path, existsSync: fs.existsSync,
      spawnSync() { throw Error('unexpected host spawn'); }, readInstallManifest: () => ({ current: { sourceRoot: owner } }),
      process: { execPath: '/synthetic/node22', env: {} } }, ['runCodexMaintenance', 'maintenanceSourceRoot']);
    assert.equal(api.maintenanceSourceRoot(f.routerRoot), owner);
    assert.equal(api.maintenanceSourceRoot(f.routerRoot, {}), f.routerRoot);
    const calls = [];
    const runner = (node, args, options) => {
      calls.push([node, Array.from(args), options.cwd]);
      return { status: 0, stdout: args.includes('--json') ? JSON.stringify({ checks: [] }) : '{}' };
    };
    assert.equal(api.runCodexMaintenance({ runner }).verified, true);
    assert.deepEqual(calls, [['/synthetic/node22', [path.join(owner, 'src/update.mjs'), 'update'], owner],
      ['/synthetic/node22', [path.join(owner, 'src/doctor.mjs'), '--json'], owner]]);
    assert.throws(() => api.runCodexMaintenance({ runner: () => ({ status: 1 }) }), /update failed/);
  } finally { f.cleanup(); }
});

async function companionResult(f, mode) {
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, 'pool.json'), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, 'switch.json'), discoveryPath: path.join(f.routerRoot, 'discovery.json') };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_updater_01', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), { schemaVersion: 1, reviewedRevision: 'a'.repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, digest(String(n))])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'fixture', semantics: 'equivalent' });
  f.services.reader = {
    readRegistry: () => ({ kind: 'ready', coordination: 'idle', accounts: [{ routerAccountId: 'router_1', eligible: true }] }),
    discoverIdentity: () => ({ kind: 'ready', identity: { accountId: 'workspace_1', userId: 'user_1' } }),
    checkCompatibility: () => ({ kind: 'ready' }),
    readCredential: (_ctx, e) => ({ kind: 'ready', identity: e.identity, accessToken: 'synthetic', expiresAt: 4102444800000, snapshot: {} }),
    revalidate: () => ({ kind: 'ready' }),
  };
  f.services.probe = async () => mode === 'probe_failure'
    ? { outcome: 'blocked', reason: 'authentication_rejected', dispatched: true }
    : { outcome: 'success', reason: 'marker_confirmed', dispatched: true };
  const context = { root: f.companionRoot, nodePath: '/synthetic/node22', scriptPath: '/synthetic/warmup.mjs' };
  const call = command => runCommand(command, context, f.services);
  const plist = fs.readFileSync(f.plistPath);
  fs.unlinkSync(f.plistPath);
  assert.equal((await call({ name: 'setup' })).exitCode, 0);
  fs.writeFileSync(f.plistPath, plist, { mode: 0o600 });
  if (mode === 'validation_failure') f.services.reader.checkCompatibility = () => ({ kind: 'blocked' });
  if (mode === 'busy') fs.mkdirSync(path.join(f.companionRoot, 'work.lock'), { mode: 0o700 });
  if (mode === 'persistence_failure') {
    let writes = 0;
    f.services.fault = point => { if (point === 'before_state.json_rename' && ++writes === 2) throw Error('synthetic persistence failure'); };
  }
  const result = await call({ name: 'run' });
  delete f.services.fault;
  if (mode === 'success') assert.deepEqual([result.exitCode, result.attempted, result.results[0].outcome], [0, 1, 'success']);
  if (mode === 'probe_failure') assert.deepEqual([result.exitCode, result.attempted, result.results[0].reason], [1, 1, 'authentication_rejected']);
  if (mode === 'validation_failure') assert.deepEqual([result.exitCode, result.attempted, result.reason], [2, 0, 'compatibility_blocked']);
  if (mode === 'persistence_failure') assert.deepEqual([result.exitCode, result.attempted, result.results[0].outcome], [2, 1, 'success']);
  if (mode === 'busy') assert.equal(result.exitCode, 3);
}

function snapshotTree(root) {
  const entries = [];
  function visit(dir, relative = '') {
    for (const name of fs.readdirSync(dir).sort()) {
      const rel = path.join(relative, name), full = path.join(root, rel), stat = fs.lstatSync(full);
      assert.ok(stat.isDirectory() || stat.isFile());
      entries.push([rel, stat.mode & 0o777, stat.isDirectory() ? 'directory' : digest(fs.readFileSync(full))]);
      if (stat.isDirectory()) visit(full, rel);
    }
  }
  visit(root);
  return entries;
}

async function maintenanceScenario(mode, failure) {
  const f = isolatedUpdater({ failInstall: failure === 'installer' });
  try {
    if (mode !== 'control') await companionResult(f, mode);
    const before = snapshotTree(f.companionRoot), plist = digest(fs.readFileSync(f.plistPath));
    const maintenance = evaluate('src-codex-maintenance.mjs.txt', { SOURCE_ROOT: f.routerRoot, path, existsSync: fs.existsSync,
      spawnSync() { throw Error('unexpected host spawn'); }, readInstallManifest: () => null,
      process: { execPath: '/synthetic/node22', env: {} } }, ['runCodexMaintenance']);
    const calls = [], updaterResults = [];
    const runner = (node, args, options) => {
      assert.equal(node, '/synthetic/node22'); assert.equal(options.cwd, f.routerRoot);
      if (args[0] === path.join(f.routerRoot, 'src/update.mjs')) {
        assert.deepEqual(Array.from(args).slice(1), ['update']); calls.push('update');
        try {
          const result = f.api.updateCheckout();
          updaterResults.push(JSON.parse(JSON.stringify(result)));
          return failure === 'update_status' ? { status: 1, stderr: 'synthetic external status' } : { status: 0, stdout: '{}' };
        } catch (error) {
          updaterResults.push({ error: error.message });
          return { status: 1, stderr: error.message };
        }
      }
      assert.deepEqual(Array.from(args), [path.join(f.routerRoot, 'src/doctor.mjs'), '--json']);
      calls.push('doctor');
      return failure === 'doctor' ? { status: 1, stderr: 'synthetic doctor failure' } : { status: 0, stdout: '{"checks":[]}' };
    };
    let result;
    try { result = JSON.parse(JSON.stringify(maintenance.runCodexMaintenance({ runner }))); }
    catch (error) { result = { error: error.message }; }
    if (failure === 'none') { assert.equal(result.verified, true); assert.deepEqual(calls, ['update', 'doctor']); }
    else {
      assert.ok(result.error); assert.notEqual(result.verified, true);
      assert.deepEqual(calls, failure === 'doctor' ? ['update', 'doctor'] : ['update']);
    }
    if (failure === 'installer') {
      assert.equal(f.head(), manifest.baseline);
      assert.deepEqual(f.installs, [manifest.candidate, manifest.baseline]);
    } else { assert.equal(f.head(), manifest.candidate); assert.deepEqual(f.installs, [manifest.candidate]); }
    assert.deepEqual(snapshotTree(f.companionRoot), before);
    assert.equal(digest(fs.readFileSync(f.plistPath)), plist);
    f.assertPreserved();
    const normalized = f.calls.map(call => call.map(value => typeof value === 'string' ? value.replaceAll(f.root, '<fixture>') : value));
    return { result, calls, updaterResults, head: f.head(), installs: [...f.installs], upstreamCalls: normalized };
  } finally { f.cleanup(); }
}

test('E frozen maintenance routes actual updater independently of companion outcomes and failures', async () => {
  for (const failure of ['none', 'installer', 'update_status', 'doctor']) {
    const baseline = await maintenanceScenario('control', failure);
    for (const mode of ['success', 'probe_failure', 'validation_failure', 'persistence_failure', 'busy']) {
      assert.deepEqual(await maintenanceScenario(mode, failure), baseline, `${mode}/${failure}`);
    }
  }
});

test('E frozen maintenance falls back for absent or unusable owner metadata and invokes both paths', () => {
  const f = makeFixture();
  try {
    for (const metadata of [null, {}, { current: { sourceRoot: path.join(f.root, 'missing-owner') } }]) {
      const api = evaluate('src-codex-maintenance.mjs.txt', { SOURCE_ROOT: f.routerRoot, path, existsSync: fs.existsSync,
        spawnSync() { throw Error('unexpected host spawn'); }, readInstallManifest: () => metadata,
        process: { execPath: '/synthetic/node22', env: {} } }, ['runCodexMaintenance']);
      const calls = [];
      const runner = (node, args, options) => { calls.push([node, Array.from(args), options.cwd]); return { status: 0, stdout: '{"checks":[]}' }; };
      assert.equal(api.runCodexMaintenance({ runner }).verified, true);
      assert.deepEqual(calls, [['/synthetic/node22', [path.join(f.routerRoot, 'src/update.mjs'), 'update'], f.routerRoot],
        ['/synthetic/node22', [path.join(f.routerRoot, 'src/doctor.mjs'), '--json'], f.routerRoot]]);
    }
  } finally { f.cleanup(); }
});
