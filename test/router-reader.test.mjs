import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { makeFixture } from './helpers.mjs';
import { safeRead, readRegistry, discoverIdentity, readCredential, revalidate, checkCompatibility } from '../router-reader.mjs';

const ID = 'acct_abcdefgh', ID2 = 'acct_ijklmnop';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
function put(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value), { mode: 0o600 }); }
function jwt(value) { return `x.${Buffer.from(JSON.stringify(value)).toString('base64url')}.x`; }
function auth(accountId = 'workspace-a', userId = 'user-a', expiry = 1893456000) { return { tokens: { access_token: jwt({ exp: expiry }), account_id: accountId, id_token: jwt({ 'https://api.openai.com/auth': { chatgpt_user_id: userId } }), refresh_token: 'CANARY_REFRESH' } }; }
function account(id) { return { id, state: 'active', paused: false, priority: 0, health: { state: 'healthy' }, turns: 0, requests: 0 }; }
function fixture() {
  const f = makeFixture();
  const sourceDigests = {};
  for (let n = 0; n < 13; n++) { const name = `src/contract-${n}.mjs`, value = `// synthetic ${n}\n`; put(path.join(f.routerRoot, name), value); sourceDigests[name] = hash(value); }
  const paths = { sourceRoot: f.routerRoot, stateRoot: path.join(f.root, 'state'), codexHome: path.join(f.root, 'codex'), poolPath: path.join(f.root, 'state/pool.json'), homesDir: path.join(f.root, 'state/homes'), switchPath: path.join(f.root, 'state/switch.json'), discoveryPath: path.join(f.root, 'state/discovery-mode.json') };
  for (const dir of [paths.stateRoot, paths.codexHome, paths.homesDir]) fs.mkdirSync(dir, { mode: 0o700 });
  const pool = { version: 1, policy: { enabled: true, mode: 'switch', selectedAccountId: ID }, accounts: { [ID]: { ...account(ID), identity: { accountId: 'workspace-a', userId: 'user-a' } }, [ID2]: { ...account(ID2), identity: { accountId: 'workspace-b', userId: 'user-b' } } }, sessions: {} };
  put(paths.poolPath, pool); put(paths.switchPath, { version: 1, desired: 'auto', active: ID, pending: false, phase: 'idle' }); put(path.join(paths.codexHome, 'auth.json'), auth()); put(path.join(paths.homesDir, ID, 'auth.json'), auth()); put(path.join(paths.homesDir, ID2, 'auth.json'), auth('workspace-b','user-b'));
  const compatibility = { schemaVersion: 1, reviewedRevision: 'a'.repeat(40), sourceDigests, adapterVersion: 1, requestContractVersion: 1, sourcePathContract: 'synthetic', reviewEvidence: 'synthetic-review', semantics: 'equivalent' };
  f.services.source = { inspect: () => ({ revision: compatibility.reviewedRevision, dirtyPaths: [] }) };
  return { ...f, paths, pool, context: { paths, compatibility } };
}

test('B-reader safeRead descriptor, containment, modes, ACL and size', () => {
  const f = fixture();
  try {
    const file = path.join(f.paths.stateRoot, 'small.json'); put(file, { ok: true });
    assert.equal(safeRead(file, f.services, { root: f.paths.stateRoot, limit: 100 }).value.ok, true);
    assert.throws(() => safeRead(file, f.services, { root: f.paths.homesDir, limit: 100 }));
    fs.chmodSync(file, 0o644); assert.throws(() => safeRead(file, f.services, { root: f.paths.stateRoot, limit: 100 })); fs.chmodSync(file, 0o600);
    assert.throws(() => safeRead(file, { ...f.services, acl: () => false }, { root: f.paths.stateRoot, limit: 100 }));
    assert.throws(() => safeRead(file, f.services, { root: f.paths.stateRoot, limit: 2 }));
    const linked = { ...f.services, files: { ...fs, lstatSync(target) { const stat = fs.lstatSync(target); if (target === file) return { ...stat, isFile: () => false, isSymbolicLink: () => true }; return stat; } } };
    assert.throws(() => safeRead(file, linked, { root: f.paths.stateRoot, limit: 100 }));
    const swapped = { ...f.services, files: { ...fs, openSync(target, flags) { put(target, { changed: true }); return fs.openSync(target, flags); } } };
    assert.throws(() => safeRead(file, swapped, { root: f.paths.stateRoot, limit: 100 }));
  } finally { f.cleanup(); }
});

