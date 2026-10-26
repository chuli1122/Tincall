// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test, {before,after} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {createSQLiteStore,nextDaily} from '../sqlite-store.mjs';
import {createServer} from 'node:http';
import {createConnector,createSupabaseStore,ConnectorError} from '../../supabase/functions/_shared/tincall/service.mjs';
import {callReference} from '../../supabase/functions/_shared/tincall/mcp.mjs';

const storage=process.env.TINCALL_TEST_STORAGE??'postgres';
if(!['sqlite','postgres'].includes(storage))throw new Error('TINCALL_TEST_STORAGE only accepts sqlite or postgres');
const sqlite=storage==='sqlite';
const directory=sqlite?mkdtempSync(join(tmpdir(),'tincall-store-test-')):null;
const databasePath=sqlite?join(directory,'connector.sqlite'):null;
let database;
const owner='10000000-0000-4000-8000-000000000001';
const other='10000000-0000-4000-8000-000000000002';
const container=`tincall-connector-test-${process.pid}`;
const storedMedia=new Map();
const sqlQuote=value=>`'${String(value).replaceAll("'","''")}'`;
function sql(query) {
  return execFileSync('docker',['exec','-i',container,'psql','-h','127.0.0.1','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres'],{input:query,encoding:'utf8',stdio:['pipe','pipe','pipe']}).trim();
}
// Exercise the production credential adapter against the real SQL functions.
const mcpStore=createSupabaseStore({supabaseURL:'https://fixture.supabase.invalid',publicKey:'public-fixture',serviceKey:'service-fixture',
  clients:[{token:'test-owner',owner_id:owner},{token:'test-other',owner_id:other},{token:'test-role',owner_id:owner,contact_id:'one'}]},async(url,init)=>{
  if(url.endsWith('/auth/v1/user'))return Response.json({message:'unauthorized'},{status:401});
  if(url.includes('/storage/v1/object/')) {
    const path=url.split('/object/tincall-private/')[1];
    if(url.endsWith('/object/list/tincall-private')) {
      const {prefix,offset=0,limit=100}=JSON.parse(init.body);
      return Response.json([...storedMedia.keys()].filter(key=>key.startsWith(prefix)).sort().slice(offset,offset+limit).map(key=>({name:key.slice(prefix.length)})));
    }
    if(init.method==='DELETE') {for(const key of JSON.parse(init.body).prefixes)storedMedia.delete(key);return Response.json({});}
    if(init.method==='POST') {
      if(storedMedia.has(path))return Response.json({},{status:409});
      storedMedia.set(path,{bytes:await new Response(init.body).arrayBuffer(),type:init.headers['Content-Type']});return Response.json({});
    }
    const item=storedMedia.get(path);
    return item?new Response(item.bytes,{headers:{'Content-Type':item.type}}):Response.json({},{status:404});
  }
  const p=JSON.parse(init.body);
  let query;
  if(url.endsWith('/rpc/tincall_mcp_role'))query=`public.tincall_mcp_role(${sqlQuote(p.p_action)},${sqlQuote(p.p_owner)}::uuid,${sqlQuote(JSON.stringify(p.p_payload))}::jsonb)`;
  else if(url.endsWith('/rpc/tincall_resolve_call_context'))query=`public.tincall_resolve_call_context(${sqlQuote(p.p_owner)}::uuid,${p.p_contact===null?'null':sqlQuote(p.p_contact)},${sqlQuote(p.p_prefix)})`;
  else if(url.endsWith('/rpc/tincall_mcp'))query=`public.tincall_mcp(${sqlQuote(p.p_action)},${p.p_owner===null?'null':sqlQuote(p.p_owner)}::uuid,${p.p_contact===null?'null':sqlQuote(p.p_contact)},${sqlQuote(JSON.stringify(p.p_payload))}::jsonb)`;
  else if(url.endsWith('/rpc/tincall_mcp_sse_command'))query=`public.tincall_mcp_sse_command(${sqlQuote(p.p_action)},${sqlQuote(p.p_owner)}::uuid,${p.p_contact===null?'null':sqlQuote(p.p_contact)},${sqlQuote(JSON.stringify(p.p_payload))}::jsonb)`;
  else if(url.endsWith('/rpc/tincall_mcp_authenticate'))query=`public.tincall_mcp_authenticate(${sqlQuote(p.p_token)})`;
  else if(url.endsWith('/rpc/tincall_recent_calls'))query=`public.tincall_recent_calls(${sqlQuote(p.p_owner)}::uuid,${p.p_contact===null?'null':sqlQuote(p.p_contact)},${p.p_limit})`;
  else if(url.endsWith('/rpc/tincall_set_voice_prompt'))query=`public.tincall_set_voice_prompt(${sqlQuote(p.p_call)}::uuid,${sqlQuote(p.p_prompt)},${sqlQuote(p.p_owner)}::uuid)`;
  else if(url.endsWith('/rpc/tincall_claim_voice_instructions'))query=`public.tincall_claim_voice_instructions(${sqlQuote(p.p_call)}::uuid,${sqlQuote(p.p_owner)}::uuid)`;
  else if(url.endsWith('/rpc/tincall_command') || url.endsWith('/rpc/tincall_image_command') || url.endsWith('/rpc/tincall_schedule_command')) {
    const fn=url.endsWith('/rpc/tincall_schedule_command')?'tincall_schedule_command':url.endsWith('/rpc/tincall_image_command')?'tincall_image_command':'tincall_command';
    query=`public.${fn}(${sqlQuote(p.p_action)},${sqlQuote(JSON.stringify(p.p_payload))}::jsonb,${sqlQuote(p.p_owner)}::uuid)`;
  }
  else throw new Error('Unexpected fixture endpoint');
  try {
    const value=sql(`set role service_role;set request.jwt.claim.role='service_role';select ${query};`);
    return Response.json(value ? JSON.parse(value) : null);
  } catch(error) {
    const message=error.stderr?.toString().match(/ERROR:\s+(\w+)/)?.[1]??'database_request_failed';
    return Response.json({message},{status:400});
  }
});
const store=sqlite?createSQLiteStore({clients:[{token:'test-owner',owner_id:owner},{token:'test-other',owner_id:other},{token:'test-role',owner_id:owner,contact_id:'one'}]},databasePath):{
  resolveCallContext:mcpStore.resolveCallContext,
  authenticate:mcpStore.authenticate,
  recentCalls:mcpStore.recentCalls,
  mcpRoleCommand:mcpStore.mcpRoleCommand,
  mcpCommand:mcpStore.mcpCommand,
  sseCommand:mcpStore.sseCommand,
  command:mcpStore.command,
  async workerOwners(){return JSON.parse(sql("set request.jwt.claim.role='service_role';select public.tincall_worker_owners();"));},
  setVoicePrompt:mcpStore.setVoicePrompt,
  claimVoiceInstructions:mcpStore.claimVoiceInstructions,
  media:mcpStore.media,
  deleteRecordMedia:mcpStore.deleteRecordMedia,
};
const tasks=[];let upstream;let base;let connector;let generationCount=0;let cancelCount=0;let stall=false;let lastGeneration;
before(async()=>{
  if(sqlite){database=new DatabaseSync(databasePath);}else{
  execFileSync('docker',['run','--rm','--detach','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:18-alpine'],{stdio:'pipe'});
  let ready=false;
  for(let i=0;i<30;i++){try{sql('select 1');ready=true;break;}catch{await new Promise(resolve=>setTimeout(resolve,200));}}
  assert.ok(ready,'local PostgreSQL started');
  sql(readFileSync(new URL('./bootstrap.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610110001_tincall_connector.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610140001_tincall_mcp_roles.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610160001_tincall_voice_instructions.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610180001_tincall_recent_calls.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610190001_tincall_mcp_sse.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610210003_tincall_message_images.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610190002_tincall_mcp_tools.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610210001_tincall_mcp_voice_ack.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610210002_tincall_mcp_conversation.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610200003_tincall_mcp_oauth.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610220002_tincall_mcp_safety.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610250001_tincall_mcp_wait_preferences.sql',import.meta.url),'utf8'));
  sql(readFileSync(new URL('../../supabase/migrations/202610200001_tincall_schedule_controls.sql',import.meta.url),'utf8'));
  }
  upstream=createServer(async(req,res)=>{
    let body='';for await(const chunk of req)body+=chunk;
    const payload=JSON.parse(body);
    if(req.url==='/cancel'){cancelCount++;assert.ok(payload.job_id);res.writeHead(200,{'Content-Type':'application/json'});res.end('{"cancelled":true}');return;}
    generationCount++;lastGeneration=payload;assert.equal(req.headers['idempotency-key'],payload.job_id);
    assert.ok(payload.messages.some(message=>message.id===payload.input_id));
    res.writeHead(200,{'Content-Type':'application/x-ndjson'});res.write('{"type":"delta","delta":"fixture first"}\n');
    if(stall)return;
    res.end('{"type":"completed","text":"fixture first and final"}\n');
  });
  await new Promise(resolve=>upstream.listen(0,'127.0.0.1',resolve));
  base=`http://127.0.0.1:${upstream.address().port}`;
  connector=createConnector({store,config:{workerToken:'worker-test',bindings:[{owner_id:owner,contact_id:'one',mode:'http',generation_url:`${base}/generate`,cancel_url:`${base}/cancel`,allow_local_http:true},{owner_id:owner,contact_id:'poll-http',mode:'http',generation_url:`${base}/generate`,cancel_url:`${base}/cancel`,allow_local_http:true},{owner_id:owner,contact_id:'tools',mode:'tools'}]},schedule:task=>{tasks.push(task);}});
});
after(async()=>{await Promise.allSettled(tasks);if(upstream)await new Promise(resolve=>upstream.close(resolve));if(sqlite){database?.close();store.close();rmSync(directory,{recursive:true,force:true});}else execFileSync('docker',['rm','-f',container],{stdio:'pipe'});});
async function api(path,body,token='test-owner',headers={}) {
  const response=await connector.handle(new Request(`http://localhost${path}`,{method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})}));
  return {status:response.status,body:await response.json()};
}
const mutation=extra=>({request_id:crypto.randomUUID(),...extra});
let call;let input;
test('Supabase gateway paths reach the same authenticated connector routes',async()=>{
  for (const prefix of ['', '/tincall', '/functions/v1/tincall']) {
    const result=await api(`${prefix}/capabilities`);
    assert.equal(result.status,200,`${prefix || '/'} capabilities route`);
    assert.equal(result.body.owner_id,owner);
    assert.equal((await api(`${prefix}/capabilities`,undefined,'bad-token')).status,401);
    const worker=await api(`${prefix}/worker`,{},'worker-test');
    assert.equal(worker.status,202);
  }
  for (const path of ['/tincall-other/capabilities','/functions/v1/tincall-other/capabilities']) {
    assert.equal((await api(path)).status,404);
  }
});

