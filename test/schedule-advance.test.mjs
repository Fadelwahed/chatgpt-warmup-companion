import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { execute } from "../warmup.mjs";
import { runCommand } from "../runtime.mjs";
import { fakeClock, makeFixture } from "./helpers.mjs";

async function prepared(start) {
  const f = makeFixture({ clock: fakeClock(start) });
  const paths = { sourceRoot: f.routerRoot, stateRoot: f.routerRoot, codexHome: f.routerRoot,
    poolPath: path.join(f.routerRoot, "pool.json"), homesDir: f.routerRoot,
    switchPath: path.join(f.routerRoot, "switch.json"), discoveryPath: path.join(f.routerRoot, "discovery.json") };
  const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  put(f.markerPath, { schemaVersion: 1, installationId: "install_admission_01", phase: "uninitialized", paths, plistPath: f.plistPath });
  put(path.join(f.companionRoot, "compatibility.json"), { schemaVersion: 1, reviewedRevision: "a".repeat(40),
    sourceDigests: Object.fromEntries(Array.from({ length: 13 }, (_, n) => [`src/f-${n}.mjs`, createHash("sha256").update(String(n)).digest("hex")])),
    adapterVersion: 1, requestContractVersion: 1, sourcePathContract: "synthetic", reviewEvidence: "synthetic", semantics: "equivalent" });
  let reads = 0, sends = 0;
  f.services.reader = {
    readRegistry: () => ({ kind: "ready", coordination: "idle", accounts: [{ routerAccountId: "router_0", eligible: true }] }),
    discoverIdentity: () => ({ kind: "ready", identity: { accountId: "workspace", userId: "user" } }),
    checkCompatibility: () => ({ kind: "ready" }),
    readCredential: (_ctx, e) => { reads++; return { kind: "ready", identity: e.identity, accessToken: "synthetic", expiresAt: 4102444800000, snapshot: {} }; },
    revalidate: () => ({ kind: "ready" }),
  };
  f.services.probe = async () => { sends++; return { outcome: "success", reason: "marker_confirmed", dispatched: true }; };
  const context = { root: f.companionRoot, nodePath: "/opt/homebrew/opt/node@22/bin/node", scriptPath: "/synthetic/warmup.mjs" };
  const call = command => runCommand(command, context, f.services);
  assert.equal((await call({ name: "setup" })).exitCode, 0);
  assert.equal((await call({ name: "run" })).exitCode, 0);
  
  return { ...f, call, context, put, state: () => JSON.parse(fs.readFileSync(f.statePath)), reads: () => reads, sends: () => sends };
}


const instant = time => Date.parse(`2026-11-12T${time}Z`);
async function advance(f, value = {date: '2026-11-12', time: '10:37'}, fresh = true) {
  const config = JSON.parse(fs.readFileSync(f.configPath));
  if (value === undefined) delete config.schedule.advance13;
  else config.schedule.advance13 = value;
  const compatibility = JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json')));
  const reviewEvidence = fresh ? 'schedule-advance-review' : compatibility.reviewEvidence;
  compatibility.reviewEvidence = reviewEvidence;
  const file = path.join(f.root, 'candidate.json');
  f.put(file, {schemaVersion: 1, config, compatibility, reviewEvidence});
  return f.call({name: 'maintain', file});
}
const preserved = s => Object.fromEntries(Object.entries(s).filter(([k]) => !['configDigest', 'compatibilityDigest', 'scheduleEnabled', 'lastTick', 'lastWall', 'scheduleRevision'].includes(k)));