test('B-reader strict registry, source drift and discovery override', () => {
  const f = fixture();
  try {
    assert.equal(readRegistry(f.context, f.services).kind, 'ready');
    assert.equal(checkCompatibility(f.context, f.services).kind, 'ready');
    f.services.source.inspect = () => ({ revision: 'b'.repeat(40), dirtyPaths: [] });
    assert.deepEqual(checkCompatibility(f.context, f.services), { kind: 'blocked', scope: 'global', reason: 'compatibility_unavailable' });
    f.services.source.inspect = () => ({ revision: f.context.compatibility.reviewedRevision, dirtyPaths: ['src/contract-1.mjs'] });
    assert.equal(checkCompatibility(f.context, f.services).kind, 'blocked');
    f.services.source.inspect = () => ({ revision: f.context.compatibility.reviewedRevision, dirtyPaths: [] });
    put(path.join(f.routerRoot, 'src/contract-1.mjs'), 'changed'); assert.equal(checkCompatibility(f.context, f.services).kind, 'blocked');
    put(path.join(f.routerRoot, 'src/contract-1.mjs'), '// synthetic 1\n');
    fs.rmSync(path.join(f.routerRoot, 'src/contract-1.mjs'));
    assert.deepEqual(checkCompatibility(f.context, f.services), { kind: 'blocked', scope: 'global', reason: 'compatibility_unavailable' });
    put(path.join(f.routerRoot, 'src/contract-1.mjs'), '// synthetic 1\n');
    const bad = structuredClone(f.pool); delete bad.accounts[ID].paused; put(f.paths.poolPath, bad);
    assert.equal(readRegistry(f.context, f.services).kind, 'blocked'); put(f.paths.poolPath, f.pool);
    f.paths.discoveryOverride = '1'; assert.equal(readRegistry(f.context, f.services).kind, 'blocked');
    f.paths.discoveryOverride = '0'; assert.equal(readRegistry(f.context, f.services).kind, 'ready');
  } finally { f.cleanup(); }
});

test('B02 Router switching disabled does not disable explicit companion enrollment or safe reads', () => {
  const f = fixture();
  try {
    f.pool.policy.enabled = false;
    put(f.paths.poolPath, f.pool);
    assert.equal(readRegistry(f.context, f.services).kind, 'ready');
    assert.equal(discoverIdentity(f.context, ID, f.services).kind, 'ready');
    assert.equal(readCredential(f.context, { routerAccountId: ID, identity: f.pool.accounts[ID].identity }, f.services).kind, 'ready');
    f.paths.discoveryOverride = '1';
    assert.equal(readRegistry(f.context, f.services).kind, 'blocked');
  } finally { f.cleanup(); }
});

test('B-reader identity, own saved profile, expiry, leases and snapshot drift', () => {
  const f = fixture();
  try {
    const found = discoverIdentity(f.context, ID, f.services);
    assert.deepEqual(found.identity, { accountId: 'workspace-a', userId: 'user-a' });
    assert.equal(found.accessToken, undefined);
    const enrollment = { routerAccountId: ID, identity: found.identity };
    const ready = readCredential(f.context, enrollment, f.services);
    assert.equal(ready.sourceKind, 'primary');
    assert.equal(revalidate(f.context, enrollment, ready.snapshot, f.services).kind, 'ready');
    put(path.join(f.paths.codexHome, 'auth.json'), auth('workspace-a','user-a',1));
    assert.equal(readCredential(f.context, enrollment, f.services).reason, 'credential_expired_or_unknown');
    fs.rmSync(path.join(f.paths.codexHome, 'auth.json'));
    assert.equal(readCredential(f.context, enrollment, f.services).sourceKind, 'saved');
    const other = discoverIdentity(f.context, ID2, f.services);
    assert.equal(other.sourceKind, 'saved');
    put(path.join(f.paths.homesDir, ID2, 'router-login-lease.relocated-00000000-0000-0000-0000-000000000000.json'), {});
    assert.equal(readCredential(f.context, { routerAccountId: ID2, identity: other.identity }, f.services).reason, 'login_lease');
    assert.equal(revalidate(f.context, enrollment, ready.snapshot, f.services).kind, 'blocked');
  } finally { f.cleanup(); }
});