test('legacy SSE carries MCP tools across instances and isolates/reconnects authenticated sessions',async()=>{
  const identity=(await api('/mcp/roles/upsert',{role_id:crypto.randomUUID(),contact_id:crypto.randomUUID(),display_name:'SSE fixture'})).body;
  const secondStore=sqlite?createSQLiteStore({clients:[{token:'test-owner',owner_id:owner},{token:'test-other',owner_id:other}]},databasePath):store;
  const pending=[];
  const second=createConnector({store:secondStore,config:{},schedule:task=>pending.push(task)});
  const controller=new AbortController();
  let reader;let buffer='';const decoder=new TextDecoder();
  async function event(){
    while(!buffer.includes('\n\n')){
      const part=await reader.read();assert.equal(part.done,false);
      buffer+=decoder.decode(part.value,{stream:true});
    }
    const end=buffer.indexOf('\n\n');const block=buffer.slice(0,end);buffer=buffer.slice(end+2);
    return Object.fromEntries(block.split('\n').filter(line=>!line.startsWith(':')).map(line=>{const i=line.indexOf(':');return [line.slice(0,i),line.slice(i+1).trimStart()];}));
  }
  const headers={Authorization:`Bearer ${identity.token}`,Accept:'text/event-stream'};
  const timeout=setTimeout(()=>controller.abort(),15000);
  try {
    assert.equal((await connector.handle(new Request('http://localhost/mcp/sse',{headers:{Accept:'text/event-stream'}}))).status,401);
    assert.equal((await connector.handle(new Request('http://localhost/mcp/sse',{headers:{...headers,Origin:'https://attacker.invalid'}}))).status,403);
    assert.equal((await connector.handle(new Request('http://localhost/mcp/sse',{headers:{Authorization:headers.Authorization}}))).status,406);
    const sseURL='http://localhost/functions/v1/tincall/mcp/sse';
    const response=await connector.handle(new Request(sseURL,{headers,signal:controller.signal}));
    assert.equal(response.status,200);assert.equal(response.headers.get('content-type'),'text/event-stream');
    reader=response.body.getReader();
    const opened=await event();assert.equal(opened.event,'endpoint');
    assert.match(opened.data,/^messages\?session_id=/);
    const postURL=new URL(opened.data,sseURL);
    assert.equal(postURL.pathname,'/functions/v1/tincall/mcp/messages');
    const send=(message,token=identity.token)=>second.handle(new Request(postURL,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(message)}));
    assert.equal((await send({jsonrpc:'2.0',id:1,method:'ping'},'test-other')).status,404);
    assert.equal((await send({jsonrpc:'2.0',id:1,method:'ping'},'test-owner')).status,404);
    assert.equal((await send({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'fixture',version:'1'}}})).status,202);
    const initialized=await event();assert.equal(initialized.event,'message');
    assert.equal(JSON.parse(initialized.data).result.protocolVersion,'2024-11-05');
    assert.equal((await send({jsonrpc:'2.0',method:'notifications/initialized'})).status,202);
    await send({jsonrpc:'2.0',id:2,method:'tools/list'});
    const definitions=JSON.parse((await event()).data).result.tools;assert.equal(definitions.length,6);
    assert.ok(!definitions.find(tool=>tool.name==='tincall_call').inputSchema.required.includes('contact_id'));
    const before=Date.now();
    await send({jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'tincall_call',arguments:{timeout_seconds:5}}});
    assert.ok(Date.now()-before<1000,'POST acknowledges before the dial finishes waiting');
    let incoming;
    for(let i=0;i<100;i++) {incoming=(await store.command(owner,'call.current',{})).call?.id;if(incoming)break;await new Promise(resolve=>setTimeout(resolve,10));}
    assert.ok(incoming);
    await api(`/calls/${incoming}/answer`,mutation({epoch:0}));
    assert.match(JSON.parse((await event()).data).result.content[0].text,/已接通/);
    await send({jsonrpc:'2.0',id:4,method:'tools/call',params:{name:'tincall_wait',arguments:{timeout_seconds:5}}});
    const input=await api(`/calls/${incoming}/input`,mutation({epoch:0,message_id:crypto.randomUUID(),text:'SSE fixture input'}));
    const received=await event();
    assert.match(JSON.parse(received.data).result.content[0].text,/SSE fixture input/);
    await reader.cancel();buffer='';
    // The POST can complete while no GET is connected; its result must survive.
    await send({jsonrpc:'2.0',id:5,method:'ping'});await Promise.all(pending);
    // Simulate the gateway passing a stripped path on reconnect.
    const resumed=await second.handle(new Request('http://localhost/tincall/mcp/sse',{headers:{...headers,'Last-Event-ID':received.id},signal:controller.signal}));
    assert.equal(resumed.status,200);reader=resumed.body.getReader();
    assert.equal((await event()).data,opened.data);
    assert.equal(JSON.parse((await event()).data).id,5);
    await send({jsonrpc:'2.0',id:6,method:'tools/call',params:{name:'tincall_reply',arguments:{call:callReference(incoming),text:'SSE fixture reply',wait_for_input:false}}});
    assert.equal(JSON.parse((await event()).data).result.isError,false);
    await api(`/calls/${incoming}/end`,mutation({epoch:1}));
    await reader.cancel();
    const session=new URL(postURL).searchParams.get('session_id');
    if(sqlite)database.prepare("UPDATE tincall_mcp_sse SET expires_at='2000-01-01T00:00:00.000Z' WHERE id=?").run(session);
    else sql(`update public.tincall_mcp_sse set expires_at='2000-01-01' where id=${sqlQuote(session)};`);
    assert.equal((await send({jsonrpc:'2.0',id:7,method:'ping'})).status,404);
    if(!sqlite)for(const role of ['anon','authenticated']){
      assert.throws(()=>sql(`set role ${role};select * from public.tincall_mcp_sse;`));
      assert.throws(()=>sql(`set role ${role};select public.tincall_mcp_sse_command('check',${sqlQuote(owner)},null,'{}');`));
    }
  } finally {
    controller.abort();await reader?.cancel();clearTimeout(timeout);
    await Promise.all(pending);if(sqlite)secondStore.close();
  }
});