test('schedule advance requires fresh review; preserves state/pilots and exposes exact schedule', async () => {
  const f = await prepared(instant('08:00:00'));
  try {
    const before = f.state();
    assert.equal((await advance(f, {date:'2026-11-12',time:'10:37'}, false)).reason, 'new_review_required');
    assert.equal((await advance(f)).exitCode, 0);
    assert.deepEqual(preserved(f.state()), preserved(before));
    const out = await f.call({name:'status'});
    assert.deepEqual(out.schedule, {zone:'Asia/Gaza',times:['08:00','13:00','18:00'],advance13:{date:'2026-11-12',time:'10:37'}});
    assert.equal((await f.call({name:'setup'})).reason,'already_initialized');
  } finally { f.cleanup(); }
});
for (const value of [null, {}, {date:'2026-02-30',time:'10:37'}, {date:'2026-11-12',time:'08:00'}, {date:'2026-11-12',time:'13:00'}, {date:'2026-11-12',time:'10:60'}, {date:'2026-11-12',time:'9:37'}, {date:'2026-11-12',time:'10:37',extra:true}])
test(`invalid advance is rejected: ${JSON.stringify(value)}`, async () => {
  const f=await prepared(instant('08:00:00'));
  try {const before=fs.readFileSync(f.statePath,'utf8');assert.equal((await advance(f,value)).reason,'invalid_config');assert.equal(fs.readFileSync(f.statePath,'utf8'),before);}finally{f.cleanup();}
});
for (const value of [{date:'2026-11-11',time:'10:37'}, {date:'2026-11-13',time:'10:37'}, {date:'2026-11-12',time:'10:01'}])
test('advance must be same-date and at least two minutes ahead '+JSON.stringify(value),async()=>{
 const f=await prepared(instant('08:00:00'));try{assert.equal((await advance(f,value)).reason,'advance_not_future');}finally{f.cleanup();}
});
for(const field of ['slots','highWater','skipThrough','activeBatch','lastSlotOutcome'])
test('advance cannot re-admit claimed or conservatively skipped slot: '+field,async()=>{
 const f=await prepared(instant('08:00:00'));try{
 const s=f.state(),slot='2026-11-12T13:00';
 if(field==='slots'){s.slots[slot]={enrollmentIds:[],claimedAt:instant('08:00:00')};s.highWater=slot;}
 else if(field==='activeBatch')s.activeBatch={slot,enrollmentIds:[]};
 else if(field==='lastSlotOutcome')s.lastSlotOutcome={slot,at:instant('08:00:00'),outcome:'success'};
 else s[field]=slot;
 f.put(f.statePath,s);assert.equal((await advance(f)).reason,'advance_slot_unavailable');
 }finally{f.cleanup();}
});
for(const [label,at,admit] of [['before',-1,false],['start',0,true],['last',59999,true],['after',60000,false]])
test('advanced admission '+label+' with no catch-up or 13:00 repeat',async()=>{
 const f=await prepared(instant('08:00:00'));try{
 assert.equal((await advance(f)).exitCode,0);assert.equal((await f.call({name:'schedule',action:'enable'})).exitCode,0);
 const sends=f.sends();f.services.clock.setWall(instant('08:37:00')+at);
 const out=await f.call({name:'tick'});assert.equal(out.attempted??0,admit?1:0);
 if(admit){assert.equal(f.state().lastSlotOutcome.slot,'2026-11-12T13:00');assert.equal((await f.call({name:'tick'})).reason,'slot_already_claimed');}
 else assert.equal(out.reason,'outside_admission_minute');
 f.services.clock.setWall(instant('11:00:00'));assert.equal((await f.call({name:'tick'})).reason,'outside_admission_minute');assert.equal(f.sends(),sends+(admit?1:0));
 f.services.clock.setWall(Date.parse('2026-11-13T11:00:00Z'));assert.equal((await f.call({name:'tick'})).attempted,1);
 }finally{f.cleanup();}
});
test('advanced minute is rechecked after validation; reporting respects non-hour minute',async()=>{
 const f=await prepared(instant('08:00:00'));try{
 assert.equal((await advance(f)).exitCode,0);await f.call({name:'schedule',action:'enable'});
 const sends=f.sends(),reads=f.reads();f.services.clock.setWall(instant('08:37:59.900'));
 f.services.reader.checkCompatibility=()=>{f.services.clock.advance(200);return {kind:'ready'};};
 assert.equal((await f.call({name:'tick'})).reason,'outside_admission_minute');assert.equal(f.sends(),sends);assert.equal(f.reads(),reads);
 f.services.reader.checkCompatibility=()=>({kind:'ready'});
 await f.call({name:'tick'});const out=await f.call({name:'status'});
 assert.equal(out.slotObservation.slot,'2026-11-12T13:00');
 assert.equal(out.slotObservation.admissionTime,'10:37');
 }finally{f.cleanup();}
});
test('accepted advance cannot be changed or removed; raw editor change blocks',async()=>{
 const f=await prepared(instant('08:00:00'));try{
 assert.equal((await advance(f)).exitCode,0);assert.equal((await advance(f,{date:'2026-11-12',time:'10:38'})).reason,'advance_immutable');
 const config=JSON.parse(fs.readFileSync(f.configPath)),compatibility=JSON.parse(fs.readFileSync(path.join(f.companionRoot,'compatibility.json')));
 delete config.schedule.advance13;const file=path.join(f.root,'removed.json');f.put(file,{schemaVersion:1,config,compatibility,reviewEvidence:compatibility.reviewEvidence});
 assert.equal((await f.call({name:'maintain',file})).reason,'advance_immutable');
 f.put(f.configPath,config);assert.equal((await f.call({name:'schedule',action:'enable'})).exitCode,2);
 }finally{f.cleanup();}
});

