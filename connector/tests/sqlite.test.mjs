// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync,readdirSync,renameSync,mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createSQLiteStore,nextDaily,defaultDatabasePath} from '../sqlite-store.mjs';
import {createNodeStore} from '../store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';
const execute=promisify(execFile);
const owner='10000000-0000-4000-8000-000000000001';
const other='10000000-0000-4000-8000-000000000002';
const mutation=p=>({request_id:crypto.randomUUID(),...p});
function fixture(t){
  const directory=mkdtempSync(join(tmpdir(),'tincall-sqlite-'));const path=join(directory,'data','store.sqlite');
  const config={clients:[{token:'phone',owner_id:owner}]};
  let store=createSQLiteStore(config,path);
  t.after(()=>{store.close();rmSync(directory,{recursive:true,force:true});});
  return {directory,path,config,get store(){return store;},restart(){store.close();store=createSQLiteStore(config,path);return store;}};
}

test('SQLite automatic rollback preserves the original failure and discards unpublished call notifications',async t=>{
  const f=fixture(t),db=new DatabaseSync(f.path),notified=[];
  t.after(()=>db.close());
  const unsubscribe=await f.store.subscribeIncoming(owner,call=>notified.push(call));t.after(unsubscribe);
  db.exec("CREATE TRIGGER abort_call_receipt BEFORE INSERT ON tincall_requests WHEN NEW.action='call.create' BEGIN SELECT RAISE(ROLLBACK,'synthetic rollback'); END;");
  await assert.rejects(f.store.command(owner,'call.create',mutation({call_id:crypto.randomUUID(),contact_id:'synthetic',source:'independent'})),{code:'database_request_failed'});
  db.exec('DROP TRIGGER abort_call_receipt');
  await f.store.command(owner,'device.put',mutation({device_id:crypto.randomUUID(),binding_id:crypto.randomUUID()}));
  assert.equal((await f.store.command(owner,'call.current',{})).call,null);
  assert.deepEqual(notified,[]);
});

test('record listing rejects an invalid date cursor with a specific client error',async t=>{
  const f=fixture(t),connector=createConnector({store:f.store,config:f.config});
  const response=await connector.handle(new Request('http://localhost/records?after=not-a-date',{headers:{Authorization:'Bearer phone'}}));
  assert.equal(response.status,400);assert.equal((await response.json()).error.code,'invalid_cursor');
});

test('SQLite write lock exhaustion is retryable and a later transaction still works',async t=>{
  const f=fixture(t),db=new DatabaseSync(f.path);t.after(()=>db.close());
  db.exec('BEGIN IMMEDIATE');
  try {await assert.rejects(f.store.command(owner,'call.current',{}),{code:'database_busy',status:503});}
  finally {db.exec('ROLLBACK');}
  assert.equal((await f.store.command(owner,'call.current',{})).call,null);
});

test('Node storage selection defaults to SQLite and partial Supabase configuration fails closed',async t=>{
  const f=fixture(t);const env={TINCALL_SQLITE_PATH:f.path};
  const selected=createNodeStore(f.config,key=>env[key]);assert.deepEqual(await selected.authenticate('phone'),{owner_id:owner,contact_id:null});selected.close();
  assert.ok(defaultDatabasePath.endsWith('/connector/data/tincall.sqlite'));
  assert.throws(()=>createNodeStore({supabaseURL:'https://example.invalid'},()=>undefined),{code:'server_configuration_missing'});
  assert.throws(()=>createNodeStore({},()=> 'unsupported'),{code:'invalid_server_configuration'});
  const supabase=createNodeStore({supabaseURL:'https://example.invalid',publicKey:'public',serviceKey:'service'},()=>undefined);
  assert.equal(supabase.close,undefined);
  env.TINCALL_STORAGE='sqlite';const explicit=createNodeStore({supabaseURL:'https://example.invalid'},key=>env[key]);explicit.close();
});

test('SQLite upgrades missing voice columns without losing calls, receipts, or messages',async t=>{
  const f=fixture(t);const call=crypto.randomUUID();const create=mutation({call_id:call,contact_id:'tools',source:'mcp'});
  await f.store.command(owner,'call.create',create);
  const input=await f.store.command(owner,'call.input',mutation({call_id:call,message_id:crypto.randomUUID(),epoch:0,text:'synthetic',mode:'tools'}));
  const db=new DatabaseSync(f.path);
  db.exec('ALTER TABLE tincall_calls DROP COLUMN tts_expression_prompt; ALTER TABLE tincall_calls DROP COLUMN voice_instructions_sent;');db.close();
  f.restart();
  assert.equal((await f.store.command(owner,'call.record',{call_id:call})).messages.length,2);
  assert.equal((await f.store.command(owner,'call.create',create)).call.id,call);
  assert.equal((await f.store.command(owner,'call.record',{call_id:call})).job.reply_id,input.reply_id);
  assert.equal((await f.store.claimVoiceInstructions(owner,call)).voice_instructions,'你的回复会被实时朗读成语音，请写适合说出口的口语。');
  f.restart();assert.equal((await f.store.claimVoiceInstructions(owner,call)).voice_instructions,null);
});