test('MCP role enrollment persists identities and isolates live calls without deployment configuration',async()=>{
  const first={role_id:crypto.randomUUID(),contact_id:crypto.randomUUID(),display_name:'Role A'};
  const second={role_id:crypto.randomUUID(),contact_id:crypto.randomUUID(),display_name:'Role B'};
  const a=await api('/mcp/roles/upsert',first);
  assert.equal(a.status,200);
  assert.equal(a.body.contact_id,first.contact_id);
  assert.equal(a.body.role_id,first.role_id);
  assert.equal(a.body.mcp_path,'mcp');
  assert.equal(a.body.token_created,true);
  assert.equal(a.body.mcp_wait_timeout_seconds,120);
  assert.match(a.body.token,/^tcmcp_[0-9a-f]{64}$/);
  const b=await api('/mcp/roles/upsert',second);
  assert.equal(b.status,200);
  assert.notEqual(a.body.token,b.body.token);
  const renamed=await api('/mcp/roles/upsert',{...first,display_name:'Renamed A',mcp_wait_timeout_seconds:100});
  assert.equal(renamed.body.token,a.body.token);
  assert.equal(renamed.body.token_created,false);
  assert.equal(renamed.body.display_name,'Renamed A');
  assert.equal(renamed.body.mcp_wait_timeout_seconds,100);
  assert.equal((await api('/mcp/roles/upsert',{...first,display_name:'Renamed A'})).body.mcp_wait_timeout_seconds,100);
  for (const mcp_wait_timeout_seconds of [0,131,1.5,'90',null]) {
    const invalid=await api('/mcp/roles/upsert',{...first,mcp_wait_timeout_seconds});
    assert.equal(invalid.status,400);
    assert.equal(invalid.body.error.code,'invalid_mcp_wait_timeout_seconds');
  }
  const duplicate=await api('/mcp/roles/upsert',{...first,role_id:crypto.randomUUID()});
  assert.equal(duplicate.status,409);
  assert.equal(duplicate.body.error.code,'role_identity_conflict');
  assert.equal((await api('/mcp/roles/upsert',{...first,contact_id:second.contact_id})).status,409);
  assert.equal((await api('/mcp/roles/upsert',{...first,role_id:crypto.randomUUID(),contact_id:'one'})).status,409);
  for(const invalid of [{...first,role_id:'invalid'},{...first,display_name:''},{...first,display_name:'x'.repeat(201)},
    {...first,token:'caller-chosen'},{...first,owner_id:other}]) {
    assert.equal((await api('/mcp/roles/upsert',invalid)).status,400);
  }
  const otherRole=await api('/mcp/roles/upsert',first,'test-other');
  assert.equal(otherRole.status,200);
  assert.notEqual(otherRole.body.token,a.body.token);
  const directory=(await api('/capabilities')).body;
  assert.equal(directory.mcp_role_management,true);
  assert.equal(directory.bindings.find(binding=>binding.contact_id===first.contact_id).display_name,'Renamed A');
  assert.equal(directory.bindings.find(binding=>binding.contact_id===first.contact_id).mcp_wait_timeout_seconds,100);
  assert.equal(directory.bindings.find(binding=>binding.contact_id===second.contact_id).mode,'tools');
  assert.equal(JSON.stringify(directory).includes(a.body.token),false);
  const scoped=(await api('/capabilities',undefined,a.body.token)).body;
  assert.equal(scoped.mcp_role_management,false);
  assert.equal(scoped.owner_id,undefined);
  assert.deepEqual(scoped.bindings.map(binding=>binding.contact_id),[first.contact_id]);
  assert.equal((await api('/mcp/roles/upsert',second,a.body.token)).status,403);
  assert.equal((await api('/records',undefined,a.body.token)).status,403);
  assert.equal((await api('/devices',mutation({}),a.body.token)).status,403);
  assert.equal((await api('/capabilities',undefined,'tcmcp_invalid')).status,401);
  assert.equal((await api('/capabilities',undefined,'tcmcp_'+'0'.repeat(64))).status,401);

  // A fresh service instance sees the same persisted identities and credentials.
  const restarted=createConnector({store,config:{}});
  const again=await restarted.handle(new Request('https://fixture.invalid/mcp/roles/upsert',{method:'POST',
    headers:{Authorization:'Bearer test-owner','Content-Type':'application/json'},body:JSON.stringify(first)}));
  assert.equal((await again.json()).token,a.body.token);
  const headers={Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'};
  const tool=(token,name,args)=>api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token,headers);
  const tools=(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/list'},a.body.token,headers)).body.result.tools;
  assert.equal(tools.find(tool=>tool.name==='tincall_call').inputSchema.required.includes('contact_id'),false);
  assert.equal((await tool(a.body.token,'tincall_call',{contact_id:second.contact_id,timeout_seconds:1})).body.result.isError,true);
  const incoming=await tool(a.body.token,'tincall_call',{timeout_seconds:1});
  assert.match(incoming.body.result.content[0].text,/尚未接听/);
  const callID=(await store.command(owner,'call.current',{})).call.id;
  assert.equal((await api('/calls/current',undefined,b.body.token)).body.call,null);
  assert.equal((await api(`/calls/${callID}/record`,undefined,b.body.token)).status,403);
  assert.equal((await api(`/calls/${callID}/record`,undefined,otherRole.body.token)).status,404);
  await api(`/calls/${callID}/answer`,mutation({epoch:0}));
  const input=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'enrolled role question'}));
  assert.equal(input.status,200);
  const reply={call:callReference(callID),text:'enrolled role answer',wait_for_input:false};
  assert.equal((await tool(b.body.token,'tincall_reply',reply)).body.result.isError,true);
  assert.equal((await tool(a.body.token,'tincall_reply',reply)).body.result.isError,false);
  assert.equal((await api(`/calls/${callID}/events`)).body.events.at(-1).payload.text,reply.text);
  await api(`/calls/${callID}/end`,mutation({epoch:1}));
  await Promise.all(tasks);

  // The table and service-only RPCs cannot leak tokens through Supabase client access.
  if(!sqlite)for(const role of ['anon','authenticated']) {
    assert.throws(()=>sql(`set role ${role};set request.jwt.claim.sub=${sqlQuote(owner)};select token from public.tincall_mcp_roles;`));
    assert.throws(()=>sql(`set role ${role};select public.tincall_mcp_authenticate('untrusted');`));
    assert.throws(()=>sql(`set role ${role};select public.tincall_mcp_role('list',${sqlQuote(owner)}::uuid);`));
  }
});
test('authenticated call, durable input idempotency and real HTTP adapter event delivery',async()=>{
  assert.equal((await api('/calls/current',undefined,'bad-token')).status,401);
  call=crypto.randomUUID();
  const create=mutation({call_id:call,contact_id:'one',source:'backend'});
  const first=await api('/calls',create);assert.equal(first.status,200);assert.equal(first.body.call.epoch,0);
  assert.deepEqual((await api('/calls',create)).body,first.body);
  assert.equal((await api('/calls',{...create,contact_id:'changed'})).body.error.code,'generation_not_configured');
  input=mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic test input'});
  const accepted=await api(`/calls/${call}/input`,input);assert.equal(accepted.status,200);assert.equal(accepted.body.epoch,1);
  assert.deepEqual((await api(`/calls/${call}/input`,input)).body,accepted.body);
  await Promise.all(tasks);assert.equal(generationCount,1);
  const events=(await api(`/calls/${call}/events?after=0&limit=2`)).body;
  assert.equal(events.events.length,2);assert.equal(events.has_more,true);
  const remaining=(await api(`/calls/${call}/events?after=${events.cursor}`)).body;
  assert.equal(remaining.events.at(-1).type,'reply.completed');assert.equal(remaining.events.at(-1).payload.text,'fixture first and final');
  assert.equal((await api(`/calls/${call}/events?after=99999`)).body.error.code,'invalid_cursor');
  assert.equal((await api(`/calls/${call}/events`,undefined,'test-other')).status,404);
  assert.equal((await api(`/calls/${call}/input`,{...input,text:'changed'})).body.error.code,'idempotency_conflict');
});
test('RLS blocks cross-user records and bucket paths; callers cannot choose another owner',async()=>{
  if(sqlite){
    assert.equal((await store.command(other,'call.list',{})).calls.length,0);
    assert.equal((await api('/records',undefined,'test-role')).status,403);
    assert.equal((await api('/capabilities',undefined,'bad-token')).status,401);
    return;
  }
  assert.equal(sql(`set role authenticated;set request.jwt.claim.sub=${sqlQuote(other)};select count(*) from public.tincall_calls;`),'0');
  assert.throws(()=>sql(`set role authenticated;set request.jwt.claim.sub=${sqlQuote(other)};select public.tincall_command('call.current','{}',${sqlQuote(owner)});`),/Command failed/);
  sql(`set role authenticated;set request.jwt.claim.sub=${sqlQuote(owner)};insert into storage.objects(bucket_id,name) values('tincall-private','${owner}/test.wav');`);
  assert.throws(()=>sql(`set role authenticated;set request.jwt.claim.sub=${sqlQuote(other)};insert into storage.objects(bucket_id,name) values('tincall-private','${owner}/invalid.wav');`),/Command failed/);
  assert.equal(sql(`set role authenticated;set request.jwt.claim.sub=${sqlQuote(other)};select count(*) from storage.objects;`),'0');
});
test('interrupt aborts generation, calls cancellation adapter and rejects late epochs',async()=>{
  stall=true;
  const accepted=await api(`/calls/${call}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'synthetic pending input'}));
  assert.equal(accepted.status,200);
  // Give the real HTTP stream time to persist its first chunk before interrupting.
  for(let i=0;i<30;i++){const record=await api(`/calls/${call}/record`);if(record.body.messages.at(-1).text)break;await new Promise(resolve=>setTimeout(resolve,30));}
  const interrupted=await api(`/calls/${call}/interrupt`,mutation({epoch:2}));assert.equal(interrupted.body.call.epoch,3);
  await Promise.all(tasks);
  // Cancellation acknowledgement is asynchronous to the fetch abort.
  for(let i=0;i<30 && cancelCount===0;i++)await new Promise(resolve=>setTimeout(resolve,50));
  assert.equal(cancelCount,1);
  const record=(await api(`/calls/${call}/record`)).body;assert.equal(record.messages.at(-1).status,'interrupted');assert.equal(record.messages.at(-1).text,'fixture first');
  const late=await store.command(owner,'reply.completed',mutation({call_id:call,reply_id:accepted.body.reply_id,epoch:2,text:'late'})).catch(error=>error);
  assert.equal(late.code,'stale_epoch');
  const ended=await api(`/calls/${call}/end`,mutation({epoch:3}));assert.equal(ended.body.call.status,'ended');
  assert.equal((await api(`/calls/${call}/events`)).body.events.at(-1).type,'call.ended');
  stall=false;
});
test('MCP dial waits for answer and returns first-call instructions once without protocol metadata',async()=>{
  const headers={Accept:'application/json, text/event-stream'};
  const rpc=async(method,params,token='test-owner')=>(await api('/mcp',{jsonrpc:'2.0',id:1,method,params},token,headers)).body;
  const tool=async(name,args={},token)=>(await rpc('tools/call',{name,arguments:args},token)).result;
  const definitions=(await rpc('tools/list',{})).result.tools;
  assert.equal(definitions.length,6);
  const reply=definitions.find(item=>item.name==='tincall_reply').inputSchema;
  assert.deepEqual(reply.required,['call','text']);assert.deepEqual(Object.keys(reply.properties).sort(),['call','text','wait_for_input']);
  assert.deepEqual(definitions.find(item=>item.name==='tincall_wait').inputSchema.properties,{call:{type:'string',minLength:8,maxLength:8}});
  let settled=false;
  const dial=tool('tincall_call',{contact_id:'tools',timeout_seconds:3}).then(value=>{settled=true;return value;});
  let call;
  for(let i=0;i<100;i++) {
    call=(await store.command(owner,'call.current',{})).call;
    if(call)break;
    await new Promise(resolve=>setTimeout(resolve,10));
  }
  assert.equal(call.status,'ringing');assert.equal(settled,false,'dial must stay pending while the phone rings');
  await api(`/calls/${call.id}/answer`,mutation({epoch:0,user_name:'小白',expression_prompt:'Speak naturally.'}));
  const answered=await dial;
  assert.equal(answered.isError,false);assert.match(answered.content[0].text,/已接通/);assert.match(answered.content[0].text,/Speak naturally/);
  assert.equal(answered.structuredContent,undefined);
  assert.equal(answered.content.find(block=>block.text?.startsWith('call: '))?.text,'call: '+callReference(call.id));
  assert.doesNotMatch(JSON.stringify(answered),/reply_to|epoch|sequence|cursor|收到对方|回复已接收/);
  const beforeInvalid=(await api(`/calls/${call.id}/events`)).body.events;
  const invalid=await tool('tincall_reply',{reply_to:crypto.randomUUID(),text:'Hello there.',wait_for_input:false});
  assert.deepEqual(invalid,{content:[{type:'text',text:'回复未发送：请按当前工具定义提交正文和必要参数，移除多余参数后重试。'}],isError:true});
  assert.deepEqual((await api(`/calls/${call.id}/events`)).body.events,beforeInvalid,'a rejected reply must not be sent');
  const sent=await tool('tincall_reply',{call:callReference(call.id),text:'Hello there.',wait_for_input:false});
  assert.equal(sent.isError,false);assert.deepEqual(sent.content,[{type:'text',text:'已发送。'}]);
  const timeout=await tool('tincall_wait',{timeout_seconds:1});
  assert.match(timeout.content[0].text,/尚未回复/);assert.match(timeout.content[0].text,/tincall_wait/);assert.doesNotMatch(timeout.content[0].text,/朗读要求|Speak naturally|get_call/);
  assert.equal(timeout.content.find(block=>block.text?.startsWith('call: '))?.text,'call: '+callReference(call.id),'discovering a call without a marker must return it');
  assert.equal((await tool('tincall_get_call',{call_id:call.id},'test-role')).isError,true);
  await tool('tincall_end',{call:callReference(call.id)});
  const events=(await api(`/calls/${call.id}/events`)).body.events;
  assert.equal(events.at(-2).type,'reply.completed');assert.equal(events.at(-1).payload.reason,'mcp_hangup');
  assert.equal((await tool('tincall_end',{call:callReference(call.id)})).isError,true);
});
test('MCP get_call announces a phone-origin call once without consuming unread input',async()=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  const id=crypto.randomUUID();
  await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白',expression_prompt:'Synthetic first-call rule.'}));
  try {
    const first=await tool('tincall_get_call');
    assert.match(first.content[0].text,/通话已接通，可以通过 tincall_reply 工具打招呼了。/);
    assert.match(first.content[0].text,/Synthetic first-call rule/);
    assert.doesNotMatch((await tool('tincall_get_call')).content[0].text,/打招呼|朗读要求/);
    await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'Synthetic unread input.'}));
    assert.match((await tool('tincall_get_call')).content[0].text,/Synthetic unread input/);
    assert.equal((await tool('tincall_wait',{timeout_seconds:1})).content[0].text,'<message name="小白">\n  <text>Synthetic unread input.</text>\n</message>');
  } finally {await tool('tincall_end',{call:callReference(id)});}
});
test('MCP first reply waits for new input instead of replaying the answer',async t=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  for(const readFirst of [true,false])await t.test(readFirst?'after get_call':'direct reply',async()=>{
    const id=crypto.randomUUID();
    await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白'}));
    let pending,settled=false;
    try {
      if(readFirst)await tool('tincall_get_call');
      pending=tool('tincall_reply',{call:callReference(id),text:'Synthetic first reply.',timeout_seconds:3}).then(result=>{settled=true;return result;});
      for(let i=0;i<100;i++) {
        if((await api(`/calls/${id}/record`)).body.messages.some(message=>message.text==='Synthetic first reply.'))break;
        await new Promise(resolve=>setTimeout(resolve,10));
      }
      await new Promise(resolve=>setTimeout(resolve,50));
      assert.equal(settled,false,'submitting a reply must not return an opening greeting');
      await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'Synthetic next question.'}));
      const result=await pending;
      assert.equal(result.content.some(block=>block.text?.startsWith('call: ')),false,'a reply in a known call must not repeat its marker');
      const text=result.content[0].text;
      assert.equal(text.split('\n\n')[0],'<message name="小白">\n  <text>Synthetic next question.</text>\n</message>');
      assert.doesNotMatch(text,/打招呼/);
      if(readFirst)assert.doesNotMatch(text,/朗读要求/);
    } finally {await tool('tincall_end',{call:callReference(id)});await pending;}
  });
});
test('MCP unanswered dial times out into wait and a rejected call returns ended',async()=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  const timeout=await tool('tincall_call',{contact_id:'tools',timeout_seconds:1});
  assert.match(timeout.content[0].text,/尚未接听/);assert.match(timeout.content[0].text,/tincall_wait/);
  const current=(await store.command(owner,'call.current',{})).call;
  const wait=tool('tincall_wait',{timeout_seconds:3});
  await api(`/calls/${current.id}/answer`,mutation({epoch:0,expression_prompt:'Late answer rule'}));
  const answered=await wait;assert.match(answered.content[0].text,/已接通/);assert.match(answered.content[0].text,/Late answer rule/);
  await api(`/calls/${current.id}/end`,mutation({epoch:0}));
  assert.match((await tool('tincall_wait',{timeout_seconds:1})).content[0].text,/已结束/);
});
test('MCP wait and reply keep waiting through playback interruption',async t=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  for(const name of ['tincall_wait','tincall_reply'])await t.test(name,async()=>{
    const id=crypto.randomUUID();
    await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白'}));
    let pending;
    try {
      await tool('tincall_wait',{timeout_seconds:1});
      if(name==='tincall_wait')await api(`/calls/${id}/interrupt`,mutation({epoch:0}));
      pending=tool(name,{call:callReference(id),timeout_seconds:3,...(name==='tincall_reply'?{text:'Synthetic complete reply.'}:{})});
      if(name==='tincall_reply') {
        for(let i=0;i<100;i++) {
          if((await api(`/calls/${id}/record`)).body.messages.some(message=>message.text==='Synthetic complete reply.'))break;
          await new Promise(resolve=>setTimeout(resolve,10));
        }
        await api(`/calls/${id}/interrupt`,mutation({epoch:0}));
      }
      await new Promise(resolve=>setTimeout(resolve,1100));
      await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'Synthetic next sentence.'}));
      assert.deepEqual((await pending).content,[{type:'text',text:'<message name="小白">\n  <text>Synthetic next sentence.</text>\n</message>'}]);
      const ending=tool('tincall_wait',{timeout_seconds:3});
      await api(`/calls/${id}/end`,mutation({epoch:2}));
      assert.equal((await ending).content[0].text,'通话已结束。');
    } finally {
      await tool('tincall_end',{call:callReference(id)});
      await pending;
    }
  });
});
test('MCP overlapping waits do not invent playback interruption after input delivery',async()=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  const id=crypto.randomUUID();
  await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白'}));
  let release,ready,reads=0,pending;
  const blocked=new Promise(resolve=>{release=resolve;});
  const polling=new Promise(resolve=>{ready=resolve;});
  const delayed=createConnector({store:{...store,async mcpCommand(...args){
    if(args[2]==='snapshot' && args[3]?.unread && args[3].limit===100 && ++reads===1){ready();await blocked;}
    return store.mcpCommand(...args);
  }},config:{},schedule:()=>{}});
  try {
    await tool('tincall_wait',{timeout_seconds:1});
    await tool('tincall_reply',{call:callReference(id),text:'Synthetic finished reply.',wait_for_input:false});
    pending=delayed.handle(new Request('http://localhost/mcp',{method:'POST',headers:{Authorization:'Bearer test-owner','Content-Type':'application/json',Accept:'application/json, text/event-stream'},body:JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'tincall_wait',arguments:{timeout_seconds:1}}})}));
    await polling;
    await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'Synthetic next question.'}));
    assert.equal((await tool('tincall_wait',{timeout_seconds:1})).content[0].text,'<message name="小白">\n  <text>Synthetic next question.</text>\n</message>');
    release();
    const result=(await (await pending).json()).result;
    assert.equal(result.isError,false);
    assert.equal(result.content[0].text,'尚未回复，通话仍在继续。请调用 tincall_wait 继续等待。');
    assert.equal((await api(`/calls/${id}/events`)).body.events.some(event=>event.type==='call.interrupted'),false);
  } finally {
    release();await tool('tincall_end',{call:callReference(id)});await pending;
  }
});
test('MCP complete text survives interruption and waits only for unread inputs',async()=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  const id=crypto.randomUUID();await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白',expression_prompt:'Speak naturally.'}));
  await tool('tincall_wait',{timeout_seconds:1});
  await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'first question'}));
  assert.equal((await tool('tincall_wait',{timeout_seconds:1})).content[0].text,'<message name="小白">\n  <text>first question</text>\n</message>');
  await api(`/calls/${id}/interrupt`,mutation({epoch:1}));
  assert.equal((await tool('tincall_reply',{call:callReference(id),text:'A complete new reply after interruption.',wait_for_input:false})).isError,false);
  const record=(await api(`/calls/${id}/record`)).body;
  assert.equal(record.messages.at(-1).text,'A complete new reply after interruption.');assert.equal(record.messages.at(-1).status,'complete');
  const events=(await api(`/calls/${id}/events`)).body.events;
  assert.equal(events.at(-2).type,'reply.started');assert.equal(events.at(-2).payload.submitted,true);assert.equal(events.at(-1).type,'reply.completed');assert.equal(events.at(-1).payload.submitted,true);
  let settled=false;
  const pending=tool('tincall_reply',{call:callReference(id),text:'Another complete sentence.',timeout_seconds:3}).then(value=>{settled=true;return value;});
  for(let i=0;i<100;i++) {
    const saved=(await api(`/calls/${id}/record`)).body.messages;
    if(saved.at(-1).text==='Another complete sentence.')break;
    await new Promise(resolve=>setTimeout(resolve,10));
  }
  assert.equal(settled,false);
  await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:2,text:'next question'}));
  assert.equal((await pending).content[0].text,'<message name="小白">\n  <text>next question</text>\n</message>');
  const again=await tool('tincall_wait',{timeout_seconds:1});assert.match(again.content[0].text,/尚未回复/);assert.doesNotMatch(again.content[0].text,/next question|朗读要求/);
  // A reconnect uses persisted delivery progress, not process memory.
  const reconnected=createConnector({store,config:{},schedule:()=>{}});
  const response=await reconnected.handle(new Request('http://localhost/mcp',{method:'POST',headers:{Authorization:'Bearer test-owner',Accept:'application/json, text/event-stream','Content-Type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'tincall_wait',arguments:{timeout_seconds:1}}})}));
  assert.match((await response.json()).result.content[0].text,/尚未回复/);
  await tool('tincall_end',{call:callReference(id)});
  assert.equal((await tool('tincall_reply',{call:callReference(id),text:'Must not start another call.'})).isError,true);
});
test('MCP short call markers reject delayed operations, missing context, other contacts and ambiguous prefixes',async()=>{
  const headers={Accept:'application/json, text/event-stream'};
  const tool=async(name,args={},token='test-owner')=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token,headers)).body.result;
  const a=crypto.randomUUID(),b=crypto.randomUUID();
  await api('/calls',mutation({call_id:a,contact_id:'tools',source:'mcp'}));
  const observed=await tool('tincall_get_call');
  const marker=observed.content.find(block=>block.text?.startsWith('call: ')).text.slice(6);
  assert.match(marker,/^[A-Za-z0-9_-]{8}$/);
  await api(`/calls/${a}/end`,mutation({epoch:0}));
  await api('/calls',mutation({call_id:b,contact_id:'tools',source:'mcp'}));
  const before=(await api(`/calls/${b}/record`)).body;
  for(const name of ['tincall_reply','tincall_end'])for(const context of [{call:marker},{},{call:callReference(b)}]) {
    const result=await tool(name,{...context,...(name==='tincall_reply'?{text:'Stale task text',wait_for_input:false}:{})},context.call===callReference(b)?'test-role':'test-owner');
    assert.equal(result.isError,true);
    assert.deepEqual((await api(`/calls/${b}/record`)).body,before,'call B must remain unchanged');
  }
  assert.equal((await tool('tincall_reply',{call:callReference(b),text:'Current call text',wait_for_input:false})).isError,false);
  assert.equal((await tool('tincall_end',{call:callReference(b)})).isError,false);
  const first='12345678-1234-4000-8000-000000000001',second='12345678-1234-4000-8000-000000000002';
  await api('/calls',mutation({call_id:first,contact_id:'tools',source:'mcp'}));
  await api(`/calls/${first}/end`,mutation({epoch:0}));
  await api('/calls',mutation({call_id:second,contact_id:'tools',source:'mcp'}));
  const collided=(await api(`/calls/${second}/record`)).body;
  assert.equal(callReference(first),callReference(second));
  assert.equal((await tool('tincall_reply',{call:callReference(second),text:'Ambiguous text',wait_for_input:false})).isError,true);
  assert.equal((await tool('tincall_end',{call:callReference(second)})).isError,true);
  assert.deepEqual((await api(`/calls/${second}/record`)).body,collided);
  if(!sqlite)for(const role of ['anon','authenticated'])assert.throws(()=>sql(`set role ${role};select public.tincall_resolve_call_context(${sqlQuote(owner)}::uuid,null,'123456781234');`));
  await api(`/calls/${second}/end`,mutation({epoch:0}));
});
test('MCP internal send retries are durable and do not append or duplicate complete text',async()=>{
  const id=crypto.randomUUID();await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp'}));
  const payload=mutation({call_id:id,text:'Synthetic complete message'});
  const accepted=await store.mcpCommand(owner,null,'send',payload);
  assert.deepEqual(await store.mcpCommand(owner,null,'send',payload),accepted);
  await assert.rejects(()=>store.mcpCommand(owner,null,'send',{...payload,text:'Changed'}));
  assert.equal((await api(`/calls/${id}/events`)).body.events.filter(event=>event.type==='reply.completed').length,1);
  await api(`/calls/${id}/end`,mutation({epoch:0}));
});
test('MCP wait drains all unread pages internally without replay or caller cursors',async()=>{
  const id=crypto.randomUUID();await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白'}));
  for(let epoch=0;epoch<105;epoch++)await store.command(owner,'call.input',mutation({call_id:id,message_id:crypto.randomUUID(),epoch,text:'Synthetic '+epoch,mode:'tools'}));
  const tool=async()=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'tincall_wait',arguments:{timeout_seconds:1}}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  const first=await tool();
  assert.equal((first.content[0].text.match(/<message name="小白">/g)||[]).length,105);assert.doesNotMatch(JSON.stringify(first),/cursor|epoch|sequence|reply_to/);
  assert.match((await tool()).content[0].text,/尚未回复/);
  await store.command(owner,'call.end',mutation({call_id:id,epoch:105}));
});
test('cloud record revisions retain deletion tombstones and reject stale uploads',async()=>{
  const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const original=mutation({expected_revision:0,record:{fixture:true}});
  const first=await api(`/records/${id.toUpperCase()}`,original);assert.equal(first.body.record.revision,1);
  assert.equal((await api(`/records/${id}/delete`,mutation({expected_revision:1}))).body.record.deleted,true);
  assert.equal((await api(`/records/${id}`,mutation({expected_revision:1,record:{old:true}}))).body.error.code,'revision_conflict');
  assert.equal((await api(`/records/${id}`)).body.record.revision,2);
  assert.equal((await api(`/records/${id}`,undefined,'test-other')).body.record,null);
  assert.equal((await api(`/records/${id}/media/${crypto.randomUUID()}`)).status,410);
  assert.equal((await api(`/records/${id.toUpperCase()}`,original)).body.error.code,'operation_retired');
  if(sqlite){const receipt=database.prepare('select * from tincall_requests where request_id=?').get(original.request_id);assert.equal(receipt.retired,1);assert.equal(JSON.parse(receipt.payload).record,undefined);assert.deepEqual(JSON.parse(receipt.response),{});}
  else assert.equal(sql(`select retired and not (payload ? 'record') and response='{}'::jsonb from public.tincall_requests where request_id=${sqlQuote(original.request_id)};`),'t');
  assert.equal((await api('/capabilities')).body.owner_id,owner);
  assert.equal((await api('/records',undefined,'test-role')).status,403);
});
test('backup-only deletion preserves MCP history and images, schedules, and other owners while clearing backup media',async()=>{
  const id=crypto.randomUUID(),image=picture(),backupImage=picture(),audio=crypto.randomUUID();
  assert.equal((await api('/capabilities')).body.backup_only_deletion,true);
  await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp'}));
  await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'Synthetic image',images:[image]}));
  const messages=(await api(`/calls/${id}/record`)).body.messages;
  const uploaded=mutation({expected_revision:0,record:{messages:[...messages,{id:crypto.randomUUID(),text:'Backup only',images:[backupImage]}]}});
  assert.equal((await api(`/records/${id}`,uploaded)).status,200);
  assert.equal((await api(`/records/${id}`,mutation({expected_revision:0,record:{other:true}}),'test-other')).status,200);
  await store.media(owner,id,audio,new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:new Uint8Array([1,2,3,4])}));
  const request=mutation({expected_revision:1});
  assert.equal((await api(`/records/${id}/delete-backup`,request,'test-role')).status,403);
  assert.equal((await api(`/records/${id}/delete-backup`,request)).body.error.code,'call_busy');
  assert.equal((await api(`/records/${id}`)).body.record.deleted,false);
  await api(`/calls/${id}/end`,mutation({epoch:1}));
  const history=(await api(`/calls/${id}/record`)).body;
  const schedule=crypto.randomUUID();
  await api('/schedules',mutation({schedule_id:schedule,contact_id:'independent-fixture',source:'independent',next_at:'2050-01-01T00:00:00Z'}));
  const schedules=(await api('/schedules')).body;
  // A backup upload already in flight must not clean MCP media after deletion wins.
  const lateImage=picture();
  const racing=createConnector({config:{},store:{...store,async media(...args){
    const result=await store.media(...args);
    if(args[2]===lateImage.id && args[3].method==='PUT')assert.equal((await api(`/records/${id}/delete-backup`,request)).status,200);
    return result;
  }}});
  const late=await racing.handle(new Request(`http://localhost/records/${id}`,{method:'POST',headers:{Authorization:'Bearer test-owner','Content-Type':'application/json'},
    body:JSON.stringify(mutation({expected_revision:1,record:{messages:[{id:crypto.randomUUID(),images:[lateImage]}]}}))}));
  assert.equal((await late.json()).error.code,'record_deleted');
  assert.equal((await api(`/records/${id}/delete-backup`,request)).status,200);
  assert.equal((await api(`/records/${id}/delete-backup`,request)).status,200);
  assert.equal((await api(`/records/${id}`)).body.record.deleted,true);
  assert.equal((await api(`/records/${id}`,undefined,'test-other')).body.record.deleted,false);
  assert.deepEqual((await api(`/calls/${id}/record`)).body,history);
  assert.deepEqual((await api('/schedules')).body,schedules);
  assert.equal((await api(`/records/${id}`,uploaded)).body.error.code,'record_deleted');
  const response=await connector.handle(new Request(`http://localhost/records/${id}/media/${image.id}`,{headers:{Authorization:'Bearer test-owner'}}));
  assert.equal(response.status,200);assert.equal(Buffer.from(await response.arrayBuffer()).toString('base64'),pngData);
  await assert.rejects(store.media(owner,id,audio,new Request('http://localhost/media')),{code:'media_not_found'});
  await assert.rejects(store.media(owner,id,backupImage.id,new Request('http://localhost/media')),{code:'media_not_found'});
  await assert.rejects(store.media(owner,id,lateImage.id,new Request('http://localhost/media')),{code:'media_not_found'});
  const mcp=(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'tincall_get_call',arguments:{call_id:id}}},'test-owner',
    {Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'})).body.result;
  assert.equal(mcp.isError,false);assert.ok(mcp.content.some(item=>item.type==='image'));
  await api('/schedules/remove',mutation({schedule_id:schedule}));
});