test('advance respects lifecycle/job gates and leaves old config intact',async()=>{
 const f=await prepared(instant('08:00:00'));try{
 await f.call({name:'schedule',action:'enable'});
 const before=fs.readFileSync(f.configPath,'utf8');assert.equal((await advance(f)).reason,'schedule_must_be_disabled');assert.equal(fs.readFileSync(f.configPath,'utf8'),before);
 await f.call({name:'schedule',action:'disable'});
 fs.mkdirSync(path.join(f.companionRoot,'lifecycle.lock'),{mode:0o700});assert.equal((await advance(f)).exitCode,3);assert.equal(fs.readFileSync(f.configPath,'utf8'),before);
 }finally{f.cleanup();}
});
for(const point of ['before_config.json_rename','after_config.json_rename','after_compatibility.json_rename','after_state.json_rename'])
test('advance persistence failure blocks safely: '+point,async()=>{
 const f=await prepared(instant('08:00:00'));try{
 const before=preserved(f.state());let hits=0;
 f.services.fault=p=>{if(p===point && ++hits===(point==='after_state.json_rename'?2:1))throw Error('synthetic_crash');};
 assert.equal((await advance(f)).exitCode,2);delete f.services.fault;
 assert.equal(f.state().scheduleEnabled,false);assert.deepEqual(preserved(f.state()),before);
 assert.equal(f.sends(),1);assert.equal(f.state().activeBatch,null);
 }finally{f.cleanup();}
});
for(const [date,utc] of [['2026-11-12','2026-11-12T06:00:00Z'],['2026-11-12','2026-11-12T16:00:00Z'],['2026-11-11','2026-11-11T11:00:00Z']])
test('other admission windows remain unchanged: '+utc,async()=>{
 const f=await prepared(instant('05:00:00'));try{
 assert.equal((await advance(f)).exitCode,0);await f.call({name:'schedule',action:'enable'});
 f.services.clock.setWall(Date.parse(utc));const out=await f.call({name:'tick'});assert.equal(out.attempted,1);
 assert.equal(f.state().lastSlotOutcome.slot,date+'T'+(utc.includes('06:00')?'08:00':utc.includes('16:00')?'18:00':'13:00'));
 }finally{f.cleanup();}
});