test('B-reader selected primary requires active marker and falls back only for complete nonmatch', () => {
  const f = fixture();
  try {
    const enrollment = { routerAccountId: ID, identity: f.pool.accounts[ID].identity };
    assert.equal(readCredential(f.context, enrollment, f.services).sourceKind, 'primary');
    fs.rmSync(f.paths.switchPath);
    assert.equal(readCredential(f.context, enrollment, f.services).sourceKind, 'saved');
    put(f.paths.switchPath, { version: 1, desired: 'auto', active: ID, pending: false, phase: 'idle' });
    put(path.join(f.paths.codexHome, 'auth.json'), auth('workspace-other', 'user-other'));
    assert.equal(readCredential(f.context, enrollment, f.services).sourceKind, 'saved');
    assert.equal(discoverIdentity(f.context, ID, f.services).sourceKind, 'saved');
    put(path.join(f.paths.codexHome, 'auth.json'), { tokens: { access_token: 'bad', account_id: 'workspace-a' } });
    assert.equal(readCredential(f.context, enrollment, f.services).reason, 'primary_untrusted');
    put(f.paths.switchPath, { version: 1, desired: ID2, active: ID, pending: false, phase: 'idle' });
    assert.equal(readCredential(f.context, enrollment, f.services).kind, 'blocked');
  } finally { f.cleanup(); }
});

test('B-reader blocks coordination, duplicate identity and nonselected primary substitution', () => {
  const f = fixture();
  try {
    const other = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    fs.rmSync(path.join(f.paths.homesDir, ID2, 'auth.json'));
    put(path.join(f.paths.codexHome, 'auth.json'), auth('workspace-b', 'user-b'));
    assert.notEqual(readCredential(f.context, other, f.services).kind, 'ready');
    put(path.join(f.paths.homesDir, ID2, 'auth.json'), auth('workspace-b', 'user-b'));
    assert.equal(readCredential(f.context, other, f.services).sourceKind, 'saved');
    f.pool.accounts[ID2].identity = f.pool.accounts[ID].identity;
    put(f.paths.poolPath, f.pool);
    assert.equal(readRegistry(f.context, f.services).kind, 'blocked');
    f.pool.accounts[ID2].identity = { accountId: 'workspace-b', userId: 'user-b' };
    put(f.paths.poolPath, f.pool);
    for (const marker of [`${f.paths.poolPath}.pool-lock.lock`, path.join(f.paths.stateRoot, 'catalog-publication.lock'), path.join(f.paths.stateRoot, 'chatgpt-profile/switch-transaction')]) {
      fs.mkdirSync(marker, { recursive: true, mode: 0o700 });
      assert.equal(readRegistry(f.context, f.services).kind, 'blocked');
      fs.rmSync(marker, { recursive: true });
    }
  } finally { f.cleanup(); }
});

test('B-reader rejects API key, missing expiry and snapshot switch change', () => {
  const f = fixture();
  try {
    const e = { routerAccountId: ID, identity: f.pool.accounts[ID].identity };
    const first = readCredential(f.context, e, f.services);
    assert.equal(first.kind, 'ready');
    put(f.paths.switchPath, { version: 1, desired: ID, active: ID, pending: false, phase: 'idle' });
    assert.equal(revalidate(f.context, e, first.snapshot, f.services).reason, 'snapshot_changed');
    put(path.join(f.paths.codexHome, 'auth.json'), { auth_mode: 'apikey', OPENAI_API_KEY: 'CANARY_KEY' });
    assert.equal(readCredential(f.context, e, f.services).reason, 'primary_untrusted');
    put(path.join(f.paths.codexHome, 'auth.json'), auth('workspace-a', 'user-a', null));
    assert.equal(readCredential(f.context, e, f.services).reason, 'credential_expired_or_unknown');
  } finally { f.cleanup(); }
});