test('Supabase media cleanup can skip more than one page of retained MCP images',async()=>{
  const prefix=`${owner}/${crypto.randomUUID()}/`,keep=Array.from({length:105},()=>crypto.randomUUID()).sort();
  const removed=Array.from({length:120},()=>crypto.randomUUID());
  const files=new Set([...keep,...removed]);
  const adapter=createSupabaseStore({supabaseURL:'https://fixture.invalid',publicKey:'fixture',serviceKey:'fixture'},async(url,init)=>{
    const body=JSON.parse(init.body);
    if(url.endsWith('/object/list/tincall-private')) {
      assert.equal(body.prefix,prefix);
      return Response.json([...files].sort().slice(body.offset,body.offset+body.limit).map(name=>({name})));
    }
    assert.equal(init.method,'DELETE');
    for(const path of body.prefixes){assert.ok(path.startsWith(prefix));files.delete(path.slice(prefix.length));}
    return Response.json({});
  });
  await adapter.deleteRecordMedia(owner,prefix.split('/')[1],keep);
  assert.deepEqual([...files].sort(),keep);
});

test('daily schedules preserve local clock time over DST and the worker creates real incoming jobs',async()=>{
  assert.equal(sqlite?nextDaily('09:00','America/New_York',new Date('2026-03-07T15:00:00Z')):sql("select public.tincall_next_daily('09:00','America/New_York','2026-03-07T15:00:00Z') at time zone 'UTC';"),sqlite?'2026-03-08T13:00:00.000Z':'2026-03-08 13:00:00');
  const schedule=crypto.randomUUID();
  assert.equal((await api('/schedules',mutation({schedule_id:schedule,contact_id:'independent-fixture',source:'independent',next_at:'2020-01-01T00:00:00Z'}))).status,200);
  await connector.runWorker();
  const current=(await api('/calls/current')).body.call;assert.equal(current.status,'ringing');assert.equal(current.source,'independent');
  const record=(await api(`/calls/${current.id}/record`)).body;assert.equal(record.push.status,'failed');assert.equal(record.push.error_code,'push_not_configured');
  assert.equal((await api('/schedules')).body.schedules.find(s=>s.id===schedule).enabled,false);
  const beforeGenerations=generationCount;
  assert.equal((await api(`/calls/${current.id}/answer`,mutation({epoch:0}))).body.call.status,'active');
  assert.equal(sqlite?String(database.prepare('select count(*) n from tincall_jobs where call_id=?').get(current.id).n):sql(`select count(*) from public.tincall_jobs where call_id=${sqlQuote(current.id)};`),'0');
  await api(`/calls/${current.id}/end`,mutation({epoch:0,reason:'hangup'}));
  assert.equal(generationCount,beforeGenerations);
  const daily=crypto.randomUUID();
  const callPreferenceOnSchedule=await api('/schedules',mutation({schedule_id:daily,contact_id:'independent-fixture',source:'independent',daily_time:'09:00',time_zone:'Asia/Shanghai',time_awareness_enabled:true}));
  assert.equal(callPreferenceOnSchedule.status,400);
  assert.equal(callPreferenceOnSchedule.body.error.code,'invalid_time_awareness');
  assert.equal((await api('/schedules',mutation({schedule_id:daily,contact_id:'independent-fixture',source:'independent',daily_time:'09:00',time_zone:'Asia/Shanghai'}))).status,200);
  const saved=(await api('/schedules')).body.schedules.find(s=>s.id===daily);assert.equal(saved.daily_time,'09:00:00');assert.equal(saved.time_zone,'Asia/Shanghai');assert.equal(saved.enabled,true);
  assert.deepEqual((await api('/schedules/remove',mutation({schedule_id:daily}))).body,{ok:true});
});
test('schedule controls pause, preserve edits, resume, deduplicate and repeat weekly',async()=>{
  const id=crypto.randomUUID(),save=mutation({schedule_id:id,contact_id:'independent-fixture',source:'independent',daily_time:'09:00',time_zone:'Asia/Shanghai',week_day:1});
  const get=async()=> (await api('/schedules')).body.schedules.find(s=>s.id===id);
  assert.equal((await api('/schedules',save)).status,200);
  assert.equal((await get()).week_day,1);
  const pause=mutation({schedule_id:id,enabled:false});
  assert.equal((await api('/schedules/enabled',pause)).status,200);
  assert.equal((await get()).enabled,false);
  const edit=mutation({...save,request_id:crypto.randomUUID(),enabled:false,daily_time:'10:00',week_day:5});
  assert.equal((await api('/schedules',edit)).status,200);
  assert.equal((await get()).enabled,false);
  assert.equal((await get()).week_day,5);
  const forceDue=()=>sqlite?database.prepare('update tincall_schedules set next_at=? where id=?').run('2020-01-03T02:00:00.000Z',id):sql(`update public.tincall_schedules set next_at='2020-01-03T02:00:00Z' where id=${sqlQuote(id)};`);
  forceDue();await connector.runWorker();
  assert.equal((await api('/calls/current')).body.call,null,'paused due plans cannot ring');
  const resume=mutation({schedule_id:id,enabled:true});
  assert.equal((await api('/schedules/enabled',resume)).status,200);
  assert.equal((await get()).enabled,true);
  assert.ok(Date.parse((await get()).next_at)>Date.now(),'resume schedules a future occurrence');
  assert.equal((await api('/schedules/enabled',pause)).status,200,'lost pause response may be retried');
  assert.equal((await api('/schedules',edit)).status,200,'lost edit response may be retried');
  assert.equal((await get()).enabled,true,'old receipts must not undo the newer resume');
  assert.equal((await api('/schedules/enabled',{...pause,enabled:true})).status,409);
  assert.equal((await api('/schedules/enabled',mutation({schedule_id:id,enabled:false}),'test-role')).status,403);
  assert.equal((await api('/schedules/enabled',mutation({schedule_id:id,enabled:false}),'test-other')).status,404);
  assert.equal((await api('/schedules/enabled',mutation({schedule_id:id,enabled:'false'}))).status,400);
  assert.equal((await api('/schedules',mutation({...save,request_id:crypto.randomUUID(),week_day:8}))).status,400);
  forceDue();await connector.runWorker();
  const call=(await api('/calls/current')).body.call;assert.equal(call.status,'ringing');
  const next=new Date((await get()).next_at);
  assert.equal(new Intl.DateTimeFormat('en-US',{timeZone:'Asia/Shanghai',weekday:'long'}).format(next),'Friday');
  assert.ok(next>Date.now());
  await api(`/calls/${call.id}/end`,mutation({epoch:call.epoch,reason:'hangup'}));
  assert.equal((await api('/schedules',mutation({...save,request_id:crypto.randomUUID(),week_day:null}))).status,200);
  assert.equal((await get()).week_day,null,'switching to daily clears the weekday');
  assert.deepEqual((await api('/schedules/remove',mutation({schedule_id:id}))).body,{ok:true});
  if(sqlite) {
    assert.equal(nextDaily('09:00','America/New_York',new Date('2026-03-07T15:00:00Z'),7),'2026-03-08T13:00:00.000Z');
    assert.equal(nextDaily('09:00','America/New_York',new Date('2026-03-08T14:00:00Z'),7),'2026-03-15T13:00:00.000Z');
  } else {
    sql(`insert into public.tincall_schedules(id,owner_id,contact_id,source,next_at,daily_time,time_zone,week_day) values(${sqlQuote(id)},${sqlQuote(owner)},'fixture','independent','2026-03-07T14:00:00Z','09:00','America/New_York',7);`);
    assert.equal(sql(`select next_at at time zone 'UTC' from public.tincall_schedules where id=${sqlQuote(id)};`),'2026-03-08 13:00:00');
    await api('/schedules/remove',mutation({schedule_id:id}));
  }
});

