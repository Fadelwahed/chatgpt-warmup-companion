import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import https from 'node:https';
import { EventEmitter } from 'node:events';
import { createHash } from 'node:crypto';
import { runCommand, recoverInstance } from '../runtime.mjs';
import { safeRead, revalidate } from '../router-reader.mjs';
import { probe, directRequest } from '../chatgpt-probe.mjs';
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

test('R2 recovery preserves backup cooldown and correction block',async()=>{
 const f=await prepared();try{
  const now=f.services.clock.wall(),state=f.state(),id=JSON.parse(fs.readFileSync(f.configPath)).enrollments[0].enrollmentId;
  const backup=structuredClone(state);backup.cooldowns[id]=now+3*86400000;backup.blocks[id]='authentication_rejected';
  const backupPath=path.join(f.root,'backup.json');put(backupPath,backup);
  assert.equal((await recoverInstance(f.context,f.services,{...f.decision(),backupPath})).exitCode,0);
  assert.equal(f.state().cooldowns[id],now+3*86400000);assert.equal(f.state().blocks[id],'authentication_rejected');
  const out=await f.call({name:'run'});assert.equal(out.attempted,0);assert.equal(out.results[0].reason,'cooldown');

 }finally{f.cleanup();}
});

test('R3 disable reports verified live manual contention as busy',async()=>{
 const f=await prepared();try{
  const dir=path.join(f.companionRoot,'work.lock');fs.mkdirSync(dir,{mode:0o700});
  put(path.join(dir,'owner.json'),{pid:9999,startId:'synthetic-manual',nonce:'manual',installationId:'install_final_audit_01'});
  f.services.processes.inspect=()=> 'alive';
  const out=await f.call({name:'schedule',action:'disable'});
  assert.equal(out.exitCode,3);assert.equal(out.reason,'lock_busy');assert.equal(out.disableCompleted,false);assert.equal(fs.existsSync(dir),true);

 }finally{f.cleanup();}
});

test('R4 final slot write failure preserves dispatch evidence',async()=>{
 const f=await prepared();try{
  await f.call({name:'run'});await f.call({name:'schedule',action:'enable'});
  let sends=0,armed=false;
  f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
  f.services.files={...fs,renameSync(from,to){if(to===f.statePath){const v=JSON.parse(fs.readFileSync(from));if(v.activeBatch===null&&v.lastSlotOutcome){armed=true;throw Error('synthetic finalization failure');}}return fs.renameSync(from,to);}};
  const out=await f.call({name:'tick'});
  assert.equal(armed,true);assert.equal(sends,1);assert.equal(out.exitCode,2);assert.equal(out.selected,1);assert.equal(out.attempted,1);assert.equal(out.results[0].reason,'marker_confirmed');
  assert.equal(f.state().history.at(-1).reason,'marker_confirmed');

 }finally{f.cleanup();}
});