test('B-reader derives legacy user from complete saved auth and permits safe selected fallback', () => {
  const f = fixture();
  try {
    delete f.pool.accounts[ID].identity.userId;
    put(f.paths.poolPath, f.pool);
    assert.deepEqual(discoverIdentity(f.context, ID, f.services).identity, { accountId: 'workspace-a', userId: 'user-a' });
    put(path.join(f.paths.codexHome, 'auth.json'), auth('workspace-other', 'user-other'));
    const found = discoverIdentity(f.context, ID, f.services);
    assert.equal(found.sourceKind, 'saved');
    const e = { routerAccountId: ID, identity: found.identity };
    assert.equal(readCredential(f.context, e, f.services).sourceKind, 'saved');
    put(path.join(f.paths.codexHome, 'auth.json'), auth('workspace-a', 'different-user'));
    assert.equal(discoverIdentity(f.context, ID, f.services).reason, 'identity_ambiguous');
  } finally { f.cleanup(); }
});

test('B-reader checks 120-second expiry boundary and local lease scan failure', () => {
  const f = fixture();
  try {
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    const now = f.services.clock.wall();
    put(path.join(f.paths.homesDir, ID2, 'auth.json'), auth('workspace-b', 'user-b', Math.floor((now + 120000) / 1000)));
    assert.equal(readCredential(f.context, e, f.services).kind, 'ready');
    f.services.clock.advance(1);
    assert.equal(readCredential(f.context, e, f.services).reason, 'credential_expired_or_unknown');
    const original = f.services.files;
    f.services.files = { ...fs, readdirSync(dir) { if (dir === path.join(f.paths.homesDir, ID2)) throw new Error('denied'); return fs.readdirSync(dir); } };
    assert.equal(readCredential(f.context, e, f.services).kind, 'blocked');
    f.services.files = original;
  } finally { f.cleanup(); }
});

test('B-reader rejects parent symlink, forged owner, invalid JSON and oversized metadata', () => {
  const f = fixture();
  try {
    const file = path.join(f.paths.stateRoot, 'small.json'); put(file, { ok: true });
    const link = path.join(f.paths.stateRoot, 'linked'); fs.symlinkSync(f.paths.homesDir, link);
    assert.throws(() => safeRead(path.join(link, ID, 'auth.json'), f.services, { root: f.paths.stateRoot, limit: 1024 }));
    const owner = { ...f.services, files: { ...fs, lstatSync(target) { const s = fs.lstatSync(target); return target === file ? { ...s, uid: s.uid + 1 } : s; } } };
    assert.throws(() => safeRead(file, owner, { root: f.paths.stateRoot, limit: 1024 }));
    const acl = { ...f.services, acl: target => target !== f.paths.stateRoot };
    assert.throws(() => safeRead(file, acl, { root: f.paths.stateRoot, limit: 1024 }));
    put(file, '{'); assert.throws(() => safeRead(file, f.services, { root: f.paths.stateRoot, limit: 1024 }));
    put(file, 'x'.repeat(1025)); assert.throws(() => safeRead(file, f.services, { root: f.paths.stateRoot, limit: 1024 }));
  } finally { f.cleanup(); }
});

test('B-reader exact active predicate and distinct users sharing workspace', () => {
  const f = fixture();
  try {
    for (const [state, paused] of [['paused', false], ['revoked', false], ['active', true]]) {
      f.pool.accounts[ID2].state = state; f.pool.accounts[ID2].paused = paused; put(f.paths.poolPath, f.pool);
      assert.equal(discoverIdentity(f.context, ID2, f.services).reason, 'registry_ineligible');
    }
    f.pool.accounts[ID2].state = 'unknown'; put(f.paths.poolPath, f.pool);
    assert.equal(readRegistry(f.context, f.services).kind, 'blocked');
    f.pool.accounts[ID2].state = 'active'; f.pool.accounts[ID2].paused = false;
    f.pool.accounts[ID2].identity.accountId = 'workspace-a'; put(f.paths.poolPath, f.pool);
    put(path.join(f.paths.homesDir, ID2, 'auth.json'), auth('workspace-a', 'user-b'));
    assert.equal(discoverIdentity(f.context, ID2, f.services).kind, 'ready');
    put(path.join(f.paths.homesDir, ID2, 'auth.json'), { auth_mode: 'apikey', OPENAI_API_KEY: 'CANARY' });
    assert.equal(discoverIdentity(f.context, ID2, f.services).kind, 'blocked');
  } finally { f.cleanup(); }
});