test('backup index pagination keeps equal timestamps and never returns full record bodies',async()=>{
  if(sqlite){const insert=database.prepare('insert into tincall_records(owner_id,id,record,updated_at) values (?,?,?,?)');for(let i=0;i<101;i++)insert.run(owner,crypto.randomUUID(),'{"fixture":true}','2030-01-01T00:00:00.000Z');}
  else sql(`insert into public.tincall_records(owner_id,id,record,updated_at) select ${sqlQuote(owner)},gen_random_uuid(),'{"fixture":true}','2030-01-01' from generate_series(1,101);`);
  const first=(await api('/records?after=2029-01-01T00:00:00Z')).body;
  assert.equal(first.records.length,100);assert.ok(first.records.every(record=>record.record===undefined));
  const last=(await api(`/records?after=${encodeURIComponent(first.next_cursor.after)}&after_id=${first.next_cursor.after_id}`)).body;
  assert.equal(last.records.length,1);assert.ok(!first.records.some(record=>record.id===last.records[0].id));
});

test('event long polling returns existing pages, waits for new durable events, times out and cancels',async()=>{
  const callID=crypto.randomUUID();
  assert.equal((await api('/calls',mutation({call_id:callID,contact_id:'poll-http',source:'backend'}))).status,200);
  const immediate=await api(`/calls/${callID}/events?after=0&limit=1&wait=20`);
  assert.equal(immediate.status,200);
  assert.equal(immediate.body.events[0].type,'call.started');
  assert.equal(immediate.body.cursor,1);
  for(const wait of ['', '&wait=0']) {
    const started=performance.now();
    const empty=await api(`/calls/${callID}/events?after=1${wait}`);
    assert.deepEqual(empty.body.events,[]);
    assert.equal(empty.body.cursor,1);
    assert.ok(performance.now()-started<1000,'legacy empty reads return immediately');
  }
  let returned=false;
  const waiting=api(`/calls/${callID}/events?after=1&wait=20`).then(value=>{returned=true;return value;});
  await new Promise(resolve=>setTimeout(resolve,100));
  assert.equal(returned,false);
  // Write through the store, as a separate worker/instance would, not the HTTP handler.
  await store.command(owner,'call.input',mutation({call_id:callID,message_id:crypto.randomUUID(),epoch:0,text:'synthetic input',mode:'http'}));
  const awakened=await waiting;
  assert.equal(awakened.status,200);
  assert.ok(awakened.body.events.some(event=>event.type==='reply.started'));
  assert.equal(awakened.body.call.tts_expression_prompt,undefined);
  const page=await api(`/calls/${callID}/events?after=0&limit=1&wait=20`);
  assert.equal(page.body.has_more,true);
  assert.equal(page.body.events.length,1);
  const cursor=awakened.body.cursor;
  const started=performance.now();
  const timeout=await api(`/calls/${callID}/events?after=${cursor}&wait=1`);
  assert.equal(timeout.status,200);
  assert.deepEqual(timeout.body.events,[]);
  assert.equal(timeout.body.cursor,cursor);
  assert.equal(timeout.body.has_more,false);
  assert.ok(performance.now()-started>=950,'empty request holds until its wait expires');
  for(const wait of ['-1','1.5','invalid']) {
    const invalid=await api(`/calls/${callID}/events?after=${cursor}&wait=${wait}`);
    assert.equal(invalid.status,400);
    assert.equal(invalid.body.error.code,'invalid_wait');
  }
  assert.equal((await api(`/calls/${callID}/events?after=${cursor+1}&wait=20`)).body.error.code,'invalid_cursor');
  assert.equal((await api(`/calls/${callID}/events?wait=20`,undefined,'test-other')).status,404);
  assert.equal((await api(`/calls/${callID}/events?wait=20`,undefined,'test-role')).status,403);
  const controller=new AbortController();
  const cancelled=connector.handle(new Request(`http://localhost/calls/${callID}/events?after=${cursor}&wait=20`,{
    headers:{Authorization:'Bearer test-owner'},signal:controller.signal,
  }));
  await new Promise(resolve=>setTimeout(resolve,100));
  const cancelling=performance.now();
  controller.abort();
  assert.equal((await (await cancelled).json()).error.code,'wait_cancelled');
  assert.ok(performance.now()-cancelling<500,'disconnect cancels the pending wait');
  await api(`/calls/${callID}/end`,mutation({epoch:1,reason:'hangup'}));
});