test('scheduler moves today’s 08:00 admission once and retains its original claim key', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    assert.equal((await advance(f)).exitCode, 0);
    assert.equal((await f.call({name:'schedule', action:'enable'})).exitCode, 0);
    const move = time => f.call({name:'schedule', action:'move', time:'08:00', target:time, today:true});
    assert.equal((await move('04:40')).reason, 'schedule_time_elapsed');
    assert.equal((await move('11:00')).reason, 'schedule_order_conflict');
    assert.equal((await move('04:45')).reason, 'schedule_updated');
    f.services.clock.setWall(instant('02:45:00'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    assert.equal(f.state().lastSlotOutcome.slot, '2026-11-12T08:00');
    assert.equal((await f.call({name:'tick'})).reason, 'slot_already_claimed');
    assert.equal((await move('04:48')).reason, 'schedule_time_elapsed');
    f.services.clock.setWall(instant('06:00:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
    f.services.clock.setWall(instant('08:37:00'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    assert.equal(f.state().lastSlotOutcome.slot, '2026-11-12T13:00');
    f.services.clock.setWall(Date.parse('2026-11-13T06:00:00Z'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    assert.equal(f.state().lastSlotOutcome.slot, '2026-11-13T08:00');
  } finally { f.cleanup(); }
});

test('recurring edits can be made while enabled and take effect the next Gaza day', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    await f.call({name:'schedule', action:'enable'});
    const edit = (action, time, target) => f.call({name:'schedule', action, time, target});
    const before = preserved(f.state());
    assert.equal((await edit('move', '08:00', '09:15')).reason, 'schedule_updated');
    assert.equal((await edit('add', '13:00')).reason, 'schedule_time_exists');
    assert.equal((await edit('remove', '18:00')).reason, 'schedule_updated');
    assert.equal((await edit('add', '21:05')).reason, 'schedule_updated');
    assert.equal((await edit('add', '24:00')).reason, 'invalid_schedule_time');
    const state = preserved(f.state());
    delete state.scheduleEdits;
    delete state.scheduleRevision;
    // Engine 1.2 keeps one undo record for the latest time edit (Increment B3).
    assert.deepEqual(state.scheduleUndo.revision, f.state().scheduleRevision);
    delete state.scheduleUndo;
    assert.deepEqual(state, before);
    const status = await f.call({name:'status'});
    assert.deepEqual(status.schedule.times, ['09:15','13:00','21:05']);
    assert.deepEqual(Object.keys(status.schedule.today.admissions), ['08:00','13:00','18:00']);
    f.services.clock.setWall(instant('06:00:00'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    f.services.clock.setWall(instant('07:15:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
    f.services.clock.setWall(Date.parse('2026-11-13T07:15:00Z'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    assert.equal(f.state().lastSlotOutcome.slot, '2026-11-13T09:15');
  } finally { f.cleanup(); }
});

test('today-only add and remove change only unclaimed future entries', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    const edit = (action, time) => f.call({name:'schedule', action, time, today:true});
    assert.equal((await edit('add', '04:41')).reason, 'schedule_updated');
    assert.equal((await edit('remove', '08:00')).reason, 'schedule_updated');
    assert.equal((await edit('remove', '08:00')).reason, 'schedule_time_missing');
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('02:41:00'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    assert.equal(f.state().lastSlotOutcome.slot, '2026-11-12T04:41');
    assert.equal((await edit('remove', '04:41')).reason, 'schedule_time_elapsed');
    f.services.clock.setWall(instant('06:00:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
  } finally { f.cleanup(); }
});


test('scheduled outcome records accounts skipped before probing and safe transport codes', async () => {
  const f = await prepared(instant('05:00:00'));
  try {
    await f.call({ name: 'schedule', action: 'enable' });
    f.services.probe = async () => ({ outcome:'blocked', reason:'transport_before_send', dispatched:false, transportCode:'EAI_AGAIN' });
    f.services.clock.setWall(instant('06:00:00'));
    await f.call({ name: 'tick' });
    const [entry] = f.state().lastSlotOutcome.results;
    assert.equal(entry.reason, 'transport_before_send');
    assert.equal(entry.transportCode, 'EAI_AGAIN');
    assert.equal(entry.dispatched, false);

    f.services.reader.readCredential = () => ({ kind:'blocked', scope:'account', reason:'credential_expired_or_unknown' });
    f.services.clock.setWall(instant('11:00:00'));
    await f.call({ name:'tick' });
    assert.equal(f.state().lastSlotOutcome.results[0].reason, 'credential_expired_or_unknown');
  } finally { f.cleanup(); }
});

test('a subsecond clock adjustment cannot apply recurring edits to a previous Gaza date', async () => {
  const f = await prepared(instant('21:50:00'));
  try {
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('22:00:00.200'));
    await f.call({name:'tick'});
    await f.call({name:'schedule', action:'add', time:'23:59'});
    f.services.clock.setWall(instant('21:59:59.800'));
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
    assert.equal(f.state().lastSlotOutcome, null);
  } finally { f.cleanup(); }
});

test('per-account history is read-only and preserves probe failures, skips and legacy records', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    const legacy = f.state();
    const enrollment = legacy.history[0].enrollmentId;
    const at = legacy.history[0].at;
    legacy.history[0] = { enrollmentId: enrollment, outcome: 'success', reason: 'marker_confirmed', dispatched: true, at };
    f.put(f.statePath, legacy);

    f.services.clock.advance(1000);
    f.services.probe = async () => ({ outcome:'blocked', reason:'transport_before_send', dispatched:false, transportCode:'EAI_AGAIN' });
    await f.call({name:'run'});
    f.services.clock.advance(1000);
    f.services.reader.readCredential = () => ({kind:'blocked',scope:'account',reason:'credential_expired_or_unknown'});
    await f.call({name:'run'});

    const before = fs.readFileSync(f.statePath,'utf8');
    f.services.reader = new Proxy({}, { get() { throw new Error('history attempted a reader call'); } });
    const result = await f.call({name:'history',account:enrollment});
    assert.equal(result.exitCode, 0);
    assert.deepEqual(result.rows.map(row => [row.status,row.reason,row.dispatched,row.transportCode]), [
      ['skipped','credential_expired_or_unknown',false,undefined],
      ['failed','transport_before_send',false,'EAI_AGAIN'],
      ['success','marker_confirmed',true,undefined],
    ]);
    assert.equal(result.rows[0].mode, 'manual');
    assert.equal(result.rows[2].mode, undefined);
    assert.equal((await f.call({name:'history',account:'unknown'})).reason, 'unknown_enrollment');
    assert.equal(fs.readFileSync(f.statePath,'utf8'), before);
  } finally { f.cleanup(); }
});

test('timing compares only successful measured probes with a known prior same-model outcome', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    const enrollment = f.state().history[0].enrollmentId;
    const probe = async (minutes, firstTextMs, outcome='success') => {
      f.services.clock.advance(minutes * 60000);
      f.services.probe = async () => ({ outcome, reason:outcome === 'success' ? 'marker_confirmed' : 'stream_or_transport_uncertain', dispatched:true, firstTextMs });
      await f.call({name:'run'});
    };
    await probe(5, 100);
    await probe(5, 140);
    await probe(250, 250);
    await probe(30, 400);
    await probe(1, 100, 'uncertain');
    await probe(1, 700);
    const result = await f.call({name:'timing',account:enrollment});
    assert.equal(result.exitCode, 0);
    assert.deepEqual(result.rows.map(row => [row.enrollmentId,row.model,row.recent,row.spaced,row.unclassified,row.deltaMs]), [
      [enrollment,'gpt-6-luna',{samples:2,medianMs:120},{samples:1,medianMs:250},2,130],
    ]);
  } finally { f.cleanup(); }
});

test('global reader and claimed-slot compatibility stops leave per-account history', async () => {
  const f = await prepared(instant('05:00:00'));
  try {
    const enrollment = f.state().history[0].enrollmentId;
    await f.call({name:'schedule', action:'enable'});
    f.services.reader.readCredential = () => ({kind:'blocked',scope:'global'});
    assert.equal((await f.call({name:'run'})).reason, 'reader_global_block');
    const cut = f.sends();
    let checks = 0;
    f.services.reader.checkCompatibility = () => ({kind:++checks === 1 ? 'ready' : 'blocked'});
    f.services.clock.setWall(instant('06:00:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'compatibility_blocked');
    const result = await f.call({name:'history',account:enrollment});
    assert.deepEqual(result.rows.slice(0,2).map(row => [row.status,row.reason,row.slot]), [
      ['skipped','compatibility_blocked','2026-11-12T08:00'],
      ['skipped','reader_global_block',undefined],
    ]);
    f.services.reader.checkCompatibility = () => ({kind:'ready'});
    assert.equal((await f.call({name:'tick'})).reason, 'slot_already_claimed');
    assert.equal(f.sends(),cut);
  } finally { f.cleanup(); }
});

test('preview and save reject close admissions without changing state, and allow a fourth slot', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    const before = fs.readFileSync(f.statePath, 'utf8');
    for (const today of [false, true]) {
      for (const preview of [false, true]) {
        const out = await f.call({ name:'schedule', action:'add', time:'08:14', today, preview });
        assert.equal(out.exitCode, 2);
        assert.equal(out.reason, 'schedule_spacing');
      }
    }
    const command = { name:'schedule', action:'add', time:'08:15' };
    const preview = await f.call({ ...command, preview:true });
    assert.equal(preview.reason, 'schedule_preview');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.deepEqual(preview.schedule.times, ['08:00', '08:15', '13:00', '18:00']);
    assert.deepEqual((await f.call(command)).schedule, preview.schedule);
    assert.equal(f.sends(), 1);
  } finally { f.cleanup(); }
});

test('spacing includes midnight and the full scheduled batch bound', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    const edit = (time, today = false) => f.call({name:'schedule', action:'add', time, today});
    assert.equal((await edit('00:05')).reason, 'schedule_updated');
    assert.equal((await edit('23:55')).reason, 'schedule_spacing');
    assert.equal((await edit('23:55', true)).reason, 'schedule_spacing');
    const config = JSON.parse(fs.readFileSync(f.configPath));
    const original = config.enrollments[0];
    config.enrollments.push(...Array.from({length:19}, (_, index) => ({
      ...original, enrollmentId:`extra_${index}`, routerAccountId:`extra_${index}`,
      identity:{accountId:`workspace_${index}`, userId:'user'},
    })));
    f.put(f.configPath, config);
    f.put(f.statePath, {...f.state(), configDigest:createHash('sha256').update(fs.readFileSync(f.configPath)).digest('hex')});
    assert.equal((await edit('08:15')).reason, 'schedule_spacing');
    assert.equal((await edit('08:16')).reason, 'schedule_updated');
  } finally { f.cleanup(); }
});


test('CLI guards against stale schedule revisions and replacement installations before mutations', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    f.services.context = { ...f.context, scriptPath:fileURLToPath(new URL('../warmup.mjs', import.meta.url)) };
    const status = (await execute(['status'], f.services)).json;
    assert.equal(status.scheduleRevision, 0);
    const guard = ['--expected-installation-id', status.installationId, '--expected-revision', '0'];
    const edit = ['schedule', 'add', '21:05'];
    assert.equal((await execute([...edit, '--preview', ...guard], f.services)).json.scheduleRevision, 0);
    assert.equal((await execute([...edit, ...guard], f.services)).json.scheduleRevision, 1);
    const before = fs.readFileSync(f.statePath, 'utf8');
    const stale = await execute(['schedule', 'enable', ...guard], f.services);
    assert.equal(stale.exitCode, 2);
    assert.equal(stale.json.reason, 'schedule_revision_conflict');
    const replacement = await execute(['run', '--expected-installation-id', 'replaced_installation'], f.services);
    assert.equal(replacement.exitCode, 2);
    assert.equal(replacement.json.reason, 'installation_id_mismatch');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(f.sends(), 1);
    assert.equal(f.reads(), 1);
  } finally { f.cleanup(); }
});

test('system-zone change explains skipped admissions and never replays a claimed local slot', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    let zone = 'Asia/Gaza';
    f.services.clock.zone = () => zone;
    assert.equal((await f.call({name:'schedule', action:'enable'})).exitCode, 0);
    f.services.clock.setWall(instant('10:58:00'));
    await f.call({name:'tick'});
    zone = 'Asia/Dubai';
    f.services.clock.setWall(instant('10:59:00'));
    const status = await f.call({name:'status'});
    assert.equal(status.schedule.zone, 'Asia/Dubai');
    assert.equal(status.lastTickZone, 'Asia/Gaza');
    assert.equal((await f.call({name:'tick'})).reason, 'zone_changed');
    assert.equal(f.state().slotLedger['2026-11-12T13:00'].cause, 'zone_changed');
    assert.equal(f.state().slotLedger['2026-11-12T13:00'].zone, 'Asia/Dubai');
    assert.equal(f.sends(), 1);
    f.services.clock.setWall(instant('14:00:00'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    assert.equal(f.state().slots['2026-11-12T18:00'].zone, 'Asia/Dubai');
    assert.equal((await f.call({name:'history'})).rows[0].zone, 'Asia/Dubai');
    zone = 'Asia/Gaza';
    await f.call({name:'tick'});
    f.services.clock.setWall(instant('16:00:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'slot_already_claimed');
    assert.equal(f.sends(), 2);
  } finally { f.cleanup(); }
});

test('reviewed legacy to local migration keeps prior claims, reservations, and high-water keys', async () => {
  const f = await prepared(instant('05:00:00'));
  try {
    f.services.clock.zone = () => 'Asia/Dubai';
    const config = JSON.parse(fs.readFileSync(f.configPath));
    config.schedule.zone = 'Asia/Gaza';
    f.put(f.configPath, config);
    f.put(f.statePath, {...f.state(), configDigest:createHash('sha256').update(fs.readFileSync(f.configPath)).digest('hex')});
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('06:00:00'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    await f.call({name:'schedule', action:'disable'});
    const before = f.state();
    const compatibility = JSON.parse(fs.readFileSync(path.join(f.companionRoot, 'compatibility.json')));
    config.schedule.zone = 'local';
    const file = path.join(f.root, 'migration-candidate.json');
    const apply = reviewEvidence => {
      f.put(file, {schemaVersion:1, config, compatibility:{...compatibility, reviewEvidence}, reviewEvidence});
      return f.call({name:'maintain', file});
    };
    assert.equal((await apply(compatibility.reviewEvidence)).reason, 'new_review_required');
    assert.equal((await apply('local-zone-review')).reason, 'maintenance_applied');
    const migrated = f.state();
    for (const field of ['slots', 'reservations', 'highWater', 'history', 'pilots']) assert.deepEqual(migrated[field], before[field]);
    assert.equal(migrated.scheduleEnabled, false);
    const status = await f.call({name:'status'});
    assert.equal(status.schedule.zone, 'Asia/Dubai');
    assert.equal(status.lastTickZone, 'Asia/Gaza');
  } finally { f.cleanup(); }
});

test('manual overlap requires an explicit override and records a fully occupied slot', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('05:59:20'));
    f.services.context = {...f.context, scriptPath:fileURLToPath(new URL('../warmup.mjs', import.meta.url))};
    const status = (await execute(['status'], f.services)).json;
    assert.deepEqual(status.next, {slot:'2026-11-12T08:00', admission:'08:00', date:'2026-11-12', at:instant('06:00:00')});
    const before = fs.readFileSync(f.statePath, 'utf8');
    const refused = await execute(['run'], f.services);
    assert.deepEqual([refused.exitCode, refused.json.reason, refused.json.attempted], [3, 'slot_overlap_risk', 0]);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(refused.json.overlap.at, instant('06:00:00'));
    // An override scoped to another instant (a moved admission, the other fall-back occurrence)
    // does not apply to the next one.
    const scopedElsewhere = await execute(['run', '--allow-slot-overlap', '--overlap-at', String(instant('06:01:00'))], f.services);
    assert.deepEqual([scopedElsewhere.exitCode, scopedElsewhere.json.reason, scopedElsewhere.json.attempted], [3, 'slot_overlap_risk', 0]);
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(f.reads(), 1);
    f.services.probe = async () => {
      f.services.clock.advance(105000);
      return {outcome:'success', reason:'marker_confirmed', dispatched:true};
    };
    assert.equal((await execute(['run', '--allow-slot-overlap', '--overlap-at', String(instant('06:00:00'))], f.services)).exitCode, 0);
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
    const row = f.state().slotLedger['2026-11-12T08:00'];
    assert.equal(row.cause, 'manual_run_overlap');
    assert.equal(row.evidence.manualStartedAt, instant('05:59:20'));
    assert.equal(row.evidence.manualEndedAt, instant('06:01:05'));
    assert.deepEqual(f.state().slots, {});
  } finally { f.cleanup(); }
});

test('a repeated system-local DST hour claims the same logical slot only once', async () => {
  const f = await prepared(Date.parse('2026-10-31T18:00:00Z'));
  try {
    f.services.clock.zone = () => 'America/New_York';
    await f.call({name:'schedule', action:'add', time:'01:30'});
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(Date.parse('2026-11-01T05:30:00Z'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    f.services.clock.setWall(Date.parse('2026-11-01T06:30:00Z'));
    assert.equal((await f.call({name:'tick'})).reason, 'slot_already_claimed');
    assert.deepEqual(Object.keys(f.state().slots), ['2026-11-01T01:30']);
    assert.equal(f.sends(), 2);
  } finally { f.cleanup(); }
});

test('slot ledger records observed compatibility, disabled, and unknown tick gaps without credential reads', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    f.services.clock.setWall(instant('06:00:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'schedule_disabled');
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('11:00:00'));
    f.services.reader.checkCompatibility = () => ({kind:'blocked'});
    assert.equal((await f.call({name:'tick'})).reason, 'compatibility_blocked');
    assert.equal((await f.call({name:'status'})).compatibilityBlockedSince, instant('11:00:00'));
    f.services.clock.setWall(instant('17:00:00'));
    f.services.reader.checkCompatibility = () => ({kind:'ready'});
    await f.call({name:'tick'});
    const rows = f.state().slotLedger;
    assert.equal(rows['2026-11-12T08:00'].cause, 'schedule_disabled');
    assert.equal(rows['2026-11-12T13:00'].cause, 'compatibility_blocked');
    assert.equal(rows['2026-11-12T18:00'].cause, 'no_tick_between');
    assert.deepEqual(rows['2026-11-12T18:00'].evidence, {previousTick:instant('11:00:00'), tick:instant('17:00:00'), previousZone:'Asia/Gaza'});
    assert.equal(f.reads(), 1);
    assert.equal(f.sends(), 1);
  } finally { f.cleanup(); }
});

test('status computes next from a real local admission and skips a nonexistent DST minute', async () => {
  const f = await prepared(Date.parse('2027-03-13T18:00:00Z'));
  try {
    f.services.clock.zone = () => 'America/New_York';
    assert.equal((await f.call({name:'schedule', action:'add', time:'02:30'})).reason, 'schedule_updated');
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(Date.parse('2027-03-14T06:50:00Z'));
    await f.call({name:'tick'});
    assert.deepEqual((await f.call({name:'status'})).next, {slot:'2027-03-14T08:00', admission:'08:00', date:'2027-03-14', at:Date.parse('2027-03-14T12:00:00Z')});
    f.services.clock.setWall(Date.parse('2027-03-14T07:15:00Z'));
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
    assert.deepEqual(f.state().slots, {});
    assert.equal(f.state().slotLedger?.['2027-03-14T02:30'], undefined);
    assert.equal((await f.call({name:'status'})).slotObservation, null);
    assert.equal(f.sends(), 1);
  } finally { f.cleanup(); }
});

test('status distinguishes a proven scheduled runner from an interrupted batch and exposes a clock hold', async () => {
  const f = await prepared(instant('05:00:00'));
  const work = path.join(f.companionRoot, 'work.lock');
  try {
    await f.call({name:'schedule', action:'enable'});
    const state = f.state();
    state.lastWall = f.services.clock.wall() + 30 * 86400000;
    state.activeBatch = {slot:'2026-11-12T08:00', enrollmentIds:[], zone:'Asia/Gaza'};
    f.put(f.statePath, state);
    fs.mkdirSync(work, {mode:0o700});
    const owner = {...f.owner, installationId:state.installationId};
    f.put(path.join(work, 'owner.json'), owner);
    let alive = true;
    f.services.processes.inspect = () => alive ? 'alive' : 'dead';
    f.services.jobs.runner = async () => alive ? {...owner, scheduled:true} : null;
    const before = fs.readFileSync(f.statePath, 'utf8');
    const running = await f.call({name:'status'});
    assert.deepEqual(running.clockHold, {lastWall:state.lastWall, highWater:null});
    assert.equal(running.next, null);
    assert.equal(running.activeBatch.state, 'running');
    alive = false;
    assert.equal((await f.call({name:'status'})).activeBatch.state, 'interrupted');
    assert.equal(fs.readFileSync(f.statePath, 'utf8'), before);
    assert.equal(f.reads(), 1);
  } finally { f.cleanup(); }
});


test('a DST-shortened gap between scheduled admissions never sends a second batch early', async () => {
  const f = await prepared(Date.parse('2027-03-13T18:00:00Z'));
  try {
    f.services.clock.zone = () => 'America/New_York';
    for (const time of ['01:55', '03:05']) assert.equal((await f.call({name:'schedule', action:'add', time})).reason, 'schedule_updated');
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(Date.parse('2027-03-14T06:55:00Z'));
    assert.equal((await f.call({name:'tick'})).attempted, 1);
    f.services.clock.setWall(Date.parse('2027-03-14T07:05:00Z'));
    assert.equal((await f.call({name:'tick'})).reason, 'schedule_spacing');
    assert.equal(f.state().slotLedger['2027-03-14T03:05'].cause, 'schedule_spacing');
    assert.deepEqual(Object.keys(f.state().slots), ['2027-03-14T01:55']);
    assert.equal(f.sends(), 2);
  } finally { f.cleanup(); }
});

test('normal pause and resume explain admissions missed while the scheduler job was unloaded', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('05:55:00'));
    await f.call({name:'tick'});
    assert.equal((await f.call({name:'schedule', action:'disable'})).reason, 'schedule_disabled');
    f.services.clock.setWall(instant('06:05:00'));
    assert.equal((await f.call({name:'schedule', action:'enable'})).reason, 'schedule_enabled');
    const status = await f.call({name:'status'});
    const ledger = status.slotLedger.find(row => row.slot === '2026-11-12T08:00');
    assert.equal(ledger?.cause, 'schedule_disabled');
    assert.equal(ledger.evidence.pauseStartedAt, instant('05:55:00'));
    assert.equal(ledger.evidence.tick, instant('06:05:00'));
    assert.equal((await f.call({name:'tick'})).reason, 'outside_admission_minute');
    assert.equal(f.sends(), 1);
  } finally { f.cleanup(); }
});