test('B-reader switch pending and staging are global blocks; relocated lease is account block', () => {
  const f = fixture();
  try {
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    put(f.paths.switchPath, { version: 1, desired: 'auto', active: ID, pending: true, phase: 'idle' });
    assert.equal(readCredential(f.context, e, f.services).kind, 'blocked');
    put(f.paths.switchPath, { version: 1, desired: 'auto', active: ID, pending: false, phase: 'idle' });
    const staging = path.join(f.paths.stateRoot, 'chatgpt-profile/switch-transaction.staging');
    fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
    assert.equal(readCredential(f.context, e, f.services).kind, 'blocked');
    fs.rmSync(staging, { recursive: true });
    put(path.join(f.paths.homesDir, ID2, 'router-login-lease.relocated-00000000-0000-0000-0000-000000000000.json'), {});
    assert.equal(readCredential(f.context, e, f.services).reason, 'login_lease');
  } finally { f.cleanup(); }
});

test('B01 applies actual auth and registry byte limits at the boundary', () => {
  const f = fixture();
  try {
    const saved = path.join(f.paths.homesDir, ID2, 'auth.json');
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    const authValue = { ...auth('workspace-b', 'user-b'), padding: '' };
    const authBase = Buffer.byteLength(JSON.stringify(authValue));
    authValue.padding = 'x'.repeat(1024 * 1024 - authBase);
    put(saved, authValue);
    assert.equal(readCredential(f.context, e, f.services).kind, 'ready');
    authValue.padding += 'x'; put(saved, authValue);
    assert.equal(readCredential(f.context, e, f.services).reason, 'saved_untrusted');

    const registryValue = { ...f.pool, padding: '' };
    const registryBase = Buffer.byteLength(JSON.stringify(registryValue));
    registryValue.padding = 'x'.repeat(8 * 1024 * 1024 - registryBase);
    put(f.paths.poolPath, registryValue);
    assert.equal(readRegistry(f.context, f.services).kind, 'ready');
    registryValue.padding += 'x'; put(f.paths.poolPath, registryValue);
    assert.deepEqual(readRegistry(f.context, f.services), { kind: 'blocked', scope: 'global', reason: 'registry_unavailable' });
  } finally { f.cleanup(); }
});

test('B02 expired OAuth remains discoverable but cannot supply dispatch credentials', () => {
  const f = fixture();
  try {
    const saved = path.join(f.paths.homesDir, ID2, 'auth.json');
    put(saved, auth('workspace-b', 'user-b', 1));
    const found = discoverIdentity(f.context, ID2, f.services);
    assert.equal(found.kind, 'ready');
    assert.deepEqual(found.identity, { accountId: 'workspace-b', userId: 'user-b' });
    assert.equal(found.accessToken, undefined);
    assert.deepEqual(readCredential(f.context, { routerAccountId: ID2, identity: found.identity }, f.services), {
      kind: 'blocked', scope: 'account', reason: 'credential_expired_or_unknown',
    });
  } finally { f.cleanup(); }
});

test('B02 excludes malformed, API-key and non-ChatGPT providers with account reasons', () => {
  const f = fixture();
  try {
    const saved = path.join(f.paths.homesDir, ID2, 'auth.json');
    put(saved, { ...auth('workspace-b', 'user-b'), auth_mode: 'chatgpt' });
    assert.deepEqual(discoverIdentity(f.context, ID2, f.services).identity, { accountId: 'workspace-b', userId: 'user-b' });
    for (const value of [
      { tokens: { access_token: 'bad', account_id: 'workspace-b' } },
      { auth_mode: 'apikey', OPENAI_API_KEY: 'CANARY' },
      { ...auth('workspace-b', 'user-b'), auth_mode: 'other-provider' },
    ]) {
      put(saved, value);
      assert.deepEqual(discoverIdentity(f.context, ID2, f.services), { kind: 'blocked', scope: 'account', reason: 'saved_untrusted' });
    }
  } finally { f.cleanup(); }
});