test('R5 expiry margin is enforced after final local reads',async()=>{
 const f=makeFixture();try{
  const paths={sourceRoot:f.routerRoot,stateRoot:path.join(f.root,'state'),codexHome:path.join(f.root,'codex'),homesDir:path.join(f.root,'state/homes'),poolPath:path.join(f.root,'state/pool.json'),switchPath:path.join(f.root,'state/switch.json'),discoveryPath:path.join(f.root,'state/discovery.json')};
  for(const d of [paths.stateRoot,paths.codexHome,paths.homesDir])fs.mkdirSync(d,{mode:0o700});
  const sourceDigests={};fs.mkdirSync(path.join(f.routerRoot,'src'),{mode:0o700});
  for(let i=0;i<13;i++){const name=`src/contract-${i}.mjs`,bytes=`// synthetic ${i}`;fs.writeFileSync(path.join(f.routerRoot,name),bytes,{mode:0o600});sourceDigests[name]=createHash('sha256').update(bytes).digest('hex');}
  const compatibility={schemaVersion:1,reviewedRevision:'a'.repeat(40),sourceDigests,adapterVersion:1,requestContractVersion:1,sourcePathContract:'synthetic',reviewEvidence:'synthetic-review',semantics:'equivalent'};
  const id='acct_abcdefgh',identity={accountId:'workspace-a',userId:'user-a'};
  put(paths.poolPath,{version:1,policy:{enabled:true,mode:'switch'},accounts:{[id]:{id,state:'active',paused:false,priority:0,health:{state:'healthy'},turns:0,requests:0,identity}},sessions:{}});
  fs.mkdirSync(path.join(paths.homesDir,id),{mode:0o700});
  const jwt=value=>`x.${Buffer.from(JSON.stringify(value)).toString('base64url')}.x`;
  const expiry=f.services.clock.wall()+120000;
  put(path.join(paths.homesDir,id,'auth.json'),{tokens:{account_id:identity.accountId,access_token:jwt({exp:expiry/1000}),id_token:jwt({sub:identity.userId})}});
  put(f.markerPath,{schemaVersion:1,installationId:'install_audit_real_01',phase:'uninitialized',paths,plistPath:f.plistPath});put(path.join(f.companionRoot,'compatibility.json'),compatibility);
  f.services.source={inspect:()=>({revision:compatibility.reviewedRevision,dirtyPaths:[]})};
  const context={root:f.companionRoot,nodePath:'/opt/homebrew/opt/node@22/bin/node',scriptPath:'/synthetic/warmup.mjs'};
  assert.equal((await runCommand({name:'setup'},context,f.services)).exitCode,0);
  let checks=0,afterFinal=false,advanced=false,remaining;
  f.services.reader={revalidate:(...args)=>{const out=revalidate(...args);assert.equal(out.kind,'ready');if(++checks===2)afterFinal=true;return out;}};
  f.services.files={...fs,lstatSync(file){if(afterFinal&&!advanced){advanced=true;f.services.clock.advance(1000);}return fs.lstatSync(file);}};
  f.services.request=async(_options,_body,control)=>{control.beforeSend();remaining=expiry-f.services.clock.wall(); control.onDispatch();return {statusCode:200,headers:{},body:[Buffer.from(`data: ${JSON.stringify({type:'response.completed',response:{status:'completed',output:[{type:'message',role:'assistant',content:[{type:'output_text',text:'WARMUP_OK'}]}]}})}\n\n`)]};};
  const out=await runCommand({name:'run'},context,f.services);
  assert.equal(checks,2);assert.equal(out.attempted,0);assert.equal(out.exitCode,1);assert.equal(remaining,undefined);assert.equal(out.results[0].reason,'credential_expired_or_unknown');

 }finally{f.cleanup();}
});


test('recovery merges cooldown maxima, correction blocks and ordered unique large history',async()=>{
 const f=await prepared();try{
  const state=f.state(), id=JSON.parse(fs.readFileSync(f.configPath)).enrollments[0].enrollmentId, now=f.services.clock.wall();
  state.cooldowns[id]=now+400000;state.blocks[id]='output_mismatch';
  state.history=Array.from({length:3000},(_,i)=>({enrollmentId:id,outcome:'blocked',reason:`current_${i}`,at:now+i}));
  put(f.statePath,state);const backup=structuredClone(state);
  backup.cooldowns[id]=now+500000;backup.blocks[id]='authentication_rejected';
  backup.history=[{enrollmentId:id,outcome:'blocked',reason:'first',at:now},...state.history.slice(0,1500)];
  const backupPath=path.join(f.root,'backup.json');put(backupPath,backup);
  assert.equal((await recoverInstance(f.context,f.services,{...f.decision(),backupPath})).exitCode,0);
  const recovered=f.state();assert.equal(recovered.cooldowns[id],now+500000);
  assert.ok(recovered.blocks[id]);assert.deepEqual(recovered.pilots,{});assert.equal(recovered.scheduleEnabled,false);
  assert.deepEqual(recovered.history,[backup.history[0],...state.history]);
 }finally{f.cleanup();}
});

