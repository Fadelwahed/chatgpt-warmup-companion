import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { execute } from '../warmup.mjs';
import { runCommand } from '../runtime.mjs';
import { makeFixture } from './helpers.mjs';

const scriptPath = fileURLToPath(new URL('../warmup.mjs', import.meta.url));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const put = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), { mode: 0o600 });
};
const jwt = claims => `synthetic.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.unsigned`;
function assembled() {
  const f = makeFixture();
  const paths = { sourceRoot: f.routerRoot, stateRoot: path.join(f.root, 'state'), codexHome: path.join(f.root, 'codex'),
    poolPath: path.join(f.root, 'state/pool.json'), homesDir: path.join(f.root, 'state/homes'),
    switchPath: path.join(f.root, 'state/switch.json'), discoveryPath: path.join(f.root, 'state/discovery.json') };
  for (const dir of [paths.stateRoot, paths.codexHome, paths.homesDir]) fs.mkdirSync(dir, { mode: 0o700 });
  const sourceDigests = {};
  for (let n = 0; n < 13; n++) {
    const name = `src/contract-${n}.mjs`, contents = `// synthetic reviewed source ${n}\n`;
    put(path.join(f.routerRoot, name), contents); sourceDigests[name] = hash(contents);
  }
  const compatibility = { schemaVersion: 1, reviewedRevision: 'a'.repeat(40), sourceDigests, adapterVersion: 1,
    requestContractVersion: 1, sourcePathContract: 'synthetic-independent-roots', reviewEvidence: 'synthetic-review', semantics: 'equivalent' };
  const pool = { version: 1, policy: { enabled: true, mode: 'switch', selectedAccountId: 'acct_abcdefgh' }, accounts: {}, sessions: {} };
  const add = (id, suffix) => {
    pool.accounts[id] = { id, state: 'active', paused: false, priority: 0, health: { state: 'healthy' }, turns: 0, requests: 0,
      identity: { accountId: `workspace-${suffix}`, userId: `user-${suffix}` } };
    put(paths.poolPath, pool);
    put(path.join(paths.homesDir, id, 'auth.json'), { tokens: { account_id: `workspace-${suffix}`,
      access_token: jwt({ exp: 4102444800 }), id_token: jwt({ 'https://api.openai.com/auth': { chatgpt_user_id: `user-${suffix}` } }),
      refresh_token: 'DO_NOT_PERSIST_REFRESH_CANARY' } });
  };
  add('acct_abcdefgh', 'first');
  put(paths.switchPath, { version: 1, desired: 'auto', active: 'acct_abcdefgh', pending: false, phase: 'idle' });
  put(f.markerPath, { schemaVersion: 1, installationId: 'install_integration_01', phase: 'uninitialized', paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, 'compatibility.json'), compatibility);
  for (const name of ['warmup.mjs', 'router-reader.mjs', 'chatgpt-probe.mjs', 'runtime.mjs', 'README.md']) put(path.join(f.companionRoot, name), '// synthetic deployed bytes');
  f.services.context = { root: f.companionRoot, nodePath: '/opt/homebrew/opt/node@22/bin/node', scriptPath };
  f.services.source = { inspect: () => ({ revision: compatibility.reviewedRevision, dirtyPaths: [] }) };
  const wire = `event: response.completed\ndata: ${JSON.stringify({ type: 'response.completed', response: { status: 'completed',
    output: [{ id: 'synthetic-item', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'WARMUP_OK' }] }] } })}\n\n`;
  let sends = 0;
  f.services.request = async (options, body, control) => {
    sends++;
    assert.equal(options.hostname, 'chatgpt.com'); assert.equal(options.path, '/backend-api/codex/responses');
    assert.equal(JSON.parse(body).model, 'gpt-6-luna');
    assert.ok(options.headers['chatgpt-account-id'].startsWith('workspace-'));
    control.beforeSend(); control.onDispatch();
    return { statusCode: 200, headers: { 'content-type': 'text/event-stream' }, body: (async function* () { yield Buffer.from(wire); })() };
  };
  const outputs = [];
  const call = async (argv, code = 0) => {
    const result = await execute(argv, f.services);
    outputs.push(result.json);
    assert.equal(result.exitCode, code, `${argv.join(' ')}: ${JSON.stringify(result.json)}`);
    for (const key of ['protocolVersion', 'command', 'outcome', 'reason', 'installationId', 'engineVersion', 'observedAt']) assert.ok(Object.hasOwn(result.json, key), key);
    assert.equal(result.json.protocolVersion, 1);
    assert.ok(Buffer.byteLength(JSON.stringify(result.json)) <= 1024 * 1024);
    assert.equal(JSON.stringify(result).includes('DO_NOT_PERSIST_REFRESH_CANARY'), false);
    return result.json;
  };
  return { ...f, paths, pool, add, outputs, call, sends: () => sends };
}