test('B04 full identity, not shared workspace or email, authorizes an account reference', () => {
  const f = fixture();
  try {
    const own = f.pool.accounts[ID2].identity;
    const saved = path.join(f.paths.homesDir, ID2, 'auth.json');
    assert.equal(readCredential(f.context, { routerAccountId: ID2, identity: f.pool.accounts[ID].identity }, f.services).reason, 'identity_mismatch');
    put(saved, auth('workspace-b', 'different-user'));
    assert.equal(readCredential(f.context, { routerAccountId: ID2, identity: own }, f.services).reason, 'identity_mismatch');
    put(saved, { tokens: { access_token: jwt({ exp: 1893456000 }), account_id: 'workspace-b', id_token: jwt({ email: 'user-b@example.test' }) } });
    assert.deepEqual(discoverIdentity(f.context, ID2, f.services), { kind: 'blocked', scope: 'account', reason: 'saved_untrusted' });
  } finally { f.cleanup(); }
});

test('B05 missing, nonfinite and unknown expiry cannot dispatch; elapsed final revalidation blocks', () => {
  const f = fixture();
  try {
    const saved = path.join(f.paths.homesDir, ID2, 'auth.json');
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    for (const token of [jwt({}), jwt({ exp: 'Infinity' }), jwt({ exp: 1e100 }), 'opaque-token']) {
      const value = auth('workspace-b', 'user-b'); value.tokens.access_token = token; put(saved, value);
      const before = fs.readFileSync(saved);
      assert.equal(readCredential(f.context, e, f.services).reason, 'credential_expired_or_unknown');
      assert.deepEqual(fs.readFileSync(saved), before);
    }
    const now = f.services.clock.wall();
    put(saved, auth('workspace-b', 'user-b', Math.ceil((now + 121000) / 1000)));
    const first = readCredential(f.context, e, f.services);
    assert.equal(first.kind, 'ready');
    const before = fs.readFileSync(saved);
    f.services.clock.advance(2000);
    assert.deepEqual(revalidate(f.context, e, first.snapshot, f.services), { kind: 'blocked', scope: 'account', reason: 'credential_expired_or_unknown' });
    assert.deepEqual(fs.readFileSync(saved), before);
  } finally { f.cleanup(); }
});

test('B06 unreadable discovery marker is global; local lease is account-scoped without mutation', () => {
  const f = fixture();
  try {
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    const marker = f.paths.discoveryPath;
    put(marker, { version: 1, discovery: 'enabled' });
    fs.chmodSync(marker, 0o000);
    assert.deepEqual(readRegistry(f.context, f.services), { kind: 'blocked', scope: 'global', reason: 'registry_unavailable' });
    fs.chmodSync(marker, 0o600);
    const leaseFile = path.join(f.paths.homesDir, ID2, 'router-login-lease.json');
    put(leaseFile, { refresh: 'CANARY' });
    const before = fs.readFileSync(leaseFile);
    assert.deepEqual(readCredential(f.context, e, f.services), { kind: 'blocked', scope: 'account', reason: 'login_lease' });
    assert.deepEqual(fs.readFileSync(leaseFile), before);
    fs.rmSync(leaseFile);
    const lock = `${f.paths.poolPath}.pool-lock.lock`;
    put(lock, 'CANARY_ROUTER_LOCK');
    const lockBefore = fs.readFileSync(lock);
    assert.deepEqual(readCredential(f.context, e, f.services), { kind: 'blocked', scope: 'global', reason: 'reader_unavailable' });
    assert.deepEqual(fs.readFileSync(lock), lockBefore);
  } finally { f.cleanup(); }
});


test('B05 credential expiry reads never request refresh or open a writable file', () => {
  const f = fixture();
  try {
    const saved = path.join(f.paths.homesDir, ID2, 'auth.json');
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    put(saved, auth('workspace-b', 'user-b', 1));
    let writes = 0, refreshes = 0;
    const mutation = () => { writes++; throw Error('WRITE_FORBIDDEN'); };
    f.services.files = new Proxy(fs, { get(target, key) {
      if (['writeFileSync','appendFileSync','writeSync','renameSync','unlinkSync','mkdirSync','rmdirSync','rmSync','chmodSync','chownSync','truncateSync','ftruncateSync','symlinkSync','linkSync','copyFileSync'].includes(key)) return mutation;
      if (key === 'openSync') return (file, flags, mode) => {
        if (typeof flags !== 'number' || flags & (fs.constants.O_WRONLY | fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_APPEND)) return mutation();
        return fs.openSync(file, flags, mode);
      };
      return target[key];
    } });
    f.services.refresh = () => { refreshes++; throw Error('REFRESH_FORBIDDEN'); };
    assert.equal(readCredential(f.context, e, f.services).reason, 'credential_expired_or_unknown');
    assert.equal(writes, 0); assert.equal(refreshes, 0); assert.equal(f.services.request.calls.length, 0);
  } finally { f.cleanup(); }
});