test('tick preserves results when post-run reload fails and never replays',async()=>{
 const f=await prepared();try{
  await f.call({name:'run'});await f.call({name:'schedule',action:'enable'});
  let sends=0,fail=false;f.services.probe=async()=>{sends++;fail=true;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
  f.services.files={...fs,openSync(file,...args){if(fail && file===f.statePath){fail=false;throw Error('secret upstream detail');}return fs.openSync(file,...args);}};
  // Arm failure after the durable result, rather than during its persistence.
  f.services.files.renameSync=(from,to)=>{const v=to===f.statePath?JSON.parse(fs.readFileSync(from)):null;const out=fs.renameSync(from,to);if(v?.history?.length===2 && v.activeBatch) fail=true;return out;};
  f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
  const out=await f.call({name:'tick'});assert.equal(out.exitCode,2);assert.equal(out.attempted,1);assert.equal(out.results[0].reason,'marker_confirmed');assert.ok(!JSON.stringify(out).includes('secret'));
  assert.equal((await f.call({name:'tick'})).reason,'slot_already_claimed');assert.equal(sends,1);
 }finally{f.cleanup();}
});

test('ownership isolation rejects an external root ancestor alias before effects',async()=>{
 const f=await prepared();try{
  let reads=0,sends=0,jobCalls=0;
  const original=f.services.reader.readCredential;f.services.reader.readCredential=(...args)=>{reads++;return original(...args);};
  f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
  const inspect=f.services.jobs.inspect.bind(f.services.jobs);f.services.jobs.inspect=async(...args)=>{jobCalls++;return inspect(...args);};
  const router=f.routerRoot;f.services.files={...fs,lstatSync(file){if(file===router)return {isDirectory:()=>false,isSymbolicLink:()=>true};return fs.lstatSync(file);}};
  const out=await f.call({name:'run'});assert.equal(out.exitCode,2);assert.equal(reads,0);assert.equal(sends,0);assert.equal(jobCalls,0);
 }finally{f.cleanup();}
});

test('tick preserves dispatch evidence if releasing its guard fails',async()=>{
 const f=await prepared();try{
  await f.call({name:'run'});await f.call({name:'schedule',action:'enable'});
  let sends=0,armed=false;f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
  f.services.files={...fs,renameSync(from,to){const v=to===f.statePath?JSON.parse(fs.readFileSync(from)):null;const result=fs.renameSync(from,to);if(v?.lastSlotOutcome&&v.activeBatch===null)armed=true;return result;},unlinkSync(file){if(armed&&file.endsWith('/work.lock/owner.json')){armed=false;throw Error('synthetic secret');}return fs.unlinkSync(file);}};
  const out=await f.call({name:'tick'});assert.equal(out.exitCode,2);assert.equal(out.reason,'lock_release_failed');assert.equal(out.attempted,1);assert.equal(out.results[0].reason,'marker_confirmed');assert.equal(sends,1);assert.ok(!JSON.stringify(out).includes('synthetic secret'));
 }finally{f.cleanup();}
});

test('missing or nonfinite expiry never enters the probe',async()=>{
 for(const expiry of [undefined,NaN,Infinity]){
  const f=await prepared();try{
   let sends=0;f.services.reader.readCredential=()=>({kind:'ready',expiresAt:expiry,snapshot:{}});f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
   const out=await f.call({name:'run'});assert.equal(out.attempted,0);assert.equal(out.results[0].reason,'credential_expired_or_unknown');assert.equal(sends,0);
  }finally{f.cleanup();}
 }
});

test('replacement of companion ancestor before later reads blocks dispatch',async()=>{
 const f=await prepared();try{
  let changed=false,sends=0;const original=f.services.reader.revalidate;f.services.reader.revalidate=(...args)=>{changed=true;return original(...args);};
  f.services.probe=async()=>{sends++;return {outcome:'success',reason:'marker_confirmed',dispatched:true};};
  f.services.files={...fs,lstatSync(file){if(changed&&file===f.root)return {isDirectory:()=>false,isSymbolicLink:()=>true};return fs.lstatSync(file);}};
  const out=await f.call({name:'run'});assert.equal(out.exitCode,2);assert.equal(out.attempted,0);assert.equal(sends,0);
 }finally{f.cleanup();}
});