test('event wait is capped at 25 seconds',async(t)=>{
  const callID=crypto.randomUUID();
  await api('/calls',mutation({call_id:callID,contact_id:'poll-http',source:'backend'}));
  t.mock.timers.enable({apis:['Date','setTimeout']});
  let returned=false;
  const pending=api(`/calls/${callID}/events?after=1&wait=999`).then(value=>{returned=true;return value;});
  await new Promise(resolve=>setImmediate(resolve));
  t.mock.timers.tick(24999);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(returned,false);
  t.mock.timers.tick(1);
  const result=await pending;
  assert.equal(result.status,200);
  assert.deepEqual(result.body.events,[]);
  t.mock.timers.reset();
  await api(`/calls/${callID}/end`,mutation({epoch:0,reason:'hangup'}));
});


test('MCP history uses short call IDs for lookup and both pagination links',async()=>{
  const headers={Accept:'application/json, text/event-stream'};
  const tool=async(name,args={},token='test-role')=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token,headers)).body.result;
  const ids=[];
  for(let index=0;index<3;index++) {
    const id=crypto.randomUUID();ids.push(id);
    await store.command(owner,'call.create',mutation({call_id:id,contact_id:'one',source:'mcp'}));
    for(let message=0;message<3;message++)await store.command(owner,'call.input',mutation({call_id:id,message_id:crypto.randomUUID(),epoch:message,text:`History ${index}/${message}`,mode:'tools'}));
    await store.command(owner,'call.end',mutation({call_id:id,epoch:3}));
  }
  const list=await tool('tincall_list_calls',{limit:2});
  assert.equal(list.isError,false);
  const text=list.content[0].text;
  const markers=[...text.matchAll(/call_id: ([^\n]+)/g)].map(match=>match[1]);
  assert.equal(markers.length,2);for(const marker of markers)assert.match(marker,/^[A-Za-z0-9_-]{8}$/);
  const nextList=JSON.parse(text.split('还有通话记录：tincall_list_calls ')[1]);
  assert.match(nextList.before.call_id,/^[A-Za-z0-9_-]{8}$/);
  const older=await tool('tincall_list_calls',{...nextList,limit:2});
  assert.equal(older.isError,false);
  assert.ok(older.content[0].text.includes('call_id: '));
  for(const marker of markers)assert.equal(older.content[0].text.includes('call_id: '+marker),false);
  const history=await tool('tincall_get_call',{call_id:markers[0],limit:1});
  assert.equal(history.isError,false);
  assert.equal(history.content.find(block=>block.text?.startsWith('call: '))?.text,'call: '+markers[0]);
  const nextMessages=JSON.parse(history.content[0].text.split('还有更早的消息：tincall_get_call ')[1]);
  assert.equal(nextMessages.call_id,markers[0]);
  const earlier=await tool('tincall_get_call',{...nextMessages,limit:1});
  assert.equal(earlier.isError,false);assert.notEqual(earlier.content[0].text,history.content[0].text);
  assert.equal((await tool('tincall_get_call',{call_id:markers[0]},'test-other')).isError,true);
  assert.equal((await tool('tincall_get_call',{call_id:ids[0]})).isError,false,'existing UUID lookups remain valid');
});