test('interrupted resume preserves the pause and its ledger across a retry', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('05:55:00'));
    await f.call({name:'schedule', action:'disable'});
    f.services.clock.setWall(instant('06:05:00'));
    let faulted = false;
    f.services.fault = point => {
      if (!faulted && point === 'after_state.json_rename' && f.state().scheduleEnabled) {
        faulted = true;
        throw new Error('synthetic resume failure after the ledger write');
      }
    };
    assert.equal((await f.call({name:'schedule', action:'enable'})).exitCode, 2);
    assert.equal(faulted, true);
    delete f.services.fault;
    const failed = await f.call({name:'status'});
    assert.equal(failed.scheduleEnabled, false);
    assert.equal(failed.job, 'absent');
    assert.equal(failed.slotLedger[0].cause, 'schedule_disabled');
    assert.equal(f.state().schedulePause.at, instant('05:55:00'));
    assert.equal((await f.call({name:'schedule', action:'enable'})).exitCode, 0);
    assert.deepEqual((await f.call({name:'status'})).slotLedger, failed.slotLedger);
    assert.equal(f.sends(), 1);
  } finally { f.cleanup(); }
});

test('R3 dispatched probe usage windows are stored per row and status shows the latest per account', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    const resetsAt = instant('06:30:00');
    f.services.probe = async () => ({outcome:'success', reason:'marker_confirmed', dispatched:true,
      usage:{primary:{usedPercent:42, windowMinutes:300, resetsAt, extra:'CANARY'}, tertiary:{usedPercent:1}}});
    assert.equal((await f.call({name:'run'})).exitCode, 0);
    const row = f.state().history.at(-1);
    assert.deepEqual(row.usage, {primary:{usedPercent:42, windowMinutes:300, resetsAt}, observedAt: row.at});
    const status = await f.call({name:'status'});
    assert.deepEqual(status.accounts[0].usage, {primary:{usedPercent:42, windowMinutes:300, resetsAt}, observedAt: row.at});
    assert.equal(JSON.stringify(status).includes('CANARY'), false);
    // An undispatched result carries no usage evidence and does not replace the last one.
    f.services.clock.advance(60000);
    f.services.probe = async () => ({outcome:'blocked', reason:'transport_before_send', dispatched:false, usage:{primary:{usedPercent:99}}});
    await f.call({name:'run'});
    assert.equal(f.state().history.at(-1).usage, undefined);
    assert.deepEqual((await f.call({name:'status'})).accounts[0].usage.primary.usedPercent, 42);
  } finally { f.cleanup(); }
});

test('R3 the unscoped override still works for existing scripts', async () => {
  const f = await prepared(instant('02:40:00'));
  try {
    await f.call({name:'schedule', action:'enable'});
    f.services.clock.setWall(instant('05:59:20'));
    f.services.context = {...f.context, scriptPath:fileURLToPath(new URL('../warmup.mjs', import.meta.url))};
    assert.equal((await execute(['run'], f.services)).json.reason, 'slot_overlap_risk');
    f.services.probe = async () => ({outcome:'success', reason:'marker_confirmed', dispatched:true});
    const out = await execute(['run', '--allow-slot-overlap'], f.services);
    assert.deepEqual([out.exitCode, out.json.reason], [0, 'run_complete']);
  } finally { f.cleanup(); }
});