test('SQLite adds MCP wait preferences while retaining enrolled identities and credentials',async t=>{
  const f=fixture(t),role={role_id:crypto.randomUUID(),contact_id:'synthetic',display_name:'Synthetic',token:'tcmcp_'+'a'.repeat(64)};
  const enrolled=await f.store.mcpRoleCommand(owner,'upsert',role);
  const db=new DatabaseSync(f.path);db.exec('ALTER TABLE tincall_mcp_roles DROP COLUMN mcp_wait_timeout_seconds');db.close();
  f.restart();
  const saved=await f.store.mcpRoleCommand(owner,'upsert',role);
  assert.equal(saved.token,enrolled.token);
  assert.equal(saved.token_created,false);
  assert.equal(saved.mcp_wait_timeout_seconds,120);
  assert.equal((await f.store.mcpRoleCommand(owner,'binding',{contact_id:'synthetic'})).binding.mcp_wait_timeout_seconds,120);
});

test('SQLite voice claim is atomic across processes and prompt retries never reset it',async t=>{
  const f=fixture(t);const call=crypto.randomUUID();
  await f.store.command(owner,'call.incoming',mutation({call_id:call,contact_id:'tools',source:'mcp'}));
  await f.store.setVoicePrompt(owner,call,'synthetic voice direction');
  assert.equal((await f.store.claimVoiceInstructions(owner,call)).voice_instructions,null);
  assert.equal((await f.store.claimVoiceInstructions(other,call)).voice_instructions,null);
  await f.store.command(owner,'call.accept',mutation({call_id:call,epoch:0}));
  const script=`import {createSQLiteStore} from ${JSON.stringify(new URL('../sqlite-store.mjs',import.meta.url).href)};const s=createSQLiteStore({},process.argv[1]);console.log(JSON.stringify(await s.claimVoiceInstructions(process.argv[2],process.argv[3])));s.close();`;
  const results=await Promise.all(Array.from({length:4},()=>execute(process.execPath,['--input-type=module','-e',script,f.path,owner,call])));
  assert.equal(results.map(result=>JSON.parse(result.stdout).voice_instructions).filter(Boolean).length,1);
  await f.store.setVoicePrompt(owner,call,'updated');f.restart();
  assert.equal((await f.store.claimVoiceInstructions(owner,call)).voice_instructions,null);
  await f.store.command(owner,'call.end',mutation({call_id:call,epoch:0}));
  await assert.rejects(f.store.setVoicePrompt(owner,call,''),{code:'call_not_found'});
});

test('SQLite media streams persist, reject overwrite, isolate owners and clean tombstones',async t=>{
  const f=fixture(t);const record=crypto.randomUUID();const asset=crypto.randomUUID();
  const request=()=>new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:'synthetic media'});
  assert.equal((await f.store.media(owner.toUpperCase(),record.toUpperCase(),asset.toUpperCase(),request())).status,200);
  await assert.rejects(f.store.media(owner,record,asset,request()),{code:'media_exists'});
  await assert.rejects(f.store.media(other,record,asset,new Request('http://localhost/media')),{code:'media_not_found'});
  const old=new DatabaseSync(f.path);
  old.exec('ALTER TABLE tincall_media DROP COLUMN deleted');old.close();
  f.restart();const downloaded=await f.store.media(owner,record,asset,new Request('http://localhost/media'));
  assert.equal(await downloaded.text(),'synthetic media');assert.equal(downloaded.headers.get('content-type'),'audio/wav');assert.equal(downloaded.headers.get('location'),null);
  await assert.rejects(f.store.media(owner,record,crypto.randomUUID(),new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav','Content-Length':String(512*1024*1024+1)},body:'x'})),{code:'media_too_large'});
  await assert.rejects(f.store.media(owner,record,crypto.randomUUID(),new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'text/html'},body:'x'})),{code:'unsupported_media_type'});
  const connector=createConnector({store:f.store,config:{}});
  async function api(path,body,method='POST'){
    return connector.handle(new Request('http://localhost'+path,{method,headers:{Authorization:'Bearer phone','Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})}));
  }
  const uploaded=await api(`/records/${record}`,mutation({expected_revision:0,record:{synthetic:true}}));assert.equal(uploaded.status,200);
  const deletion=mutation({expected_revision:1});assert.equal((await api(`/records/${record}/delete`,deletion)).status,200);
  assert.equal((await api(`/records/${record}/delete`,deletion)).status,200);
  assert.equal((await api(`/records/${record}/media/${asset}`,undefined,'GET')).status,410);
  await assert.rejects(f.store.media(owner,record,asset,request()),{code:'record_deleted'});
  assert.deepEqual(readdirSync(f.path+'.media'),[]);
  await f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'DELETE'}));
});

