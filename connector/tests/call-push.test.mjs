// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createCallJobs} from '../../supabase/functions/_shared/tincall/call-jobs.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

test('push jobs continue after one device fails and remove only confirmed obsolete bindings',async t=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-call-push-'));
  const store=createSQLiteStore({clients:[]},join(directory,'calls.sqlite'));
  t.after(()=>{store.close();rmSync(directory,{recursive:true,force:true});});
  const owner=crypto.randomUUID();const old='10000000-0000-4000-8000-000000000001';const good='10000000-0000-4000-8000-000000000002';
  const mutate=(action,payload)=>store.command(owner,action,{request_id:crypto.randomUUID(),...payload});
  await mutate('device.put',{device_id:old,binding_id:'old-binding'});
  await mutate('device.put',{device_id:good,binding_id:'good-binding'});
  let failure='device_not_registered';const sent=[];
  const jobs=createCallJobs({store,config:{pushURL:'https://fixture.invalid',pushToken:'synthetic-token'},fetcher:async(_,init)=>{
    const body=JSON.parse(init.body);sent.push(body.binding_id);
    if(body.binding_id==='old-binding'){
      if(failure==='network')throw Error('synthetic network failure');
      return Response.json({error:{code:failure}},{status:failure==='device_not_registered'?404:502});
    }
    return Response.json({accepted_by_apns:true});
  }});
  const ring=async()=>{const id=crypto.randomUUID();await mutate('call.incoming',{call_id:id,contact_id:'synthetic',source:'mcp'});await jobs.runOwner(owner);return id;};
  const first=await ring();
  assert.deepEqual(sent,['old-binding','good-binding']);
  assert.equal((await store.command(owner,'call.record',{call_id:first})).push.status,'sent');
  await mutate('call.end',{call_id:first,epoch:0,reason:'ended'});
  sent.length=0;const second=await ring();assert.deepEqual(sent,['good-binding'],'obsolete binding must not be retried');
  await mutate('call.end',{call_id:second,epoch:0,reason:'ended'});
  for(const code of ['apns_rejected','network']){
    await mutate('device.put',{device_id:old,binding_id:'old-binding'});failure=code;sent.length=0;
    const id=await ring();assert.ok(sent.includes('good-binding'));
    await mutate('call.end',{call_id:id,epoch:0,reason:'ended'});
    sent.length=0;const retry=await ring();assert.ok(sent.includes('old-binding'),'temporary errors must retain the binding');
    await mutate('call.end',{call_id:retry,epoch:0,reason:'ended'});
  }
});

test('old APNs failure cannot remove a token refreshed during delivery', async t => {
  const {createPushGateway, PushError} = await import('../apns-sender.mjs');
  const {createConnector} = await import('../../supabase/functions/_shared/tincall/service.mjs');
  const directory = mkdtempSync(join(tmpdir(), 'tincall-token-race-'));
  const owner = crypto.randomUUID(), device = crypto.randomUUID(), call = crypto.randomUUID();
  let started, rejectOld;
  const sending = new Promise(resolve => { started = resolve; });
  const config = {clients: [{token: 'synthetic-phone', owner_id: owner}], pushURL: 'https://synthetic.invalid', pushToken: 'synthetic-push-token-at-least-24-characters'};
  const gateway = createPushGateway({databasePath: join(directory, 'push.sqlite'), token: config.pushToken,
    send: async value => {
      if (value.device_token === 'a'.repeat(64)) { started(); await new Promise((_, reject) => { rejectOld = reject; }); }
    }});
  const store = createSQLiteStore(config, join(directory, 'calls.sqlite'));
  t.after(() => { store.close(); gateway.close(); rmSync(directory, {recursive: true, force: true}); });
  const fetcher = (url, init) => gateway.handle(new Request(url, init));
  const connector = createConnector({store, config, fetcher});
  async function register(value) {
    const response = await connector.handle(new Request('https://connector.invalid/devices', {method: 'POST',
      headers: {Authorization: 'Bearer synthetic-phone', 'Content-Type': 'application/json'},
      body: JSON.stringify({request_id: crypto.randomUUID(), device_id: device, device_token: value.repeat(64), environment: 'sandbox'})}));
    assert.equal(response.status, 200); return response.json();
  }
  const original = await register('a');
  assert.equal((await register('a')).binding_id, original.binding_id, 'unchanged healthy binding stays stable');
  await store.command(owner, 'call.incoming', {request_id: crypto.randomUUID(), call_id: call, contact_id: 'synthetic', source: 'mcp'});
  const jobs = createCallJobs({store, config, fetcher});
  const running = jobs.runOwner(owner);
  await sending;
  const refreshed = await register('b');
  rejectOld(new PushError('apns_device_expired', 502));
  await running;
  await store.command(owner, 'call.end', {request_id: crypto.randomUUID(), call_id: call, epoch: 0});
  await store.command(owner, 'call.incoming', {request_id: crypto.randomUUID(), call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp'});
  const next = await store.command(owner, 'push.claim', {});
  assert.equal(next.push.devices.length, 1, 'late failure must retain refreshed connector routing');
  assert.notEqual(refreshed.binding_id, original.binding_id);
  const direct = await gateway.handle(new Request('https://synthetic.invalid/push', {method: 'POST',
    headers: {Authorization: `Bearer ${config.pushToken}`, 'Content-Type': 'application/json'},
    body: JSON.stringify({owner_id: owner, binding_id: refreshed.binding_id, call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp', event: 'incoming_call'})}));
  assert.equal(direct.status, 200, 'late failure must leave the new token enabled in the gateway');
});

test('push enrollment is relayed by the deployment that owns the push credential', async () => {
  const pushToken = 'tcpush_abcdefghijklmnopqrst_' + 'a'.repeat(64);
  const sent = [];
  let reply = {status: 200, body: {registered: true}};
  const connector = createConnector({
    store: {async authenticate() { return null; }},
    config: {bindings: [], pushURL: 'https://push.invalid/', pushToken},
    fetcher: async (url, init) => { sent.push({url, init}); return new Response(JSON.stringify(reply.body), {status: reply.status}); },
  });
  const register = token => connector.handle(new Request('https://example.invalid/functions/v1/tincall/push/register', {
    method: 'POST', headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'}, body: '{}',
  }));

  const ok = await register(pushToken);
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), {registered: true});
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, 'https://push.invalid/services/register');
  assert.equal(sent[0].init.headers.Authorization, `Bearer ${pushToken}`);
  assert.equal(sent[0].init.body, '{}');

  assert.equal((await register('tcpush_other')).status, 403, 'only the configured push credential can enroll');
  assert.equal(sent.length, 1);

  reply = {status: 403, body: {error: {code: 'service_verification_failed'}}};
  assert.equal((await register(pushToken)).status, 502, 'a refused enrollment is not reported as registered');
});
