import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { execFileSync } from 'node:child_process';
import { checkRootAncestors, safeRead, readRegistry, discoverIdentity, readCredential, revalidate, checkCompatibility } from './router-reader.mjs';
import { probe, directRequest, safeTransportCode } from './chatgpt-probe.mjs';

const MAX_STATE = 16 * 1024 * 1024;
const MAX_FILE = 1024 * 1024;
const HISTORY_LIMIT = 50;
const validReservationId = value => typeof value === 'string' && /^res_[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
const RECENT_MINUTES = 15;
const SPACED_MINUTES = 240;
const LEGACY_ZONE = 'Asia/Gaza';
const LOCAL_ZONE = 'local';
const LEDGER_CAUSES = new Set(['zone_changed', 'schedule_disabled', 'compatibility_blocked', 'recovery_skip_through', 'clock_hold', 'manual_run_overlap', 'no_tick_between', 'schedule_spacing', 'no_scheduled_accounts']);
const TIMES = ['08:00', '13:00', '18:00'];
const scheduledBatchMs = accounts => accounts * 45000 + 30000;
const minimumSpacingMs = accounts => Math.max(15 * 60000, scheduledBatchMs(accounts));
const validTime = value => typeof value === 'string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value);
const validDate = value => typeof value === 'string' && /^\d{4}-\d\d-\d\d$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(Date.parse(value)).toISOString().startsWith(value + 'T');
const validSlot = value => typeof value === 'string' && value.length === 16 && value[10] === 'T' && validDate(value.slice(0, 10)) && validTime(value.slice(11));
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const own = (object, key) => Object.hasOwn(object, key);
const SAFE_REASON = Symbol('safe_reason');
const plain = value => value && typeof value === 'object' && !Array.isArray(value);
const exact = (object, keys) => plain(object) && Object.keys(object).every(key => keys.includes(key)) && keys.every(key => own(object, key));
const result = (exitCode, outcome, reason, extra = {}) => ({ exitCode, outcome, reason, ...extra });
const fail = (reason, exitCode = 2, extra = {}) => result(exitCode, exitCode === 3 ? 'busy' : 'blocked', reason, extra);
const throwCode = reason => { throw Object.assign(new Error(reason), { reason, [SAFE_REASON]: true }); };
const readerReasons = new Set(['registry_ineligible', 'login_lease', 'primary_untrusted', 'saved_untrusted', 'identity_ambiguous', 'identity_mismatch', 'credential_expired_or_unknown', 'invalid_enrollment', 'invalid_router_account_id', 'snapshot_changed']);
const readerReason = value => readerReasons.has(value) ? value : 'reader_unavailable';
const validFirstTextMs = value => Number.isInteger(value) && value >= 0 && value <= 45000;
const confirmed = row => row.outcome === 'success' && row.reason === 'marker_confirmed' && row.dispatched === true;
const probeReasons = new Set(['marker_confirmed', 'invalid_probe', 'deadline_before_send', 'deadline_exceeded', 'credential_expired_or_unknown', 'transport_unavailable', 'redirect_refused', 'protocol_failure', 'authentication_rejected', 'forbidden_or_challenged', 'rate_limited', 'unsupported_model', 'upstream_rejected', 'output_mismatch', 'stream_or_transport_uncertain', 'transport_before_send', 'send_check_failed']);

function binding(context, services) {
  const root = context.root;
  if (!path.isAbsolute(root) || path.resolve(root) !== root) throwCode('invalid_root');
  checkRootAncestors(root, services);
  const stat = services.files.lstatSync(root);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== services.uid || (stat.mode & 0o077) || services.acl(root) !== true) throwCode('unsafe_root');
  return { root, dev: stat.dev, ino: stat.ino };
}

function unchanged(base, services) {
  checkRootAncestors(base.root, services);
  const stat = services.files.lstatSync(base.root);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.dev !== base.dev || stat.ino !== base.ino || stat.uid !== services.uid || (stat.mode & 0o077) || services.acl(base.root) !== true) throwCode('installation_replaced');
  if (base.installationId) {
    const marker = safeRead(path.join(base.root, 'instance.json'), services, { root: base.root, limit: MAX_FILE }).value;
    if (marker?.installationId !== base.installationId) throwCode('installation_replaced');
  }
}

function read(base, name, services, limit = MAX_STATE, optional = false) {
  unchanged(base, services);
  return safeRead(path.join(base.root, name), services, { root: base.root, limit, optional });
}
const adapter = (services, name, fallback) => services.reader?.[name] ?? fallback;

function atomic(base, name, value, services) {
  unchanged(base, services);
  const f = services.files;
  const bytes = Buffer.from(JSON.stringify(value));
  if (bytes.length > (name === 'state.json' ? MAX_STATE : MAX_FILE)) throwCode('state_capacity');
  const dest = path.join(base.root, name);
  const temp = path.join(base.root, `.${name}.${crypto.randomUUID()}.tmp`);
  let fd;
  try {
    services.fault?.(`before_${name}_create`);
    fd = f.openSync(temp, f.constants.O_WRONLY | f.constants.O_CREAT | f.constants.O_EXCL | f.constants.O_NOFOLLOW, 0o600);
    services.fault?.(`after_${name}_create`);
    for (let offset = 0; offset < bytes.length;) {
      const written = f.writeSync(fd, bytes, offset, bytes.length - offset);
      if (written <= 0) throwCode('write_failed');
      offset += written;
    }
    services.fault?.(`after_${name}_write`);
    f.fsyncSync(fd);
    services.fault?.(`after_${name}_fsync`);
    f.closeSync(fd); fd = undefined;
    services.fault?.(`before_${name}_rename`);
    unchanged(base, services);
    f.renameSync(temp, dest);
    services.fault?.(`after_${name}_rename_before_dirsync`);
    const dir = f.openSync(base.root, f.constants.O_RDONLY | f.constants.O_DIRECTORY);
    try { f.fsyncSync(dir); } finally { f.closeSync(dir); }
    services.fault?.(`after_${name}_rename`);
  } finally {
    if (fd !== undefined) f.closeSync(fd);
    try { f.unlinkSync(temp); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return hash(bytes);
}

function validateMarker(marker) {
  if (!exact(marker, ['schemaVersion', 'installationId', 'phase', 'paths', 'plistPath']) || marker.schemaVersion !== 1 || typeof marker.installationId !== 'string' || !/^[a-zA-Z0-9_-]{12,100}$/.test(marker.installationId) || !['uninitialized', 'in_progress', 'complete'].includes(marker.phase) || !validPaths(marker.paths) || !path.isAbsolute(marker.plistPath) || path.resolve(marker.plistPath) !== marker.plistPath) throwCode('invalid_marker');
}

function validateIsolation(base, paths, plistPath, services) {
  const checkExistingAncestor = target => {
    let current = target;
    for (;;) {
      try { checkRootAncestors(current, services); return; }
      catch (error) {
        if (error?.code !== 'ENOENT' || current === path.dirname(current)) throw error;
        current = path.dirname(current);
      }
    }
  };
  for (const key of ['sourceRoot', 'stateRoot', 'codexHome', 'homesDir']) checkExistingAncestor(paths[key]);
  for (const key of ['poolPath', 'switchPath', 'discoveryPath']) checkExistingAncestor(path.dirname(paths[key]));
  checkExistingAncestor(path.dirname(plistPath));
  const overlap = (a, b) => a === b || a.startsWith(`${b}${path.sep}`) || b.startsWith(`${a}${path.sep}`);
  for (const external of Object.values(paths).filter(value => typeof value === 'string' && path.isAbsolute(value))) {
    if (overlap(base.root, external) || overlap(plistPath, external)) throwCode('ownership_overlap');
  }
  if (overlap(base.root, plistPath)) throwCode('ownership_overlap');

  // No link resolution: inspect the actual identities of each existing component.
  const describe = (target, directory) => {
    let current = target, missing = false, targetId = null, nearestId = null;
    const ancestors = new Set();
    for (;;) {
      let stat;
      try { stat = services.files.lstatSync(current); }
      catch (error) {
        if (error?.code !== 'ENOENT') throw error;
        missing = true;
      }
      if (stat) {
        if (stat.isSymbolicLink() || (current !== target || missing || directory) && !stat.isDirectory() || !Number.isSafeInteger(stat.dev) || !Number.isSafeInteger(stat.ino) || stat.ino <= 0) throwCode('unsafe_ownership_path');
        const identity = `${stat.dev}:${stat.ino}`;
        if (!nearestId) nearestId = identity;
        if (current === target && !missing) targetId = identity;
        ancestors.add(identity);
      }
      if (current === path.dirname(current)) break;
      current = path.dirname(current);
    }
    return { targetId, nearestId, ancestors };
  };
  const physicalOverlap = (a, b) => {
    if (a.targetId && b.ancestors.has(a.targetId) || b.targetId && a.ancestors.has(b.targetId)) return true;
    // Two unresolved paths below the same physical directory cannot be proven separate.
    return !a.targetId && !b.targetId && a.nearestId === b.nearestId;
  };
  const companion = describe(base.root, true);
  const plist = describe(plistPath, false);
  if (physicalOverlap(companion, plist)) throwCode('ownership_overlap');
  for (const key of ['sourceRoot', 'stateRoot', 'codexHome', 'homesDir', 'poolPath', 'switchPath', 'discoveryPath']) {
    const external = describe(paths[key], ['sourceRoot', 'stateRoot', 'codexHome', 'homesDir'].includes(key));
    if (physicalOverlap(companion, external) || physicalOverlap(plist, external)) throwCode('ownership_overlap');
  }
}

function validPaths(paths) {
  const required = ['sourceRoot', 'stateRoot', 'codexHome', 'poolPath', 'homesDir', 'switchPath', 'discoveryPath'];
  return plain(paths) && Object.keys(paths).every(key => [...required, 'discoveryOverride'].includes(key)) && required.every(key => typeof paths[key] === 'string' && path.isAbsolute(paths[key]) && path.resolve(paths[key]) === paths[key]) && (!own(paths, 'discoveryOverride') || ['0', '1'].includes(paths.discoveryOverride));
}

function validateCompatibility(record) {
  const fields = ['schemaVersion', 'reviewedRevision', 'sourceDigests', 'adapterVersion', 'requestContractVersion', 'sourcePathContract', 'reviewEvidence', 'semantics'];
  if (!exact(record, fields) || record.schemaVersion !== 1 || !/^[a-f0-9]{40}$/.test(record.reviewedRevision) || !plain(record.sourceDigests) || Object.keys(record.sourceDigests).length !== 13 || Object.keys(record.sourceDigests).some(name => !/^(src|bin)\/[A-Za-z0-9._/-]+$/.test(name) || name.split('/').includes('..')) || Object.values(record.sourceDigests).some(value => typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value)) || !Number.isSafeInteger(record.adapterVersion) || record.adapterVersion < 1 || record.requestContractVersion !== 1 || typeof record.sourcePathContract !== 'string' || !record.sourcePathContract || typeof record.reviewEvidence !== 'string' || !record.reviewEvidence || !['equivalent', 'changed'].includes(record.semantics)) throwCode('invalid_compatibility');
}

function validSchedule(schedule) {
  if (!exact(schedule, own(schedule ?? {}, 'advance13') ? ['zone', 'times', 'advance13'] : ['zone', 'times']) || ![LEGACY_ZONE, LOCAL_ZONE].includes(schedule.zone) || JSON.stringify(schedule.times) !== JSON.stringify(TIMES)) return false;
  if (!own(schedule, 'advance13')) return true;
  const a = schedule.advance13;
  return exact(a, ['date', 'time']) && typeof a.date === 'string' && /^\d{4}-\d\d-\d\d$/.test(a.date) && Number.isFinite(Date.parse(a.date)) && new Date(a.date).toISOString().slice(0, 10) === a.date && typeof a.time === 'string' && /^(?:0[89]|1[012]):[0-5]\d$/.test(a.time) && a.time > '08:00';
}

function validAdmissions(admissions) {
  if (!plain(admissions)) return false;
  const entries = Object.keys(admissions).sort();
  return entries.every((time, i) => validTime(time) && validTime(admissions[time]) && (!i || admissions[entries[i - 1]] < admissions[time]));
}

// Optional weekday rule: ISO days 1 (Monday) to 7 (Sunday), strictly ascending, stored only
// when it excludes at least one day. Absence keeps the legacy every-day behavior.
const validWeekdays = days => Array.isArray(days) && days.length >= 1 && days.length < 7 &&
  days.every((day, i) => Number.isSafeInteger(day) && day >= 1 && day <= 7 && (!i || days[i - 1] < day));
const DATE_EXCLUSIONS = new Set(['weekday']);
const MAX_VACATIONS = 24, MAX_VACATION_DAYS = 366, MAX_CAP = 48;
const dayNumber = date => Date.parse(date) / 86400000;
// Inclusive local-date ranges, sorted by start and not overlapping.
const validVacations = list => Array.isArray(list) && list.length <= MAX_VACATIONS && list.every((range, i) =>
  exact(range, ['start', 'end']) && validDate(range.start) && validDate(range.end) && range.start <= range.end &&
  dayNumber(range.end) - dayNumber(range.start) < MAX_VACATION_DAYS && (!i || list[i - 1].end < range.start));
const MANUAL_KEY = /^manual:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// A reservation key the engine writes: a manual UUID, or the canonical [slot, enrollmentId,
// accountId, userId] tuple agreeing with its record. Load tolerates other keys (status and recovery
// report them); the cap and duplicate checks fail closed on them.
const validIdentityPart = value => typeof value === 'string' && value.length >= 1 && value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
function validReservationKey(key, record) {
  if (!/^[A-Za-z0-9_-]{1,100}$/.test(record.enrollmentId) || !validIdentityPart(record.identity.accountId) ||
    !validIdentityPart(record.identity.userId)) return false;
  if (key.startsWith('manual:')) return MANUAL_KEY.test(key);
  let tuple;
  try { tuple = JSON.parse(key); } catch { return false; }
  return Array.isArray(tuple) && tuple.length === 4 && validSlot(tuple[0]) && tuple[1] === record.enrollmentId &&
    tuple[2] === record.identity.accountId && tuple[3] === record.identity.userId && JSON.stringify(tuple) === key;
}
const validAccountList = list => Array.isArray(list) && list.length <= 1000 &&
  list.every((id, i) => typeof id === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(id) && (!i || list[i - 1] < id));
const validCap = count => Number.isSafeInteger(count) && count >= 1 && count <= MAX_CAP;

function validScheduleEdits(edits) {
  const optional = ['weekdays', 'todayExclusion'].filter(key => own(edits ?? {}, key));
  return exact(edits, ['date', 'times', 'admissions', ...optional]) && validDate(edits.date) && Array.isArray(edits.times) &&
    edits.times.every((time, i) => validTime(time) && (!i || edits.times[i - 1] < time)) && validAdmissions(edits.admissions) &&
    (!own(edits, 'weekdays') || validWeekdays(edits.weekdays)) &&
    (!own(edits, 'todayExclusion') || (DATE_EXCLUSIONS.has(edits.todayExclusion) && !Object.keys(edits.admissions).length));
}

function validateConfig(config, marker) {
  if (!exact(config, ['schemaVersion', 'installationId', 'paths', 'schedule', 'enrollments', 'requestContractVersion']) || config.schemaVersion !== 1 || config.installationId !== marker.installationId || !validPaths(config.paths) || config.requestContractVersion !== 1 || !validSchedule(config.schedule) || !Array.isArray(config.enrollments)) throwCode('invalid_config');
  const ids = new Set(), refs = new Set(), identities = new Set();
  for (const e of config.enrollments) {
    if (!exact(e, ['enrollmentId', 'routerAccountId', 'identity', 'model', 'enabled']) || !/^[A-Za-z0-9_-]{1,100}$/.test(e.enrollmentId) || !/^[A-Za-z0-9_-]{1,100}$/.test(e.routerAccountId) || !exact(e.identity, ['accountId', 'userId']) || typeof e.identity.accountId !== 'string' || typeof e.identity.userId !== 'string' || !e.identity.accountId || !e.identity.userId || e.identity.accountId.length > 256 || e.identity.userId.length > 256 || /[\u0000-\u001f\u007f]/.test(e.identity.accountId + e.identity.userId) || typeof e.model !== 'string' || !/^[A-Za-z0-9_.-]{1,100}$/.test(e.model) || typeof e.enabled !== 'boolean' || ids.has(e.enrollmentId) || refs.has(e.routerAccountId) || identities.has(JSON.stringify([e.identity.accountId, e.identity.userId]))) throwCode('invalid_enrollment');
    ids.add(e.enrollmentId); refs.add(e.routerAccountId); identities.add(JSON.stringify([e.identity.accountId, e.identity.userId]));
  }
}

function validateState(state, marker) {
  const fields = ['schemaVersion', 'installationId', 'scheduleEnabled', 'removalPending', 'configDigest', 'compatibilityDigest', 'pilots', 'cooldowns', 'blocks', 'slots', 'reservations', 'highWater', 'lastWall', 'lastTick', 'activeBatch', 'lastSlotOutcome', 'history', 'skipThrough'];
  if (own(state ?? {}, 'schedulePause')) {
    fields.push('schedulePause');
    const pause = state.schedulePause;
    if (!exact(pause, ['at', 'zone', 'revision']) || !Number.isFinite(pause.at) || !isZone(pause.zone) || !Number.isSafeInteger(pause.revision) || pause.revision < 0) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'lastManual')) {
    fields.push('lastManual');
    const manual = state.lastManual;
    if (!exact(manual, ['startedAt', 'endedAt', 'zone']) || !Number.isFinite(manual.startedAt) || !Number.isFinite(manual.endedAt) || manual.endedAt < manual.startedAt || !isZoneName(manual.zone)) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'zoneChange')) {
    fields.push('zoneChange');
    if (!exact(state.zoneChange, ['at', 'previousZone', 'zone']) || !Number.isFinite(state.zoneChange.at) || !isZoneName(state.zoneChange.previousZone) || !isZoneName(state.zoneChange.zone)) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'lastTickZone')) {
    fields.push('lastTickZone');
    if (!isZone(state.lastTickZone)) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'compatibilityBlockedSince')) {
    fields.push('compatibilityBlockedSince');
    if (!Number.isFinite(state.compatibilityBlockedSince)) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'slotLedger')) {
    fields.push('slotLedger');
    if (!plain(state.slotLedger) || Object.entries(state.slotLedger).some(([slot, row]) =>
      !validSlot(slot) || !exact(row, ['admission', 'verdict', 'cause', 'zone', 'at', 'evidence']) || !validTime(row.admission) || row.verdict !== 'not_admitted' ||
      !LEDGER_CAUSES.has(row.cause) || !isZoneName(row.zone) || !Number.isFinite(row.at) ||
      !exact(row.evidence, row.cause === 'manual_run_overlap' ? ['previousTick', 'tick', 'previousZone', 'manualStartedAt', 'manualEndedAt'] : ['previousTick', 'tick', 'previousZone', ...(own(row.evidence ?? {}, 'pauseStartedAt') ? ['pauseStartedAt'] : [])]) ||
      (own(row.evidence, 'pauseStartedAt') && (row.cause !== 'schedule_disabled' || !Number.isFinite(row.evidence.pauseStartedAt) || row.evidence.pauseStartedAt > row.evidence.tick)) ||
      (row.cause === 'manual_run_overlap' && (!Number.isFinite(row.evidence.manualStartedAt) || !Number.isFinite(row.evidence.manualEndedAt) || row.evidence.manualEndedAt < row.evidence.manualStartedAt)) ||
      !(row.evidence.previousTick === null || Number.isFinite(row.evidence.previousTick)) ||
      !Number.isFinite(row.evidence.tick) || !(row.evidence.previousZone === null || isZoneName(row.evidence.previousZone)))) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'scheduleRevision')) {
    fields.push('scheduleRevision');
    if (!Number.isSafeInteger(state.scheduleRevision) || state.scheduleRevision < 0) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'scheduleEdits')) {
    fields.push('scheduleEdits');
    if (!validScheduleEdits(state.scheduleEdits)) throwCode('invalid_state');
  }
  // Increment B (engine 1.2): each key is stored only when it differs from the default.
  if (own(state ?? {}, 'vacations')) {
    fields.push('vacations');
    if (!validVacations(state.vacations) || !state.vacations.length) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'scheduledAccounts')) {
    fields.push('scheduledAccounts');
    if (!validAccountList(state.scheduledAccounts)) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'caps')) {
    fields.push('caps');
    if (!plain(state.caps) || !Object.keys(state.caps).length || Object.entries(state.caps).some(([id, count]) => !/^[A-Za-z0-9_-]{1,100}$/.test(id) || !validCap(count))) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'settledAt')) {
    fields.push('settledAt');
    if (!Number.isFinite(state.settledAt)) throwCode('invalid_state');
  }
  if (own(state ?? {}, 'scheduleUndo')) {
    fields.push('scheduleUndo');
    const undo = state.scheduleUndo;
    if (!exact(undo, ['revision', 'date', 'previous']) || !Number.isSafeInteger(undo.revision) || undo.revision < 1 || !validDate(undo.date) ||
      !(undo.previous === null || validScheduleEdits(undo.previous))) throwCode('invalid_state');
  }
  if (!exact(state, fields) || state.schemaVersion !== 1 || state.installationId !== marker.installationId || typeof state.scheduleEnabled !== 'boolean' || typeof state.removalPending !== 'boolean' || !/^[a-f0-9]{64}$/.test(state.configDigest) || !/^[a-f0-9]{64}$/.test(state.compatibilityDigest) || !plain(state.pilots) || !plain(state.cooldowns) || !plain(state.blocks) || !plain(state.slots) || !plain(state.reservations) || !Array.isArray(state.history) || state.history.length > 100000 || !(state.highWater === null || typeof state.highWater === 'string') || !(state.lastWall === null || Number.isFinite(state.lastWall)) || !(state.lastTick === null || Number.isFinite(state.lastTick)) || !(state.activeBatch === null || plain(state.activeBatch)) || !(state.lastSlotOutcome === null || plain(state.lastSlotOutcome)) || !(state.skipThrough === null || typeof state.skipThrough === 'string')) throwCode('invalid_state');
  if (state.highWater !== null && !validSlot(state.highWater) || state.skipThrough !== null && !validSlot(state.skipThrough) || Object.keys(state.slots).some(key => !validSlot(key) || !plain(state.slots[key]) || !Array.isArray(state.slots[key].enrollmentIds) || !Number.isFinite(state.slots[key].claimedAt) || (own(state.slots[key], 'admission') && !validTime(state.slots[key].admission)) || (own(state.slots[key], 'outcome') && !/^[a-z_]{1,64}$/.test(state.slots[key].outcome)) || (own(state.slots[key], 'finishedAt') && !Number.isFinite(state.slots[key].finishedAt))) || Object.entries(state.cooldowns).some(([, at]) => !Number.isFinite(at)) || Object.values(state.blocks).some(value => typeof value !== 'string') || Object.values(state.pilots).some(value => !plain(value) || !Number.isFinite(value.at)) || Object.values(state.reservations).some(value => !plain(value) || typeof value.enrollmentId !== 'string' || !exact(value.identity, ['accountId', 'userId']) || !Number.isFinite(value.at) || value.possibleSend !== true || (own(value, 'reservationId') && !validReservationId(value.reservationId)) || (own(value, 'resolved') && (value.resolved !== true || !validReservationId(value.reservationId)))) || state.activeBatch && (!validSlot(state.activeBatch.slot) || !Array.isArray(state.activeBatch.enrollmentIds)) || state.lastSlotOutcome && (!validSlot(state.lastSlotOutcome.slot) || !Number.isFinite(state.lastSlotOutcome.at))) throwCode('invalid_state');
  if (Object.keys(state.slots).length && (state.highWater === null || Object.keys(state.slots).some(slot => slot > state.highWater))) throwCode('invalid_state');
}