test('SQLite bounds media cleanup and retries the same committed deletion',async t=>{
  const f=fixture(t);const record=crypto.randomUUID();const db=new DatabaseSync(f.path);
  const insert=db.prepare('INSERT INTO tincall_media(owner_id,record_id,asset_id,content_type,size,file) VALUES (?,?,?,?,?,?)');
  for(let i=0;i<301;i++)insert.run(owner,record,crypto.randomUUID(),'audio/wav',1,crypto.randomUUID());
  await assert.rejects(f.store.deleteRecordMedia(owner,record),{code:'media_cleanup_pending'});
  assert.equal(db.prepare('SELECT count(*) n FROM tincall_media').get().n,1);
  await f.store.deleteRecordMedia(owner,record);assert.equal(db.prepare('SELECT count(*) n FROM tincall_media').get().n,0);db.close();
});

for(const mode of ['single','record']) {
  test(`SQLite ${mode} media deletion preserves files on SQL rollback`,async t=>{
    const f=fixture(t),record=crypto.randomUUID(),assets=[crypto.randomUUID(),crypto.randomUUID()];
    for(const asset of assets)await f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:asset}));
    const db=new DatabaseSync(f.path);t.after(()=>db.close());
    const blocked=mode==='single'?assets[0]:assets[1];
    // Abort the logical deletion through the real SQLite engine.
    for(const event of ['UPDATE','DELETE'])db.exec(`CREATE TRIGGER block_media_${event} BEFORE ${event} ON tincall_media
      WHEN OLD.asset_id='${blocked}' BEGIN SELECT RAISE(ABORT,'synthetic deletion failure'); END;`);
    const remove=()=>mode==='single'
      ?f.store.media(owner,record,assets[0],new Request('http://localhost/media',{method:'DELETE'}))
      :f.store.deleteRecordMedia(owner,record);
    await assert.rejects(remove(),{code:mode==='single'?'database_request_failed':'media_cleanup_failed'});
    for(const asset of assets)assert.equal(await (await f.store.media(owner,record,asset,new Request('http://localhost/media'))).text(),asset);
    db.exec('DROP TRIGGER block_media_UPDATE; DROP TRIGGER block_media_DELETE;');
    await remove();
    assert.equal(readdirSync(f.path+'.media').length,mode==='single'?1:0);
  });

  test(`SQLite ${mode} media cleanup retries after filesystem failure and restart`,async t=>{
    const f=fixture(t),record=crypto.randomUUID(),asset=crypto.randomUUID();
    await f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:'synthetic media'}));
    const file=join(f.path+'.media',readdirSync(f.path+'.media')[0]),held=file+'.held';
    renameSync(file,held);mkdirSync(file); // unlink fails without relying on OS permissions.
    const remove=()=>mode==='single'
      ?f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'DELETE'}))
      :f.store.deleteRecordMedia(owner,record);
    await assert.rejects(remove(),{code:'media_cleanup_failed'});
    f.restart();
    await assert.rejects(f.store.media(owner,record,asset,new Request('http://localhost/media')),{code:'media_not_found'});
    rmSync(file,{recursive:true});renameSync(held,file);
    await remove();await remove();
    assert.deepEqual(readdirSync(f.path+'.media'),[]);
    // An already-removed file remains a successful, idempotent deletion.
    await f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:'replacement'}));
    rmSync(join(f.path+'.media',readdirSync(f.path+'.media')[0]));
    await remove();
  });

  test(`SQLite ${mode} media cleanup retries after file removal and SQL failure`,async t=>{
    const f=fixture(t),record=crypto.randomUUID(),asset=crypto.randomUUID();
    await f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:'synthetic media'}));
    const db=new DatabaseSync(f.path);t.after(()=>db.close());
    db.exec("CREATE TRIGGER block_cleanup BEFORE DELETE ON tincall_media BEGIN SELECT RAISE(ABORT,'synthetic cleanup failure'); END;");
    const remove=()=>mode==='single'
      ?f.store.media(owner,record,asset,new Request('http://localhost/media',{method:'DELETE'}))
      :f.store.deleteRecordMedia(owner,record);
    await assert.rejects(remove(),{code:'media_cleanup_failed'});
    assert.deepEqual(readdirSync(f.path+'.media'),[]);
    f.restart();
    await assert.rejects(f.store.media(owner,record,asset,new Request('http://localhost/media')),{code:'media_not_found'});
    db.exec('DROP TRIGGER block_cleanup');
    await remove();
    assert.equal(db.prepare('SELECT count(*) n FROM tincall_media').get().n,0);
  });
}

