import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { runCommand, recoverInstance } from '../runtime.mjs';
import { makeFixture } from './helpers.mjs';
const put=(file,value)=>fs.writeFileSync(file,JSON.stringify(value),{mode:0o600});
async function prepared() {
 const f=makeFixture();
 const paths={sourceRoot:f.routerRoot,stateRoot:f.routerRoot,codexHome:f.routerRoot,poolPath:path.join(f.routerRoot,'pool.json'),homesDir:f.routerRoot,switchPath:path.join(f.routerRoot,'switch.json'),discoveryPath:path.join(f.routerRoot,'discovery.json')};
 put(f.markerPath,{schemaVersion:1,installationId:'install_final_audit_01',phase:'uninitialized',paths,plistPath:f.plistPath});
 put(path.join(f.companionRoot,'compatibility.json'),{schemaVersion:1,reviewedRevision:'a'.repeat(40),sourceDigests:Object.fromEntries(Array.from({length:13},(_,i)=>[`src/f-${i}.mjs`,createHash('sha256').update(String(i)).digest('hex')])),adapterVersion:1,requestContractVersion:1,sourcePathContract:'synthetic',reviewEvidence:'synthetic-review',semantics:'equivalent'});
 const identity={accountId:'workspace-a',userId:'user-a'};
 f.services.reader={readRegistry:()=>({kind:'ready',coordination:'idle',accounts:[{routerAccountId:'router_a',eligible:true}]}),discoverIdentity:()=>({kind:'ready',identity}),checkCompatibility:()=>({kind:'ready'}),readCredential:()=>({kind:'ready',identity,accessToken:'SYNTHETIC',expiresAt:f.services.clock.wall()+120000,snapshot:{}}),revalidate:()=>({kind:'ready'})};
 f.services.probe=async()=>({outcome:'success',reason:'marker_confirmed',dispatched:true});
 const context={root:f.companionRoot,nodePath:'/opt/homebrew/opt/node@22/bin/node',scriptPath:'/synthetic/warmup.mjs'};
 const call=command=>runCommand(command,context,f.services);
 assert.equal((await call({name:'setup'})).exitCode,0);
 return {...f,context,call,state:()=>JSON.parse(fs.readFileSync(f.statePath)),decision:()=>{const s=fs.lstatSync(f.companionRoot);return {installationId:'install_final_audit_01',rootDev:s.dev,rootIno:s.ino,skipThrough:'2026-11-12T18:00',reviewEvidence:'explicit synthetic review',backupPath:null};}};
}


async function interrupted() {
 const f=await prepared();
 const baseConfigPath=path.join(f.root,'base-config.json'),baseCompatibilityPath=path.join(f.root,'base-compatibility.json');
 fs.copyFileSync(f.configPath,baseConfigPath);fs.copyFileSync(path.join(f.companionRoot,'compatibility.json'),baseCompatibilityPath);
 const config=JSON.parse(fs.readFileSync(baseConfigPath));config.enrollments[0].model='gpt-6-sol';
 const candidate={schemaVersion:1,config,compatibility:JSON.parse(fs.readFileSync(baseCompatibilityPath)),reviewEvidence:'synthetic-review'};
 const candidatePath=path.join(f.root,'candidate.json');put(candidatePath,candidate);
 const decision={...f.decision(),intendedPair:{path:candidatePath,sha256:createHash('sha256').update(fs.readFileSync(candidatePath)).digest('hex'),baseConfigPath,baseCompatibilityPath}};
 f.services.fault=point=>{if(point==='after_config.json_rename')throw Error('synthetic crash');};
 assert.equal((await f.call({name:'maintain',file:candidatePath})).exitCode,2);delete f.services.fault;
 return {...f,decision,candidate};
}
test('reviewed intended pair completes interrupted maintenance with disabled state',async()=>{
 const f=await interrupted();try{
  const out=await recoverInstance(f.context,f.services,f.decision);assert.equal(out.exitCode,0);assert.equal(out.reason,'recovered_disabled');assert.equal(out.reconciledPair,true);
  const state=f.state();assert.equal(state.scheduleEnabled,false);assert.deepEqual(state.pilots,{});
  assert.deepEqual(JSON.parse(fs.readFileSync(f.configPath)),f.candidate.config);
  assert.equal((await f.call({name:'status'})).exitCode,0);
 }finally{f.cleanup();}
});