function load(base, services) {
  const marker = read(base, 'instance.json', services, MAX_FILE).value;
  validateMarker(marker);
  if (marker.phase !== 'complete') throwCode('incomplete_initialization');
  const s = read(base, 'state.json', services);
  validateState(s.value, marker);
  if (s.value.removalPending) throwCode('removal_pending');
  const c = read(base, 'config.json', services, MAX_FILE);
  const x = read(base, 'compatibility.json', services, MAX_FILE);
  validateConfig(c.value, marker);
  validateIsolation(base, c.value.paths, marker.plistPath, services);
  validateCompatibility(x.value);
  if (c.stamp.sha256 !== s.value.configDigest || x.stamp.sha256 !== s.value.compatibilityDigest) throwCode('digest_mismatch');
  return { marker, config: c.value, compatibility: x.value, state: s.value };
}

function lock(base, name, marker, services) {
  unchanged(base, services);
  const f = services.files;
  const dir = path.join(base.root, `${name}.lock`);
  const owner = { ...services.processes.current, installationId: marker.installationId, nonce: crypto.randomUUID() };
  if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0 || typeof owner.startId !== 'string' || !owner.startId) throwCode('process_identity_unavailable');
  try { f.mkdirSync(dir, { mode: 0o700 }); }
  catch (error) {
    if (error.code !== 'EEXIST') throw error;
    throw Object.assign(new Error('lock_busy'), { reason: 'lock_busy', exitCode: 3, [SAFE_REASON]: true });
  }
  const dirStat = f.lstatSync(dir);
  if (!dirStat.isDirectory() || dirStat.isSymbolicLink() || dirStat.uid !== services.uid || (dirStat.mode & 0o077) || services.acl(dir) !== true) throwCode('unsafe_lock');
  try {
    const fd = f.openSync(path.join(dir, 'owner.json'), f.constants.O_WRONLY | f.constants.O_CREAT | f.constants.O_EXCL | f.constants.O_NOFOLLOW, 0o600);
    try { f.writeSync(fd, JSON.stringify(owner)); f.fsyncSync(fd); } finally { f.closeSync(fd); }
    const d = f.openSync(dir, f.constants.O_RDONLY | f.constants.O_DIRECTORY);
    try { f.fsyncSync(d); } finally { f.closeSync(d); }
  } catch (error) {
    try { f.unlinkSync(path.join(dir, 'owner.json')); } catch { /* missing owner after failed creation */ }
    f.rmdirSync(dir);
    throw error;
  }
  return ({ markerRemoved = false } = {}) => {
    if (!markerRemoved) unchanged(base, services);
    else if (f.lstatSync(base.root).dev !== base.dev || f.lstatSync(base.root).ino !== base.ino) throwCode('installation_replaced');
    const currentDir = f.lstatSync(dir);
    if (currentDir.dev !== dirStat.dev || currentDir.ino !== dirStat.ino) throwCode('lock_replaced');
    const saved = safeRead(path.join(dir, 'owner.json'), services, { root: base.root, limit: 4096 }).value;
    if (JSON.stringify(saved) !== JSON.stringify(owner)) throwCode('lock_owner_changed');
    f.unlinkSync(path.join(dir, 'owner.json'));
    f.rmdirSync(dir);
  };
}

async function remove(base, marker, context, services, resuming = false) {
  const f = services.files;
  const releaseLife = lock(base, 'lifecycle', marker, services);
  let lifeHeld = true;
  let recoveryFd = null;
  try {
    if (resuming) removalState(base, marker, services);
    else load(base, services);
    const binding = jobBinding(base, { marker }, context);
    const observed = await services.jobs.inspect(binding);
    if (!['loaded', 'absent'].includes(observed)) throwCode('job_ownership_unknown');
    const runner = await services.jobs.runner(binding);
    if (observed === 'loaded') await services.jobs.disable(binding);
    if (runner) {
      if (!runner.scheduled || runner.installationId !== marker.installationId || services.processes.inspect(runner) !== 'alive') throwCode('runner_ownership_unknown');
      if (!await services.processes.wait(runner, 50000)) {
        if (services.processes.inspect(runner) !== 'alive') throwCode('runner_ownership_unknown');
        await services.processes.terminate(runner);
        if (!await services.processes.wait(runner, 5000)) throwCode('runner_still_active');
      }
    }
    // Removal holds the one recovery mutex from here to the end, so no recovery can run, create
    // the mutex file or touch a tombstone while the installation is torn down.
    recoveryFd = await holdRecoveryForRemoval(base, services);
    try { recoverDeadLock(base, 'work', marker, services); }
    catch (error) { if (!error?.[SAFE_REASON] || error.reason !== 'lock_owner_not_proven_dead' || error.ownerStatus !== 'alive') throw error; }
    const releaseWork = lock(base, 'work', marker, services);
    let workHeld = true;
    let markerRemoved = false;
    try {
      if (resuming) removalState(base, marker, services);
      else {
        const data = load(base, services);
        data.state.scheduleEnabled = false;
        data.state.removalPending = true;
        storeState(base, data.state, services);
      }
      if (await services.jobs.inspect(binding) !== 'absent' || await services.jobs.runner(binding)) throwCode('disable_incomplete');
      const allowed = new Set(['instance.json', 'config.json', 'compatibility.json', 'state.json', 'lifecycle.lock', 'work.lock', 'warmup.mjs', 'router-reader.mjs', 'chatgpt-probe.mjs', 'runtime.mjs', 'README.md']);
      if (f.readdirSync(base.root).some(name => !allowed.has(name) && !TOMBSTONE.test(name))) throwCode('foreign_installation_content');
      try { f.lstatSync(binding.plistPath); if (typeof services.jobs.remove !== 'function') throwCode('plist_removal_unavailable'); await services.jobs.remove(binding); }
      catch (error) { if (error?.code !== 'ENOENT') throw error; }
      for (const name of ['warmup.mjs', 'router-reader.mjs', 'chatgpt-probe.mjs', 'runtime.mjs', 'README.md', 'config.json', 'compatibility.json']) {
        const file = path.join(base.root, name);
        let stat;
        try { stat = f.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
        if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== services.uid || (stat.mode & 0o077) || services.acl(file) !== true) throwCode('foreign_installation_content');
        services.fault?.(`before_remove_${name}`);
        unchanged(base, services);
        f.unlinkSync(file);
      }
      services.fault?.('before_remove_final_guard');
      unchanged(base, services);
      if (await services.jobs.inspect(binding) !== 'absent' || await services.jobs.runner(binding)) throwCode('remove_incomplete');
      for (const name of ['state.json', 'instance.json']) {
        const file = path.join(base.root, name);
        try { f.lstatSync(file); } catch (error) { if (error.code === 'ENOENT' && name === 'state.json' && resuming) continue; throw error; }
        services.fault?.(`before_remove_${name}`);
        unchanged(base, services);
        f.unlinkSync(file);
        if (name === 'instance.json') markerRemoved = true;
      }
      releaseWork({ markerRemoved }); workHeld = false;
      releaseLife({ markerRemoved }); lifeHeld = false;
    } finally { if (workHeld) releaseWork({ markerRemoved }); }
    // Still holding the mutex: the root must be the verified one before anything else is removed.
    const rootNow = f.lstatSync(base.root);
    if (rootNow.dev !== base.dev || rootNow.ino !== base.ino) throwCode('installation_replaced');
    sweepTombstones(base, services);
    services.fault?.('before_remove_rmdir');
    // Node has no directory-descriptor rmdir; checking identity right before it keeps the window
    // to one system call, inside the same-user boundary the installation already relies on.
    sameRoot(base, services);
    f.rmdirSync(base.root);
    // Still held: delete the sibling mutex only if the path still names the very file held and it
    // still carries the marker; a file already gone at either step counts as clean.
    let named = null;
    try { named = f.lstatSync(mutexPath(base)); } catch (error) { if (error?.code !== 'ENOENT') throw error; }
    // The installation is already gone: a sibling that cannot be verified (read error included) is
    // left in place rather than deleted, and the sync and checks below still run.
    let held = null;
    if (named) try { held = ownedMutex(recoveryFd, services); } catch { held = null; }
    if (held && named && named.dev === held.dev && named.ino === held.ino) {
      // Looked up again right before the unlink: a file swapped in during validation is left alone.
      let again = null;
      try { again = f.lstatSync(mutexPath(base)); } catch (error) { if (error?.code !== 'ENOENT') throw error; }
      if (again && again.dev === held.dev && again.ino === held.ino) {
        try { f.unlinkSync(mutexPath(base)); } catch (error) { if (error?.code !== 'ENOENT') throw error; }
      }
    }
    const parent = f.openSync(path.dirname(base.root), f.constants.O_RDONLY | f.constants.O_DIRECTORY);
    try { f.fsyncSync(parent); } finally { f.closeSync(parent); }
    try { f.lstatSync(base.root); throwCode('remove_incomplete'); } catch (error) { if (error?.code !== 'ENOENT') throw error; }
    try { f.lstatSync(binding.plistPath); throwCode('remove_incomplete'); } catch (error) { if (error?.code !== 'ENOENT') throw error; }
    return result(0, 'ready', 'removed');
  } finally {
    if (recoveryFd !== null) { delete base.recoveryHeld; f.closeSync(recoveryFd); }
    if (lifeHeld) releaseLife({ markerRemoved: !f.existsSync(path.join(base.root, 'instance.json')) });
  }
}

function removalState(base, marker, services) {
  const state = read(base, 'state.json', services, MAX_STATE, true)?.value;
  if (state) {
    validateState(state, marker);
    if (!state.removalPending) throwCode('removal_not_pending');
  } else if (services.files.existsSync(path.join(base.root, 'config.json')) || services.files.existsSync(path.join(base.root, 'compatibility.json'))) throwCode('removal_state_unknown');
}

export async function resumeRemoval(context, services, decision) {
  let installationId = null;
  try {
    if (!services?.files || !services?.acl || !services?.clock || !services?.processes || !services?.jobs) throwCode('missing_capability');
    if (!exact(decision, ['installationId', 'rootDev', 'rootIno', 'reviewEvidence']) || typeof decision.reviewEvidence !== 'string' || !decision.reviewEvidence) throwCode('invalid_removal_decision');
    const base = binding(context, services);
    if (base.dev !== decision.rootDev || base.ino !== decision.rootIno) throwCode('installation_replaced');
    const marker = read(base, 'instance.json', services, MAX_FILE).value;
    validateMarker(marker);
    if (marker.phase !== 'complete' || marker.installationId !== decision.installationId) throwCode('removal_identity_unknown');
    base.installationId = installationId = marker.installationId;
    validateIsolation(base, marker.paths, marker.plistPath, services);
    removalState(base, marker, services);
    recoverDeadLock(base, 'lifecycle', marker, services);
    return { ...await remove(base, marker, context, services, true), installationId };
  } catch (error) { return { ...fail(error?.[SAFE_REASON] ? error.reason : 'internal_error', error?.[SAFE_REASON] ? error.exitCode ?? 2 : 2), installationId }; }
}

// Recovery mutex: a flock-style lock (macOS O_EXLOCK) on the hidden sibling `.<root>.recovery.lock`. The kernel releases it
// when its holder exits or is killed, so a crash during recovery can never leave it held, and two
// recoverers can never both pass the proof and remove each other's fresh lock.
const O_EXLOCK = 0x20, O_NONBLOCK = 0x4;
// The mutex lives beside the installation, not in it, so removing the installation directory never
// races a recoverer that recreates the file, and a stalled recoverer cannot block the rmdir.
const mutexPath = base => path.join(path.dirname(base.root), `.${path.basename(base.root)}.recovery.lock`);
// The engine's mutex holds exactly this text and has mode 0600; any other file at the path (empty,
// different, wider mode) is someone else's and is never locked as the mutex or deleted.
export const MUTEX_MARK = 'codex-router-warmup recovery mutex v1\n';
// Created complete in one step: the marked file is written beside the path, then linked into place
// (link fails if anything is there), so a crash never leaves an unmarked mutex behind.
function createMutex(file, services) {
  const f = services.files, temp = `${file}.new-${crypto.randomUUID()}`;
  const fd = f.openSync(temp, f.constants.O_WRONLY | f.constants.O_CREAT | f.constants.O_EXCL | f.constants.O_NOFOLLOW, 0o600);
  try {
    try {
      if (f.writeSync(fd, MUTEX_MARK) !== Buffer.byteLength(MUTEX_MARK)) throwCode('unsafe_lock');  // never publish a short write
      f.fsyncSync(fd);
    } finally { f.closeSync(fd); }
    try { f.linkSync(temp, file); } catch (error) { if (error?.code !== 'EEXIST') throw error; }
  } finally {
    try { f.unlinkSync(temp); } catch (error) { if (error?.code !== 'ENOENT') throw error; }
  }
}
function ownedMutex(fd, services) {
  const f = services.files, stat = f.fstatSync(fd);
  if (!stat.isFile() || stat.uid !== services.uid || (stat.mode & 0o7777) !== 0o600 || stat.size !== Buffer.byteLength(MUTEX_MARK)) return null;
  const buffer = Buffer.alloc(stat.size);
  return f.readSync(fd, buffer, 0, stat.size, 0) === stat.size && buffer.toString() === MUTEX_MARK ? stat : null;
}
const TOMBSTONE = /^(?:work|lifecycle)\.lock\.dead-[a-f0-9-]{36}$/;
const recoveryBusy = () => Object.assign(new Error('lock_owner_not_proven_dead'), { reason: 'lock_owner_not_proven_dead', ownerStatus: 'alive', [SAFE_REASON]: true });
// Removal takes the mutex with O_CREAT (it may be resuming after the marker was removed) and waits
// up to five seconds for a recovery already in progress; it then holds it until the end.
async function holdRecoveryForRemoval(base, services) {
  const f = services.files, file = mutexPath(base);
  if (process.platform !== 'darwin') throwCode('recovery_mutex_unavailable');
  for (let attempt = 0; ; attempt++) {
    sameRoot(base, services);  // also after every wait: never create the mutex in a replaced root
    try {
      const fd = f.openSync(file, f.constants.O_RDWR | f.constants.O_NOFOLLOW | O_EXLOCK | O_NONBLOCK);
      try { if (!ownedMutex(fd, services)) throwCode('unsafe_lock'); } catch (error) { f.closeSync(fd); throw error; }
      base.recoveryHeld = true;
      return fd;
    } catch (error) {
      if (error?.code === 'ENOENT') { createMutex(file, services); continue; }
      if (!['EAGAIN', 'EWOULDBLOCK'].includes(error?.code)) throw error;
      if (attempt >= 50) throw Object.assign(new Error('lock_busy'), { reason: 'lock_busy', exitCode: 3, [SAFE_REASON]: true });
      await delay(100);
    }
  }
}

function withRecoveryMutex(base, services, fn) {
  const f = services.files, file = mutexPath(base);
  if (process.platform !== 'darwin') throwCode('recovery_mutex_unavailable');
  // This process already holds it (removal in progress): run under that hold.
  if (base.recoveryHeld) { sweepTombstones(base, services); return fn(); }
  const flags = f.constants.O_RDWR | f.constants.O_NOFOLLOW | O_EXLOCK | O_NONBLOCK;
  let fd;
  try {
    try { fd = f.openSync(file, flags); }
    catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      // Created only for a live installation: a removal in progress (marker gone) is left alone.
      try { f.lstatSync(path.join(base.root, 'instance.json')); } catch { throw recoveryBusy(); }
      createMutex(file, services);
      try { fd = f.openSync(file, flags); } catch (again) { if (again?.code === 'ENOENT') throw recoveryBusy(); throw again; }
    }
  } catch (error) {
    if (['EAGAIN', 'EWOULDBLOCK', 'EEXIST'].includes(error?.code)) throw recoveryBusy();
    throw error;
  }
  try {
    const stat = ownedMutex(fd, services);
    if (!stat) throwCode('unsafe_lock');
    // Checked again while holding it: if removal took the marker meanwhile, this recoverer stands
    // down and removes the mutex file it may have recreated, so removal's rmdir can finish.
    try { f.lstatSync(path.join(base.root, 'instance.json')); }
    catch {
      try { if (f.lstatSync(file).ino === stat.ino) f.unlinkSync(file); } catch { /* already gone */ }
      throw recoveryBusy();
    }
    sweepTombstones(base, services);
    return fn();
  } finally { f.closeSync(fd); }
}