test('MCP recent calls limits after identity filtering and summary uploads replace durably',async()=>{
  const headers={Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'};
  const tool=(name,args={},token='test-role')=>api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token,headers);
  const list=async(args={},token='test-role')=>{
    const result=(await tool('tincall_list_calls',args,token)).body.result;
    assert.equal(result.structuredContent,undefined);
    if(result.isError)return result;
    return {...result,data:await store.mcpCommand(token==='test-other'?other:owner,token==='test-role'?'one':null,'list',{limit:10,...args})};
  };
  const definitions=(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/list'},'test-role',headers)).body.result.tools;
  assert.deepEqual(definitions.find(t=>t.name==='tincall_list_calls').inputSchema.properties.limit,{type:'integer',minimum:1,maximum:50,default:10});
  const owned=[];
  for(let i=0;i<52;i++) {
    const id=crypto.randomUUID(); owned.push(id);
    await store.command(owner,'call.create',mutation({call_id:id,contact_id:'one',source:'mcp'}));
    await store.command(owner,'call.end',mutation({call_id:id,epoch:0}));
  }
  // More than the old 100-row HTTP cap, all belonging to another contact.
  for(let i=0;i<101;i++) {
    const id=crypto.randomUUID();
    await store.command(owner,'call.create',mutation({call_id:id,contact_id:'unrelated',source:'mcp'}));
    await store.command(owner,'call.end',mutation({call_id:id,epoch:0}));
  }
  const foreign=crypto.randomUUID();
  await store.command(other,'call.create',mutation({call_id:foreign,contact_id:'one',source:'mcp'}));
  const defaultList=await list();
  assert.equal(defaultList.isError,false);assert.equal(defaultList.data.calls.length,10);
  const calls=(await list({limit:50})).data.calls;
  assert.equal(calls.length,50);
  const firstPage=(await list({limit:50})).data;
  assert.equal(firstPage.has_more,true);
  const older=(await list({limit:50,before:firstPage.next_cursor})).data;
  assert.ok(older.calls.length>=2 && older.calls.every(c=>!calls.some(first=>first.call_id===c.call_id)));
  assert.equal(older.has_more,false);
  assert.ok(calls.every(c=>owned.includes(c.call_id)));
  assert.ok(calls.every(c=>c.status==='ended' && c.ended_at && c.has_summary===false));
  assert.deepEqual(Object.keys(calls[0]).sort(),['call_id','started_at','ended_at','status','has_summary'].sort());
  assert.ok(calls.every((c,i)=>i===0 || Date.parse(c.started_at)<=Date.parse(calls[i-1].started_at)));
  assert.equal((await list({limit:1})).data.calls.length,1);
  for(const limit of [0,-1,51,1.5,'10',null])assert.equal((await list({limit})).isError,true);
  assert.equal((await list({contact_id:'unrelated'})).isError,true);
  assert.equal((await tool('tincall_list_calls',{},'bad-token')).status,401);
  assert.equal((await tool('tincall_get_call',{call_id:foreign})).body.result.isError,true);
  assert.equal((await list({limit:50},'test-owner')).data.calls.length,50);
  const foreignCalls=(await list({},'test-other')).data.calls;
  assert.ok(foreignCalls.some(c=>c.call_id===foreign && c.status==='active' && c.ended_at===null));
  assert.ok(foreignCalls.every(c=>!owned.includes(c.call_id)));
  const id=calls[0].call_id;
  const record=async()=>{const result=(await tool('tincall_get_call',{call_id:id})).body.result;assert.equal(result.isError,false);return result.content.map(block=>block.text??'').join('\n');};
  assert.doesNotMatch(await record(),/通话摘要/);
  const first=mutation({text:'synthetic first summary'});
  assert.equal((await api(`/calls/${id}/summary`,first,'test-other')).status,404);
  assert.doesNotMatch(await record(),/通话摘要/);
  assert.equal((await api(`/calls/${id}/summary`,first)).status,200);
  assert.equal((await api(`/calls/${id}/summary`,first)).status,200);
  assert.ok((await record()).includes(first.text));
  assert.equal((await list({limit:50})).data.calls.find(c=>c.call_id===id).has_summary,true);
  const replacement=mutation({text:'synthetic regenerated summary'});
  assert.equal((await api(`/calls/${id}/summary`,replacement)).status,200);
  // A lost first response retried after regeneration must not overwrite the new summary.
  assert.equal((await api(`/calls/${id}/summary`,first)).status,200);
  assert.ok((await record()).includes(replacement.text));
  const forbidden=crypto.randomUUID();
  await store.command(owner,'call.create',mutation({call_id:forbidden,contact_id:'unrelated',source:'mcp'}));
  assert.equal((await api(`/calls/${forbidden}/summary`,mutation({text:'forbidden'}),'test-role')).status,403);
  for(const text of [12,{},'x'.repeat(100001)])assert.equal((await api(`/calls/${id}/summary`,mutation({text}))).status,400);
  assert.ok((await record()).includes(replacement.text));
  if(!sqlite)for(const role of ['anon','authenticated']) {
    assert.throws(()=>sql(`set role ${role};set request.jwt.claim.sub=${sqlQuote(owner)};select public.tincall_recent_calls(${sqlQuote(other)}::uuid);`));
  }
  await store.command(owner,'call.end',mutation({call_id:forbidden,epoch:0}));
  await store.command(other,'call.end',mutation({call_id:foreign,epoch:0}));
});

const pngData='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
const picture=()=>({id:crypto.randomUUID(),mime_type:'image/png',data_base64:pngData});
test('MCP conversational output uses the phone user name without redundant receipt announcements',async()=>{
  const id=crypto.randomUUID();
  const headers={Accept:'application/json, text/event-stream'};
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',headers)).body.result;
  await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:'小白'}));
  try {
    await tool('tincall_wait',{timeout_seconds:1});
    await tool('tincall_reply',{call:callReference(id),text:'你好。',wait_for_input:false});
    await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'下午好'}));
    const result=await tool('tincall_wait',{timeout_seconds:1});
    assert.equal(result.content[0].text,'<message name="小白">\n  <text>下午好</text>\n</message>');
  } finally {
    const current=(await api(`/calls/${id}/record`)).body.call;
    await api(`/calls/${id}/end`,mutation({epoch:current.epoch}));
  }
});
test('MCP XML separates timestamps and names from text and keeps each image with its message',async()=>{
  const tool=async(name,args={})=>(await api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},'test-owner',{Accept:'application/json, text/event-stream'})).body.result;
  for(const name of ['', '小白 "A" & <B>']) {
    const id=crypto.randomUUID();
    await api('/calls',mutation({call_id:id,contact_id:'tools',source:'mcp',user_name:name,time_awareness_enabled:true,time_zone:'Asia/Shanghai'}));
    try {
      await tool('tincall_wait',{timeout_seconds:1});
      const raw='[2026-10-26 15:30:00]\n"A&B" <message>正文</message>\n原话提到 [2026-10-25 12:00:00]。';
      await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:raw,images:[picture(),picture()]}));
      const result=await tool('tincall_wait',{call:callReference(id),timeout_seconds:1});
      const nameAttribute=name?' name="小白 &quot;A&quot; &amp; &lt;B&gt;"':'';
      assert.equal(result.content[0].text,`<message${nameAttribute} timestamp="2026-10-26 15:30:00">\n  <text>"A&amp;B" &lt;message&gt;正文&lt;/message&gt;\n原话提到 [2026-10-25 12:00:00]。</text>\n</message>`);
      assert.deepEqual(result.content.slice(1),Array.from({length:2},()=>({type:'image',data:pngData,mimeType:'image/png'})));
      await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'[2026-10-26 15:31:00]\n',images:[picture()]}));
      const onlyImage=await tool('tincall_wait',{call:callReference(id),timeout_seconds:1});
      assert.equal(onlyImage.content[0].text,`<message${nameAttribute} timestamp="2026-10-26 15:31:00">\n  <text></text>\n</message>`);
      assert.equal(onlyImage.content[1].type,'image');
    } finally {
      const current=(await api(`/calls/${id}/record`)).body.call;
      await api(`/calls/${id}/end`,mutation({epoch:current.epoch}));
    }
  }
});
test('phone images persist, reach every MCP input path, and reject invalid uploads without accepting input',async()=>{
  const callID=crypto.randomUUID();
  await api('/calls',mutation({call_id:callID,contact_id:'tools',source:'mcp'}));
  const firstImage=picture();
  const inputRequest=mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic caption',images:[firstImage]});
  const first=await api(`/calls/${callID}/input`,inputRequest);
  assert.equal(first.status,200);
  assert.deepEqual((await api(`/calls/${callID}/input`,inputRequest)).body,first.body);
  const record=(await api(`/calls/${callID}/record`)).body;
  const saved=record.messages.find(message=>message.id===first.body.input_id);
  assert.equal(saved.text,inputRequest.text);
  assert.deepEqual(saved.images,[{id:firstImage.id,mime_type:'image/png',bytes:Buffer.from(pngData,'base64').length}]);
  assert.equal(JSON.stringify(record).includes(pngData),false,'records store references rather than inline bytes');
  const headers={Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'};
  const tool=(name,args,token='test-owner')=>api('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token,headers);
  for(const name of ['tincall_get_call','tincall_wait']) {
    const result=(await tool(name,name==='tincall_wait'?{timeout_seconds:1}:{call_id:callID})).body.result;
    assert.equal(result.isError,false);
    assert.deepEqual(result.content.filter(item=>item.type==='image'),[{type:'image',data:pngData,mimeType:'image/png'}]);
    assert.equal(result.content[1].type,'image','each image immediately follows its message');
    assert.ok(result.content[0].text.includes(saved.text));assert.doesNotMatch(JSON.stringify(result),/reply_to|cursor|epoch/);
  }
  assert.equal((await tool('tincall_get_call',{call_id:callID},'test-role')).body.result.isError,true);
  assert.equal((await tool('tincall_get_call',{call_id:callID},'test-other')).body.result.isError,true);
  const changed=await api(`/calls/${callID}/input`,{...inputRequest,images:[{...firstImage,data_base64:Buffer.from([137,80,78,71,13,10,26,10,1]).toString('base64')}]});
  assert.equal(changed.status,409);assert.equal(changed.body.error.code,'image_conflict');
  const badRequests=[
    {images:picture(),code:'invalid_images'},
    {images:Array.from({length:5},picture),code:'invalid_images'},
    {images:[firstImage,firstImage],code:'duplicate_image_id'},
    {images:[{...picture(),id:'bad'}],code:'invalid_image_id'},
    {images:[{...picture(),mime_type:'image/heic'}],code:'unsupported_image_type'},
    {images:[{...picture(),mime_type:'image/gif'}],code:'unsupported_image_type'},
    {images:[{...picture(),mime_type:'image/jpeg'}],code:'image_type_mismatch'},
    {images:[{...picture(),data_base64:'data:image/png;base64,'+pngData}],code:'invalid_image_data'},
    {images:[{...picture(),data_base64:'!!!!'}],code:'invalid_image_data'},
    {images:[{...picture(),data_base64:''}],code:'invalid_image_data'},
    {images:[{...picture(),data_base64:'AAAA='.repeat(2)}],code:'invalid_image_data'},
    {images:[{...picture(),data_base64:Buffer.alloc(5*1024*1024+1).toString('base64')}],code:'image_too_large'},
    {images:[],text:'',code:'invalid_text'},
  ];
  for(const {code,...fields} of badRequests) {
    const response=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'synthetic',...fields}));
    assert.equal(response.body.error?.code,code);
  }
  assert.equal((await api(`/calls/${callID}/record`)).body.call.epoch,1);
  const replying=tool('tincall_reply',{call:callReference(callID),text:'synthetic answer',timeout_seconds:3});
  for(let i=0;i<30;i++) {
    if((await api(`/calls/${callID}/record`)).body.messages.some(message=>message.id===first.body.reply_id && message.status==='complete'))break;
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  const nextImage=picture();
  const imageOnly=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,images:[nextImage]}));
  assert.equal(imageOnly.status,200);
  const next=(await replying).body.result;
  assert.equal(next.isError,false);assert.equal(next.content.filter(block=>block.type==='image').length,1);
  assert.deepEqual(next.content.filter(item=>item.type==='image'),[{type:'image',data:pngData,mimeType:'image/png'}]);
  const history=(await tool('tincall_get_call',{call_id:callID})).body.result;
  const imagePositions=history.content.flatMap((block,index)=>block.type==='image'?[index]:[]);
  assert.equal(imagePositions.length,2);
  assert.match(history.content[imagePositions[0]-1].text,/<message>\n  <text>synthetic caption<\/text>\n<\/message>$/);
  assert.match(history.content[imagePositions[1]-1].text,/<message>\n  <text><\/text>\n<\/message>$/);
  await api(`/calls/${callID}/end`,mutation({epoch:2}));
});

