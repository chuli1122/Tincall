// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';
import {callReference} from '../../supabase/functions/_shared/tincall/mcp.mjs';

test('MCP explains an owner-wide busy slot without disclosing another contact or ending its call',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-busy-'));
  const owner=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'contact',owner_id:owner,contact_id:'visible'}]},join(directory,'calls.sqlite'));
  const connector=createConnector({store,config:{bindings:[{owner_id:owner,contact_id:'visible',mode:'tools'}]}});
  const mutation=p=>({request_id:crypto.randomUUID(),...p});
  async function tool(name,args={}) {
    const response=await connector.handle(new Request('https://fixture.invalid/mcp',{method:'POST',headers:{Authorization:'Bearer contact','Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})}));
    return (await response.json()).result;
  }
  try {
    const ended=crypto.randomUUID();
    await store.command(owner,'call.create',mutation({call_id:ended,contact_id:'visible',source:'mcp'}));
    await store.command(owner,'call.end',mutation({call_id:ended,epoch:0,reason:'hangup'}));
    const hidden=crypto.randomUUID();
    await store.command(owner,'call.create',mutation({call_id:hidden,contact_id:'private-other-contact',source:'mcp'}));
    assert.match((await tool('tincall_get_call')).content[0].text,/没有进行中/);
    assert.doesNotMatch((await tool('tincall_list_calls')).content[0].text,/进行中/);
    const busy=await tool('tincall_call',{timeout_seconds:1});
    assert.equal(busy.isError,true);assert.match(busy.content[0].text,/未结束的通话记录/);assert.match(busy.content[0].text,/Tincall/);
    assert.ok(!JSON.stringify(busy).includes(hidden));
    assert.ok(!JSON.stringify(busy).includes('private-other-contact'));
    assert.equal((await store.command(owner,'call.current')).call.id,hidden);
  } finally {store.close();rmSync(directory,{recursive:true,force:true});}
});

test('a disconnected phone releases its active slot on the next dial; current event reads keep real calls alive',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const directory=mkdtempSync(join(tmpdir(),'tincall-presence-'));
  const file=join(directory,'calls.sqlite'),owner=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:owner},{token:'contact',owner_id:owner,contact_id:'visible'}]},file);
  const db=new DatabaseSync(file);
  const connector=createConnector({store,config:{bindings:[{owner_id:owner,contact_id:'visible',mode:'tools'}]},schedule:()=>{}});
  const mutation=p=>({request_id:crypto.randomUUID(),...p});
  async function dial(){
    const response=await connector.handle(new Request('https://fixture.invalid/mcp',{method:'POST',headers:{Authorization:'Bearer contact','Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'tincall_call',arguments:{timeout_seconds:1}}})}));
    return (await response.json()).result;
  }
  try {
    const id=crypto.randomUUID();
    await store.command(owner,'call.create',mutation({call_id:id,contact_id:'private-other-contact',source:'mcp'}));
    const old=new Date(Date.now()-240000).toISOString();
    db.prepare('UPDATE tincall_calls SET created_at=?,phone_seen_at=? WHERE id=?').run(old,old,id);
    // Swift UUID.uuidString uses uppercase; reads and presence must identify the same call.
    const eventRead=await connector.handle(new Request(`https://fixture.invalid/calls/${id.toUpperCase()}/events?after=0`,{headers:{Authorization:'Bearer phone'}}));assert.equal(eventRead.status,200);
    assert.match((await dial()).content[0].text,/未结束的通话记录/,'an old call with a connected phone is still busy');
    db.prepare('UPDATE tincall_calls SET phone_seen_at=? WHERE id=?').run(old,id);
    const next=await dial();const nextID=(await store.command(owner,'call.current')).call.id;assert.match(next.content[0].text,/尚未接听/);assert.equal(next.isError,false);
    const ended=await store.command(owner,'call.record',{call_id:id});assert.equal(ended.call.status,'ended');assert.equal((await store.command(owner,'call.events',{call_id:id,after:0})).events.at(-1).payload.reason,'phone_disconnected');
    await store.command(owner,'call.end',mutation({call_id:nextID,epoch:0,reason:'hangup'}));
    const ring=crypto.randomUUID();await store.command(owner,'call.incoming',mutation({call_id:ring,contact_id:'private-other-contact',source:'mcp'}));
    db.prepare('UPDATE tincall_calls SET created_at=? WHERE id=?').run(old,ring);
    assert.match((await dial()).content[0].text,/尚未接听/,'a missed ring must also release its slot without relying on cron');
    assert.equal((await store.command(owner,'call.events',{call_id:ring,after:0})).events.at(-1).payload.reason,'missed');
  } finally {db.close();store.close();rmSync(directory,{recursive:true,force:true});}
});

test('switching the linked contact to standalone rejects MCP as a mode mismatch, preserves its credential, and stops its pending ring',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-contact-mode-'));
  const owner=crypto.randomUUID(),roleID=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:owner}]},join(directory,'calls.sqlite'));
  const connector=createConnector({store,config:{},schedule:()=>{}});
  async function post(path,token,body){return connector.handle(new Request('https://fixture.invalid'+path,{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify(body)}));}
  const mode=(call_mode,token='phone')=>post('/mcp/roles/mode',token,{role_id:roleID,call_mode});
  async function dial(token){return (await (await post('/mcp',token,{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'tincall_call',arguments:{timeout_seconds:1}}})).json()).result;}
  try {
    const enrollment=await (await post('/mcp/roles/upsert','phone',{role_id:roleID,contact_id:'linked',display_name:'Fixture'})).json();
    const initial=await dial(enrollment.token);const initialID=(await store.command(owner,'call.current')).call.id;assert.match(initial.content[0].text,/尚未接听/);
    assert.equal((await mode('standalone',enrollment.token)).status,403);
    assert.equal((await mode('invalid')).status,400);
    assert.equal((await mode('standalone')).status,200);
    assert.equal((await store.command(owner,'call.record',{call_id:initialID})).call.status,'ended');
    assert.equal((await store.command(owner,'call.events',{call_id:initialID,after:0})).events.at(-1).payload.reason,'contact_mode_changed');
    const hidden=crypto.randomUUID();
    await store.command(owner,'call.create',{request_id:crypto.randomUUID(),call_id:hidden,contact_id:'private-other',source:'mcp'});
    const denied=await dial(enrollment.token);
    assert.equal(denied.isError,true);
    assert.match(denied.content[0].text,/contact mode mismatch/);
    assert.ok(!JSON.stringify(denied).includes(hidden));
    assert.equal((await store.command(owner,'call.current')).call.id,hidden,'reject mode before unrelated occupancy without ending it');
    await store.command(owner,'call.end',{request_id:crypto.randomUUID(),call_id:hidden,epoch:0});
    assert.equal((await mode('mcp')).status,200);
    assert.match((await dial(enrollment.token)).content[0].text,/尚未接听/,'switching back reuses the same credential');
  } finally {store.close();rmSync(directory,{recursive:true,force:true});}
});


