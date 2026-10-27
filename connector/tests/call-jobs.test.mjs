// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {setImmediate as settle} from 'node:timers/promises';
import {createCallJobs} from '../../supabase/functions/_shared/tincall/call-jobs.mjs';
import {ConnectorError} from '../../supabase/functions/_shared/tincall/protocol.mjs';

function generation(t, read) {
  t.mock.timers.enable({apis:['setTimeout','setInterval']});
  const call={id:crypto.randomUUID(),contact_id:'synthetic',status:'active',epoch:1};
  const job={id:crypto.randomUUID(),reply_id:crypto.randomUUID(),epoch:1};
  const deliveries=[];let polls=0,cancels=0,finish;
  const store={async command(owner,action,p){
    if(action==='job.claim')return {call,job,messages:[]};
    if(action==='push.claim')return {};
    if(action==='call.record')return read(++polls,call,()=>finish(Response.json({text:'synthetic reply'})));
    deliveries.push({action,...p});return {};
  }};
  const fetcher=async(url,{signal})=>{
    if(url.endsWith('/cancel')){cancels++;return Response.json({});}
    return new Promise((resolve,reject)=>{finish=resolve;signal.addEventListener('abort',()=>reject(signal.reason),{once:true});});
  };
  const config={bindings:[{owner_id:'synthetic-owner',contact_id:call.contact_id,mode:'http',generation_url:'https://example.invalid/generate',cancel_url:'https://example.invalid/cancel'}]};
  const done=createCallJobs({store,config,fetcher,backendMessages:async()=>[]}).runOwner('synthetic-owner');
  return {done,deliveries,get cancels(){return cancels;},async tick(ms=1000){await settle();t.mock.timers.tick(ms);await settle();}};
}

test('generation tolerates transient health failures and resets the failure budget after recovery',async t=>{
  const f=generation(t,(poll,call,finish)=>{
    if([1,3,4].includes(poll))throw new ConnectorError('database_unavailable',503);
    if(poll===5)finish();return {call};
  });
  for(let n=0;n<5;n++)await f.tick();await f.done;
  assert.equal(f.cancels,0);
  assert.deepEqual(f.deliveries.map(item=>item.action),['reply.completed']);
});

test('generation cancels upstream and reports failure when health checks remain unavailable',async t=>{
  const f=generation(t,()=>{throw new ConnectorError('database_unavailable',503);});
  await f.tick();await f.tick();assert.equal(f.cancels,0);
  await f.tick();await f.done;
  assert.equal(f.cancels,1);
  assert.equal(f.deliveries.find(item=>item.action==='reply.failed').code,'health_check_lost');
});

test('confirmed interruption cancels upstream without failing the replaced reply',async t=>{
  const f=generation(t,(_,call)=>({call:{...call,epoch:2}}));
  await f.tick();await f.done;
  assert.equal(f.cancels,1);
  assert.deepEqual(f.deliveries.map(item=>item.action),['job.cancel_result']);
});

test('generation retains its ninety second deadline even when a health read is stuck',async t=>{
  const f=generation(t,()=>new Promise(()=>{}));
  await f.tick();await f.tick(89000);await f.done;
  assert.equal(f.cancels,1);
  assert.equal(f.deliveries.find(item=>item.action==='reply.failed').code,'generation_timeout');
});