// A proven-dead lock is first renamed out of the lock path in one atomic step, then emptied. A
// crash after the rename leaves only a tombstone, which the next recovery (or removal) clears;
// the lock path itself is never left ownerless. Call only while holding the recovery mutex.
function sameRoot(base, services) {
  const root = services.files.lstatSync(base.root);
  if (root.dev !== base.dev || root.ino !== base.ino) throwCode('installation_replaced');
}

function sweepTombstones(base, services) {
  const f = services.files;
  sameRoot(base, services);
  for (const name of f.readdirSync(base.root)) {
    if (!TOMBSTONE.test(name)) continue;
    const dir = path.join(base.root, name);
    const stat = f.lstatSync(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== services.uid) throwCode('unsafe_lock');
    for (const entry of f.readdirSync(dir)) {
      if (entry !== 'owner.json') throwCode('unsafe_lock');
      f.unlinkSync(path.join(dir, entry));
    }
    f.rmdirSync(dir);
  }
}

// The read-only half of the dead-owner proof, shared by recovery and by status: what the lock
// directory and its owner record say, without removing anything.
function inspectLockOwner(base, name, marker, services, { notSelf = false } = {}) {
  const f = services.files, dir = path.join(base.root, `${name}.lock`);
  let stat;
  try { stat = f.lstatSync(dir); } catch (error) { if (error.code === 'ENOENT') return { state: 'free' }; throw error; }
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== services.uid || (stat.mode & 0o077) || services.acl(dir) !== true) throwCode('unsafe_lock');
  const owner = safeRead(path.join(dir, 'owner.json'), services, { root: base.root, limit: 4096 }).value;
  if (!plain(owner) || owner.installationId !== marker.installationId || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 || typeof owner.startId !== 'string' || !owner.startId || typeof owner.nonce !== 'string' || !owner.nonce) throwCode('lock_owner_unknown');
  // A process never clears a lock it holds itself: its own owner is alive by definition.
  const current = services.processes.current;
  const self = notSelf && owner.pid === current?.pid && owner.startId === current?.startId;
  return { state: 'owned', stat, owner, ownerStatus: self ? 'alive' : services.processes.inspect(owner) };
}

function recoverDeadLock(base, name, marker, services, options = {}) {
  return withRecoveryMutex(base, services, () => clearProvenDeadLock(base, name, marker, services, options));
}

function clearProvenDeadLock(base, name, marker, services, options) {
  const f = services.files, dir = path.join(base.root, `${name}.lock`);
  const found = inspectLockOwner(base, name, marker, services, options);
  if (found.state === 'free') return;
  const { stat, owner, ownerStatus } = found;
  if (ownerStatus !== 'dead') throw Object.assign(new Error('lock_owner_not_proven_dead'), { reason: 'lock_owner_not_proven_dead', ownerStatus, [SAFE_REASON]: true });
  unchanged(base, services);
  const again = f.lstatSync(dir);
  if (again.dev !== stat.dev || again.ino !== stat.ino) throwCode('lock_replaced');
  const still = safeRead(path.join(dir, 'owner.json'), services, { root: base.root, limit: 4096 }).value;
  if (JSON.stringify(still) !== JSON.stringify(owner)) throwCode('lock_owner_changed');
  f.renameSync(dir, path.join(base.root, `${name}.lock.dead-${crypto.randomUUID()}`));
  const fd = f.openSync(base.root, f.constants.O_RDONLY | f.constants.O_DIRECTORY);
  try { f.fsyncSync(fd); } finally { f.closeSync(fd); }
  services.fault?.('after_dead_lock_rename');
  sweepTombstones(base, services);
}

// Takes the work lock. When it is busy, clears it only if its owner is proven dead, with the same
// proof `schedule disable` uses, under the crash-released recovery mutex. Any other outcome keeps
// the lock and reports lock_busy, exactly as before recovery existed.
function acquireWork(base, marker, services) {
  try { return lock(base, 'work', marker, services); }
  catch (error) {
    if (!error?.[SAFE_REASON] || error.reason !== 'lock_busy') throw error;
    try { recoverDeadLock(base, 'work', marker, services, { notSelf: true }); }
    catch { throw error; }
    return lock(base, 'work', marker, services);
  }
}

// Read-only view of the work lock for status, from the same proof recovery uses: `stale` only
// when recovery would clear it. Never removes anything.
function workLockStatus(base, marker, services) {
  let since = null;
  try { since = Math.trunc(services.files.lstatSync(path.join(base.root, 'work.lock')).mtimeMs); } catch { /* free or unreadable */ }
  try {
    const found = inspectLockOwner(base, 'work', marker, services);
    if (found.state === 'free') return { state: 'free', since: null };
    return { state: found.ownerStatus === 'alive' ? 'held' : found.ownerStatus === 'dead' ? 'stale' : 'unknown', since: Number.isFinite(since) ? since : null };
  } catch { return { state: 'unknown', since: Number.isFinite(since) ? since : null }; }
}

export async function recoverInstance(context, services, decision) {
  try {
    if (!exact(decision, own(decision ?? {}, 'intendedPair') ? ['installationId', 'rootDev', 'rootIno', 'skipThrough', 'reviewEvidence', 'backupPath', 'intendedPair'] : ['installationId', 'rootDev', 'rootIno', 'skipThrough', 'reviewEvidence', 'backupPath']) || typeof decision.reviewEvidence !== 'string' || !decision.reviewEvidence || !validSlot(decision.skipThrough)) throwCode('invalid_recovery_decision');
    if (own(decision, 'intendedPair')) {
      const pair = decision.intendedPair;
      if (!exact(pair, ['path', 'sha256', 'baseConfigPath', 'baseCompatibilityPath']) || !/^[a-f0-9]{64}$/.test(pair.sha256) || ['path', 'baseConfigPath', 'baseCompatibilityPath'].some(key => typeof pair[key] !== 'string' || !path.isAbsolute(pair[key]) || path.resolve(pair[key]) !== pair[key])) throwCode('invalid_recovery_decision');
    }
    const base = binding(context, services);
    if (decision.rootDev !== base.dev || decision.rootIno !== base.ino) throwCode('installation_replaced');
    const marker = read(base, 'instance.json', services, MAX_FILE).value;
    validateMarker(marker);
    if (marker.phase !== 'complete' || marker.installationId !== decision.installationId) throwCode('recovery_identity_unknown');
    base.installationId = marker.installationId;
    validateIsolation(base, marker.paths, marker.plistPath, services);
    recoverDeadLock(base, 'lifecycle', marker, services);
    const releaseLife = lock(base, 'lifecycle', marker, services);
    try {
      const job = jobBinding(base, { marker }, context);
      const observed = await services.jobs.inspect(job);
      if (!['loaded', 'absent'].includes(observed)) throwCode('job_ownership_unknown');
      const runner = await services.jobs.runner(job);
      if (observed === 'loaded') await services.jobs.disable(job);
      if (runner) {
        if (!runner.scheduled || runner.installationId !== marker.installationId || services.processes.inspect(runner) !== 'alive') throwCode('runner_ownership_unknown');
        if (!await services.processes.wait(runner, 50000)) {
          if (services.processes.inspect(runner) !== 'alive') throwCode('runner_ownership_unknown');
          await services.processes.terminate(runner);
          if (!await services.processes.wait(runner, 5000)) throwCode('runner_still_active');
        }
      }
      try { recoverDeadLock(base, 'work', marker, services); }
      catch (error) { if (error?.[SAFE_REASON] && error.reason === 'lock_owner_not_proven_dead' && error.ownerStatus === 'alive') throw Object.assign(error, { exitCode: 3, reason: 'lock_busy' }); throw error; }
      const releaseWork = lock(base, 'work', marker, services);
      let commitStarted = false, commitComplete = false;
      try {
        const c = read(base, 'config.json', services, MAX_FILE, !!decision.intendedPair);
        const x = read(base, 'compatibility.json', services, MAX_FILE, !!decision.intendedPair);
        const existing = read(base, 'state.json', services, MAX_STATE, true);
        const backup = decision.backupPath === null ? null : safeRead(decision.backupPath, services, { root: path.dirname(decision.backupPath), limit: MAX_STATE });
        if (!existing && !backup) throwCode('history_unavailable');
        if (existing) validateState(existing.value, marker);
        if (backup) validateState(backup.value, marker);
        const state = structuredClone(existing?.value ?? backup.value);
        if (state.removalPending || backup?.value.removalPending) throwCode('removal_pending');
        let candidate, targetConfigDigest, targetCompatibilityDigest, scheduleChanged = false, predecessorZone;
        const states = [existing?.value, backup?.value].filter(Boolean);
        if (decision.intendedPair) {
          const pair = decision.intendedPair;
          const privateRead = file => safeRead(file, services, { root: path.dirname(file), limit: MAX_FILE });
          const intended = privateRead(pair.path), baselineConfig = privateRead(pair.baseConfigPath), baselineCompatibility = privateRead(pair.baseCompatibilityPath);
          if (intended.stamp.sha256 !== pair.sha256) throwCode('recovery_candidate_unreviewed');
          candidate = intended.value;
          validateConfig(baselineConfig.value, marker); validateCompatibility(baselineCompatibility.value);
          await validateMaintenanceCandidate(base, marker, { config: baselineConfig.value, compatibility: baselineCompatibility.value }, candidate, services);
          targetConfigDigest = hash(Buffer.from(JSON.stringify(candidate.config)));
          targetCompatibilityDigest = hash(Buffer.from(JSON.stringify(candidate.compatibility)));
          const predecessor = item => item.configDigest === baselineConfig.stamp.sha256 && item.compatibilityDigest === baselineCompatibility.stamp.sha256;
          const target = item => item.configDigest === targetConfigDigest && item.compatibilityDigest === targetCompatibilityDigest;
          const committed = existing && target(existing.value) && c?.stamp.sha256 === targetConfigDigest && x?.stamp.sha256 === targetCompatibilityDigest;
          if (states.some(item => !predecessor(item) && !(committed && target(item)))) throwCode('recovery_candidate_unreviewed');
          if (!committed && !states.some(predecessor)) throwCode('recovery_candidate_unreviewed');
          scheduleChanged = !committed && JSON.stringify(baselineConfig.value.schedule) !== JSON.stringify(candidate.config.schedule);
          if (baselineConfig.value.schedule.zone !== candidate.config.schedule.zone && (!committed || state.lastTickZone === undefined)) predecessorZone = baselineConfig.value.schedule.zone;
          if (c && ![baselineConfig.stamp.sha256, targetConfigDigest].includes(c.stamp.sha256) || x && ![baselineCompatibility.stamp.sha256, targetCompatibilityDigest].includes(x.stamp.sha256)) throwCode('recovery_candidate_unreviewed');
        } else {
          validateConfig(c.value, marker); validateCompatibility(x.value);
          validateIsolation(base, c.value.paths, marker.plistPath, services);
          if ((await adapter(services, 'checkCompatibility', checkCompatibility)({ paths: c.value.paths, compatibility: x.value }, services))?.kind !== 'ready') throwCode('compatibility_blocked');
          if (states.some(item => item.configDigest !== c.stamp.sha256 || item.compatibilityDigest !== x.stamp.sha256)) throwCode('recovery_candidate_unreviewed');
        }
        if (existing && backup) {
          if (JSON.stringify(existing.value.scheduleEdits) !== JSON.stringify(backup.value.scheduleEdits)) throwCode('recovery_schedule_conflict');
          const revision = Math.max(scheduleRevision(existing.value), scheduleRevision(backup.value));
          if (revision) state.scheduleRevision = revision;
          for (const field of ['slots', 'reservations']) {
            for (const [key, value] of Object.entries(backup.value[field])) {
              const current = state[field][key];
              if (!current) state[field][key] = value;
              else if (JSON.stringify(current) !== JSON.stringify(value)) {
                if (field !== 'reservations' || JSON.stringify({ ...current, resolved: true }) !== JSON.stringify({ ...value, resolved: true })) throwCode('recovery_history_conflict');
                if (value.resolved) current.resolved = true;
              }
            }
          }
          const seen = new Set();
          state.history = [...backup.value.history, ...state.history].filter(entry => {
            const key = JSON.stringify(entry);
            if (seen.has(key)) return false;
            seen.add(key); return true;
          });
          for (const [id, at] of Object.entries(backup.value.cooldowns)) state.cooldowns[id] = Math.max(state.cooldowns[id] ?? at, at);
          for (const [id, block] of Object.entries(backup.value.blocks)) {
            if (!own(state.blocks, id)) state.blocks[id] = block;
            else if (state.blocks[id] !== block) state.blocks[id] = 'recovery_correction_required';
          }
          state.highWater = [state.highWater, backup.value.highWater].filter(Boolean).sort().at(-1) ?? null;
          state.lastWall = [state.lastWall, backup.value.lastWall].filter(Number.isFinite).reduce((latest, value) => Math.max(latest, value), -Infinity);
          if (state.lastWall === -Infinity) state.lastWall = null;
        }
        if (backup?.value.slotLedger) {
          state.slotLedger = { ...backup.value.slotLedger, ...state.slotLedger };
          for (const slot of Object.keys(state.slots)) delete state.slotLedger[slot];
        }
        if (predecessorZone) state.lastTickZone = predecessorZone;
        const recoveryConfig = candidate?.config ?? c.value;
        const recoveryAt = services.clock.wall();
        const zones = new Set([scheduleZone(recoveryConfig, services), state.lastTickZone ?? LEGACY_ZONE, backup?.value.lastTickZone].filter(Boolean));
        const date = [...zones].map(zone => localDate(localParts(recoveryAt, zone))).sort().at(-1);
        const lastPossibleTime = states.some(item => item.scheduleEdits) ? '23:59' : '18:00';
        const todayEnd = `${date}T${lastPossibleTime}`;
        const highest = [todayEnd, state.highWater, state.skipThrough, ...Object.keys(state.slots), ...[existing?.value, backup?.value].filter(Boolean).flatMap(item => [item.highWater, item.skipThrough])].filter(Boolean).sort().at(-1);
        if (decision.skipThrough < highest) throwCode('recovery_boundary_too_early');
        setScheduleEnabled(state, false);
        state.activeBatch = null;
        state.skipThrough = decision.skipThrough;
        state.highWater = [state.highWater, ...Object.keys(state.slots)].filter(Boolean).sort().at(-1) ?? null;
        state.pilots = {};
        validateState(state, marker);
        if (Buffer.byteLength(JSON.stringify(state)) > MAX_STATE) throwCode('state_capacity');
        commitStarted = true;
        atomic(base, 'state.json', state, services);
        if (candidate) {
          state.configDigest = atomic(base, 'config.json', candidate.config, services);
          state.compatibilityDigest = atomic(base, 'compatibility.json', candidate.compatibility, services);
          if (state.configDigest !== targetConfigDigest || state.compatibilityDigest !== targetCompatibilityDigest) throwCode('recovery_incomplete');
          if (scheduleChanged) bumpScheduleRevision(state);
          atomic(base, 'state.json', state, services);
        }
        if (await services.jobs.inspect(job) !== 'absent' || await services.jobs.runner(job) || load(base, services).state.scheduleEnabled) throwCode('recovery_incomplete');
        commitComplete = true;
        return result(0, 'ready', 'recovered_disabled', { installationId: marker.installationId, skipThrough: state.skipThrough, ...(candidate ? { reconciledPair: true } : {}) });
      } finally { if (!commitStarted || commitComplete) releaseWork(); }
    } finally { releaseLife(); }
  } catch (error) { return fail(error?.[SAFE_REASON] ? error.reason : 'recovery_unavailable', error?.[SAFE_REASON] ? error.exitCode ?? 2 : 2); }
}

async function guarded(base, marker, services, lifecycle, fn) {
  const releaseLife = lifecycle ? lock(base, 'lifecycle', marker, services) : null;
  let releaseWork, value, failure;
  try {
    releaseWork = acquireWork(base, marker, services);
    value = await fn();
  } catch (error) { failure = error; }
  finally {
    try { releaseWork?.(); } catch (error) { failure ??= error; }
    try { releaseLife?.(); } catch (error) { failure ??= error; }
  }
  if (failure) {
    if (Array.isArray(value?.results)) return { ...value, exitCode: 2, outcome: 'blocked', reason: 'lock_release_failed' };
    throw failure;
  }
  return value;
}