test('each recovery write fault retains protections and the same decision retries',async()=>{
 const hooks=['before_create','after_create','after_write','after_fsync','before_rename','after_rename_before_dirsync','after_rename'];
 for(const [file,ordinal] of [['state.json',1],['config.json',1],['compatibility.json',1],['state.json',2]]) for(const hook of hooks){
  const f=await interrupted();try{
   const before=f.state(), id=f.candidate.config.enrollments[0].enrollmentId, at=f.services.clock.wall()+360000;
   before.pilots['historical-pilot']={at:f.services.clock.wall()};before.cooldowns[id]=at;before.blocks[id]='authentication_rejected';before.history=[{enrollmentId:id,outcome:'uncertain',reason:'stream_or_transport_uncertain',at:f.services.clock.wall()}];put(f.statePath,before);
   let count=0;const point=hook.replace('create',`${file}_create`).replace('write',`${file}_write`).replace('fsync',`${file}_fsync`).replace('rename',`${file}_rename`);
   f.services.fault=p=>{if(p===point&&++count===ordinal)throw Error('synthetic crash');};
   let sends=0;f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
   const failed=await recoverInstance(f.context,f.services,f.decision);assert.equal(failed.exitCode,2,`${file}:${ordinal}:${hook}`);delete f.services.fault;
   const blocked=await f.call({name:'run'});assert.notEqual(blocked.exitCode,0);assert.equal(sends,0);
   const retry=await recoverInstance(f.context,f.services,f.decision);assert.equal(retry.exitCode,0,`${file}:${ordinal}:${hook} ${retry.reason}`);
   const after=f.state();assert.equal(after.scheduleEnabled,false);assert.deepEqual(after.pilots,{});assert.equal(after.cooldowns[id],at);assert.equal(after.blocks[id],'authentication_rejected');assert.equal(after.history.length,1);
  }finally{f.cleanup();}
 }
});

test('extension binds reviewed candidate and predecessor and rejects unrelated files',async()=>{
 for(const variant of ['digest','candidate','baseline','current','extra','relative']){
  const f=await interrupted();try{
   const d=structuredClone(f.decision);
   if(variant==='digest')d.intendedPair.sha256='0'.repeat(64);
   if(variant==='candidate'){const v=structuredClone(f.candidate);v.config.enrollments[0].identity.userId='changed';put(d.intendedPair.path,v);d.intendedPair.sha256=createHash('sha256').update(fs.readFileSync(d.intendedPair.path)).digest('hex');}
   if(variant==='baseline'){const v=JSON.parse(fs.readFileSync(d.intendedPair.baseConfigPath));v.enrollments[0].model='unreviewed';put(d.intendedPair.baseConfigPath,v);}
   if(variant==='current'){const v=JSON.parse(fs.readFileSync(f.configPath));v.enrollments[0].model='unrelated';put(f.configPath,v);}
   if(variant==='extra')d.intendedPair.extra=true;
   if(variant==='relative')d.intendedPair.path='candidate.json';
   const state=fs.readFileSync(f.statePath,'utf8');const out=await recoverInstance(f.context,f.services,d);assert.equal(out.exitCode,2,variant);assert.equal(fs.readFileSync(f.statePath,'utf8'),state,variant);
  }finally{f.cleanup();}
 }
});

test('completed target is idempotent with the same decision',async()=>{
 const f=await interrupted();try{
  assert.equal((await recoverInstance(f.context,f.services,f.decision)).exitCode,0);
  const again=await recoverInstance(f.context,f.services,f.decision);assert.equal(again.exitCode,0);assert.equal(again.reconciledPair,true);assert.deepEqual(f.state().pilots,{});
 }finally{f.cleanup();}
});

test('recovery rejects conflicting claims and reservations without altering state',async()=>{
 for(const field of ['slots','reservations']){
  const f=await prepared();try{
   const state=f.state(),backup=structuredClone(state),id='synthetic_id';
   if(field==='slots'){state.slots['2026-11-12T08:00']={enrollmentIds:[id],claimedAt:1};backup.slots['2026-11-12T08:00']={enrollmentIds:[id],claimedAt:2};state.highWater=backup.highWater='2026-11-12T08:00';}
   else {state.reservations.r={enrollmentId:id,identity:{accountId:'a',userId:'u'},at:1,possibleSend:true};backup.reservations.r={...state.reservations.r,at:2};}
   put(f.statePath,state);const backupPath=path.join(f.root,'backup.json');put(backupPath,backup);const old=fs.readFileSync(f.statePath,'utf8');
   const out=await recoverInstance(f.context,f.services,{...f.decision(),backupPath});assert.equal(out.reason,'recovery_history_conflict');assert.equal(fs.readFileSync(f.statePath,'utf8'),old);
  }finally{f.cleanup();}
 }
});