test('B06 pending and staging are global while local and relocated leases are account scoped and untouched', () => {
  const f = fixture();
  try {
    const e = { routerAccountId: ID2, identity: f.pool.accounts[ID2].identity };
    put(f.paths.switchPath, { version: 1, desired: 'auto', active: ID, pending: true, phase: 'idle' });
    assert.equal(readCredential(f.context, e, f.services).scope, 'global');
    put(f.paths.switchPath, { version: 1, desired: 'auto', active: ID, pending: false, phase: 'idle' });
    const staging = path.join(f.paths.stateRoot, 'chatgpt-profile/switch-transaction.staging');
    fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
    assert.equal(readCredential(f.context, e, f.services).scope, 'global'); fs.rmSync(staging, { recursive: true });
    for (const name of ['router-login-lease.json', 'router-login-lease.relocated-00000000-0000-0000-0000-000000000000.json']) {
      const file = path.join(f.paths.homesDir, ID2, name); put(file, { phase: 'running', attention: 'synthetic-refresh' });
      const before = fs.readFileSync(file);
      assert.deepEqual(readCredential(f.context, e, f.services), { kind: 'blocked', scope: 'account', reason: 'login_lease' });
      assert.deepEqual(fs.readFileSync(file), before); fs.unlinkSync(file);
    }
  } finally { f.cleanup(); }
});

test('OAuth null API-key sentinel permits enrollment and dispatch for selected and saved profiles', () => {
  const f = fixture();
  try {
    for (const [id, file, accountId, userId, sourceKind] of [
      [ID, path.join(f.paths.codexHome, 'auth.json'), 'workspace-a', 'user-a', 'primary'],
      [ID2, path.join(f.paths.homesDir, ID2, 'auth.json'), 'workspace-b', 'user-b', 'saved'],
    ]) {
      for (const sentinel of ['absent', 'null']) {
        const value = { ...auth(accountId, userId), auth_mode: 'chatgpt' };
        if (sentinel === 'null') value.OPENAI_API_KEY = null;
        put(file, value);
        const found = discoverIdentity(f.context, id, f.services);
        assert.equal(found.kind, 'ready');
        assert.equal(found.sourceKind, sourceKind);
        assert.deepEqual(found.identity, { accountId, userId });
        assert.equal(JSON.stringify(found).includes('CANARY_REFRESH'), false);
        assert.equal(JSON.stringify(found).includes(value.tokens.access_token), false);
        assert.equal(JSON.stringify(found).includes(value.tokens.id_token), false);
        const enrollment = { routerAccountId: id, identity: found.identity };
        const ready = readCredential(f.context, enrollment, f.services);
        assert.equal(ready.kind, 'ready');
        assert.equal(ready.sourceKind, sourceKind);
        assert.equal(ready.accessToken, value.tokens.access_token);
        assert.equal(JSON.stringify(ready).includes('CANARY_REFRESH'), false);
        assert.equal(JSON.stringify(ready).includes(value.tokens.id_token), false);
        assert.equal(revalidate(f.context, enrollment, ready.snapshot, f.services).kind, 'ready');
      }
    }
  } finally { f.cleanup(); }
});