function contextFor(data) { return { paths: data.config.paths, compatibility: data.compatibility }; }
function pruneLedger(state, cutoff) {
  for (const [slot, row] of Object.entries(state.slotLedger ?? {})) if (row.at < cutoff) delete state.slotLedger[slot];
}
// Bounds state growth: resolved reservations and slot claims older than the cutoff go. Unresolved
// reservations stay, and so do the claims (and their reservations) that highWater, the active batch
// or the last outcome name. A slot must also lie a whole day before the cutoff, so in every zone it is
// already beyond status retention, and its key must be one the cap check can classify.
function pruneSlots(state, cutoff, manualCutoff) {
  const kept = new Set([state.highWater, state.activeBatch?.slot, state.lastSlotOutcome?.slot].filter(Boolean));
  const lastDate = new Date(cutoff - 86400000).toISOString().slice(0, 10);
  const old = slot => validSlot(slot) && !kept.has(slot) && state.highWater !== null && slot <= state.highWater && slot.slice(0, 10) < lastDate;
  for (const [slot, claim] of Object.entries(state.slots)) if (claim.claimedAt < cutoff && old(slot)) delete state.slots[slot];
  for (const [key, record] of Object.entries(state.reservations)) {
    if (record.resolved !== true || !validReservationKey(key, record)) continue;
    // Manual rows count toward no cap or slot, so they age out on the wall clock even while paused.
    if (key.startsWith('manual:') ? record.at < manualCutoff : record.at < cutoff && old(JSON.parse(key)[0])) delete state.reservations[key];
  }
}
function storeState(base, state, services) {
  const cutoff = services.clock.wall() - 30 * 86400000;
  state.history = state.history.filter(entry => typeof entry.at !== 'number' || entry.at >= cutoff);
  pruneLedger(state, cutoff);
  // Records that feed caps and deduplication are pruned against the earliest of now, the last tick's
  // wall time and the newest send evidence, so a forward clock jump can't drop today's rows.
  // A tick on a jumped clock raises lastWall too, so the newest send evidence also bounds it: an idle
  // jump writes no reservation or claim, and pruning never runs ahead of the last real batch.
  const evidence = Math.max(-Infinity, ...Object.values(state.reservations).map(r => r.at), ...Object.values(state.slots).map(c => c.claimedAt));
  const slotCutoff = Math.min(services.clock.wall(), Number.isFinite(state.lastWall) ? state.lastWall : Infinity, Number.isFinite(evidence) ? evidence : Infinity) - 30 * 86400000;
  if (Math.abs(slotCutoff) < 8e15) pruneSlots(state, slotCutoff, cutoff);  // false for NaN; keeps the Date range valid
  atomic(base, 'state.json', state, services);
}
function pilotKey(e, compatibility, config) { return JSON.stringify([e.enrollmentId, e.identity.accountId, e.identity.userId, e.model, compatibility.adapterVersion, config.requestContractVersion]); }
const formatters = new Map();
function localFormatter(zone) {
  if (!formatters.has(zone)) formatters.set(zone, new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }));
  return formatters.get(zone);
}
const isZoneName = zone => typeof zone === 'string' && /^[A-Za-z][A-Za-z0-9_+/-]{0,99}$/.test(zone);
function isZone(zone) {
  if (!isZoneName(zone)) return false;
  try { localFormatter(zone); return true; }
  catch { return false; }
}
function scheduleZone(config, services) {
  if (config.schedule.zone === LEGACY_ZONE) return LEGACY_ZONE;
  const zone = services.clock.zone?.();
  if (!isZone(zone)) throwCode('system_zone_unavailable');
  return zone;
}
function localParts(ms, zone) {
  return Object.fromEntries(localFormatter(zone).formatToParts(ms).filter(x => x.type !== 'literal').map(x => [x.type, x.value]));
}
const localDate = parts => `${parts.year}-${parts.month}-${parts.day}`;
const localTime = parts => `${parts.hour}:${parts.minute}`;
function localLabel(ms, zone) {
  const parts = localParts(ms, zone);
  return `${localDate(parts)}T${localTime(parts)}`;
}
const scheduleRevision = state => state.scheduleRevision ?? 0;
function checkScheduleRevision(state, expected) {
  if (expected !== undefined && expected !== scheduleRevision(state)) throwCode('schedule_revision_conflict');
}
function bumpScheduleRevision(state, keepPause = false) {
  if (scheduleRevision(state) === Number.MAX_SAFE_INTEGER) throwCode('schedule_revision_exhausted');
  const previous = scheduleRevision(state);
  state.scheduleRevision = previous + 1;
  // An edit that settled the pause (settlePause) keeps it current, so resume still records the later paused
  // slots. Other schedule changes (recovery, maintenance) leave it stale, as do edits to a stale pause.
  if (keepPause && state.scheduleEnabled !== true && state.schedulePause?.revision === previous) state.schedulePause = { ...state.schedulePause, revision: state.scheduleRevision };
}
function setScheduleEnabled(state, enabled) {
  if (state.scheduleEnabled !== enabled) bumpScheduleRevision(state);
  state.scheduleEnabled = enabled;
}
function applyEdits(schedule, edits) {
  const { weekdays: _previous, ...rest } = schedule;
  return { ...rest, times: edits.times,
    today: { date: edits.date, admissions: edits.admissions, ...(edits.todayExclusion ? { exclusion: edits.todayExclusion } : {}) },
    ...(edits.weekdays ? { weekdays: edits.weekdays } : {}) };
}
function effectiveSchedule(data, zone = data.config.schedule.zone) {
  const edits = data.state.scheduleEdits;
  const schedule = { ...data.config.schedule, zone, ...(data.state.vacations?.length ? { vacations: data.state.vacations } : {}) };
  return edits ? applyEdits(schedule, edits) : schedule;
}
const isoWeekday = date => new Date(Date.parse(date)).getUTCDay() || 7;
// The single date-policy resolver shared by tick, projection, spacing and edit validation.
// The edit date keeps its frozen admissions, so a rule change can only affect later dates.
// Vacations (Increment B1) are a layer above everything else: they never enter the frozen edit
// snapshot or the spacing check, so removing a range restores exactly the underlying schedule.
const onVacation = (schedule, date) => !!schedule.vacations?.some(range => range.start <= date && date <= range.end);
function policyExclusion(schedule, date) {
  if (schedule.today?.date === date) return schedule.today.exclusion ?? null;
  if (schedule.today && date < schedule.today.date) return null;
  if (schedule.weekdays && !schedule.weekdays.includes(isoWeekday(date))) return 'weekday';
  return null;
}
function dateExclusion(schedule, date) {
  return onVacation(schedule, date) ? 'vacation' : policyExclusion(schedule, date);
}
// The schedule's admissions for a date before vacations are applied.
function policyAdmissionTimes(schedule, date) {
  if (schedule.today && date < schedule.today.date) return [];
  if (schedule.today?.date === date) return Object.entries(schedule.today.admissions).sort(([a], [b]) => a.localeCompare(b));
  if (policyExclusion(schedule, date)) return [];
  return schedule.times.map(time => [time, time === '13:00' && schedule.advance13?.date === date ? schedule.advance13.time : time]);
}
function admissionTimes(schedule, date) {
  return onVacation(schedule, date) ? [] : policyAdmissionTimes(schedule, date);
}
// Freezes the date's resolved admissions and carries the recurring policy forward unchanged.
function snapshotEdits(schedule, date) {
  const exclusion = policyExclusion(schedule, date);
  return { date, times: [...schedule.times], admissions: Object.fromEntries(policyAdmissionTimes(schedule, date)),
    ...(schedule.weekdays ? { weekdays: [...schedule.weekdays] } : {}), ...(exclusion ? { todayExclusion: exclusion } : {}) };
}
function localSlot(ms, schedule) {
  const parts = localParts(ms, schedule.zone);
  const date = localDate(parts), time = localTime(parts);
  const logicalTime = admissionTimes(schedule, date).find(([, admission]) => admission === time)?.[0];
  return logicalTime ? { slot: `${date}T${logicalTime}`, admission: time } : null;
}
function slotObservation(state, now, schedule) {
  const tick = state.lastTick;
  if (!Number.isFinite(tick) || !Number.isFinite(now) || !Number.isFinite(state.lastWall) || tick > now || state.lastWall > now || tick > state.lastWall || Math.abs(tick) > 8640000000000000) return null;
  const zone = state.lastTickZone ?? schedule.zone;
  const date = localDate(localParts(tick, zone));
  const elapsed = admissionsOnDate({ ...schedule, zone }, date).reverse().find(({ at }) => at + 60000 <= tick);
  if (!elapsed) return null;
  const { slot, admission: admissionTime } = elapsed;
  const time = slot.slice(11);
  if (!offeredAdmission(state, slot) || state.slotLedger?.[slot] || state.activeBatch?.slot >= slot || state.lastSlotOutcome?.slot >= slot) return null;
  for (const key of Object.keys(state.reservations)) {
    if (key.startsWith('manual:')) continue;
    let reservation;
    try { reservation = JSON.parse(key); } catch { return null; }
    const record = state.reservations[key];
    if (!Array.isArray(reservation) || reservation.length !== 4 || !validSlot(reservation[0]) || reservation[1] !== record.enrollmentId || reservation[2] !== record.identity.accountId || reservation[3] !== record.identity.userId || reservation[0] >= slot) return null;
  }
  return { slot, observation: 'unobserved', asOf: tick, ...(admissionTime !== time ? { admissionTime } : {}) };
}
function jobBinding(base, data, context) { return { root: base.root, dev: base.dev, ino: base.ino, installationId: data.marker.installationId, label: 'local.codex-router-warmup', plistPath: data.marker.plistPath, nodePath: context.nodePath, scriptPath: context.scriptPath }; }

const minutes = time => Number(time.slice(0, 2)) * 60 + Number(time.slice(3));
const offsetDate = (date, days) => new Date(Date.parse(date) + days * 86400000).toISOString().slice(0, 10);
function dateOffsets(date, zone) {
  const start = Date.parse(date);
  return new Set([-36, -12, 12, 36].map(hour => {
    const sample = start + hour * 3600000;
    return Date.parse(`${localLabel(sample, zone)}Z`) - sample;
  }));
}
// The instants a local `YYYY-MM-DDTHH:MM` label names in `zone`: two in a fall-back hour, none in a skipped one.
function labelInstants(label, zone, offsets = dateOffsets(label.slice(0, 10), zone)) {
  return [...offsets].map(offset => Date.parse(`${label}Z`) - offset).filter(at => localLabel(at, zone) === label);
}
function admissionsOnDate(schedule, date) {
  const offsets = dateOffsets(date, schedule.zone);
  const entries = [];
  for (const [time, admission] of admissionTimes(schedule, date)) {
    for (const at of labelInstants(`${date}T${admission}`, schedule.zone, offsets)) entries.push({ slot: `${date}T${time}`, admission, date, at });
  }
  return entries.sort((a, b) => a.at - b.at);
}
function offeredAdmission(state, slot) {
  return !(state.slots[slot] || state.highWater && slot <= state.highWater ||
    state.skipThrough && slot <= state.skipThrough || state.slotLedger?.[slot]?.cause === 'zone_changed');
}
function spacedFromLastClaim(state, at, accounts) {
  const last = state.slots[state.highWater];
  return !last || (Math.floor(at / 60000) - Math.floor(last.claimedAt / 60000)) * 60000 >=
    minimumSpacingMs(Math.max(accounts, last.enrollmentIds.length));
}
// The accounts a scheduled batch would hold now: enabled ones, limited by an explicit selection.
// Tick, projection, status and the manual overlap guard all size spacing from this same set.
function scheduledEnrollments(data) {
  const chosen = data.state.scheduledAccounts ? new Set(data.state.scheduledAccounts) : null;
  return data.config.enrollments.filter(e => e.enabled && (!chosen || chosen.has(e.enrollmentId)));
}
function nextAdmission(state, schedule, now, accounts) {
  const local = localDate(localParts(now, schedule.zone));
  for (let offset = 0; offset < 7; offset++) {
    const entry = admissionsOnDate(schedule, offsetDate(local, offset)).find(({ at, slot }) => at + 60000 > now && offeredAdmission(state, slot) && spacedFromLastClaim(state, at, accounts));
    if (entry) return entry;
  }
  return null;
}
const SPACING_WINDOW = [0, 1, 2, 3, 4, 5, 6, 7, 8];
function checkSpacing(data, date, edits, todayOnly) {
  const before = effectiveSchedule(data);
  const after = applyEdits(before, edits);
  const minimumMs = minimumSpacingMs(data.config.enrollments.filter(e => e.enabled).length);
  // Nine dates cover every pair of adjacent weekdays, so a weekday rule cannot hide a too-close
  // pair behind excluded days. Excluded days contribute no admissions.
  const offsets = todayOnly ? [-1, ...SPACING_WINDOW] : SPACING_WINDOW;
  // Vacations are ignored here: a pattern must be valid on its own, so ending or removing a range
  // can never reopen too-close admissions.
  const admissions = offsets.flatMap(offset => policyAdmissionTimes(offset < 0 ? before : after, offsetDate(date, offset))
    .map(([, time]) => (offset * 1440 + minutes(time)) * 60000));
  if (admissions.some((at, index) => index > 0 && at - admissions[index - 1] < minimumMs)) throwCode('schedule_spacing');
}

const EDIT_ACTIONS = ['add', 'remove', 'move', 'weekdays'];
function validEditCommand({ action, time, target, days, today }) {
  if (action === 'weekdays') {
    if (today || !Array.isArray(days) || !days.length || days.length > 7 || !days.every((day, i) => Number.isSafeInteger(day) && day >= 1 && day <= 7 && (!i || days[i - 1] < day))) throwCode('invalid_weekdays');
    return;
  }
  if (!EDIT_ACTIONS.includes(action)) throwCode('invalid_schedule_action');
  if (!validTime(time) || (action === 'move' && !validTime(target))) throwCode('invalid_schedule_time');
}

// Pure validation of one proposed edit against an already loaded snapshot. Preview,
// inspect and the locked save all call this, so they accept and reject the same edits.
function proposeEdit(data, { action, time, target, days, today, expectedRevision, expectedLocalDate }, now, zone) {
  validEditCommand({ action, time, target, days, today });
  const { state } = data;
  checkScheduleRevision(state, expectedRevision);
  const parts = localParts(now, zone);
  const date = localDate(parts);
  if ((state.lastWall !== null && now + 1000 < state.lastWall) || state.scheduleEdits?.date > date) throwCode('clock_moved_backward');
  if (expectedLocalDate !== undefined && expectedLocalDate !== date) throwCode('schedule_date_changed');
  const schedule = effectiveSchedule(data, zone);
  const edits = snapshotEdits(schedule, date);
  if (action === 'weekdays') {
    if (days.length === 7) delete edits.weekdays;
    else edits.weekdays = [...days];
    checkSpacing(data, date, edits, false);
    return { date, edits };
  }
  const times = today ? Object.keys(edits.admissions) : edits.times;
  if (today && (edits.todayExclusion || onVacation(schedule, date))) throwCode('schedule_date_excluded');
  if (action !== 'add' && !times.includes(time)) throwCode('schedule_time_missing');
  if (action !== 'remove' && times.includes(action === 'move' ? target : time)) throwCode('schedule_time_exists');

  if (today) {
    const minute = `${parts.hour}:${parts.minute}`;
    const slot = `${date}T${time}`;
    if ((action === 'add' ? time : edits.admissions[time]) <= minute || (action === 'move' && target <= minute)) throwCode('schedule_time_elapsed');
    if (state.skipThrough?.slice(0, 10) >= date || state.highWater >= slot || state.slots[slot] || state.activeBatch?.slot >= slot) throwCode('schedule_slot_unavailable');
    if (action === 'remove') delete edits.admissions[time];
    else edits.admissions[time] = action === 'move' ? target : time;
    if (!validAdmissions(edits.admissions)) throwCode('schedule_order_conflict');
  } else {
    if (action !== 'add') edits.times.splice(edits.times.indexOf(time), 1);
    if (action !== 'remove') edits.times.push(action === 'move' ? target : time);
    edits.times.sort();
  }
  checkSpacing(data, date, edits, today);
  return { date, edits };
}

async function editSchedule(base, marker, command, services) {
  validEditCommand(command);
  const evaluate = () => {
    const data = load(base, services);
    const { state } = data;
    const zone = scheduleZone(data.config, services);
    const { date, edits } = proposeEdit(data, command, services.clock.wall(), zone);
    const previous = state.scheduleEdits ?? null;
    let keepPause = false;
    if (!command.preview && state.scheduleEnabled) settleElapsed(data, zone, services.clock.wall());
    else if (!command.preview) keepPause = settlePause(data, zone, services.clock.wall());
    state.scheduleEdits = edits;
    if (!command.preview) {
      bumpScheduleRevision(state, keepPause);
      // B3: one safe undo for the latest time edit; any other schedule change replaces it.
      if (['add', 'remove', 'move'].includes(command.action)) state.scheduleUndo = { revision: scheduleRevision(state), date, previous };
      else delete state.scheduleUndo;
      atomic(base, 'state.json', state, services);
    }
    return result(0, 'ready', command.preview ? 'schedule_preview' : 'schedule_updated', { schedule: effectiveSchedule(data, zone), scheduleEnabled: state.scheduleEnabled, scheduleRevision: scheduleRevision(state), localDate: date });
  };
  return command.preview ? evaluate() : guarded(base, marker, services, true, evaluate);
}

// Increment B settings: vacations (B1), scheduled accounts (B2), one undo (B3) and daily caps (B4).
// Each validates against the snapshot loaded under the lifecycle and work locks and returns the
// state change, so the check and the write see the same state.
const SETTING_ACTIONS = ['exclude', 'include', 'accounts', 'undo', 'cap'];
function proposeSetting(data, command, now, zone) {
  const { state, config } = data;
  checkScheduleRevision(state, command.expectedRevision);
  const parts = localParts(now, zone);
  const date = localDate(parts);
  if ((state.lastWall !== null && now + 1000 < state.lastWall) || state.scheduleEdits?.date > date) throwCode('clock_moved_backward');
  if (command.expectedLocalDate !== undefined && command.expectedLocalDate !== date) throwCode('schedule_date_changed');
  // Ended ranges are dropped, but only once the last tick has passed them: until then the missed-slot
  // backfill still needs them.
  // The same zone the missed-slot backfill uses for the last tick.
  const tickDate = Number.isFinite(state.lastTick) ? localDate(localParts(state.lastTick, tickZoneOf(data) ?? zone)) : date;
  const keepFrom = tickDate < date ? tickDate : date;
  const current = (state.vacations ?? []).filter(range => range.end >= keepFrom);
  const setVacations = list => next => { if (list.length) next.vacations = list; else delete next.vacations; };
  if (command.action === 'exclude' || command.action === 'include') {
    const { start, end } = command;
    if (!validDate(start) || !validDate(end) || start > end || dayNumber(end) - dayNumber(start) >= MAX_VACATION_DAYS) throwCode('invalid_vacation');
    if (command.action === 'include') {
      if (!(state.vacations ?? []).some(range => range.start === start && range.end === end)) throwCode('vacation_missing');
      // Past days and today were decided already (a slot may be under way), so only the days after
      // today are removed: a range that has started ends today instead, and one ending today or
      // earlier cannot be removed.
      if (end <= date) throwCode('vacation_not_future');
      const rest = current.filter(range => range.start !== start || range.end !== end);
      return setVacations(start <= date ? [...rest, { start, end: date }].sort((a, b) => a.start.localeCompare(b.start)) : rest);
    }
    // A range starts tomorrow at the earliest: today's admissions are already decided (pause instead).
    if (start <= date) throwCode('vacation_not_future');
    if (current.some(range => range.start <= end && start <= range.end)) throwCode('vacation_overlap');
    const list = [...current, { start, end }].sort((a, b) => a.start.localeCompare(b.start));
    if (list.length > MAX_VACATIONS) throwCode('vacation_limit');
    return setVacations(list);
  }
  const known = new Set(config.enrollments.map(e => e.enrollmentId));
  if (command.action === 'accounts') {
    if (command.all) return next => { delete next.scheduledAccounts; };
    if (command.add || command.remove) {
      const id = command.add ?? command.remove;
      if (!known.has(id)) throwCode('unknown_enrollment');
      // "All" becomes an explicit list of the accounts enabled right now, read under the lock.
      const current = state.scheduledAccounts ?? config.enrollments.filter(e => e.enabled).map(e => e.enrollmentId);
      const ids = [...new Set(command.add ? [...current, id] : current.filter(item => item !== id))].sort();
      if (!validAccountList(ids)) throwCode('invalid_account_selection');
      return next => { next.scheduledAccounts = ids; };
    }
    const ids = [...new Set(command.only)].sort();
    if (ids.length !== command.only.length || !validAccountList(ids)) throwCode('invalid_account_selection');
    if (ids.some(id => !known.has(id))) throwCode('unknown_enrollment');
    return next => { next.scheduledAccounts = ids; };
  }
  if (command.action === 'cap') {
    if (!known.has(command.account)) throwCode('unknown_enrollment');
    if (command.count !== null && !validCap(command.count)) throwCode('invalid_cap');
    return next => {
      const caps = { ...(next.caps ?? {}) };
      if (command.count === null) delete caps[command.account];
      else caps[command.account] = command.count;
      if (Object.keys(caps).length) next.caps = caps;
      else delete next.caps;
    };
  }
  if (command.action !== 'undo') throwCode('invalid_schedule_action');
  const undo = state.scheduleUndo;
  if (!undo || undo.revision !== scheduleRevision(state)) throwCode('undo_unavailable');
  if (undo.date !== date) throwCode('undo_expired');
  const restoredState = { ...state };
  if (undo.previous === null) delete restoredState.scheduleEdits;
  else restoredState.scheduleEdits = undo.previous;
  const before = effectiveSchedule(data, zone), after = effectiveSchedule({ ...data, state: restoredState }, zone);
  const was = Object.fromEntries(admissionTimes(before, date)), will = Object.fromEntries(admissionTimes(after, date));
  const minute = `${parts.hour}:${parts.minute}`;
  // Resolved instants catch a fall-back fold, where one wall label names a past and a future time.
  const instants = [...admissionsOnDate(before, date), ...admissionsOnDate(after, date)];
  // Every admission today that the reversal adds, removes or moves must still be ahead and unclaimed.
  for (const time of new Set([...Object.keys(was), ...Object.keys(will)])) {
    if (was[time] === will[time]) continue;
    if ([was[time], will[time]].some(admission => admission !== undefined && admission <= minute)) throwCode('schedule_time_elapsed');
    if (instants.some(entry => entry.slot === `${date}T${time}` && entry.at <= now)) throwCode('schedule_time_elapsed');
    const slot = `${date}T${time}`;
    if (state.skipThrough?.slice(0, 10) >= date || state.highWater >= slot || state.slots[slot] || state.activeBatch?.slot >= slot) throwCode('schedule_slot_unavailable');
  }
  checkSpacing(data, date, snapshotEdits(after, date), true);
  return next => {
    if (undo.previous === null) delete next.scheduleEdits;
    else next.scheduleEdits = undo.previous;
  };
}

function settingsReport(state, schedule, date) {
  return { schedule, scheduleEnabled: state.scheduleEnabled, scheduleRevision: scheduleRevision(state), localDate: date,
    scheduledAccounts: state.scheduledAccounts ?? null, caps: state.caps ?? {}, undoAvailable: undoAvailable(state, date) };
}
function undoAvailable(state, date) {
  return !!state.scheduleUndo && state.scheduleUndo.revision === scheduleRevision(state) && state.scheduleUndo.date === date;
}