test('large merged history deduplicates in order and rejects overflow without pruning',async()=>{
 for(const overflow of [false,true]){
  const f=await prepared();try{
   const state=f.state(), backup=structuredClone(state);const entry=i=>({at:0,outcome:'uncertain',reason:`r${i}`});
   backup.history=Array.from({length:60000},(_,i)=>entry(i));state.history=Array.from({length:60000},(_,i)=>entry(i+(overflow?60000:30000)));
   put(f.statePath,state);const backupPath=path.join(f.root,'backup.json');put(backupPath,backup);const original=fs.readFileSync(f.statePath,'utf8');
   const out=await recoverInstance(f.context,f.services,{...f.decision(),backupPath});
   if(overflow){assert.equal(out.exitCode,2);assert.equal(fs.readFileSync(f.statePath,'utf8'),original);}
   else {assert.equal(out.exitCode,0);const history=f.state().history;assert.equal(history.length,90000);assert.equal(history[0].reason,'r0');assert.equal(history[59999].reason,'r59999');assert.equal(history[60000].reason,'r60000');assert.equal(history.at(-1).reason,'r89999');}
  }finally{f.cleanup();}
 }
});

test('recovery distinguishes live manual and ambiguous work guards',async()=>{
 for(const [status,code] of [['alive',3],['unknown',2],['reused',2]]){
  const f=await interrupted();try{
   const dir=path.join(f.companionRoot,'work.lock');fs.mkdirSync(dir,{mode:0o700});put(path.join(dir,'owner.json'),{pid:9999,startId:'manual',nonce:'manual',installationId:'install_final_audit_01'});
   f.services.processes.inspect=()=>status;let kills=0;f.services.processes.terminate=async()=>{kills++;};
   const out=await recoverInstance(f.context,f.services,f.decision);assert.equal(out.exitCode,code,status);assert.equal(kills,0);assert.ok(fs.existsSync(dir));
  }finally{f.cleanup();}
 }
});

test('candidate transition rejects unsupported changes and source review failures',async()=>{
 for(const change of ['cohort','schedule','field','rollback','source','unreviewed']){
  const f=await interrupted();try{
   const v=structuredClone(f.candidate);
   if(change==='cohort')v.config.enrollments.push({...v.config.enrollments[0],enrollmentId:'other',routerAccountId:'other',identity:{accountId:'different',userId:'different'}});
   if(change==='schedule')v.config.schedule.times=['01:00'];
   if(change==='field')v.extra='forbidden';
   if(change==='rollback'){const b=JSON.parse(fs.readFileSync(f.decision.intendedPair.baseCompatibilityPath));b.adapterVersion=2;put(f.decision.intendedPair.baseCompatibilityPath,b);const state=f.state();state.compatibilityDigest=createHash('sha256').update(fs.readFileSync(f.decision.intendedPair.baseCompatibilityPath)).digest('hex');put(f.statePath,state);}
   if(change==='source')v.compatibility.reviewedRevision='b'.repeat(40);
   if(change==='unreviewed')f.services.reader.checkCompatibility=()=>({kind:'blocked'});
   put(f.decision.intendedPair.path,v);f.decision.intendedPair.sha256=createHash('sha256').update(fs.readFileSync(f.decision.intendedPair.path)).digest('hex');
   const out=await recoverInstance(f.context,f.services,f.decision);assert.equal(out.exitCode,2,change);
  }finally{f.cleanup();}
 }
});

