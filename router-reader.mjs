import path from 'node:path';
import crypto from 'node:crypto';

const idPattern = /^acct_[A-Za-z0-9_-]{8,80}$/;
const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const blocked = (scope, reason) => ({ kind: 'blocked', scope, reason });
const same = (a, b) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs;
const hasControls = value => /[\u0000-\u001f\u007f]/.test(value);

export function checkRootAncestors(root, services) {
  if (typeof root !== 'string' || !path.isAbsolute(root) || path.resolve(root) !== root || typeof services?.files?.lstatSync !== 'function') throw new Error('unsafe_root');
  for (let current = root; ; current = path.dirname(current)) {
    const stat = services.files.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('unsafe_root');
    if (current === path.dirname(current)) break;
  }
}

export function safeRead(file, services, { root, limit, json = true, optional = false, private: privateFile = true } = {}) {
  const fs = services?.files;
  if (!fs || !Number.isInteger(services.uid) || typeof services.acl !== 'function' || !path.isAbsolute(root) || !path.isAbsolute(file) || !Number.isSafeInteger(limit) || limit < 1) throw new Error('unsafe_read_contract');
  const relative = path.relative(root, file);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error('unsafe_path');
  const parts = [root, ...relative.split(path.sep).slice(0, -1).map((_, i, all) => path.join(root, ...all.slice(0, i + 1)))];
  const protectedStat = (stat, target) => stat.uid === services.uid && (stat.mode & (privateFile ? 0o077 : 0o022)) === 0 && services.acl(target) === true;
  const checkParents = () => { checkRootAncestors(root, services); for (const dir of parts) { const stat = fs.lstatSync(dir); if (!stat.isDirectory() || stat.isSymbolicLink() || !protectedStat(stat, dir)) throw new Error('unsafe_parent'); } };
  checkParents();
  let before;
  try { before = fs.lstatSync(file); } catch (error) { if (optional && error?.code === 'ENOENT') return null; throw new Error('unsafe_file'); }
  if (!before.isFile() || before.isSymbolicLink() || before.size > limit || !protectedStat(before, file)) throw new Error('unsafe_file');
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || !same(before, opened) || opened.size > limit || !protectedStat(opened, file)) throw new Error('changed_file');
    const buffer = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < buffer.length) {
      const count = fs.readSync(fd, buffer, offset, buffer.length - offset, offset);
      if (count <= 0) throw new Error('short_read');
      offset += count;
    }
    const after = fs.lstatSync(file);
    checkParents();
    if (!same(opened, after) || !protectedStat(after, file)) throw new Error('changed_file');
    const bytes = buffer.length;
    const value = json ? JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer)) : buffer;
    return { value, bytes, stamp: { dev: opened.dev, ino: opened.ino, size: opened.size, mtimeMs: opened.mtimeMs, sha256: digest(buffer) } };
  } finally { fs.closeSync(fd); }
}

function paths(context) {
  const p = context?.paths;
  if (!p || !path.isAbsolute(p.sourceRoot) || !path.isAbsolute(p.stateRoot) || !path.isAbsolute(p.codexHome) || !path.isAbsolute(p.poolPath) || !path.isAbsolute(p.homesDir) || !path.isAbsolute(p.switchPath)) throw new Error('missing_paths');
  return p;
}

function sourceGate(context, services) {
  const p = paths(context), record = context.compatibility;
  if (!plain(record) || record.schemaVersion !== 1 || !/^[0-9a-f]{40}$/.test(record.reviewedRevision) || !plain(record.sourceDigests) || Object.keys(record.sourceDigests).length !== 13 || !Number.isSafeInteger(record.adapterVersion) || record.adapterVersion < 1 || record.requestContractVersion !== 1 || typeof record.sourcePathContract !== 'string' || !record.sourcePathContract || typeof record.reviewEvidence !== 'string' || !record.reviewEvidence || !['equivalent', 'changed'].includes(record.semantics) || typeof services.source?.inspect !== 'function') throw new Error('unreviewed_source');
  const names = Object.keys(record.sourceDigests);
  for (const name of names) if (!/^(src|bin)\/[A-Za-z0-9._/-]+$/.test(name) || name.split('/').includes('..') || !/^[0-9a-f]{64}$/.test(record.sourceDigests[name])) throw new Error('unreviewed_source');
  const observed = services.source.inspect(p.sourceRoot, names);
  if (observed?.revision !== record.reviewedRevision || !Array.isArray(observed.dirtyPaths) || observed.dirtyPaths.length) throw new Error('source_drift');
  for (const name of names) {
    const actual = safeRead(path.join(p.sourceRoot, name), services, { root: p.sourceRoot, limit: 2 * 1024 * 1024, json: false, private: false });
    if (actual.stamp.sha256 !== record.sourceDigests[name]) throw new Error('source_drift');
  }
  return digest(JSON.stringify({ revision: observed.revision, digests: record.sourceDigests }));
}