async function changeSettings(base, marker, command, services) {
  return guarded(base, marker, services, true, async () => {
    const data = load(base, services);
    const zone = scheduleZone(data.config, services);
    const now = services.clock.wall();
    const apply = proposeSetting(data, command, now, zone);
    const keepPause = data.state.scheduleEnabled ? (settleElapsed(data, zone, now), false) : settlePause(data, zone, now);
    apply(data.state);
    bumpScheduleRevision(data.state, keepPause);
    delete data.state.scheduleUndo;
    atomic(base, 'state.json', data.state, services);
    return result(0, 'ready', 'schedule_updated', settingsReport(data.state, effectiveSchedule(data, zone), localDate(localParts(now, zone))));
  });
}

// Daily scheduled probes per account: scheduled reservations whose write fell on the current local
// date, from the durable ledger (only resolved rows older than 30 days are pruned, so a restart or an
// unresolved send cannot reset it).
// Counting by the write rather than the slot keeps a batch that crosses midnight inside the cap.
// Any scheduled reservation for this slot and enrollment blocks a second one, whatever identity its
// key or record names (status reports keys that cannot be parsed).
function slotReserved(state, slot, enrollmentId) {
  return Object.entries(state.reservations).some(([key, record]) => {
    if (key.startsWith('manual:')) return false;
    let tuple;
    try { tuple = JSON.parse(key); } catch { return false; }
    return Array.isArray(tuple) && tuple[0] === slot && (tuple[1] === enrollmentId || record.enrollmentId === enrollmentId);
  });
}
function capReached(state, enrollmentId, zone, now) {
  const cap = state.caps?.[enrollmentId];
  if (!cap) return false;
  const today = localDate(localParts(now, zone));
  let used = 0;
  for (const [key, record] of Object.entries(state.reservations)) {
    if (!validReservationKey(key, record)) return true;  // cannot be classified: fail closed
    if (key.startsWith('manual:') || record.enrollmentId !== enrollmentId) continue;
    if (localDate(localParts(record.at, zone)) === today) used++;
  }
  return used >= cap;
}

// Additive contract the native app checks before enabling any control. Bump `version` only
// for an incompatible change; add a feature name when a new command shape becomes available.
export const UI_CAPABILITY = Object.freeze({ version: 1, features: Object.freeze(['expected_installation_id', 'expected_revision', 'expected_local_date', 'schedule_inspect', 'schedule_weekdays', 'slot_explanation', 'scoped_slot_overlap', 'work_lock_status', 'usage_windows', 'schedule_vacations', 'scheduled_accounts', 'schedule_undo', 'daily_caps']) });
const PROJECTION_DAYS = 7;
const EVIDENCE_RETENTION_MS = 30 * 86400000;
// Read-only projection of the same admissions tick would resolve. Each admission keeps its
// logical slot key; a nonexistent local minute is reported instead of being silently moved.
function projectSchedule(data, schedule, now) {
  const { state } = data;
  const zone = schedule.zone;
  const today = localDate(localParts(now, zone));
  const accounts = scheduledEnrollments(data).map(e => e.enrollmentId);
  const next = state.scheduleEnabled && accounts.length ? nextAdmission(state, schedule, now, accounts.length) : null;
  const days = [];
  for (let offset = 0; offset < PROJECTION_DAYS; offset++) {
    const date = offsetDate(today, offset);
    const resolved = admissionsOnDate(schedule, date);
    const admissions = [];
    for (const [logicalTime, admission] of admissionTimes(schedule, date)) {
      const slot = `${date}T${logicalTime}`;
      const matches = resolved.filter(entry => entry.slot === slot);
      if (!matches.length) { admissions.push({ slot, logicalTime, admission, at: null, state: 'nonexistent_local_time' }); continue; }
      matches.forEach((entry, index) => {
        const ledger = state.slotLedger?.[slot];
        const status = state.slots[slot] ? 'claimed' : ledger ? `not_admitted` : entry.at + 60000 <= now ? 'elapsed' :
          !offeredAdmission(state, slot) ? 'unavailable' : !state.scheduleEnabled ? 'paused' :
          !spacedFromLastClaim(state, entry.at, accounts.length) ? 'spacing_hold' : 'upcoming';
        admissions.push({ slot, logicalTime, admission, at: entry.at, state: status, ...(ledger ? { cause: ledger.cause } : {}),
          ...(matches.length > 1 ? { repeatedLocalTime: index + 1 } : {}), ...(next?.slot === slot && next.at === entry.at ? { next: true } : {}) });
      });
    }
    const resolvable = new Set(admissions.filter(item => item.at !== null).map(item => item.slot)).size;
    days.push({ date, weekday: isoWeekday(date), source: schedule.today?.date === date ? 'edit_date' : 'recurring',
      exclusion: dateExclusion(schedule, date), admissions, attemptsPerAccount: resolvable, configuredAttempts: resolvable * accounts.length });
  }
  return { localDate: today, zone, accounts, days, next: next ? { slot: next.slot, admission: next.admission, date: next.date, at: next.at } : null };
}

function inspectBase(data, schedule) {
  const { state } = data;
  return { scheduleEnabled: state.scheduleEnabled, scheduleRevision: scheduleRevision(state),
    timeZoneMode: data.config.schedule.zone === LOCAL_ZONE ? 'local' : 'fixed',
    weekdays: schedule.weekdays ?? [1, 2, 3, 4, 5, 6, 7], times: [...schedule.times],
    zoneNotice: state.lastTickZone && state.lastTickZone !== schedule.zone ? { previousZone: state.lastTickZone, zone: schedule.zone } : null };
}

// Guidance is chosen from a fixed table keyed by the engine's own safe reason codes.
const GUIDANCE = {
  success: 'none', marker_confirmed: 'none', pilot_required: 'run_manual_pilot', correction_required: 'review_account_block',
  cooldown: 'wait_for_cooldown', compatibility_blocked: 'review_source_compatibility', schedule_disabled: 'resume_schedule_if_intended',
  no_tick_between: 'check_job_and_mac_awake', clock_hold: 'review_clock', zone_changed: 'review_time_zone', manual_run_overlap: 'none',
  schedule_spacing: 'review_schedule_spacing', recovery_skip_through: 'none', batch_deadline_or_clock: 'review_clock',
  batch_unprocessed: 'review_history', reader_global_block: 'review_router_state', credential_expired_or_unknown: 'refresh_router_login',
  already_reserved: 'none', probe_result_untrusted: 'outcome_unknown_no_resend',
  stream_or_transport_uncertain: 'outcome_unknown_no_resend', deadline_exceeded: 'outcome_unknown_no_resend',
  deadline_before_send: 'none', transport_before_send: 'check_network', transport_unavailable: 'check_network',
  redirect_refused: 'review_history', rate_limited: 'wait_for_cooldown', upstream_rejected: 'review_history',
  authentication_rejected: 'refresh_router_login', forbidden_or_challenged: 'review_account_block',
  unsupported_model: 'review_account_block', protocol_failure: 'review_account_block', output_mismatch: 'review_account_block',
  invalid_probe: 'review_history', registry_ineligible: 'review_router_state', login_lease: 'retry_after_router_login',
  primary_untrusted: 'review_router_state', saved_untrusted: 'review_router_state', identity_ambiguous: 'review_router_state',
  identity_mismatch: 'review_router_state', invalid_enrollment: 'review_router_state', invalid_router_account_id: 'review_router_state',
  snapshot_changed: 'none', send_check_failed: 'review_router_state',
};
const guidanceFor = reason => GUIDANCE[reason] ?? 'review_history';

function accountDispatch(row, reservation, active) {
  const unresolved = reservation && reservation.resolved !== true;
  if (row) {
    if (row.dispatched === true) return 'confirmed';
    if (unresolved || row.outcome === 'uncertain' || row.reason === 'probe_result_untrusted') return 'unknown';
    return 'ruled_out';
  }
  if (unresolved) return 'unknown';
  return active ? 'pending' : 'unknown';
}
// The most informative row wins: a confirmed send, then an uncertain one, then the latest row.
// A later skipped row (for example `already_reserved`) must not hide earlier send evidence.
function evidenceRow(rows) {
  return rows.findLast(entry => entry.dispatched === true) ??
    rows.findLast(entry => entry.outcome === 'uncertain' || entry.reason === 'probe_result_untrusted') ?? rows.at(-1) ?? null;
}
function accountGuidance(reason, dispatch) {
  const guidance = guidanceFor(reason);
  return guidance === 'check_network' && dispatch !== 'ruled_out' ? 'outcome_unknown_no_resend' : guidance;
}
function accountResponse(row) {
  if (!row || row.skipped === true || row.dispatched !== true && row.outcome !== 'uncertain') return 'unobserved';
  if (row.outcome === 'success' && row.reason === 'marker_confirmed') return 'confirmed';
  return row.outcome === 'uncertain' ? 'uncertain' : 'failed';
}

// Explains one logical slot from recorded evidence only. Silence stays "unknown"/"unobserved";
// nothing here infers sleep, zero requests or a provider usage-window effect.
function slotExplanation(data, schedule, slot, now) {
  const { state, config } = data;
  const date = slot.slice(0, 10), time = slot.slice(11);
  const today = localDate(localParts(now, schedule.zone));
  const resolved = admissionsOnDate(schedule, date).filter(entry => entry.slot === slot);
  const configuredTimes = admissionTimes(schedule, date).filter(([logical]) => logical === time);
  // History and ledger rows are pruned after 30 days, so older silence is not evidence.
  const beyondRetention = date < localDate(localParts(now - EVIDENCE_RETENTION_MS, schedule.zone));
  const pastUnknown = beyondRetention || date < (schedule.today?.date ?? today) && !configuredTimes.length;
  const claim = state.slots[slot] ?? null;
  const ledger = state.slotLedger?.[slot] ?? null;
  const active = state.activeBatch?.slot === slot;
  const last = state.lastSlotOutcome?.slot === slot ? state.lastSlotOutcome : null;
  const rows = state.history.filter(entry => entry.slot === slot && entry.mode === 'scheduled');
  const reservations = new Map();
  for (const [key, record] of Object.entries(state.reservations)) {
    if (key.startsWith('manual:')) continue;
    try { const parsed = JSON.parse(key); if (Array.isArray(parsed) && parsed[0] === slot) reservations.set(record.enrollmentId, record); } catch { /* malformed keys are reported by status */ }
  }
  const ids = [...new Set([...(claim?.enrollmentIds ?? []), ...rows.map(entry => entry.enrollmentId), ...reservations.keys()])];
  const accounts = ids.map(enrollmentId => {
    const row = evidenceRow(rows.filter(entry => entry.enrollmentId === enrollmentId));
    const reservation = reservations.get(enrollmentId) ?? null;
    const reason = row && /^[a-z_]{1,64}$/.test(row.reason) ? row.reason : null;
    const dispatch = accountDispatch(row, reservation, active);
    const reservationUnresolved = Boolean(reservation && reservation.resolved !== true);
    return { enrollmentId, known: config.enrollments.some(e => e.enrollmentId === enrollmentId),
      outcome: row && /^[a-z_]{1,64}$/.test(row.outcome) ? row.outcome : null, reason, at: Number.isFinite(row?.at) ? row.at : null,
      skipped: row?.skipped === true, possibleSend: dispatch !== 'ruled_out' && (reservationUnresolved || dispatch === 'confirmed' || Boolean(reservation)),
      reservationUnresolved, dispatch, response: accountResponse(row), windowEffect: 'unverified',
      guidance: row ? accountGuidance(reason, dispatch) : reservation ? 'review_unresolved_reservation' : active ? 'none' : 'review_history' };
  });
  const firstAt = resolved[0]?.at ?? null;
  const verdict = claim ? (active ? 'in_progress' : 'admitted') : ledger ? 'not_admitted' :
    pastUnknown ? 'unknown' : !configuredTimes.length ? (dateExclusion(schedule, date) ? 'excluded' : 'not_configured') :
    firstAt === null ? 'nonexistent_local_time' : firstAt + 60000 > now ? 'scheduled' : 'unobserved';
  const heartbeat = { lastTick: state.lastTick, lastTickZone: state.lastTickZone ?? null,
    observedAfterAdmission: firstAt === null || !Number.isFinite(state.lastTick) ? null : state.lastTick >= firstAt + 60000 };
  return { slot, date, logicalTime: time, verdict, configured: pastUnknown ? null : configuredTimes.length > 0,
    exclusion: pastUnknown ? null : dateExclusion(schedule, date), admission: configuredTimes[0]?.[1] ?? (validTime(claim?.admission) ? claim.admission : null) ?? ledger?.admission ?? null,
    admissionAt: firstAt, claim: claim ? { claimedAt: claim.claimedAt, enrollmentIds: [...claim.enrollmentIds], zone: claim.zone ?? null } : null,
    notAdmitted: ledger ? { cause: ledger.cause, zone: ledger.zone, at: ledger.at, guidance: guidanceFor(ledger.cause) } : null,
    activeBatch: active, batchOutcome: last && /^[a-z_]{1,64}$/.test(last.outcome) ? last.outcome : null, batchFinishedAt: last?.at ?? null,
    accounts, heartbeat, windowEffect: 'unverified', retentionDays: EVIDENCE_RETENTION_MS / 86400000 };
}

function inspectSchedule(data, command, services) {
  const now = services.clock.wall();
  const zone = scheduleZone(data.config, services);
  const schedule = effectiveSchedule(data, zone);
  if (command.slot) {
    if (!validSlot(command.slot)) throwCode('invalid_slot');
    return result(0, 'ready', 'slot_explanation', { ...inspectBase(data, schedule), zone, explanation: slotExplanation(data, schedule, command.slot, now) });
  }
  const current = projectSchedule(data, schedule, now);
  if (!command.proposal) return result(0, 'ready', 'schedule_projection', { ...inspectBase(data, schedule), ...current });
  const { date, edits } = proposeEdit(data, command.proposal, now, zone);
  const proposedData = { ...data, state: { ...data.state, scheduleEdits: edits } };
  const proposedSchedule = effectiveSchedule(proposedData, zone);
  return result(0, 'ready', 'schedule_projection', { ...inspectBase(data, schedule), ...current,
    proposal: { ...command.proposal, localDate: date, expectedRevision: scheduleRevision(data.state), ...inspectBase(proposedData, proposedSchedule), ...projectSchedule(proposedData, proposedSchedule, now) } });
}

function savePause(base, data, services) {
  const { state } = data;
  const wasEnabled = state.scheduleEnabled;
  setScheduleEnabled(state, false);
  if (wasEnabled) {
    try { state.schedulePause = { at: services.clock.wall(), zone: scheduleZone(data.config, services), revision: scheduleRevision(state) }; }
    catch { delete state.schedulePause; }
  }
  storeState(base, state, services);
}

async function schedule(base, data, { action, expectedRevision, now }, context, services) {
  const releaseLife = lock(base, 'lifecycle', data.marker, services);
  try {
    data = load(base, services);
    checkScheduleRevision(data.state, expectedRevision);
    const binding = jobBinding(base, data, context);
    const observed = await services.jobs.inspect(binding);
    if (!['loaded', 'absent'].includes(observed)) throwCode('job_ownership_unknown');
    if (action === 'disable') {
      unchanged(base, services);
      if (!now) {
        const batch = data.state.activeBatch;
        const claimedAt = batch && data.state.slots[batch.slot]?.claimedAt;
        const remaining = Number.isFinite(claimedAt) ? claimedAt + scheduledBatchMs(batch.enrollmentIds.length) - services.clock.wall() : 0;
        const until = performance.now() + Math.min(240000, Math.max(0, remaining));
        let releaseWork;
        while (!releaseWork) {
          try { releaseWork = lock(base, 'work', data.marker, services); }
          catch (error) {
            if (!error?.[SAFE_REASON] || error.reason !== 'lock_busy') throw error;
            try { recoverDeadLock(base, 'work', data.marker, services); }
            catch (ownerError) {
              if (!ownerError?.[SAFE_REASON] || ownerError.reason !== 'lock_owner_not_proven_dead' || ownerError.ownerStatus !== 'alive') throw ownerError;
              const waitMs = until - performance.now();
              if (waitMs <= 0) return fail(batch ? 'pause_waiting_for_batch' : 'lock_busy', 3, { disableCompleted: false });
              await delay(Math.min(50, waitMs));
            }
          }
        }
        try {
          data = load(base, services);
          checkScheduleRevision(data.state, expectedRevision);
          savePause(base, data, services);
        } finally { releaseWork(); }
        unchanged(base, services);
        if (observed === 'loaded') await services.jobs.disable(binding);
        if (await services.jobs.inspect(binding) !== 'absent' || await services.jobs.runner(binding)) throwCode('disable_incomplete');
        return result(0, 'ready', 'schedule_disabled', { scheduleEnabled: false, scheduleRevision: scheduleRevision(data.state), job: 'absent' });
      }
      const runner = await services.jobs.runner(binding);
      if (runner && (!runner.scheduled || runner.installationId !== data.marker.installationId || services.processes.inspect(runner) !== 'alive')) throwCode('runner_ownership_unknown');
      if (observed === 'loaded') await services.jobs.disable(binding);
      if (runner) {
        if (!await services.processes.wait(runner, 50000)) {
          if (services.processes.inspect(runner) !== 'alive') throwCode('runner_ownership_unknown');
          await services.processes.terminate(runner);
          if (!await services.processes.wait(runner, 5000)) throwCode('runner_still_active');
        }
      }
      try { recoverDeadLock(base, 'work', data.marker, services); }
      catch (error) {
        if (error?.[SAFE_REASON] && error.reason === 'lock_owner_not_proven_dead') {
          return fail(error.ownerStatus === 'alive' ? 'lock_busy' : error.reason, error.ownerStatus === 'alive' ? 3 : 2, { disableCompleted: false });
        }
        throw error;
      }
      const releaseWork = lock(base, 'work', data.marker, services);
      try {
        data = load(base, services);
        checkScheduleRevision(data.state, expectedRevision);
        savePause(base, data, services);
        if (await services.jobs.inspect(binding) !== 'absent' || await services.jobs.runner(binding) || load(base, services).state.scheduleEnabled) throwCode('disable_incomplete');
      } finally { releaseWork(); }
      return result(0, 'ready', 'schedule_disabled', { scheduleEnabled: false, scheduleRevision: scheduleRevision(data.state), job: 'absent', forced: true });
    }
    if (action !== 'enable') throwCode('invalid_schedule_action');
    const releaseWork = lock(base, 'work', data.marker, services);
    try {
      data = load(base, services);
      checkScheduleRevision(data.state, expectedRevision);
      if ((await adapter(services, 'checkCompatibility', checkCompatibility)(contextFor(data), services))?.kind !== 'ready') throwCode('compatibility_blocked');
      if (!data.config.enrollments.some(e => e.enabled && data.state.pilots[pilotKey(e, data.compatibility, data.config)])) throwCode('pilot_required');
      unchanged(base, services);
      const previouslyEnabled = data.state.scheduleEnabled;
      const previousPause = data.state.schedulePause;
      const pauseRevisionMatches = previousPause?.revision === scheduleRevision(data.state);
      const zone = scheduleZone(data.config, services);
      let enableAttempted = false;
      try {
        if (observed === 'absent') { enableAttempted = true; await services.jobs.enable(binding); }
        if (await services.jobs.inspect(binding) !== 'loaded') throwCode('enable_incomplete');
        const enabledAt = services.clock.wall();
        if (!previouslyEnabled && previousPause) dropOpenPauseRows(data.state, enabledAt, previousPause.at);
        // Slots that closed before a paused edit were settled by it under the schedule they had (settlePause).
        const settledBefore = Number.isFinite(data.state.settledAt) ? data.state.settledAt : -Infinity;
        if (previousPause?.zone === zone && pauseRevisionMatches && enabledAt >= previousPause.at) {
          const evidence = { previousTick: data.state.lastTick, tick: enabledAt, previousZone: zone, pauseStartedAt: previousPause.at };
          recordMissedRange(data.state, effectiveSchedule(data, zone), localLabel(previousPause.at, zone).slice(0, 10),
            localLabel(enabledAt, zone).slice(0, 10), 'schedule_disabled', evidence,
            due => due.at >= previousPause.at && due.at + 60000 > settledBefore && due.at + 60000 <= enabledAt);
        }
        delete data.state.schedulePause;
        setScheduleEnabled(data.state, true);
        storeState(base, data.state, services);
        if (await services.jobs.inspect(binding) !== 'loaded' || !load(base, services).state.scheduleEnabled) throwCode('enable_incomplete');
      } catch (error) {
        let absent = false, incomplete = false;
        try {
          if (enableAttempted && await services.jobs.inspect(binding) === 'loaded') await services.jobs.disable(binding);
          const job = await services.jobs.inspect(binding);
          absent = job === 'absent' && !await services.jobs.runner(binding);
          if (!['loaded', 'absent'].includes(job) || enableAttempted && !absent) incomplete = true;
        } catch { incomplete = true; }
        try {
          setScheduleEnabled(data.state, previouslyEnabled && !enableAttempted && !absent);
          if (!data.state.scheduleEnabled && previousPause) data.state.schedulePause = pauseRevisionMatches ? { ...previousPause, revision: scheduleRevision(data.state) } : previousPause;
          storeState(base, data.state, services);
        } catch { incomplete = true; }
        if (incomplete) throwCode('enable_rollback_incomplete');
        throw error;
      }
      return result(0, 'ready', 'schedule_enabled', { scheduleEnabled: true, scheduleRevision: scheduleRevision(data.state), job: 'loaded' });
    } finally { releaseWork(); }
  } finally { releaseLife(); }
}