test('reviewed source relocation and supported missing target files reconcile',async()=>{
 for(const missing of [null,'config.json','compatibility.json']){
  const f=await interrupted();try{
   const dir=path.join(f.root,'relocated');fs.mkdirSync(dir,{mode:0o700});
   const v=structuredClone(f.candidate);v.config.paths.sourceRoot=dir;v.compatibility.reviewEvidence=v.reviewEvidence='fresh-synthetic-review';
   put(f.decision.intendedPair.path,v);f.decision.intendedPair.sha256=createHash('sha256').update(fs.readFileSync(f.decision.intendedPair.path)).digest('hex');
   fs.copyFileSync(f.decision.intendedPair.baseConfigPath,f.configPath);
   if(missing)fs.unlinkSync(path.join(f.companionRoot,missing));
   let discovery=0,reads=0,sends=0;f.services.reader.discoverIdentity=()=>{discovery++;};f.services.reader.readCredential=()=>{reads++;};f.services.probe=async()=>{sends++;};
   const out=await recoverInstance(f.context,f.services,f.decision);assert.equal(out.exitCode,0,missing??'relocation');assert.equal(discovery,0);assert.equal(reads,0);assert.equal(sends,0);assert.equal(f.state().scheduleEnabled,false);
  }finally{f.cleanup();}
 }
});

test('trusted probe expiry refusal remains a sanitized blocked result',async()=>{
 const f=await prepared();try{
  f.services.probe=async()=>({outcome:'blocked',reason:'credential_expired_or_unknown',dispatched:false});
  const out=await f.call({name:'run'});assert.equal(out.attempted,0);assert.equal(out.results[0].reason,'credential_expired_or_unknown');
 }finally{f.cleanup();}
});

test('merged state byte capacity is checked before writing',async()=>{
 const f=await prepared();try{
  const state=f.state(),backup=structuredClone(state),padding='x'.repeat(230);
  state.history=Array.from({length:40000},(_,i)=>({at:0,reason:`current_${i}`,padding}));
  backup.history=Array.from({length:40000},(_,i)=>({at:0,reason:`backup_${i}`,padding}));
  put(f.statePath,state);const old=fs.readFileSync(f.statePath,'utf8');const backupPath=path.join(f.root,'backup.json');put(backupPath,backup);
  const out=await recoverInstance(f.context,f.services,{...f.decision(),backupPath});assert.equal(out.reason,'state_capacity');assert.equal(fs.readFileSync(f.statePath,'utf8'),old);
 }finally{f.cleanup();}
});

test('recovery of an interrupted legacy zone migration keeps the previous tick zone', async () => {
  const f = await prepared();
  try {
    const config = JSON.parse(fs.readFileSync(f.configPath));
    config.schedule.zone = 'Asia/Gaza';
    put(f.configPath, config);
    const state = f.state();
    state.configDigest = createHash('sha256').update(fs.readFileSync(f.configPath)).digest('hex');
    state.lastTick = state.lastWall = f.services.clock.wall();
    put(f.statePath, state);
    const baseConfigPath = path.join(f.root, 'base-config.json');
    const baseCompatibilityPath = path.join(f.root, 'base-compatibility.json');
    const candidatePath = path.join(f.root, 'local-zone-candidate.json');
    fs.copyFileSync(f.configPath, baseConfigPath);
    fs.copyFileSync(path.join(f.companionRoot, 'compatibility.json'), baseCompatibilityPath);
    const compatibility = JSON.parse(fs.readFileSync(baseCompatibilityPath));
    const reviewEvidence = 'synthetic-zone-migration-review';
    config.schedule.zone = 'local';
    put(candidatePath, { schemaVersion:1, config, compatibility:{...compatibility, reviewEvidence}, reviewEvidence });
    f.services.clock.zone = () => 'Asia/Dubai';
    f.services.fault = point => { if (point === 'after_config.json_rename') throw Error('synthetic crash'); };
    assert.equal((await f.call({name:'maintain', file:candidatePath})).exitCode, 2);
    delete f.services.fault;
    const decision = {...f.decision(), intendedPair:{path:candidatePath, sha256:createHash('sha256').update(fs.readFileSync(candidatePath)).digest('hex'), baseConfigPath, baseCompatibilityPath}};
    assert.equal((await recoverInstance(f.context, f.services, decision)).exitCode, 0);
    const result = await f.call({name:'status'});
    assert.equal(result.schedule.zone, 'Asia/Dubai');
    assert.equal(result.lastTickZone, 'Asia/Gaza');
    assert.equal(result.scheduleRevision, 1);
    assert.equal(result.scheduleEnabled, false);
    assert.equal((await recoverInstance(f.context, f.services, decision)).exitCode, 0);
    assert.equal(f.state().scheduleRevision, 1);
  } finally { f.cleanup(); }
});