test('SQLite worker leases expire without regeneration and missed rings release the live slot',async t=>{
  const f=fixture(t);const call=crypto.randomUUID();
  await f.store.command(owner,'call.create',mutation({call_id:call,contact_id:'one',source:'backend'}));
  await f.store.command(owner,'call.input',mutation({call_id:call,message_id:crypto.randomUUID(),epoch:0,text:'synthetic',mode:'http'}));
  const [first,second]=await Promise.all([f.store.command(owner,'job.claim',{}),f.store.command(owner,'job.claim',{})]);assert.ok(first.job);assert.equal(second.job,null);
  const db=new DatabaseSync(f.path);db.exec("UPDATE tincall_jobs SET claimed_at='2000-01-01T00:00:00.000Z'");
  assert.deepEqual(await f.store.workerOwners(),[]);
  const failed=await f.store.command(owner,'call.record',{call_id:call});assert.equal(failed.messages.at(-1).status,'failed');assert.equal((await f.store.command(owner,'call.events',{call_id:call})).events.at(-1).payload.code,'worker_expired');
  await f.store.command(owner,'call.end',mutation({call_id:call,epoch:1}));
  const ring=crypto.randomUUID();await f.store.command(owner,'call.incoming',mutation({call_id:ring,contact_id:'one',source:'mcp'}));
  await f.store.command(owner,'push.claim',{});
  db.exec("UPDATE tincall_push_jobs SET claimed_at='2000-01-01T00:00:00.000Z'; UPDATE tincall_calls SET created_at='2000-01-01T00:00:00.000Z' WHERE status='ringing'");
  await f.store.workerOwners();assert.equal((await f.store.command(owner,'call.current',{})).call,null);
  const ended=await f.store.command(owner,'call.record',{call_id:ring});assert.equal(ended.push.error_code,'worker_expired');assert.equal(ended.call.status,'ended');db.close();
});

test('SQLite device receipts, owner limits and timezone gaps/folds match the storage contract',async t=>{
  const f=fixture(t);const device=crypto.randomUUID();const p=mutation({device_id:device,device_token:'a'.repeat(64),environment:'sandbox'});
  assert.deepEqual(await f.store.command(owner,'device.lookup',p),{response:null});
  const registered=await f.store.command(owner,'device.put',{...p,binding_id:crypto.randomUUID()});
  assert.deepEqual((await f.store.command(owner,'device.lookup',p)).response,registered);
  await assert.rejects(f.store.command(owner,'device.lookup',{...p,environment:'production'}),{code:'idempotency_conflict'});
  for(let i=0;i<4;i++)await f.store.command(owner,'device.put',mutation({device_id:crypto.randomUUID(),binding_id:crypto.randomUUID()}));
  await assert.rejects(f.store.command(owner,'device.put',mutation({device_id:crypto.randomUUID(),binding_id:crypto.randomUUID()})),{code:'device_limit'});
  await f.store.command(owner,'device.delete',mutation({device_id:device}));
  assert.equal(nextDaily('02:30','America/New_York',new Date('2026-03-08T00:00:00Z')),'2026-03-08T07:30:00.000Z');
  assert.equal(nextDaily('01:30','America/New_York',new Date('2026-11-01T00:00:00Z')),'2026-11-01T06:30:00.000Z');
  assert.equal(nextDaily('9:00:00.123','Asia/Shanghai',new Date('2026-10-16T00:00:00Z')),'2026-10-16T01:00:00.123Z');
  assert.equal(nextDaily('24:00','Asia/Shanghai',new Date('2026-10-16T00:00:00Z')),'2026-10-16T16:00:00.000Z');
  assert.equal(nextDaily('09:00','Asia/Shanghai',new Date('2026-10-16T02:00:00Z')),'2026-10-17T01:00:00.000Z');
});