async function validateMaintenanceCandidate(base, marker, baseline, candidate, services) {
  if (!exact(candidate, ['schemaVersion', 'config', 'compatibility', 'reviewEvidence']) || candidate.schemaVersion !== 1 || typeof candidate.reviewEvidence !== 'string' || !candidate.reviewEvidence || !plain(candidate.config) || !plain(candidate.compatibility)) throwCode('invalid_candidate');
  validateConfig(candidate.config, marker);
  validateIsolation(base, candidate.config.paths, marker.plistPath, services);
  validateCompatibility(candidate.compatibility);
  if (baseline.config.schedule.zone === LOCAL_ZONE && candidate.config.schedule.zone !== LOCAL_ZONE) throwCode('zone_policy_immutable');
  if (baseline.config.schedule.zone !== candidate.config.schedule.zone && JSON.stringify(baseline.config.schedule.advance13) !== JSON.stringify(candidate.config.schedule.advance13)) throwCode('migration_schedule_conflict');
  if (baseline.config.schedule.advance13 && JSON.stringify(candidate.config.schedule.advance13) !== JSON.stringify(baseline.config.schedule.advance13)) throwCode('advance_immutable');
  if (JSON.stringify(candidate.config.schedule) !== JSON.stringify(baseline.config.schedule) && candidate.reviewEvidence === baseline.compatibility.reviewEvidence) throwCode('new_review_required');
  if (candidate.config.enrollments.length !== baseline.config.enrollments.length || candidate.config.enrollments.some((e, i) => e.enrollmentId !== baseline.config.enrollments[i].enrollmentId || e.routerAccountId !== baseline.config.enrollments[i].routerAccountId || JSON.stringify(e.identity) !== JSON.stringify(baseline.config.enrollments[i].identity))) throwCode('enrollment_change_forbidden');
  if (candidate.compatibility.reviewEvidence !== candidate.reviewEvidence || candidate.compatibility.semantics !== 'equivalent' && candidate.compatibility.semantics !== 'changed') throwCode('review_missing');
  if ((JSON.stringify(candidate.config.paths) !== JSON.stringify(baseline.config.paths) || JSON.stringify(candidate.compatibility.sourceDigests) !== JSON.stringify(baseline.compatibility.sourceDigests) || candidate.compatibility.reviewedRevision !== baseline.compatibility.reviewedRevision || candidate.compatibility.sourcePathContract !== baseline.compatibility.sourcePathContract) && candidate.reviewEvidence === baseline.compatibility.reviewEvidence) throwCode('new_review_required');
  if (candidate.compatibility.semantics === 'changed' && candidate.compatibility.adapterVersion <= baseline.compatibility.adapterVersion && candidate.compatibility.requestContractVersion <= baseline.compatibility.requestContractVersion) throwCode('contract_version_required');
  if (candidate.compatibility.adapterVersion < baseline.compatibility.adapterVersion || candidate.compatibility.requestContractVersion < baseline.compatibility.requestContractVersion) throwCode('contract_version_rollback');
  if (candidate.config.requestContractVersion !== baseline.config.requestContractVersion) throwCode('request_contract_change_forbidden');
  if ((await adapter(services, 'checkCompatibility', checkCompatibility)({ paths: candidate.config.paths, compatibility: candidate.compatibility }, services))?.kind !== 'ready') throwCode('candidate_source_unreviewed');
}

async function maintain(base, data, file, context, services) {
  return guarded(base, data.marker, services, true, async () => {
    data = load(base, services);
    if (data.state.scheduleEnabled) throwCode('schedule_must_be_disabled');
    const binding = jobBinding(base, data, context);
    if (await services.jobs.inspect(binding) !== 'absent' || await services.jobs.runner(binding)) throwCode('job_must_be_absent');
    const candidate = safeRead(file, services, { root: path.dirname(file), limit: MAX_FILE }).value;
    await validateMaintenanceCandidate(base, data.marker, data, candidate, services);
    const zone = scheduleZone(candidate.config, services);
    if (!data.config.schedule.advance13 && candidate.config.schedule.advance13) {
      if (data.state.scheduleEdits) throwCode('schedule_already_edited');
      const a = candidate.config.schedule.advance13, now = services.clock.wall(), p = localParts(now, zone);
      const lead = (Number(a.time.slice(0, 2)) - Number(p.hour)) * 60 + Number(a.time.slice(3)) - Number(p.minute);
      if (minutes(a.time) - minutes('08:00') < minimumSpacingMs(candidate.config.enrollments.filter(e => e.enabled).length) / 60000) throwCode('schedule_spacing');
      if (a.date !== localDate(p) || lead < 3 || data.state.lastWall !== null && now + 1000 < data.state.lastWall) throwCode('advance_not_future');
      const slot = `${a.date}T13:00`, state = data.state;
      if (state.slots[slot] || state.highWater && slot <= state.highWater || state.skipThrough && slot <= state.skipThrough || state.activeBatch || state.lastSlotOutcome?.slot >= slot) throwCode('advance_slot_unavailable');
    }
    for (const [i, next] of candidate.config.enrollments.entries()) {
      const old = data.config.enrollments[i];
      if (next.model !== old.model || candidate.compatibility.semantics === 'changed') for (const key of Object.keys(data.state.pilots)) if (key.startsWith(`[${JSON.stringify(old.enrollmentId)},`)) delete data.state.pilots[key];
    }
    data.state.scheduleEnabled = false;
    storeState(base, data.state, services);
    const configDigest = atomic(base, 'config.json', candidate.config, services);
    const compatibilityDigest = atomic(base, 'compatibility.json', candidate.compatibility, services);
    data.state.configDigest = configDigest;
    data.state.compatibilityDigest = compatibilityDigest;
    if (data.config.schedule.zone !== candidate.config.schedule.zone) data.state.lastTickZone = LEGACY_ZONE;
    if (JSON.stringify(data.config.schedule) !== JSON.stringify(candidate.config.schedule)) bumpScheduleRevision(data.state);
    storeState(base, data.state, services);
    load(base, services);
    if (await services.jobs.inspect(binding) !== 'absent') throwCode('job_must_be_absent');
    return result(0, 'ready', 'maintenance_applied', { scheduleEnabled: false });
  });
}

async function setup(base, context, services) {
  const marker = read(base, 'instance.json', services, MAX_FILE).value;
  validateMarker(marker);
  return guarded(base, marker, services, true, async () => {
    if (marker.phase === 'complete') { load(base, services); return result(0, 'ready', 'already_initialized'); }
    if (marker.phase !== 'uninitialized') throwCode('incomplete_initialization');
    for (const name of ['config.json', 'state.json']) if (read(base, name, services, MAX_STATE, true) !== null) throwCode('existing_state');
    const compatibility = read(base, 'compatibility.json', services, MAX_FILE).value;
    if (!compatibility) throwCode('missing_compatibility');
    validateCompatibility(compatibility);
    const job = jobBinding(base, { marker }, context);
    if (await services.jobs.inspect(job) !== 'absent' || await services.jobs.runner(job)) throwCode('existing_job_or_plist');
    try { services.files.lstatSync(marker.plistPath); throwCode('existing_job_or_plist'); }
    catch (error) { if (error?.code !== 'ENOENT') throw error; }
    const config = { schemaVersion: 1, installationId: marker.installationId, paths: marker.paths, schedule: { zone: LOCAL_ZONE, times: TIMES }, enrollments: [], requestContractVersion: 1 };
    const partial = { ...marker, phase: 'in_progress' };
    atomic(base, 'instance.json', partial, services);
    const registry = await adapter(services, 'readRegistry', readRegistry)({ paths: marker.paths, compatibility }, services);
    if (registry?.kind !== 'ready' || !Array.isArray(registry.accounts) || registry.coordination !== 'idle') throwCode('registry_blocked');
    const excluded = [];
    for (const account of registry.accounts) {
      if (typeof account.routerAccountId !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(account.routerAccountId)) throwCode('registry_blocked');
      if (!account.eligible) { excluded.push({ routerAccountId: account.routerAccountId, reason: 'registry_ineligible' }); continue; }
      const identity = await adapter(services, 'discoverIdentity', discoverIdentity)({ paths: marker.paths, compatibility }, account.routerAccountId, services);
      if (identity?.kind !== 'ready' && identity?.scope !== 'account') throwCode('identity_global_block');
      if (identity?.kind === 'ready' && identity.identity?.accountId && identity.identity?.userId) {
        if (config.enrollments.some(e => JSON.stringify(e.identity) === JSON.stringify(identity.identity))) throwCode('duplicate_identity');
        config.enrollments.push({ enrollmentId: `enr_${crypto.randomUUID()}`, routerAccountId: account.routerAccountId, identity: identity.identity, model: 'gpt-6-luna', enabled: true });
      } else if (identity?.kind === 'ready') throwCode('identity_global_block');
      else excluded.push({ routerAccountId: account.routerAccountId, reason: readerReason(identity?.reason) });
    }
    validateConfig(config, marker);
    const configDigest = atomic(base, 'config.json', config, services);
    const compatibilityDigest = read(base, 'compatibility.json', services, MAX_FILE).stamp.sha256;
    const state = { schemaVersion: 1, installationId: marker.installationId, scheduleEnabled: false, removalPending: false, configDigest, compatibilityDigest, pilots: {}, cooldowns: {}, blocks: {}, slots: {}, reservations: {}, highWater: null, lastWall: null, lastTick: null, activeBatch: null, lastSlotOutcome: null, history: [], skipThrough: null };
    storeState(base, state, services);
    atomic(base, 'instance.json', { ...marker, phase: 'complete' }, services);
    return result(0, 'ready', 'initialized', { enrolled: config.enrollments.length, excluded });
  });
}

async function enroll(base, data, id, services) {
  if (!id) throwCode('missing_account');
  return guarded(base, data.marker, services, false, async () => {
    data = load(base, services);
    const ctx = contextFor(data);
    const registry = await adapter(services, 'readRegistry', readRegistry)(ctx, services);
    const account = registry.accounts?.find(a => a.routerAccountId === id);
    if (registry?.kind !== 'ready' || !account?.eligible) throwCode('account_ineligible');
    const found = await adapter(services, 'discoverIdentity', discoverIdentity)(ctx, id, services);
    if (found?.kind !== 'ready' || !found.identity?.accountId || !found.identity?.userId) throwCode('identity_blocked');
    if (data.config.enrollments.some(e => e.routerAccountId !== id && JSON.stringify(e.identity) === JSON.stringify(found.identity))) throwCode('duplicate_identity');
    const existing = data.config.enrollments.find(e => e.routerAccountId === id);
    if (existing) {
      if (JSON.stringify(existing.identity) !== JSON.stringify(found.identity)) throwCode('identity_changed');
      return result(0, 'ready', 'already_enrolled', { enrollmentId: existing.enrollmentId });
    }
    const e = { enrollmentId: `enr_${crypto.randomUUID()}`, routerAccountId: id, identity: found.identity, model: 'gpt-6-luna', enabled: true };
    data.config.enrollments.push(e);
    const digest = atomic(base, 'config.json', data.config, services);
    data.state.configDigest = digest;
    storeState(base, data.state, services);
    return result(0, 'ready', 'enrolled', { enrollmentId: e.enrollmentId });
  });
}

async function run(base, data, command, services, scheduled = false, slot = null, deadline = null, clockOrigin = null) {
  let manualWindow;
  const perform = async () => {
    data = load(base, services);
    const current = scheduled && command.batch ? data.config.enrollments.filter(e => e.enabled && command.batch.includes(e.enrollmentId))
      : command.account ? data.config.enrollments.filter(e => e.enrollmentId === command.account && e.enabled) : data.config.enrollments.filter(e => e.enabled);
    const out = { selected: current.length, attempted: 0, results: [] };
    const zone = clockOrigin?.zone ?? scheduleZone(data.config, services);
    const clockUnsafe = () => scheduled && (services.clock.mono() >= deadline || scheduleZone(data.config, services) !== zone || Math.abs((services.clock.wall() - clockOrigin.wall) - (services.clock.mono() - clockOrigin.mono)) > 1000);
    if (command.account && !current.length) return fail('unknown_enrollment', 2, out);
    if (JSON.stringify(out).length + current.length * 1024 > MAX_FILE) return fail('output_capacity', 2, out);
    if (!scheduled && data.state.scheduleEnabled && current.length && scheduledEnrollments(data).length) {
      const startedAt = services.clock.wall();
      const schedule = effectiveSchedule(data, zone);
      const next = nextAdmission(data.state, schedule, startedAt, scheduledEnrollments(data).length);
      // A scoped override names the exact admission instant it accepts (`--overlap-at`, from the
      // refusal). A moved admission or the other fall-back occurrence has another instant, so the
      // run is refused again if anything changed after the operator confirmed.
      const overrideApplies = command.allowSlotOverlap && (command.overlapAt === undefined || command.overlapAt === next?.at);
      if (!overrideApplies && next && next.at <= startedAt + current.length * 45000 + 60000) {
        return fail('slot_overlap_risk', 3, { ...out, overlap: { slot: next.slot, admission: next.admission, date: next.date, at: next.at } });
      }
      manualWindow = { startedAt, zone, schedule };
    }
    const record = (entry, enrollment, skipped = false, reason = entry.reason, reservation) => {
      if (reservation && entry.outcome !== 'uncertain' && entry.reason !== 'probe_result_untrusted') data.state.reservations[reservation].resolved = true;
      out.results.push(skipped ? { ...entry, skipped: true } : entry);
      data.state.history.push({
        ...entry, mode: scheduled ? 'scheduled' : 'manual', model: enrollment.model, zone, ...(slot ? { slot } : {}),
        ...(skipped ? { skipped: true, reason, dispatched: false, at: services.clock.wall() } : {}),
      });
      storeState(base, data.state, services);
    };
    const recordUnprocessed = (reason = 'batch_unprocessed') => {
      for (const e of current.slice(out.results.length)) {
        record({ enrollmentId: e.enrollmentId, outcome: 'blocked', reason: 'batch_unprocessed' }, e, true, reason);
      }
    };
    const stopBatch = reason => {
      recordUnprocessed(reason);
      return fail(reason, 2, out);
    };
    try {
    const ctx = contextFor(data);
    const compat = await adapter(services, 'checkCompatibility', checkCompatibility)(ctx, services);
    if (compat?.kind !== 'ready') return scheduled ? stopBatch('compatibility_blocked') : fail('compatibility_blocked', 2, out);
    if (!current.length) return { exitCode: 4, outcome: 'no_work', reason: 'no_enabled_enrollments', ...out };
    for (const e of current) {
      const key = pilotKey(e, data.compatibility, data.config);
      let entry = { enrollmentId: e.enrollmentId, outcome: 'blocked', reason: 'unknown' };
      if (clockUnsafe()) { entry.reason = 'batch_deadline_or_clock'; record(entry, e, true); break; }
      if (scheduled && !data.state.pilots[key]) entry.reason = 'pilot_required';
      else if (scheduled && data.state.blocks[e.enrollmentId]) entry.reason = 'correction_required';
      else if (scheduled && capReached(data.state, e.enrollmentId, zone, services.clock.wall())) entry.reason = 'daily_cap_reached';
      else if (data.state.cooldowns[e.enrollmentId] && data.state.cooldowns[e.enrollmentId] > services.clock.wall()) entry.reason = 'cooldown';
      else {
        load(base, services);
        const credential = await adapter(services, 'readCredential', readCredential)(ctx, e, services);
        if (credential?.kind !== 'ready') {
          if (credential?.scope === 'global') return stopBatch('reader_global_block');
          entry.reason = readerReason(credential?.reason);
        }
        else {
          load(base, services);
          const rev = await adapter(services, 'revalidate', revalidate)(ctx, e, credential.snapshot, services);
          if (rev?.kind !== 'ready') {
            if (rev?.scope === 'global') return stopBatch('reader_global_block');
            entry.reason = readerReason(rev?.reason);
          }
          else {
            if (clockUnsafe()) { entry.reason = 'batch_deadline_or_clock'; record(entry, e, true); break; }
            if (Buffer.byteLength(JSON.stringify(data.state)) + 4096 > MAX_STATE) throwCode('state_capacity');
            const reservation = scheduled ? JSON.stringify([slot, e.enrollmentId, e.identity.accountId, e.identity.userId]) : `manual:${crypto.randomUUID()}`;
            if (scheduled && slotReserved(data.state, slot, e.enrollmentId)) { entry.reason = 'already_reserved'; record(entry, e, true); continue; }
            // One instant for the final cap check and the write, so a midnight between them cannot split the day.
            const reservedAt = services.clock.wall();
            if (scheduled && capReached(data.state, e.enrollmentId, zone, reservedAt)) { entry.reason = 'daily_cap_reached'; record(entry, e, true); continue; }
            const reservationId = `res_${crypto.randomUUID()}`;
            entry.reservationId = reservationId;
            data.state.reservations[reservation] = { enrollmentId: e.enrollmentId, identity: e.identity, at: reservedAt, possibleSend: true, reservationId };
            storeState(base, data.state, services);
            unchanged(base, services);
            load(base, services);
            const final = await adapter(services, 'revalidate', revalidate)(ctx, e, credential.snapshot, services);
            if (final?.kind !== 'ready') {
              if (final?.scope === 'global') {
                entry.reason = 'reader_global_block';
                record(entry, e, true, entry.reason, reservation);
                return stopBatch('reader_global_block');
              }
              entry.reason = readerReason(final?.reason); record(entry, e, true, entry.reason, reservation); continue;
            }
            if (clockUnsafe()) { entry.reason = 'batch_deadline_or_clock'; record(entry, e, true, entry.reason, reservation); break; }
            unchanged(base, services);
            load(base, services);
            if (clockUnsafe()) { entry.reason = 'batch_deadline_or_clock'; record(entry, e, true, entry.reason, reservation); break; }
            const dispatchWall = services.clock.wall();
            if (!Number.isFinite(dispatchWall) || !Number.isFinite(credential.expiresAt) || credential.expiresAt - dispatchWall < 120000) { entry.reason = 'credential_expired_or_unknown'; record(entry, e, true, entry.reason, reservation); continue; }
            // Rechecked at the send boundary (after DNS/TLS); the cause is carried out for the batch decision.
            let sendCheck = null;
            const finalCheck = () => {
              const check = adapter(services, 'revalidate', revalidate)(ctx, e, credential.snapshot, services);
              if (typeof check?.then === 'function') { check.catch(() => {}); sendCheck = 'reader'; return false; }  // fail closed
              if (check?.kind !== 'ready') { sendCheck = check?.scope === 'global' ? 'global' : 'reader'; return false; }
              if (clockUnsafe()) { sendCheck = 'clock'; return false; }
              return true;
            };
            const p = await adapter(services, 'probe', services.probe ?? probe)({ credential, model: e.model, ...(scheduled ? { batchDeadline: deadline } : {}), finalCheck }, services);
            if (p?.dispatched === true) out.attempted++;
            const trusted = ['success', 'blocked', 'uncertain'].includes(p?.outcome) && probeReasons.has(p?.reason) && (p.outcome !== 'success' || p.reason === 'marker_confirmed' && p.dispatched === true);
            if (trusted && p.reason === 'send_check_failed' && p.dispatched !== true) {
              if (sendCheck === 'global') { entry.reason = 'reader_global_block'; record(entry, e, true, entry.reason, reservation); return stopBatch('reader_global_block'); }
              if (sendCheck === 'clock') { entry.reason = 'batch_deadline_or_clock'; record(entry, e, true, entry.reason, reservation); break; }
            }
            entry = { enrollmentId: e.enrollmentId, reservationId, outcome: trusted ? p.outcome : p?.dispatched === true ? 'uncertain' : 'blocked', reason: trusted ? p.reason : 'probe_result_untrusted', dispatched: p?.dispatched === true, at: services.clock.wall() };
            const transportCode = trusted && entry.reason === 'transport_before_send' && !entry.dispatched ? safeTransportCode(p.transportCode) : undefined;
            if (transportCode) entry.transportCode = transportCode;
            if (confirmed(entry) && validFirstTextMs(p.firstTextMs)) entry.firstTextMs = p.firstTextMs;
            const usage = trusted && entry.dispatched ? cleanUsage(p.usage) : null;
            if (usage) entry.usage = { ...usage, observedAt: entry.at };
            if (entry.outcome === 'success') { if (!scheduled) data.state.pilots[key] = { at: entry.at }; delete data.state.blocks[e.enrollmentId]; }
            else if (['authentication_rejected', 'forbidden_or_challenged', 'unsupported_model', 'protocol_failure', 'output_mismatch'].includes(entry.reason)) {
              data.state.blocks[e.enrollmentId] = entry.reason;
              if (['unsupported_model', 'protocol_failure', 'output_mismatch'].includes(entry.reason)) for (const k of Object.keys(data.state.pilots)) if (k.startsWith(`[${JSON.stringify(e.enrollmentId)},`)) delete data.state.pilots[k];
            }
            if (trusted && Number.isFinite(p.notBefore) && p.notBefore > services.clock.wall()) data.state.cooldowns[e.enrollmentId] = p.notBefore;
            record(entry, e, false, entry.reason, reservation);
            if (scheduled && (services.clock.mono() >= deadline ||
                entry.reason === 'deadline_exceeded' || entry.reason === 'deadline_before_send')) break;
            continue;
          }
        }
      }
      record(entry, e, true);
      if (scheduled && services.clock.mono() >= deadline) break;
    }
    recordUnprocessed();
    return { exitCode: out.results.every(e => e.outcome === 'success') ? 0 : 1, outcome: out.results.every(e => e.outcome === 'success') ? 'success' : 'partial', reason: 'run_complete', ...out };
    } catch (error) {
      while (out.results.length < current.length) out.results.push({ enrollmentId: current[out.results.length].enrollmentId, outcome: 'blocked', reason: 'batch_unprocessed' });
      return fail(error?.[SAFE_REASON] ? error.reason : 'internal_error', 2, out);
    }
  };
  if (scheduled) return perform();
  return guarded(base, data.marker, services, false, async () => {
    const out = await perform();
    if (!manualWindow) return out;
    try {
      const { state } = load(base, services);
      const { startedAt, zone, schedule } = manualWindow;
      const endedAt = services.clock.wall();
      if (endedAt < startedAt || scheduleZone(data.config, services) !== zone) return out;
      state.lastManual = { startedAt, endedAt, zone };
      const date = localDate(localParts(startedAt, zone));
      const lastDate = localDate(localParts(endedAt, zone));
      const evidence = { previousTick: state.lastTick, tick: endedAt, previousZone: state.lastTickZone ?? null,
        manualStartedAt: startedAt, manualEndedAt: endedAt };
      if (endedAt - startedAt >= 60000 && endedAt - startedAt < 86400000) {
        for (const day of new Set([date, lastDate])) {
          for (const due of admissionsOnDate(schedule, day)) {
            if (due.at >= startedAt && due.at + 60000 <= endedAt && offeredAdmission(state, due.slot)) {
              recordSlotMiss(state, due, 'manual_run_overlap', zone, evidence);
            }
          }
        }
      }
      storeState(base, state, services);
      return out;
    } catch {
      return { ...out, exitCode: 2, outcome: 'blocked', reason: 'manual_finalization_failed' };
    }
  });
}

