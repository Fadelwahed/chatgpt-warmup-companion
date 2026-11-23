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


function aliasFiles(aliases) {
 const translate=p=>{for(const [alias,target] of aliases)if(p===alias||p.startsWith(alias+path.sep))return target+p.slice(alias.length);return p;};
 return {...fs,lstatSync(p){return fs.lstatSync(translate(p));}};
}
function markerPaths(f,change){const marker=JSON.parse(fs.readFileSync(f.markerPath));change(marker);put(f.markerPath,marker);}

test('physical aliases in either ancestor direction and a missing descendant block before effects',async()=>{
 for(const kind of ['same','external_ancestor','external_descendant','missing_descendant']){
  const f=await prepared();try{
   const alias=path.join(f.root,'physical_alias');let target=f.companionRoot;
   if(kind==='external_ancestor')target=f.root;
   if(kind==='external_descendant')fs.mkdirSync(path.join(f.companionRoot,'inside'),{mode:0o700});
   f.services.files=aliasFiles([[alias,target]]);
   markerPaths(f,m=>{m.paths.stateRoot=kind==='missing_descendant'?path.join(alias,'missing'):kind==='external_descendant'?path.join(alias,'inside'):alias;});
   let reads=0,sends=0;f.services.reader.readCredential=()=>{reads++;};f.services.probe=async()=>{sends++;};
   const before=fs.readFileSync(f.statePath,'utf8');const out=await f.call({name:'run'});
   assert.equal(out.exitCode,2,kind);assert.equal(reads,0);assert.equal(sends,0);assert.equal(fs.readFileSync(f.statePath,'utf8'),before);
  }finally{f.cleanup();}
 }
});

test('physical alias between plist and Router file or companion rejects',async()=>{
 for(const kind of ['plist_companion','plist_router_file']){
  const f=await prepared();try{
   const alias=path.join(f.root,'physical_alias');
   if(kind==='plist_companion'){
    f.services.files=aliasFiles([[alias,f.companionRoot]]);markerPaths(f,m=>{m.plistPath=path.join(alias,'owned.plist');});
   }else{
    const external=path.join(f.routerRoot,'router-file.json');put(external,{sentinel:true});
    const plist=path.join(f.launchAgents,'job.plist');put(plist,{sentinel:true});
    f.services.files=aliasFiles([[plist,external]]);markerPaths(f,m=>{m.plistPath=plist;m.paths.poolPath=external;});
   }
   const out=await f.call({name:'run'});assert.equal(out.exitCode,2,kind);
  }finally{f.cleanup();}
 }
});

test('reviewed maintenance refuses aliased source before accepting candidate',async()=>{
 const f=await prepared();try{
  const alias=path.join(f.root,'alias');f.services.files=aliasFiles([[alias,f.companionRoot]]);
  const config=JSON.parse(fs.readFileSync(f.configPath));config.paths.stateRoot=alias;
  const compatibility=JSON.parse(fs.readFileSync(path.join(f.companionRoot,'compatibility.json')));compatibility.reviewEvidence='fresh';
  const candidate=path.join(f.root,'candidate.json');put(candidate,{schemaVersion:1,config,compatibility,reviewEvidence:'fresh'});
  const before=fs.readFileSync(f.configPath,'utf8'),stateBefore=fs.readFileSync(f.statePath,'utf8');
  const sentinel=path.join(f.launchAgents,'unrelated.plist');put(sentinel,{unrelated:true});let jobChanges=0,reads=0,sends=0;
  f.services.jobs.enable=async()=>{jobChanges++;};f.services.jobs.disable=async()=>{jobChanges++;};f.services.reader.readCredential=()=>{reads++;};f.services.probe=async()=>{sends++;};
  const out=await f.call({name:'maintain',file:candidate});
  assert.equal(out.exitCode,2);assert.equal(fs.readFileSync(f.configPath,'utf8'),before);assert.equal(fs.readFileSync(f.statePath,'utf8'),stateBefore);assert.deepEqual(JSON.parse(fs.readFileSync(sentinel)),{unrelated:true});assert.equal(jobChanges,0);assert.equal(reads,0);assert.equal(sends,0);
 }finally{f.cleanup();}
});

test('ordinary separated sibling paths and shared ancestors remain allowed',async()=>{
 const f=await prepared();try{const out=await f.call({name:'run'});assert.equal(out.exitCode,0);assert.equal(out.attempted,1);}finally{f.cleanup();}
});

test('first setup rejects physical alias before discovery or job mutation',async()=>{
 const f=await prepared();try{
  const alias=path.join(f.root,'alias');f.services.files=aliasFiles([[alias,f.companionRoot]]);
  markerPaths(f,m=>{m.phase='uninitialized';m.paths.stateRoot=alias;});fs.unlinkSync(f.configPath);fs.unlinkSync(f.statePath);
  let discovery=0,jobChanges=0;f.services.reader.readRegistry=()=>{discovery++;};f.services.jobs.enable=async()=>{jobChanges++;};f.services.jobs.disable=async()=>{jobChanges++;};
  const before=fs.readFileSync(f.markerPath,'utf8');const out=await f.call({name:'setup'});
  assert.equal(out.exitCode,2);assert.equal(discovery,0);assert.equal(jobChanges,0);assert.equal(fs.readFileSync(f.markerPath,'utf8'),before);assert.equal(fs.existsSync(f.configPath),false);
 }finally{f.cleanup();}
});

test('missing targets under the same physical parent remain conservatively blocked',async()=>{
 const f=await prepared();try{
  const alias=path.join(f.root,'alias');f.services.files=aliasFiles([[alias,f.routerRoot]]);
  markerPaths(f,m=>{m.plistPath=path.join(alias,'missing-job');m.paths.poolPath=path.join(f.routerRoot,'missing-pool');});
  assert.equal((await f.call({name:'run'})).exitCode,2);
 }finally{f.cleanup();}
});

test('modeled link and unavailable physical identity fail closed',async()=>{
 for(const mode of ['link','unknown']){
  const f=await prepared();try{
   f.services.files={...fs,lstatSync(file){const stat=fs.lstatSync(file);if(file!==f.routerRoot)return stat;if(mode==='link')return {...stat,isDirectory:()=>false,isSymbolicLink:()=>true};return {...stat,ino:undefined,isDirectory:()=>true,isSymbolicLink:()=>false};}};
   const out=await f.call({name:'run'});assert.equal(out.exitCode,2,mode);
  }finally{f.cleanup();}
 }
});