function coordination(p, services) {
  const fs = services.files;
  const exists = file => { try { fs.lstatSync(file); return true; } catch (e) { if (e?.code === 'ENOENT') return false; throw e; } };
  const switchFile = safeRead(p.switchPath, services, { root: p.stateRoot, limit: 8 * 1024 * 1024, optional: true });
  const switchState = switchFile?.value;
  if (switchState && (!plain(switchState) || switchState.version !== 1 || switchState.pending !== false || switchState.phase !== 'idle')) throw new Error('switch_busy');
  const selected = p.selectedAccountId;
  if (switchState && (
    switchState.active !== undefined && switchState.active !== selected && switchState.active !== 'primary' ||
    switchState.desired !== undefined && switchState.desired !== selected && switchState.desired !== 'auto' && switchState.desired !== 'primary' ||
    switchState.active === 'primary' && selected !== undefined ||
    switchState.desired === 'primary' && selected !== undefined
  )) throw new Error('switch_conflict');
  const switchDir = path.dirname(p.switchPath);
  const profileDir = path.join(switchDir, 'chatgpt-profile');
  try {
    const stat = fs.lstatSync(profileDir);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== services.uid || (stat.mode & 0o077) || services.acl(profileDir) !== true) throw new Error('unsafe_profile_dir');
  } catch (error) { if (error?.code !== 'ENOENT') throw error; }
  for (const file of [`${p.poolPath}.pool-lock.lock`, path.join(switchDir, 'catalog-publication.lock'), path.join(profileDir, 'switch-transaction'), path.join(profileDir, 'switch-transaction.staging')]) if (exists(file)) throw new Error('router_coordination_busy');
  return { switchState, switchStamp: switchFile?.stamp ?? null, selected, primarySelected: Boolean(selected && switchState?.active === selected) };
}

function discovery(p, services) {
  if (p.discoveryOverride === '1') return false;
  if (p.discoveryOverride === '0') return true;
  if (p.discoveryOverride !== undefined && p.discoveryOverride !== null) throw new Error('discovery_unknown');
  const file = p.discoveryPath ?? path.join(p.stateRoot, 'discovery-mode.json');
  const marker = safeRead(file, services, { root: p.stateRoot, limit: 1024 * 1024, optional: true });
  return !(marker?.value?.version === 1 && marker.value.discovery === 'disabled');
}

function registry(context, services) {
  const p = paths(context);
  const sourceStamp = sourceGate(context, services);
  if (!discovery(p, services)) throw new Error('discovery_disabled');
  const file = safeRead(p.poolPath, services, { root: p.stateRoot, limit: 8 * 1024 * 1024 });
  const value = file.value;
  if (!plain(value) || value.version !== 1 || !plain(value.policy) || typeof value.policy.enabled !== 'boolean' || value.policy.mode !== 'switch' || !plain(value.accounts) || !plain(value.sessions)) throw new Error('bad_registry');
  const entries = Object.entries(value.accounts);
  if (entries.length > 64 || value.policy.selectedAccountId !== undefined && (!idPattern.test(value.policy.selectedAccountId) || !Object.hasOwn(value.accounts, value.policy.selectedAccountId))) throw new Error('bad_registry');
  for (const [id, a] of entries) {
    if (!idPattern.test(id) || !plain(a) || a.id !== id || !['active','paused','revoked'].includes(a.state) || typeof a.paused !== 'boolean' || !Number.isFinite(a.priority) || !plain(a.health) || !['healthy','cooldown','reauth-required','failed'].includes(a.health.state) || !Number.isFinite(a.turns) || !Number.isFinite(a.requests)) throw new Error('bad_registry');
    if (a.identity !== undefined && (!plain(a.identity) || typeof a.identity.accountId !== 'string' || !a.identity.accountId.trim() || a.identity.accountId.length > 256 || hasControls(a.identity.accountId) || a.identity.userId !== undefined && (typeof a.identity.userId !== 'string' || !a.identity.userId.trim() || a.identity.userId.length > 256 || hasControls(a.identity.userId)))) throw new Error('bad_registry');
  }
  const identities = entries.map(([, a]) => a.identity).filter(identity => identity?.userId);
  if (identities.some((identity, i) => identities.some((other, j) => i !== j && match(identity, other)))) throw new Error('duplicate_identity');
  const coord = coordination({ ...p, selectedAccountId: value.policy.selectedAccountId }, services);
  return { p, value, file, sourceStamp, coord };
}