// Re-validates the probe's usage evidence before it is stored: two known windows, bounded numbers.
function cleanUsage(usage) {
  if (!plain(usage)) return null;
  const out = {};
  for (const window of ['primary', 'secondary']) {
    const row = usage[window];
    if (!plain(row)) continue;
    const clean = {};
    if (Number.isFinite(row.usedPercent) && row.usedPercent >= 0 && row.usedPercent <= 100) clean.usedPercent = row.usedPercent;
    if (Number.isSafeInteger(row.windowMinutes) && row.windowMinutes > 0 && row.windowMinutes <= 527040) clean.windowMinutes = row.windowMinutes;
    if (Number.isSafeInteger(row.resetsAt) && row.resetsAt > 0) clean.resetsAt = row.resetsAt;
    if (Object.keys(clean).length) out[window] = clean;
  }
  return Object.keys(out).length ? out : null;
}

// The latest usage observation per enrolled account, newest first, in one pass over history. At
// most MAX_USAGE_ACCOUNTS are reported so status stays far below its output limit.
export const MAX_USAGE_ACCOUNTS = 64;
export function latestUsage(state, enrolled) {
  const found = new Map();
  let truncated = false;
  for (let i = state.history.length - 1; i >= 0; i--) {
    const row = state.history[i];
    if (!plain(row) || row.skipped === true || !plain(row.usage) || !enrolled.has(row.enrollmentId) || found.has(row.enrollmentId)) continue;
    const usage = cleanUsage(row.usage);
    if (!usage || !Number.isFinite(row.usage.observedAt)) continue;
    if (found.size >= MAX_USAGE_ACCOUNTS) { truncated = true; break; }
    found.set(row.enrollmentId, { ...usage, observedAt: row.usage.observedAt });
  }
  return { found, truncated };
}

// Rows that only report an elapsed slot; a zone-change hold for the same key replaces them, so the
// hold that keeps the new zone's matching minute from running can never be pre-empted by a report.
const SETTLED_CAUSES = new Set(['no_tick_between', 'no_scheduled_accounts', 'schedule_disabled']);
function recordSlotMiss(state, due, cause, zone, evidence) {
  const existing = state.slotLedger?.[due?.slot];
  if (!due || state.slots[due.slot] || existing && !(cause === 'zone_changed' && SETTLED_CAUSES.has(existing.cause))) return false;
  state.slotLedger ??= {};
  state.slotLedger[due.slot] = { admission: due.admission, verdict: 'not_admitted', cause, zone, at: evidence.tick, evidence };
  return true;
}

function recordMissedRange(state, schedule, firstDate, lastDate, cause, evidence, skipped) {
  if (!validDate(firstDate) || !validDate(lastDate) || firstDate > lastDate) return;
  const earliest = offsetDate(lastDate, -30);
  for (let date = firstDate > earliest ? firstDate : earliest; date <= lastDate; date = offsetDate(date, 1)) {
    for (const due of admissionsOnDate(schedule, date)) {
      if (!skipped(due)) continue;
      const reason = cause !== 'schedule_disabled' && state.skipThrough && due.slot <= state.skipThrough ? 'recovery_skip_through' : cause;
      recordSlotMiss(state, due, reason, schedule.zone, evidence);
    }
    if (date === lastDate) break;
  }
}

// Elapsed admissions since the last tick become ledger rows under the settings that applied to
// them: with no scheduled account they were never due (`no_scheduled_accounts`), otherwise missed.
// Settings and time edits settle this window first, so they never rewrite how past slots count.
// It is resolved in the last tick's zone; after a zone change the tick's own zone logic owns
// ordinary misses, so only the no-account skips are settled there.
function tickZoneOf(data) {
  return data.state.lastTickZone ?? (data.state.lastTick !== null && data.config.schedule.zone === LEGACY_ZONE ? LEGACY_ZONE : null);
}
// Rows recorded for the pause that began at `pauseAt` (a disabled tick's own rows are observations, and
// other pauses' rows are history) whose occurrence inside that pause has not closed on the current clock
// were written while it ran ahead: drop them and pull the settled mark back, so those slots run or are
// reported under the corrected clock.
function dropOpenPauseRows(state, now, pauseAt) {
  for (const [slot, row] of Object.entries(state.slotLedger ?? {})) {
    if (row.cause !== 'schedule_disabled' || row.evidence?.pauseStartedAt !== pauseAt) continue;
    if (!labelInstants(`${slot.slice(0, 10)}T${row.admission}`, row.zone).some(at => at >= pauseAt && at + 60000 <= now)) delete state.slotLedger[slot];
  }
  if (state.settledAt > now) state.settledAt = now;
}
// While paused, an edit first settles everything that closed before it under the settings that applied:
// paused slots as `schedule_disabled`, and slots missed between the last tick and the pause as a tick
// would. It then marks them settled (`settledAt`), so resume and later ticks apply the edited schedule
// only to minutes still open at the edit: a time added after its minute passed is never reported.
// Returns whether the pause stays current through the edit. Rows already written are kept.
function settlePause(data, zone, now) {
  const { state } = data, pause = state.schedulePause;
  if (state.scheduleEnabled || !pause) return false;
  dropOpenPauseRows(state, now, pause.at);
  if (pause.revision !== scheduleRevision(state) || pause.zone !== zone || !(now >= pause.at)) return false;
  const settled = Number.isFinite(state.settledAt) ? state.settledAt : -Infinity;
  recordMissedRange(state, effectiveSchedule(data, zone), localLabel(pause.at, zone).slice(0, 10), localLabel(now, zone).slice(0, 10), 'schedule_disabled',
    { previousTick: state.lastTick, tick: now, previousZone: zone, pauseStartedAt: pause.at }, due => due.at >= pause.at && due.at + 60000 > settled && due.at + 60000 <= now);
  // Slots missed between the last tick and the pause, including one open when it began, count as a tick would count them.
  settleElapsed(data, zone, Math.min(now, pause.at + 60000));
  state.settledAt = Math.max(state.settledAt ?? settled, now);
  return true;
}
function settleElapsed(data, zone, now, fromTick = false) {
  const { state } = data;
  const tickZone = tickZoneOf(data);
  // An edit records how far it settled (`settledAt`): an admission whose minute had closed by then
  // was already counted, so a later edit never replays it under its own settings; one still open
  // then is counted later. The next tick clears it.
  const settled = Number.isFinite(state.settledAt) ? state.settledAt : -Infinity;
  if (!tickZone || !Number.isFinite(state.lastTick) || now - state.lastTick < 60000) return;
  const empty = !scheduledEnrollments(data).length;
  // In a tick after a zone change, its zone logic records ordinary misses; an edit or settings
  // change records them here first, under the settings that applied before it.
  if (fromTick && tickZone !== zone && !empty) return;
  const evidence = { previousTick: state.lastTick, tick: now, previousZone: tickZone };
  recordMissedRange(state, effectiveSchedule(data, tickZone), localLabel(state.lastTick, tickZone).slice(0, 10),
    localLabel(now, tickZone).slice(0, 10), empty ? 'no_scheduled_accounts' : 'no_tick_between', evidence,
    event => event.at > state.lastTick && event.at + 60000 > settled && event.at + 60000 <= now);
  if (!fromTick) state.settledAt = Math.max(settled, now);  // never moves back, even if the clock does
}

async function tick(base, data, services) {
  return guarded(base, data.marker, services, false, async () => {
    data = load(base, services);
    const { state } = data;
    const now = services.clock.wall();
    const tickMono = services.clock.mono();
    const zone = scheduleZone(data.config, services);
    const schedule = effectiveSchedule(data, zone);
    const previousZone = tickZoneOf(data);
    const evidence = { previousTick: state.lastTick, tick: now, previousZone };
    const minute = localLabel(now, zone);
    const due = localSlot(now, schedule);
    const note = (slot, cause) => recordSlotMiss(state, slot, cause, zone, evidence);
    if (state.lastWall !== null && now + 1000 < state.lastWall) {
      if (note(due, 'clock_hold')) atomic(base, 'state.json', state, services);
      throwCode('clock_moved_backward');
    }
    const changed = previousZone !== null && previousZone !== zone;
    if (changed) state.zoneChange = { at: now, previousZone, zone };
    if (previousZone) settleElapsed(data, zone, now, true);
    if (changed && state.scheduleEnabled) {
      const before = localLabel(now, previousZone);
      recordMissedRange(state, schedule, before.slice(0, 10), minute.slice(0, 10), 'zone_changed', evidence, event => {
        const label = `${event.date}T${event.admission}`;
        return label >= before && label < minute;
      });
      note(due, 'zone_changed');
    } else if (!state.scheduleEnabled) note(due, 'schedule_disabled');
    pruneLedger(state, now - 30 * 86400000);
    delete state.settledAt;
    state.lastTick = now;
    state.lastWall = now;
    state.lastTickZone = zone;
    atomic(base, 'state.json', state, services);
    if (!state.scheduleEnabled) return result(0, 'idle', 'schedule_disabled');
    if (changed) return result(0, 'idle', 'zone_changed');
    const compatible = (await adapter(services, 'checkCompatibility', checkCompatibility)(contextFor(data), services))?.kind === 'ready';
    if (!compatible) {
      const first = state.compatibilityBlockedSince === undefined;
      state.compatibilityBlockedSince ??= now;
      if (note(due, 'compatibility_blocked') || first) atomic(base, 'state.json', state, services);
      throwCode('compatibility_blocked');
    }
    if (state.compatibilityBlockedSince !== undefined) {
      delete state.compatibilityBlockedSince;
      atomic(base, 'state.json', state, services);
    }
    const claimWall = services.clock.wall();
    if (scheduleZone(data.config, services) !== zone) return result(0, 'idle', 'zone_changed');
    if (claimWall + 1000 < now) throwCode('clock_moved_backward');
    if (Math.abs((claimWall - now) - (services.clock.mono() - tickMono)) > 1000) {
      if (note(due, 'clock_hold')) atomic(base, 'state.json', state, services);
      return result(0, 'idle', 'clock_hold');
    }
    const admission = localSlot(claimWall, schedule);
    if (!admission) return result(0, 'idle', 'outside_admission_minute');
    const { slot } = admission;
    if (state.skipThrough && slot <= state.skipThrough) {
      if (note(admission, 'recovery_skip_through')) atomic(base, 'state.json', state, services);
      return result(0, 'idle', 'recovery_skip_through');
    }
    if (state.slots[slot] || state.highWater && slot <= state.highWater) return result(0, 'idle', 'slot_already_claimed');
    if (state.slotLedger?.[slot]?.cause === 'zone_changed') return result(0, 'idle', 'zone_changed');
    // B2: an explicit selection limits scheduled batches; manual runs still reach every enabled account.
    const chosen = state.scheduledAccounts ? new Set(state.scheduledAccounts) : null;
    const selected = scheduledEnrollments(data);
    // No account chosen: the slot is a durable, operator-chosen skip, not an empty batch claim.
    if (chosen && !selected.length) {
      if (note(admission, 'no_scheduled_accounts')) atomic(base, 'state.json', state, services);
      return result(0, 'idle', 'no_scheduled_accounts');
    }
    if (!spacedFromLastClaim(state, claimWall, selected.length)) {
      // A no-account row for this minute was provisional: the spacing refusal is the real outcome.
      if (state.slotLedger?.[slot]?.cause === 'no_scheduled_accounts') delete state.slotLedger[slot];
      if (note(admission, 'schedule_spacing')) atomic(base, 'state.json', state, services);
      return result(0, 'idle', 'schedule_spacing');
    }
    const enrollmentIds = selected.map(e => e.enrollmentId);
    if (state.slotLedger) delete state.slotLedger[slot];
    state.slots[slot] = { enrollmentIds, claimedAt: claimWall, zone, admission: admission.admission };
    state.highWater = slot;
    const clockOrigin = { wall: claimWall, mono: services.clock.mono(), zone };
    const deadline = clockOrigin.mono + scheduledBatchMs(selected.length);
    state.activeBatch = { slot, enrollmentIds, zone };
    storeState(base, state, services);
    let out;
    if (!selected.length) out = result(0, 'idle', 'no_enabled_enrollments', { selected: 0, attempted: 0, results: [] });
    else out = await run(base, data, { name: 'run', batch: enrollmentIds }, services, true, slot, deadline, clockOrigin);
    try {
      data = load(base, services);
      data.state.activeBatch = null;
      data.state.lastSlotOutcome = { slot, zone, outcome: out.outcome, at: services.clock.wall(), results: out.results };
      // Kept on the claim so history keeps a stopped batch visible after lastSlotOutcome moves on.
      if (data.state.slots[slot] && /^[a-z_]{1,64}$/.test(out.outcome)) {
        data.state.slots[slot].outcome = out.outcome;
        data.state.slots[slot].finishedAt = data.state.lastSlotOutcome.at;
      }
      storeState(base, data.state, services);
      return out;
    } catch { return { ...out, exitCode: 2, outcome: 'blocked', reason: 'slot_finalization_failed' }; }
  });
}

// Recent claims the engine stopped, newest first: visible even when no account row was saved.
function blockedSlots(state) {
  // `at` is when the batch stopped, so the app's catch-up cutoff compares the stop, not the start.
  return Object.entries(state.slots).filter(([, claim]) => claim.outcome === 'blocked' && Number.isFinite(claim.claimedAt))
    .sort(([a], [b]) => b.localeCompare(a)).slice(0, HISTORY_LIMIT)
    .map(([slot, claim]) => ({ slot, at: Number.isFinite(claim.finishedAt) ? claim.finishedAt : claim.claimedAt }));
}

function reportRows(data, account, since = -Infinity) {
  if (account && !data.config.enrollments.some(e => e.enrollmentId === account)) throwCode('unknown_enrollment');
  const enrolled = new Set(account ? [account] : data.config.enrollments.map(e => e.enrollmentId));
  return data.state.history.filter(row => plain(row) && enrolled.has(row.enrollmentId) && Number.isFinite(row.at) && row.at >= since)
    .sort((a, b) => a.at - b.at);
}

function historyReport(data, account, since, now) {
  const saved = reportRows(data, account, Math.max(now - 30 * 86400000, since ? Date.parse(since) : -Infinity));
  const rows = saved.slice(-HISTORY_LIMIT).reverse().map(row => {
    const status = row.skipped === true ? 'skipped' : confirmed(row) ? 'success' : row.outcome === 'uncertain' ? 'uncertain' : 'failed';
    const reason = typeof row.reason === 'string' && /^[a-z_]{1,64}$/.test(row.reason) ? row.reason : 'unknown';
    const transportCode = reason === 'transport_before_send' && row.dispatched === false ? safeTransportCode(row.transportCode) : undefined;
    return {
      enrollmentId: row.enrollmentId, at: row.at, status, reason,
      ...(validReservationId(row.reservationId) ? { reservationId: row.reservationId } : {}),
      ...(typeof row.dispatched === 'boolean' ? { dispatched: row.dispatched } : {}),
      ...(['scheduled', 'manual'].includes(row.mode) ? { mode: row.mode } : {}),
      ...(validSlot(row.slot) ? { slot: row.slot } : {}),
      ...(row.mode === 'scheduled' && validSlot(row.slot) && typeof data.state.slots[row.slot]?.outcome === 'string' ? { batchOutcome: data.state.slots[row.slot].outcome } : {}),
      ...(isZoneName(row.zone) ? { zone: row.zone } : {}),
      ...(transportCode ? { transportCode } : {}),
      ...(status === 'success' && validFirstTextMs(row.firstTextMs) ? { firstTextMs: row.firstTextMs } : {}),
    };
  });
  return result(0, 'ready', 'history', { rows, truncated: saved.length > rows.length });
}