test('HTTP generation receives inline images in current and historical messages; text-only shape stays unchanged',async()=>{
  const callID=crypto.randomUUID();
  await api('/calls',mutation({call_id:callID,contact_id:'one',source:'backend'}));
  const image=picture();
  const first=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'',images:[image]}));
  assert.equal(first.status,200);
  await Promise.all(tasks);
  assert.equal(lastGeneration.input_id,first.body.input_id);
  assert.deepEqual(lastGeneration.messages[0].images,[{mime_type:'image/png',data_base64:pngData}]);
  assert.equal(lastGeneration.messages[0].text,'');
  const second=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'synthetic follow-up'}));
  assert.equal(second.status,200);
  await Promise.all(tasks);
  assert.deepEqual(lastGeneration.messages.find(message=>message.id===first.body.input_id).images,[{mime_type:'image/png',data_base64:pngData}]);
  const textOnly=lastGeneration.messages.find(message=>message.id===second.body.input_id);
  assert.equal(Object.hasOwn(textOnly,'images'),false);
  assert.equal(textOnly.text,'synthetic follow-up');
  await api(`/calls/${callID}/end`,mutation({epoch:2}));
});

test('backup images follow messages, accept stored references on revision update, and delete with the backup',async()=>{
  const legacyID=crypto.randomUUID();
  const legacy={messages:{legacy:'opaque manifest'}};
  assert.equal((await api(`/records/${legacyID}`,mutation({expected_revision:0,record:legacy}))).status,200);
  assert.deepEqual((await api(`/records/${legacyID}`)).body.record.record,legacy);
  const id=crypto.randomUUID(),image=picture(),messageID=crypto.randomUUID();
  const upload=mutation({expected_revision:0,record:{version:1,call:{id,messages:[{id:messageID,text:'',images:[image]}]}}});
  const first=await api(`/records/${id}`,upload);
  assert.equal(first.status,200);
  assert.deepEqual((await api(`/records/${id}`,upload)).body,first.body);
  const document=(await api(`/records/${id}`)).body.record.record;
  assert.deepEqual(document.call.messages[0].images,[{id:image.id,mime_type:'image/png',bytes:Buffer.from(pngData,'base64').length}]);
  const response=await connector.handle(new Request(`http://localhost/records/${id}/media/${image.id}`,{headers:{Authorization:'Bearer test-owner'}}));
  assert.equal(Buffer.from(await response.arrayBuffer()).toString('base64'),pngData);
  assert.equal((await api(`/records/${id}`,mutation({expected_revision:1,record:document}))).status,200);
  const removed=mutation({expected_revision:2});
  assert.equal((await api(`/records/${id}/delete`,removed)).status,200);
  assert.equal((await api(`/records/${id}/delete`,removed)).status,200);
  await assert.rejects(store.media(owner,id,image.id,new Request('http://localhost/media')),{code:'media_not_found'});
  assert.equal((await api(`/records/${id}`,upload)).body.error.code,'record_deleted');
  assert.equal((await api(`/records/${id}/media/${image.id}`)).status,410);
  assert.equal((await api(`/records/${id}`)).body.record.deleted,true);
});

test('image envelopes exceed the legacy JSON limit safely, accept four images and preserve text-only limits',async()=>{
  const callID=crypto.randomUUID();
  await api('/calls',mutation({call_id:callID,contact_id:'tools',source:'mcp'}));
  const padded=Buffer.alloc(5*1024*1024);Buffer.from(pngData,'base64').copy(padded);
  const large={...picture(),data_base64:padded.toString('base64')};
  const second={...picture(),data_base64:padded.toString('base64')};
  const first=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'',images:[large,second]}));
  assert.equal(first.status,200,'two 5 MiB files fit in the 28 MiB image envelope');
  const jpeg={...picture(),mime_type:'image/jpeg',data_base64:Buffer.from([255,216,255,224,0,0,255,217]).toString('base64')};
  assert.equal((await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'four',images:[picture(),picture(),picture(),jpeg]}))).status,200);
  const textOnly=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:2,text:'synthetic',padding:' '.repeat(8*1024*1024)}));
  assert.equal(textOnly.status,413);assert.equal(textOnly.body.error.code,'body_too_large');
  await api(`/calls/${callID}/end`,mutation({epoch:2}));
});

test('MCP preserves reply acceptance when the next image cannot be loaded and deletion clears linked call images',async()=>{
  const callID=crypto.randomUUID();
  await api('/calls',mutation({call_id:callID,contact_id:'tools',source:'mcp'}));
  const first=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic first'}));
  const broken=createConnector({store:{...store,async media(...args){if(args[3].method==='GET')throw new ConnectorError('media_unavailable',503);return store.media(...args);}},config:{}});
  await api('/mcp',{jsonrpc:'2.0',id:0,method:'tools/call',params:{name:'tincall_wait',arguments:{timeout_seconds:1}}},'test-owner',{Accept:'application/json, text/event-stream'});
  const request={call:callReference(callID),text:'accepted answer',timeout_seconds:3};
  const replying=broken.handle(new Request('http://localhost/mcp',{method:'POST',headers:{Authorization:'Bearer test-owner','Content-Type':'application/json',Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'tincall_reply',arguments:request}})}));
  for(let i=0;i<30;i++) {
    if((await api(`/calls/${callID}/record`)).body.messages.some(message=>message.id===first.body.reply_id && message.status==='complete'))break;
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  const image=picture();
  const imageInput=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:1,text:'',images:[image]}));
  const supplement=await api(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:2,text:'Synthetic supplement'}));
  const result=(await (await replying).json()).result;
  assert.equal(result.isError,false);assert.match(result.content[0].text,/回复已保存/);assert.match(result.content[0].text,/media_unavailable/);
  assert.equal(result.structuredContent,undefined);
  const recovered=(await api('/mcp',{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'tincall_wait',arguments:{timeout_seconds:1}}},'test-owner',{Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'})).body.result;
  assert.deepEqual(recovered.content.slice(0,3).map(block=>block.type),['text','image','text']);
  assert.match(recovered.content[2].text,/Synthetic supplement/);
  assert.equal(recovered.content.filter(block=>block.type==='image').length,1);
  const saved=await api(`/records/${callID}`,mutation({expected_revision:0,record:{messages:(await api(`/calls/${callID}/record`)).body.messages}}));
  assert.equal(saved.status,200);
  const removed=mutation({expected_revision:1});
  assert.equal((await api(`/records/${callID}/delete`,removed)).status,200);
  assert.ok((await api(`/calls/${callID}/record`)).body.messages.every(message=>!message.images));
  await assert.rejects(store.media(owner,callID,image.id,new Request('http://localhost/media')),{code:'media_not_found'});
  await api(`/calls/${callID}/end`,mutation({epoch:3}));
  if(!sqlite)for(const role of ['anon','authenticated']) {
    assert.throws(()=>sql(`set role ${role};select public.tincall_image_command('record.delete','{}',${sqlQuote(owner)}::uuid);`));
  }
});