test('OAuth null sentinel preserves key, mode, identity, expiry and revalidation rejection', () => {
  const f = fixture();
  try {
    for (const [id, file, accountId, userId, reason] of [
      [ID, path.join(f.paths.codexHome, 'auth.json'), 'workspace-a', 'user-a', 'primary_untrusted'],
      [ID2, path.join(f.paths.homesDir, ID2, 'auth.json'), 'workspace-b', 'user-b', 'saved_untrusted'],
    ]) {
      const enrollment = { routerAccountId: id, identity: { accountId, userId } };
      const base = { ...auth(accountId, userId), auth_mode: 'chatgpt', OPENAI_API_KEY: null };
      put(file, base);
      const initial = readCredential(f.context, enrollment, f.services);
      assert.equal(initial.kind, 'ready');
      const invalid = [
        ...['', false, 0, {}, [], 'CANARY_KEY'].map(key => ({ ...base, OPENAI_API_KEY: key })),
        { ...base, auth_mode: 'apikey' }, { ...base, auth_mode: 'other-provider' },
        { ...base, tokens: { ...base.tokens, id_token: 'malformed' } },
        { ...base, tokens: { ...base.tokens, access_token: '' } },
      ];
      for (const value of invalid) {
        put(file, value);
        for (const result of [discoverIdentity(f.context, id, f.services), readCredential(f.context, enrollment, f.services), revalidate(f.context, enrollment, initial.snapshot, f.services)]) {
          assert.deepEqual(result, { kind: 'blocked', scope: 'account', reason });
          assert.equal(JSON.stringify(result).includes('CANARY'), false);
        }
      }
      for (const token of [jwt({ exp: 1 }), jwt({}), 'opaque-token']) {
        put(file, { ...base, tokens: { ...base.tokens, access_token: token } });
        const found = discoverIdentity(f.context, id, f.services);
        assert.equal(found.kind, 'ready');
        assert.equal(JSON.stringify(found).includes('CANARY_REFRESH'), false);
        assert.equal(readCredential(f.context, enrollment, f.services).reason, 'credential_expired_or_unknown');
        assert.equal(revalidate(f.context, enrollment, initial.snapshot, f.services).reason, 'credential_expired_or_unknown');
      }
      put(file, base);
      fs.chmodSync(file, 0o644);
      assert.equal(discoverIdentity(f.context, id, f.services).reason, reason);
      assert.equal(readCredential(f.context, enrollment, f.services).reason, reason);
      assert.equal(revalidate(f.context, enrollment, initial.snapshot, f.services).reason, reason);
    }
  } finally { f.cleanup(); }
});

for (const [label, id, accountId, userId, sourceKind] of [
  ['selected primary', ID, 'workspace-a', 'user-a', 'primary'],
  ['nonselected saved', ID2, 'workspace-b', 'user-b', 'saved'],
]) {
  test(`reader projects ${label} identity without registry or enrollment metadata`, () => {
    const f = fixture();
    try {
      const expected = { accountId, userId };
      const metadata = { alias: 'CANARY_METADATA', nested: { accountId: 'wrong-account', userId: 'wrong-user' } };
      Object.assign(f.pool.accounts[id].identity, metadata);
      put(f.paths.poolPath, f.pool);
      const found = discoverIdentity(f.context, id, f.services);
      assert.equal(found.kind, 'ready');
      assert.equal(found.sourceKind, sourceKind);
      assert.deepEqual(found.identity, expected);
      const secret = auth(accountId, userId).tokens;
      for (const value of [secret.access_token, secret.id_token, secret.refresh_token, 'CANARY_METADATA']) {
        assert.equal(JSON.stringify(found).includes(value), false);
      }
      const enrollment = { routerAccountId: id, identity: { ...expected, ...metadata } };
      const ready = readCredential(f.context, enrollment, f.services);
      assert.equal(ready.kind, 'ready');
      assert.equal(ready.sourceKind, sourceKind);
      assert.deepEqual(ready.identity, expected);
      assert.equal(JSON.stringify(ready).includes('CANARY_METADATA'), false);
      const checked = revalidate(f.context, enrollment, ready.snapshot, f.services);
      assert.equal(checked.kind, 'ready');
      assert.deepEqual(checked.identity, expected);
      assert.equal(JSON.stringify(checked).includes('CANARY_METADATA'), false);
      for (const field of ['accountId', 'userId']) {
        const wrong = { routerAccountId: id, identity: { ...enrollment.identity, [field]: 'wrong-value' } };
        assert.equal(readCredential(f.context, wrong, f.services).reason, 'identity_mismatch');
        assert.equal(revalidate(f.context, wrong, ready.snapshot, f.services).reason, 'identity_mismatch');
        const original = f.pool.accounts[id].identity[field];
        f.pool.accounts[id].identity[field] = 'wrong-value';
        put(f.paths.poolPath, f.pool);
        assert.equal(discoverIdentity(f.context, id, f.services).reason, 'identity_mismatch');
        f.pool.accounts[id].identity[field] = original;
        put(f.paths.poolPath, f.pool);
      }
    } finally { f.cleanup(); }
  });
}