function unresolvedReport(data) {
  const enrolled = new Set(data.config.enrollments.map(row => row.enrollmentId));
  const entries = Object.entries(data.state.reservations).filter(([, row]) => !row.resolved && enrolled.has(row.enrollmentId));
  entries.sort(([, a], [, b]) => b.at - a.at);
  return {
    unresolved: entries.slice(0, HISTORY_LIMIT).map(([key, row]) => {
      let slot = null;
      try {
        const parts = JSON.parse(key);
        if (Array.isArray(parts) && parts.length === 4 && validSlot(parts[0]) && parts[1] === row.enrollmentId && parts[2] === row.identity.accountId && parts[3] === row.identity.userId) slot = parts[0];
      } catch { /* Manual reservation. */ }
      return { reservation: validReservationId(row.reservationId) ? row.reservationId : `legacy_${hash(key).slice(0, 32)}`, enrollmentId: row.enrollmentId, slot, at: row.at };
    }),
    unresolvedTruncated: entries.length > HISTORY_LIMIT,
  };
}

function timingReport(data, account) {
  const median = values => {
    const middle = Math.floor(values.length / 2);
    if (!values.length) return { samples: 0, medianMs: null };
    values.sort((a, b) => a - b);
    return { samples: values.length, medianMs: values.length % 2 ? values[middle] : (values[middle - 1] + values[middle]) / 2 };
  };
  const groups = new Map();
  for (const row of reportRows(data, account)) {
    if (row.skipped === true || typeof row.model !== 'string' || !/^[A-Za-z0-9_.-]{1,100}$/.test(row.model) || row.dispatched !== true) continue;
    const key = JSON.stringify([row.enrollmentId, row.model]);
    if (!groups.has(key)) groups.set(key, { enrollmentId: row.enrollmentId, model: row.model, recent: [], spaced: [], unclassified: 0, prior: null });
    const group = groups.get(key);
    if (confirmed(row) && validFirstTextMs(row.firstTextMs)) {
      const gap = group.prior && confirmed(group.prior) ? (row.at - group.prior.at) / 60000 : null;
      if (gap > 0 && gap <= RECENT_MINUTES) group.recent.push(row.firstTextMs);
      else if (gap >= SPACED_MINUTES) group.spaced.push(row.firstTextMs);
      else group.unclassified++;
    }
    group.prior = row;
  }
  const rows = [...groups.values()].filter(group => group.recent.length || group.spaced.length || group.unclassified)
    .map(group => {
      const recent = median(group.recent), spaced = median(group.spaced);
      return { enrollmentId: group.enrollmentId, model: group.model, recent, spaced, unclassified: group.unclassified,
        deltaMs: recent.samples && spaced.samples ? spaced.medianMs - recent.medianMs : null };
    });
  return result(0, 'ready', 'timing', { recentWithinMinutes: RECENT_MINUTES, spacedAtLeastMinutes: SPACED_MINUTES, rows });
}

async function activeBatchStatus(base, data, binding, services) {
  const batch = data.state.activeBatch;
  if (!batch) return null;
  let state = 'unknown';
  try {
    const owner = read(base, 'work.lock/owner.json', services, 4096, true)?.value;
    if (!owner) state = 'interrupted';
    else if (owner.installationId === data.marker.installationId && Number.isSafeInteger(owner.pid) && typeof owner.startId === 'string') {
      const status = services.processes.inspect(owner);
      if (status === 'dead') state = 'interrupted';
      else if (status === 'alive') {
        const runner = await services.jobs.runner(binding);
        if (runner?.scheduled && runner.installationId === owner.installationId && runner.pid === owner.pid && runner.startId === owner.startId) state = 'running';
      }
    }
  } catch { /* Unknown ownership is not proof of interruption. */ }
  return { ...batch, state };
}

export async function runCommand(command, context, services) {
  let installationId = null;
  try {
    if (!services?.files || !services?.acl || !services?.clock || !services?.processes || !services?.jobs) throwCode('missing_capability');
    const base = binding(context, services);
    const marker = read(base, 'instance.json', services, MAX_FILE).value;
    validateMarker(marker);
    validateIsolation(base, marker.paths, marker.plistPath, services);
    base.installationId = marker.installationId;
    installationId = marker.installationId;
    if (command.expectedInstallationId !== undefined && command.expectedInstallationId !== installationId) throwCode('installation_id_mismatch');
    const finish = value => ({ ...value, installationId });
    if (command.name === 'setup') return finish(await setup(base, context, services));
    const data = load(base, services);
    if (command.name === 'enroll') return finish(await enroll(base, data, command.account, services));
    if (command.name === 'run') return finish(await run(base, data, command, services));
    if (command.name === 'tick') return finish(await tick(base, data, services));
    if (command.name === 'maintain') return finish(await maintain(base, data, command.file, context, services));
    if (command.name === 'schedule') {
      if (command.action === 'inspect') return finish(inspectSchedule(data, command, services));
      if (EDIT_ACTIONS.includes(command.action)) return finish(await editSchedule(base, data.marker, command, services));
      if (SETTING_ACTIONS.includes(command.action)) return finish(await changeSettings(base, data.marker, command, services));
      return finish(await schedule(base, data, command, context, services));
    }
    if (command.name === 'remove') return finish(await remove(base, data.marker, context, services));
    if (command.name === 'history') return finish(historyReport(data, command.account, command.since, services.clock.wall()));
    if (command.name === 'timing') return finish(timingReport(data, command.account));
    if (command.name === 'status') {
      const binding = jobBinding(base, data, context);
      const job = await services.jobs.inspect(binding);
      const compatibility = await adapter(services, 'checkCompatibility', checkCompatibility)(contextFor(data), services);
      if (!['loaded', 'absent'].includes(job)) throwCode('job_ownership_unknown');
      const compatible = compatibility?.kind === 'ready';
      const schedule = effectiveSchedule(data, scheduleZone(data.config, services));
      const now = services.clock.wall();
      const { lastWall, highWater } = data.state;
      const clockHold = lastWall !== null && now + 1000 < lastWall ? { lastWall, highWater } : null;
      const next = data.state.scheduleEnabled && !clockHold && scheduledEnrollments(data).length ? nextAdmission(data.state, schedule, now, scheduledEnrollments(data).length) : null;
      const usage = latestUsage(data.state, new Set(data.config.enrollments.map(e => e.enrollmentId)));
      const accounts = data.config.enrollments.map(({ enrollmentId }) => ({ enrollmentId,
        block: ['authentication_rejected', 'forbidden_or_challenged', 'unsupported_model', 'protocol_failure', 'output_mismatch', 'recovery_correction_required'].includes(data.state.blocks[enrollmentId]) ? data.state.blocks[enrollmentId] : null,
        cooldownUntil: data.state.cooldowns[enrollmentId] ?? null,
        usage: usage.found.get(enrollmentId) ?? null,
      }));
      const activeBatch = await activeBatchStatus(base, data, binding, services);
      const recent = data.state.history.filter(entry => entry.skipped !== true && data.config.enrollments.some(e => e.enrollmentId === entry.enrollmentId)).slice(-10).map(entry => ({ enrollmentId: entry.enrollmentId, outcome: /^[a-z_]{1,64}$/.test(entry.outcome) ? entry.outcome : 'unknown', reason: /^[a-z_]{1,64}$/.test(entry.reason) ? entry.reason : 'unknown', at: Number.isFinite(entry.at) ? entry.at : null }));
      return finish(result(0, 'ready', 'status', { schedule, scheduleEnabled: data.state.scheduleEnabled, scheduleRevision: scheduleRevision(data.state), job, compatibility: compatible ? 'ready' : 'blocked', lastTick: data.state.lastTick, lastTickZone: data.state.lastTickZone ?? (data.state.lastTick !== null && data.config.schedule.zone === LEGACY_ZONE ? LEGACY_ZONE : null), timeZoneMode: data.config.schedule.zone === LOCAL_ZONE ? 'local' : 'fixed', zoneChange: data.state.zoneChange ?? null, slotLedger: Object.entries(data.state.slotLedger ?? {}).sort(([a], [b]) => b.localeCompare(a)).slice(0, HISTORY_LIMIT).map(([slot, row]) => ({ slot, ...row })), compatibilityBlockedSince: data.state.compatibilityBlockedSince ?? null, slotObservation: slotObservation(data.state, now, schedule), next: next ? { slot: next.slot, admission: next.admission, date: next.date, at: next.at } : null, accounts, activeBatch, workLock: workLockStatus(base, data.marker, services), usageTruncated: usage.truncated, scheduledAccounts: data.state.scheduledAccounts ?? null, caps: data.state.caps ?? {}, undoAvailable: undoAvailable(data.state, localDate(localParts(now, schedule.zone))), clockHold, lastSlotOutcome: data.state.lastSlotOutcome, blockedSlots: blockedSlots(data.state), enrolled: data.config.enrollments.length, enabled: data.config.enrollments.filter(e => e.enabled).length, pilots: Object.keys(data.state.pilots).length, recent, historyTruncated: recent.length < data.state.history.length, ...unresolvedReport(data), capability: UI_CAPABILITY, engine: { nodePath: context.nodePath, scriptPath: context.scriptPath }, recovery: !compatible ? 'review_source_compatibility' : data.state.scheduleEnabled !== (job === 'loaded') ? 'reconcile_job_state' : 'none' }));
    }
    if (command.name === 'list') {
      const registry = await adapter(services, 'readRegistry', readRegistry)(contextFor(data), services);
      if (registry?.kind !== 'ready' || !Array.isArray(registry.accounts)) throwCode('registry_blocked');
      const rows = [...registry.accounts, ...data.config.enrollments.filter(e => !registry.accounts.some(a => a.routerAccountId === e.routerAccountId)).map(e => ({ routerAccountId: e.routerAccountId, eligible: false }))].map(a => {
        const e = data.config.enrollments.find(item => item.routerAccountId === a.routerAccountId);
        const last = e ? data.state.history.findLast(entry => entry.skipped !== true && entry.enrollmentId === e.enrollmentId) : null;
        const registered = registry.accounts.some(item => item.routerAccountId === a.routerAccountId);
        const registryReason = !registered ? 'unregistered' : a.state === 'revoked' ? 'revoked' : a.state === 'paused' || a.paused === true ? 'paused' : a.eligible ? 'eligible' : a.state === 'active' ? 'identity_unknown' : 'ineligible';
        return { routerAccountId: a.routerAccountId, enrollmentId: e?.enrollmentId ?? null, registered, registryReason, enrollmentState: !e ? 'not_enrolled' : !e.enabled ? 'disabled' : !registered ? 'enrolled_unregistered' : 'enabled', eligible: !!a.eligible, enabled: e?.enabled ?? false, pilot: e ? !!data.state.pilots[pilotKey(e, data.compatibility, data.config)] : false, credentialFreshness: 'unknown', finalDispatchEligibility: 'unknown', lastOutcome: last && /^[a-z_]{1,64}$/.test(last.outcome) ? last.outcome : null, lastReason: last && /^[a-z_]{1,64}$/.test(last.reason) ? last.reason : null, lastAt: Number.isFinite(last?.at) ? last.at : null, enrollCommand: `enroll --account ${a.routerAccountId}`, runCommand: e ? `run --account ${e.enrollmentId}` : null };
      });
      return finish(result(0, 'ready', 'list', { rows }));
    }
    return finish(fail('not_implemented'));
  } catch (error) { return { ...fail(error?.[SAFE_REASON] ? error.reason : 'internal_error', error?.[SAFE_REASON] ? error.exitCode ?? 2 : 2), installationId }; }
}

export function hostServices(root, command = (file, args) => execFileSync(file, args, { encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024, env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } }), nodeInspector) {
  // Factory is inert; deployment qualification must establish the exact root and plist before CLI use.
  if (!path.isAbsolute(root) || path.resolve(root) !== root) throwCode('invalid_root');
  const scriptPath = path.join(root, 'warmup.mjs');
  const nodePath = '/opt/homebrew/opt/node@22/bin/node';
  const uid = process.getuid();
  const xml = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  const run = (file, args) => command(file, args);
  const verifyNode = nodeInspector ?? (() => {
    const resolved = fs.realpathSync(nodePath);
    const stat = fs.statSync(nodePath);
    const match = String(run(nodePath, ['--version'])).trim().match(/^v22\.(\d+)\.(\d+)$/);
    if (!resolved.startsWith('/opt/homebrew/Cellar/node@22/') || !stat.isFile() || ![0, uid].includes(stat.uid) || (stat.mode & 0o022) || !(stat.mode & 0o111) || !match || Number(match[1]) < 19) throwCode('node_runtime_unqualified');
  });
  const processInfo = pid => {
    if (!Number.isSafeInteger(pid) || pid <= 0) return null;
    try {
      const line = String(run('/bin/ps', ['-p', String(pid), '-o', 'lstart=', '-o', 'command='])).trim();
      if (line.length < 26 || !/^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9]{2} \d\d:\d\d:\d\d \d{4}$/.test(line.slice(0, 24))) throwCode('process_inspection_unavailable');
      return { startId: line.slice(0, 24), command: line.slice(24).trim() };
    }
    catch (error) { if (error?.status === 1 && !String(error?.stderr ?? '').trim()) return null; throwCode('process_inspection_unavailable'); }
  };
  const inspectProcess = owner => {
    if (!owner || !Number.isSafeInteger(owner.pid) || typeof owner.startId !== 'string') return 'unknown';
    let info;
    try { info = processInfo(owner.pid); } catch { return 'unknown'; }
    return !info ? 'dead' : info.startId === owner.startId ? 'alive' : 'unknown';
  };
  const jobText = binding => {
    if (binding.root !== root || binding.nodePath !== nodePath || binding.scriptPath !== scriptPath || binding.label !== 'local.codex-router-warmup' || !path.isAbsolute(binding.plistPath) || path.basename(binding.plistPath) !== `${binding.label}.plist`) throwCode('invalid_job_binding');
    const rootStat = fs.lstatSync(root);
    if (rootStat.dev !== binding.dev || rootStat.ino !== binding.ino || rootStat.uid !== uid || !rootStat.isDirectory()) throwCode('installation_replaced');
    const parent = fs.lstatSync(path.dirname(binding.plistPath));
    if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== uid || (parent.mode & 0o022) || !services.acl(path.dirname(binding.plistPath))) throwCode('unsafe_plist_parent');
    return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>${xml(binding.label)}</string><key>ProgramArguments</key><array><string>${xml(nodePath)}</string><string>${xml(scriptPath)}</string><string>tick</string></array><key>WorkingDirectory</key><string>${xml(root)}</string><key>StartInterval</key><integer>30</integer><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string></dict></plist>`;
  };
  const plist = binding => {
    const expected = jobText(binding);
    const stat = fs.lstatSync(binding.plistPath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077)) throwCode('unsafe_plist');
    if (safeRead(binding.plistPath, services, { root: path.dirname(binding.plistPath), limit: MAX_FILE, json: false, private: false }).value.toString() !== expected) throwCode('foreign_plist');
  };
  const launch = binding => {
    jobText(binding);
    try {
      const output = String(run('/bin/launchctl', ['print', `gui/${uid}/${binding.label}`]));
      plist(binding);
      // launchctl indents top-level keys with one tab and each argument with two; only that indentation is
      // removed, so paths with spaces or trailing blanks compare exactly. The top-level path is the loaded plist.
      const program = output.match(/^\tprogram = (.*)$/m)?.[1];
      const args = output.match(/^\targuments = \{\n((?:\t\t.*\n)*)\t\}$/m)?.[1].split('\n').slice(0, -1).map(line => line.slice(2));
      const loadedFrom = output.match(/^\tpath = (.+)$/m)?.[1];
      if (program !== nodePath || JSON.stringify(args) !== JSON.stringify([nodePath, scriptPath, 'tick']) || loadedFrom !== binding.plistPath) throwCode('job_ownership_unknown');
      return output;
    }
    catch (error) {
      if (/Could not find service/.test(String(error?.stderr ?? ''))) return null;
      throwCode('job_ownership_unknown');
    }
  };
  const services = {
    files: fs, uid,
    acl(file) {
      try { return /^[-d][r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]@? +\d+ +\S+ +\S+ +\d+ +[A-Z][a-z]{2} +\d{1,2} +(?:\d{2}:\d{2}|\d{4}) +[^\x00-\x1f\x7f]+\n?(?![\s\S])/.test(String(run('/bin/ls', ['-lde', file]))); }
      catch { return false; }
    },
    clock: { wall: () => Date.now(), mono: () => performance.now(), setTimeout, clearTimeout,
      zone() {
        let localtime;
        try { localtime = path.resolve('/etc', fs.readlinkSync('/etc/localtime')); }
        catch { throwCode('system_zone_unavailable'); }
        const prefix = ['/var/db/timezone/zoneinfo/', '/usr/share/zoneinfo/', '/private/var/db/timezone/zoneinfo/']
          .find(directory => localtime.startsWith(directory));
        if (!prefix) throwCode('system_zone_unavailable');
        return localtime.slice(prefix.length);
      },
    },
    request: directRequest,
    context: { root, nodePath, scriptPath },
    source: { inspect(sourceRoot, relativePaths) {
      if (!path.isAbsolute(sourceRoot) || !Array.isArray(relativePaths) || relativePaths.some(name => !/^(src|bin)\/[A-Za-z0-9._/-]+$/.test(name) || name.includes('..'))) throwCode('invalid_source_path');
      const prefix = ['--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', '-C', sourceRoot];
      return { revision: String(run('/usr/bin/git', [...prefix, 'rev-parse', 'HEAD'])).trim(), dirtyPaths: String(run('/usr/bin/git', [...prefix, 'status', '--porcelain', '--untracked-files=no', '--', ...relativePaths])).trim().split('\n').filter(Boolean) };
    } },
    processes: {
      get current() { return { pid: process.pid, startId: processInfo(process.pid)?.startId }; },
      inspect: inspectProcess,
      async wait(owner, ms) {
        const until = Date.now() + ms;
        while (Date.now() < until) {
          const status = inspectProcess(owner);
          if (status === 'dead') return true;
          if (status === 'unknown') throwCode('runner_ownership_unknown');
          await new Promise(resolve => setTimeout(resolve, Math.min(250, until - Date.now())));
        }
        return inspectProcess(owner) === 'dead';
      },
      async terminate(owner) { if (inspectProcess(owner) !== 'alive') throwCode('runner_ownership_unknown'); process.kill(owner.pid, 'SIGTERM'); },
    },
    jobs: {
      async inspect(binding) { return launch(binding) ? 'loaded' : 'absent'; },
      async enable(binding) {
        const expected = jobText(binding);
        verifyNode();
        try { plist(binding); }
        catch (error) {
          if (error.code !== 'ENOENT' || error.path !== binding.plistPath) throw error;
          const fd = fs.openSync(binding.plistPath, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
          try { fs.writeSync(fd, expected); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
          const dir = fs.openSync(path.dirname(binding.plistPath), fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
          try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
        }
        jobText(binding);
        run('/bin/launchctl', ['bootstrap', `gui/${uid}`, binding.plistPath]);
      },
      async disable(binding) { if (launch(binding)) { plist(binding); run('/bin/launchctl', ['bootout', `gui/${uid}`, binding.plistPath]); } },
      async remove(binding) {
        if (launch(binding)) throwCode('job_still_loaded');
        plist(binding);
        fs.unlinkSync(binding.plistPath);
        const dir = fs.openSync(path.dirname(binding.plistPath), fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
        try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
      },
      async runner(binding) {
        const output = launch(binding);
        if (!output) return null;
        plist(binding);
        const match = output.match(/^\s*pid = ([0-9]+)\s*$/m);
        if (!match) return null;
        const pid = Number(match[1]);
        const info = processInfo(pid);
        if (!info || info.command !== `${nodePath} ${scriptPath} tick`) throwCode('runner_ownership_unknown');
        return { pid, startId: info.startId, scheduled: true, installationId: binding.installationId };
      },
    },
  };
  return services;
}
