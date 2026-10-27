// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import fs from 'node:fs';
import {syncBuiltinESMExports} from 'node:module';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createPushGateway,PushError} from '../apns-sender.mjs';

test('push database is private before permission tightening even with a permissive umask',()=>{
  const dir=mkdtempSync(join(tmpdir(),'tincall-push-permissions-')),path=join(dir,'push.sqlite');
  const chmod=fs.chmodSync,mask=process.umask(0o022);let gateway;
  fs.chmodSync=(file,mode)=>{assert.equal(fs.statSync(file).mode & 0o777,0o600);return chmod(file,mode);};
  syncBuiltinESMExports();
  try {gateway=createPushGateway({databasePath:path,token:'synthetic-permissions-token-at-least-24',send:async()=>{}});}
  finally {gateway?.close();fs.chmodSync=chmod;syncBuiltinESMExports();process.umask(mask);rmSync(dir,{recursive:true,force:true});}
});

test('trial expiry prevents new incoming pushes and a purchased rebind clears the deadline',async t=>{
  let now=1800000000000, sent=0;
  t.mock.method(Date,'now',()=>now);
  const dir=mkdtempSync(join(tmpdir(),'tincall-push-expiry-'));
  const token='synthetic-expiry-service-token-at-least-24';
  const gateway=createPushGateway({databasePath:join(dir,'push.sqlite'),token,send:async()=>{sent++;}});
  t.after(()=>{gateway.close();rmSync(dir,{recursive:true,force:true});});
  async function post(path,body){const r=await gateway.handle(new Request(`http://localhost${path}`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body)}));return {status:r.status,body:await r.json()};}
  const device={owner_id:crypto.randomUUID(),device_id:crypto.randomUUID(),device_token:'a'.repeat(64),environment:'sandbox'};
  const registered=await post('/devices',{...device,calls_valid_until:new Date(now+35000).toISOString()});
  assert.equal(registered.body.call_access_expiry,true);
  const call={owner_id:device.owner_id,binding_id:registered.body.binding_id,call_id:crypto.randomUUID(),contact_id:'synthetic',source:'mcp',event:'incoming_call'};
  assert.equal((await post('/push',call)).status,200);
  now+=35000;
  assert.equal((await post('/push',{...call,call_id:crypto.randomUUID()})).body.error.code,'call_access_expired');
  assert.equal(sent,1);
  await post('/devices',{...device,calls_valid_until:null});
  assert.equal((await post('/push',{...call,call_id:crypto.randomUUID()})).status,200);
  assert.equal(sent,2);
  assert.equal((await post('/devices',{...device,calls_valid_until:'invalid'})).status,400);
});

test('push gateway binds devices to owners, deduplicates accepted delivery and reports APNs failure',async()=>{
  const dir=mkdtempSync(join(tmpdir(),'tincall-push-test-'));let sent=0;let fail=false;let sentDevice;
  const token='fixture-server-token-with-at-least-24-characters';
  const gateway=createPushGateway({databasePath:join(dir,'push.sqlite'),token,send:async(device)=>{sent++;sentDevice=device;if(fail)throw new PushError('apns_rejected',502);}});
  async function post(path,body){const r=await gateway.handle(new Request(`http://localhost${path}`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body)}));return {status:r.status,body:await r.json()};}
  try{
    const owner=crypto.randomUUID();const device=crypto.randomUUID();
    const registered=await post('/devices',{owner_id:owner,device_id:device,device_token:'a'.repeat(64),environment:'sandbox'});assert.equal(registered.status,200);
    const payload={owner_id:owner,binding_id:registered.body.binding_id,device_id:crypto.randomUUID(),call_id:crypto.randomUUID(),contact_id:'fixture-role',source:'backend',event:'incoming_call'};
    assert.equal((await post('/push',{...payload,owner_id:crypto.randomUUID()})).status,404);
    assert.equal((await post('/push',payload)).body.accepted_by_apns,true);
    assert.equal(sentDevice.device_id,device);
    assert.equal((await post('/push',payload)).body.accepted_by_apns,true);assert.equal(sent,1);
    assert.equal((await post('/push',{...payload,call_id:crypto.randomUUID()})).status,200);
    const second=await post('/devices',{owner_id:owner,device_id:crypto.randomUUID(),device_token:'b'.repeat(64),environment:'production'});
    fail=true;const failed=await post('/push',{...payload,binding_id:second.body.binding_id,call_id:crypto.randomUUID()});assert.equal(failed.status,502);assert.equal(failed.body.error.code,'apns_rejected');
    await post('/devices/remove',{owner_id:owner,device_id:device});assert.equal((await post('/push',payload)).status,404);
  }finally{gateway.close();rmSync(dir,{recursive:true,force:true});}
});


test('immediate redial delivers new calls without a cooldown while duplicate retries stay deduplicated',async t=>{
  t.mock.method(Date,'now',()=>1800000000000);
  const dir=mkdtempSync(join(tmpdir(),'tincall-push-redial-'));
  let sent=0;
  const token='synthetic-redial-service-token-at-least-24';
  const gateway=createPushGateway({databasePath:join(dir,'push.sqlite'),token,send:async()=>{sent++;}});
  t.after(()=>{gateway.close();rmSync(dir,{recursive:true,force:true});});
  async function post(path,body){const r=await gateway.handle(new Request(`http://localhost${path}`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(body)}));return {status:r.status,body:await r.json()};}
  const device={owner_id:crypto.randomUUID(),device_id:crypto.randomUUID(),device_token:'a'.repeat(64),environment:'sandbox'};
  const registered=await post('/devices',device);
  const call={owner_id:device.owner_id,binding_id:registered.body.binding_id,call_id:crypto.randomUUID(),contact_id:'synthetic',source:'mcp',event:'incoming_call'};
  assert.equal((await post('/push',call)).status,200);
  const redial={...call,call_id:crypto.randomUUID()};
  assert.equal((await post('/push',redial)).status,200,'a new call immediately after the previous one must reach APNs');
  assert.equal((await post('/push',redial)).status,200);
  assert.equal(sent,2,'retrying the same call must not ring twice');
  for(let count=2;count<12;count++)assert.equal((await post('/push',{...call,call_id:crypto.randomUUID()})).status,200);
  assert.equal((await post('/push',redial)).status,200);
  assert.equal(sent,12);
});