test('E assembled four-module CLI smoke uses real safe reader/probe with synthetic transport only', async () => {
  const f = assembled();
  try {
    await f.call(['setup']);
    const listed = await f.call(['list']);
    const rows = listed.rows ?? listed.accounts;
    assert.equal(rows.length, 1);
    const firstId = rows[0].enrollmentId;
    assert.notEqual(firstId, rows[0].routerAccountId);
    await f.call(['status']); assert.equal(f.sends(), 0);
    const auth = path.join(f.paths.homesDir, 'acct_abcdefgh', 'auth.json');
    const before = hash(fs.readFileSync(auth));
    const one = await f.call(['run', '--account', firstId]);
    assert.deepEqual([one.selected, one.attempted, one.results.length], [1, 1, 1]);
    assert.equal(hash(fs.readFileSync(auth)), before);
    await f.call(['run', '--account', 'acct_abcdefgh'], 2);
    f.add('acct_ijklmnop', 'later');
    await f.call(['setup']);
    const later = await f.call(['list']);
    assert.equal((later.rows ?? later.accounts).find(r => r.routerAccountId === 'acct_ijklmnop').enrollmentId, null);
    await f.call(['enroll', '--account', 'acct_ijklmnop']);
    const all = await f.call(['run']);
    assert.deepEqual([all.selected, all.attempted, all.results.length], [2, 2, 2]);
    assert.equal(f.sends(), 3);
    await f.call(['schedule', 'enable']);
    const tick = await f.call(['tick']);
    assert.equal(tick.attempted, 2);
    await f.call(['tick']); assert.equal(f.sends(), 5);
    await f.call(['schedule', 'disable']);
    const candidate = path.join(f.root, 'candidate.json');
    put(candidate, { schemaVersion: 1, config: JSON.parse(fs.readFileSync(f.configPath)),
      compatibility: JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'))), reviewEvidence: 'synthetic-review' });
    await f.call(['maintain', '--file', candidate]);
    await f.call(['remove']);
    assert.equal(fs.existsSync(f.companionRoot), false);
    assert.ok(fs.existsSync(f.paths.poolPath)); assert.ok(fs.existsSync(auth));
    assert.equal(JSON.stringify(f.outputs).includes('workspace-first'), false);
  } finally { f.cleanup(); }
});

test('E real dispatcher preserves all-blocked selection and exit-4 no-work distinction', async () => {
  const f = assembled();
  try {
    await f.call(['setup']);
    f.pool.accounts.acct_abcdefgh.paused = true;
    put(f.paths.poolPath, f.pool);
    const blocked = await f.call(['run'], 1);
    assert.deepEqual([blocked.selected, blocked.attempted, blocked.results.length], [1, 0, 1]);
    assert.notEqual(blocked.outcome, 'no_work');
    const config = JSON.parse(fs.readFileSync(f.configPath)); config.enrollments[0].enabled = false;
    const candidate = path.join(f.root, 'candidate.json');
    put(candidate, { schemaVersion: 1, config, compatibility: JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'))), reviewEvidence: 'synthetic-review' });
    await f.call(['maintain', '--file', candidate]);
    const empty = await f.call(['run'], 4);
    assert.deepEqual([empty.outcome, empty.reason, empty.selected, empty.attempted, empty.results], ['no_work', 'no_enabled_enrollments', 0, 0, []]);
    assert.equal(f.sends(), 0);
  } finally { f.cleanup(); }
});

test('E04 actual source digest drift after reservation blocks the final real-reader dispatch boundary', async () => {
  const f = assembled();
  try {
    await f.call(['setup']);
    let changed = false;
    f.services.fault = point => {
      if (point === 'after_state.json_rename' && !changed && Object.keys(JSON.parse(fs.readFileSync(f.statePath)).reservations).length) {
        changed = true;
        put(path.join(f.routerRoot, 'src/contract-0.mjs'), '// changed contract with unchanged revision/schema');
      }
    };
    const result = await f.call(['run'], 2);
    assert.equal(changed, true); assert.equal(result.attempted, 0); assert.equal(f.sends(), 0);
    assert.equal(result.selected, 1); assert.equal(result.results.length, 1);
    assert.equal(Object.keys(JSON.parse(fs.readFileSync(f.statePath)).reservations).length, 1);
  } finally { f.cleanup(); }
});

test('E04 real source change after the first snapshot send prevents later account sends', async () => {
  const f = assembled();
  try {
    await f.call(['setup']);
    f.add('acct_ijklmnop', 'later'); await f.call(['enroll', '--account', 'acct_ijklmnop']);
    const original = f.services.request;
    f.services.request = async (...args) => {
      const response = await original(...args);
      put(path.join(f.routerRoot, 'src/contract-0.mjs'), '// unreviewed same-schema update');
      return response;
    };
    const result = await f.call(['run'], 2);
    assert.equal(result.selected, 2); assert.equal(result.attempted, 1); assert.equal(result.results.length, 2);
    assert.equal(result.results[0].outcome, 'success'); assert.equal(f.sends(), 1);
  } finally { f.cleanup(); }
});

test('D01 identical selector strings still resolve only the command-declared namespace', async () => {
  const f = assembled();
  try {
    await f.call(['setup']);
    f.add('acct_ijklmnop', 'later'); await f.call(['enroll', '--account', 'acct_ijklmnop']);
    const config = JSON.parse(fs.readFileSync(f.configPath));
    config.enrollments[0].enrollmentId = 'acct_ijklmnop';
    const update = () => {
      const bytes = JSON.stringify(config); put(f.configPath, bytes);
      const state = JSON.parse(fs.readFileSync(f.statePath)); state.configDigest = hash(bytes); put(f.statePath, state);
    };
    update();
    const headers = [], original = f.services.request;
    f.services.request = async (...args) => { headers.push(args[0].headers['chatgpt-account-id']); return original(...args); };
    await f.call(['run', '--account', 'acct_ijklmnop']);
    assert.deepEqual(headers, ['workspace-first']);
    const repeated = await f.call(['enroll', '--account', 'acct_ijklmnop']);
    assert.equal(repeated.enrollmentId, config.enrollments[1].enrollmentId);
    config.enrollments[0].enabled = false; update();
    const disabled = await f.call(['run', '--account', 'acct_ijklmnop'], 2);
    assert.equal(disabled.attempted, 0); assert.equal(headers.length, 1);
  } finally { f.cleanup(); }
});

test('E05 actual CLI wrapper emits exactly one bounded JSON object with agreeing exits for every command', async () => {
  const f = assembled();
  try {
    const source = fs.readFileSync(scriptPath, 'utf8').replace(/^import\s[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '')
      .replace('const scriptPath = fileURLToPath(import.meta.url);', `const scriptPath = ${JSON.stringify(scriptPath)};`);
    assert.equal(source.includes('import.meta'), false);
    const call = async (argv, expected = 0) => {
      let stdout = '', stderr = '';
      const process = { argv: [f.services.context.nodePath, scriptPath, ...argv],
        stdout: { write(text) { stdout += text; } }, stderr: { write(text) { stderr += text; } }, exitCode: null };
      // Bind imports to the real dispatcher and synthetic capabilities; execute the unchanged CLI body.
      await vm.runInNewContext(`(async () => { ${source}\n })()`, { path, Buffer, runCommand, hostServices: () => f.services, process },
        { timeout: 5000, contextCodeGeneration: { strings: false, wasm: false } });
      assert.equal(process.exitCode, expected, `${argv.join(' ')}: ${stdout}`);
      assert.match(stdout, /^\{[^\n]*\}\n$/);
      assert.ok(Buffer.byteLength(stdout) <= 1024 * 1024); assert.ok(Buffer.byteLength(stderr) <= 64 * 1024);
      const result = JSON.parse(stdout);
      assert.equal(result.protocolVersion, 1); assert.ok(result.command && result.outcome && result.reason && result.observedAt);
      assert.ok(Object.hasOwn(result, 'installationId')); assert.ok(result.engineVersion);
      assert.equal((stdout + stderr).includes('DO_NOT_PERSIST_REFRESH_CANARY'), false);
      return result;
    };
    await call(['setup']);
    const rows = (await call(['list'])).rows;
    await call(['status']); await call(['run', '--account', rows[0].enrollmentId]);
    await call(['schedule', 'enable']); await call(['tick']); await call(['schedule', 'disable']);
    fs.mkdirSync(path.join(f.companionRoot, 'work.lock'), { mode: 0o700 });
    await call(['run'], 3); fs.rmdirSync(path.join(f.companionRoot, 'work.lock'));
    f.pool.accounts.acct_abcdefgh.paused = true; put(f.paths.poolPath, f.pool);
    await call(['run'], 1); f.pool.accounts.acct_abcdefgh.paused = false; put(f.paths.poolPath, f.pool);
    const config = JSON.parse(fs.readFileSync(f.configPath)); config.enrollments[0].enabled = false;
    const candidate = path.join(f.root, 'candidate.json');
    put(candidate, { schemaVersion: 1, config, compatibility: JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'))), reviewEvidence: 'synthetic-review' });
    await call(['maintain', '--file', candidate]); await call(['run'], 4);
    f.add('acct_ijklmnop', 'later'); await call(['enroll', '--account', 'acct_ijklmnop']);
    await call(['run']); await call(['run', '--account', 'missing'], 2);
    await call(['remove']); await call(['not_a_command'], 2);
  } finally { f.cleanup(); }
});

// Complete inventory of this declared synthetic tree, including directories and links.
function treeInventory(root) {
  const entries = [];
  function visit(dir, relative = '') {
    for (const name of fs.readdirSync(dir).sort()) {
      const rel = relative ? `${relative}/${name}` : name;
      const file = path.join(dir, name), stat = fs.lstatSync(file);
      const type = stat.isDirectory() ? 'directory' : stat.isFile() ? 'file' : stat.isSymbolicLink() ? 'link' : 'other';
      entries.push({ path: rel, type, mode: stat.mode & 0o7777,
        content: type === 'file' ? hash(fs.readFileSync(file)) : type === 'link' ? fs.readlinkSync(file) : null });
      if (type === 'directory') visit(file, rel);
    }
  }
  visit(root);
  return entries;
}
const readJSON = file => JSON.parse(fs.readFileSync(file));

test('E reviewed sibling source relocation uses the real reader and preserves equivalent state', async () => {
  const f = assembled();
  try {
    await f.call(['setup']);
    await f.call(['run']);
    await f.call(['schedule', 'enable']);
    await f.call(['tick']);
    await f.call(['schedule', 'disable']);
    const before = readJSON(f.statePath);
    assert.ok(Object.keys(before.pilots).length && Object.keys(before.reservations).length && before.history.length);
    const newRoot = path.join(f.root, 'relocated-router');
    fs.cpSync(f.routerRoot, newRoot, { recursive: true }); // Intentional fixture-owned copy.
    const oldTree = treeInventory(f.routerRoot), newTree = treeInventory(newRoot);
    const config = readJSON(f.configPath), compatibility = readJSON(path.join(f.companionRoot, 'compatibility.json'));
    config.paths.sourceRoot = newRoot;
    compatibility.reviewEvidence = 'synthetic-relocation-review';
    compatibility.sourcePathContract = 'synthetic-reviewed-sibling-root';
    const candidate = path.join(f.root, 'candidate.json');
    put(candidate, { schemaVersion: 1, config, compatibility, reviewEvidence: compatibility.reviewEvidence });
    const inspected = [];
    f.services.source.inspect = (root, names) => {
      inspected.push({ root, names });
      return { revision: compatibility.reviewedRevision, dirtyPaths: [] };
    };
    await f.call(['maintain', '--file', candidate]);
    const after = readJSON(f.statePath);
    assert.equal(after.configDigest, hash(fs.readFileSync(f.configPath)));
    assert.equal(after.compatibilityDigest, hash(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json'))));
    assert.deepEqual(readJSON(f.configPath), config);
    assert.deepEqual(readJSON(path.join(f.companionRoot, 'compatibility.json')), compatibility);
    for (const key of ['pilots', 'reservations', 'history']) assert.deepEqual(after[key], before[key]);
    assert.equal(after.scheduleEnabled, false);
    assert.equal(f.services.jobs.binding, null);
    assert.equal((await f.call(['status'])).compatibility, 'ready');
    await f.call(['run']);
    assert.ok(inspected.length >= 3);
    assert.ok(inspected.every(item => item.root === newRoot && item.names.length === 13));
    assert.deepEqual(treeInventory(f.routerRoot), oldTree);
    assert.deepEqual(treeInventory(newRoot), newTree);
  } finally { f.cleanup(); }
});

test('E missing inspected identity or consumed source blocks assembled manual dispatch', async () => {
  for (const failure of ['missing revision', 'invalid revision', 'missing file']) {
    const f = assembled();
    try {
      await f.call(['setup']);
      await f.call(['run']);
      const before = readJSON(f.statePath), sends = f.sends();
      if (failure === 'missing file') fs.unlinkSync(path.join(f.routerRoot, 'src/contract-0.mjs'));
      else f.services.source.inspect = () => ({ revision: failure === 'missing revision' ? undefined : 'invalid', dirtyPaths: [] });
      const result = await f.call(['run'], 2);
      assert.equal(result.attempted, 0, failure);
      assert.equal(f.sends(), sends, failure);
      const after = readJSON(f.statePath);
      assert.deepEqual(after.reservations, before.reservations, failure);
      assert.deepEqual(after.pilots, before.pilots, failure);
      assert.deepEqual(after.history.slice(0, before.history.length), before.history, failure);
    } finally { f.cleanup(); }
  }
});

test('E assembled commands preserve the complete declared synthetic Router tree', async () => {
  const f = assembled();
  try {
    put(path.join(f.routerRoot, 'unrelated/tracked.txt'), 'synthetic unrelated tracked file\n');
    // All fixture-owned source and account changes precede the snapshot.
    f.add('acct_ijklmnop', 'later');
    const before = treeInventory(f.routerRoot);
    assert.equal(before.filter(entry => entry.type === 'file').length, 14);
    assert.ok(before.some(entry => entry.path === 'unrelated/tracked.txt'));
    await f.call(['setup']);
    await f.call(['list']);
    await f.call(['status']);
    await f.call(['run']);
    await f.call(['enroll', '--account', 'acct_ijklmnop']);
    await f.call(['schedule', 'enable']);
    await f.call(['tick']);
    await f.call(['schedule', 'disable']);
    const candidate = path.join(f.root, 'candidate.json');
    put(candidate, { schemaVersion: 1, config: readJSON(f.configPath),
      compatibility: readJSON(path.join(f.companionRoot, 'compatibility.json')), reviewEvidence: 'synthetic-review' });
    await f.call(['maintain', '--file', candidate]);
    await f.call(['remove']);
    assert.deepEqual(treeInventory(f.routerRoot), before);
  } finally { f.cleanup(); }
});