test('MCP default wait lasts 120 seconds and exposes no caller-managed reply identifiers',async context=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-simple-mcp-')),owner=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'contact',owner_id:owner,contact_id:'visible'}]},join(directory,'calls.sqlite'));
  let advance=false,snapshots=0,clock=Date.now();
  const connector=createConnector({store:{...store,async mcpCommand(...args){
    const result=await store.mcpCommand(...args);
    if(advance && args[2]==='snapshot' && args[3].after_sequence!==undefined){clock+=45000;snapshots++;}
    return result;
  }},config:{bindings:[{owner_id:owner,contact_id:'visible',mode:'tools'}]},schedule:()=>{}});
  async function rpc(method,params){return (await (await connector.handle(new Request('https://fixture.invalid/mcp',{method:'POST',headers:{Authorization:'Bearer contact','Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})}))).json()).result;}
  const tool=(name,args={})=>rpc('tools/call',{name,arguments:args});
  try {
    const definitions=(await rpc('tools/list')).tools;
    assert.deepEqual(definitions.find(tool=>tool.name==='tincall_reply').inputSchema.required,['call','text']);
    for(const name of ['tincall_call','tincall_wait','tincall_reply','tincall_end'])for(const key of ['reply_to','sequence','epoch','call_id','request_id','timeout_seconds'])assert.equal(definitions.find(tool=>tool.name===name).inputSchema.properties[key],undefined);
    const id=crypto.randomUUID();await store.command(owner,'call.create',{request_id:id,call_id:id,contact_id:'visible',source:'mcp'});
    await tool('tincall_wait',{timeout_seconds:1});
    context.mock.method(Date,'now',()=>clock);advance=true;
    const timeout=await tool('tincall_wait');advance=false;
    assert.equal(snapshots,4);assert.match(timeout.content[0].text,/tincall_wait/);assert.doesNotMatch(timeout.content[0].text,/get_call|cursor|epoch/);
    assert.equal((await tool('tincall_reply',{call:callReference(id),text:'Complete text',wait_for_input:false})).isError,false);
    await tool('tincall_end',{call:callReference(id)});
  } finally {context.mock.restoreAll();store.close();rmSync(directory,{recursive:true,force:true});}
});

test('MCP contact wait preferences survive restart and apply to dial, wait and reply with explicit overrides',async context=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-wait-preferences-')),owner=crypto.randomUUID();
  const file=join(directory,'calls.sqlite'),config={clients:[{token:'phone',owner_id:owner},{token:'contact',owner_id:owner,contact_id:'visible'}]};
  let store=createSQLiteStore(config,file),clock=Date.now(),advance=false,snapshots=0;
  const connector=()=>createConnector({store:{...store,async mcpCommand(...args){
    const result=await store.mcpCommand(...args);
    if(advance && args[2]==='snapshot' && args[3].after_sequence!==undefined){clock+=1000;snapshots++;}
    return result;
  }},config:{bindings:[{owner_id:owner,contact_id:'visible',mode:'tools'}]},schedule:()=>{}});
  let service=connector();
  async function post(path,payload,token='phone'){
    return service.handle(new Request('https://fixture.invalid'+path,{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify(payload)}));
  }
  const tool=async(name,args={})=>(await (await post('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'contact')).json()).result;
  const role={role_id:crypto.randomUUID(),contact_id:'visible',display_name:'Synthetic'};
  async function timed(name,args,seconds){
    snapshots=0;advance=true;
    const result=await tool(name,args);advance=false;
    assert.equal(result.isError,false,JSON.stringify(result));
    assert.match(result.content[0].text,/tincall_wait/);
    assert.equal(snapshots,seconds);
  }
  try {
    assert.equal((await (await post('/mcp/roles/upsert',{...role,mcp_wait_timeout_seconds:100})).json()).mcp_wait_timeout_seconds,100);
    store.close();store=createSQLiteStore(config,file);service=connector();
    assert.equal((await (await post('/mcp/roles/upsert',role)).json()).mcp_wait_timeout_seconds,100);
    context.mock.method(Date,'now',()=>clock);
    context.mock.method(globalThis,'setTimeout',callback=>{queueMicrotask(callback);return 0;});
    await timed('tincall_call',{},100);
    let call=(await store.command(owner,'call.current')).call;
    await store.command(owner,'call.accept',{request_id:crypto.randomUUID(),call_id:call.id,epoch:call.epoch});
    await tool('tincall_wait'); // Deliver the connection event before waiting for speech.
    await timed('tincall_wait',{},100);
    await timed('tincall_reply',{call:callReference(call.id),text:'Synthetic reply'},100);
    assert.equal((await (await post('/mcp/roles/upsert',{...role,mcp_wait_timeout_seconds:130})).json()).mcp_wait_timeout_seconds,130);
    await timed('tincall_wait',{},130);
    await timed('tincall_wait',{timeout_seconds:2},2);
    for(const timeout_seconds of [0,131,1.5])assert.equal((await tool('tincall_reply',{call:callReference(call.id),text:'Must not send',timeout_seconds})).isError,true);
    assert.equal((await store.command(owner,'call.record',{call_id:call.id})).messages.some(message=>message.text==='Must not send'),false);
  } finally {context.mock.restoreAll();store.close();rmSync(directory,{recursive:true,force:true});}
});