function auth(raw) {
  if (!plain(raw) || raw.auth_mode !== undefined && raw.auth_mode !== 'chatgpt' || Object.hasOwn(raw, 'OPENAI_API_KEY') && raw.OPENAI_API_KEY !== null || !plain(raw.tokens)) throw new Error('not_oauth');
  const token = raw.tokens.access_token, accountId = raw.tokens.account_id;
  if (typeof token !== 'string' || !token || token.length > 65536 || hasControls(token) || typeof accountId !== 'string') throw new Error('bad_auth');
  const cleanAccount = accountId.trim();
  if (!cleanAccount || cleanAccount.length > 256 || hasControls(cleanAccount)) throw new Error('bad_identity');
  const jwt = String(raw.tokens.id_token ?? '').split('.');
  if (jwt.length < 2 || jwt[1].length > 65536) throw new Error('bad_identity');
  let claims;
  try { claims = JSON.parse(Buffer.from(jwt[1], 'base64url').toString('utf8')); } catch { throw new Error('bad_identity'); }
  const value = claims?.['https://api.openai.com/auth']?.chatgpt_user_id || claims?.['https://api.openai.com/auth']?.user_id || claims?.sub;
  if (typeof value !== 'string' || !value.trim() || value.length > 256 || hasControls(value)) throw new Error('bad_identity');
  let expiry;
  try { expiry = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8')).exp; } catch { /* identity-only enrollment can still proceed */ }
  return { identity: { accountId: cleanAccount, userId: value.trim() }, accessToken: token, expiresAt: Number.isSafeInteger(expiry) && expiry > 0 ? expiry * 1000 : null };
}

function profile(file, root, services) {
  const read = safeRead(file, services, { root, limit: 1024 * 1024, optional: true });
  return read ? { ...auth(read.value), stamp: read.stamp } : null;
}

function ownProfile(p, id, services) {
  return profile(path.join(p.homesDir, id, 'auth.json'), p.homesDir, services);
}

function lease(p, id, services) {
  const dir = path.join(p.homesDir, id);
  let names;
  try {
    const stat = services.files.lstatSync(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== services.uid || (stat.mode & 0o077) || services.acl(dir) !== true) throw new Error('unsafe_home');
    names = services.files.readdirSync(dir);
  } catch (e) { if (e?.code === 'ENOENT') return false; throw e; }
  if (names.length > 10000) throw new Error('lease_unknown');
  const leases = names.filter(name => name === 'router-login-lease.json' || name.startsWith('router-login-lease.relocated-'));
  if (leases.length > 32) throw new Error('lease_unknown');
  return leases.length > 0;
}

function match(a, b) { return a?.accountId === b?.accountId && a?.userId === b?.userId && typeof a?.accountId === 'string' && typeof a?.userId === 'string'; }
function inspect(context, id, expected, services, enrollment = false) {
  const r = registry(context, services), a = r.value.accounts[id];
  if (!a || a.state !== 'active' || a.paused) return blocked('account', 'registry_ineligible');
  if (lease(r.p, id, services)) return blocked('account', 'login_lease');
  if (!a.identity?.accountId) return blocked('account', 'identity_ambiguous');
  let primary = null, saved = null;
  const selected = r.value.policy.selectedAccountId === id;
  if (selected && r.coord.primarySelected) {
    try { primary = profile(path.join(r.p.codexHome, 'auth.json'), r.p.codexHome, services); } catch { return blocked('account', 'primary_untrusted'); }
  }
  const bound = expected ?? (a.identity.userId ? a.identity : null);
  if (!selected || !primary || !bound || !match(primary.identity, bound)) {
    try { saved = ownProfile(r.p, id, services); } catch { return blocked('account', 'saved_untrusted'); }
  }
  if (!bound && primary && saved && primary.identity.accountId === a.identity.accountId && saved.identity.accountId === a.identity.accountId && !match(primary.identity, saved.identity)) return blocked('account', 'identity_ambiguous');
  const identity = bound ?? (saved?.identity.accountId === a.identity.accountId ? saved.identity : primary?.identity);
  if (!identity || !saved && !primary) return blocked('account', 'identity_ambiguous');
  if (a.identity.accountId.trim() !== identity.accountId || a.identity.userId !== undefined && a.identity.userId.trim() !== identity.userId) return blocked('account', 'identity_mismatch');
  for (const [otherId, other] of Object.entries(r.value.accounts)) if (otherId !== id && match(other.identity, identity)) return blocked('account', 'identity_ambiguous');
  const publicIdentity = { accountId: identity.accountId, userId: identity.userId };
  if (enrollment) {
    const source = selected && primary && match(primary.identity, identity) ? primary : saved;
    if (!source || !match(source.identity, identity)) return blocked('account', 'identity_mismatch');
    return { kind: 'ready', identity: publicIdentity, sourceKind: selected && source === primary ? 'primary' : 'saved', snapshot: { registry: r.file.stamp, switch: r.coord.switchStamp, source: source.stamp, sourceStamp: r.sourceStamp, selected } };
  }
  let chosen = selected && primary && match(primary.identity, identity) ? primary : saved;
  if (!chosen || !match(chosen.identity, identity)) return blocked('account', 'identity_mismatch');
  if (!Number.isFinite(chosen.expiresAt) || chosen.expiresAt < services.clock.wall() + 120000) return blocked('account', 'credential_expired_or_unknown');
  return { kind: 'ready', identity: publicIdentity, sourceKind: selected && chosen === primary ? 'primary' : 'saved', accessToken: chosen.accessToken, expiresAt: chosen.expiresAt, snapshot: { registry: r.file.stamp, switch: r.coord.switchStamp, source: chosen.stamp, sourceStamp: r.sourceStamp, selected, expiresAt: chosen.expiresAt } };
}

export function readRegistry(context, services) {
  try {
    const r = registry(context, services);
    return { kind: 'ready', accounts: Object.entries(r.value.accounts).map(([routerAccountId, a]) => ({ routerAccountId, state: a.state, paused: a.paused, eligible: a.state === 'active' && !a.paused && Boolean(a.identity?.accountId) })), selectedAccountId: r.value.policy.selectedAccountId ?? null, compatibility: 'reviewed', coordination: 'idle' };
  } catch { return blocked('global', 'registry_unavailable'); }
}

export function checkCompatibility(context, services) {
  try { return { kind: 'ready', sourceStamp: sourceGate(context, services) }; }
  catch { return blocked('global', 'compatibility_unavailable'); }
}

export function discoverIdentity(context, routerAccountId, services) {
  if (!idPattern.test(routerAccountId)) return blocked('account', 'invalid_router_account_id');
  try { return inspect(context, routerAccountId, null, services, true); } catch { return blocked('global', 'reader_unavailable'); }
}

export function readCredential(context, enrollment, services) {
  if (!idPattern.test(enrollment?.routerAccountId) || !plain(enrollment?.identity)) return blocked('account', 'invalid_enrollment');
  try { return inspect(context, enrollment.routerAccountId, enrollment.identity, services); } catch { return blocked('global', 'reader_unavailable'); }
}

export function revalidate(context, enrollment, snapshot, services) {
  const next = readCredential(context, enrollment, services);
  if (next.kind !== 'ready') return next;
  if (!snapshot || JSON.stringify(next.snapshot) !== JSON.stringify(snapshot)) return blocked('account', 'snapshot_changed');
  return next;
}
