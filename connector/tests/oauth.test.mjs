// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector,createSupabaseStore} from '../../supabase/functions/_shared/tincall/service.mjs';

const storage=process.env.TINCALL_TEST_STORAGE??'postgres';
if(!['sqlite','postgres'].includes(storage))throw new Error('TINCALL_TEST_STORAGE only accepts sqlite or postgres');
const postgres=storage==='postgres';
const owner='10000000-0000-4000-8000-000000000001';
const directory=mkdtempSync(join(tmpdir(),'tincall-oauth-'));
const container='tincall-oauth-test-'+process.pid;
const base='https://fixture.invalid/functions/v1/tincall';
const callback='https://chatgpt.com/connector_platform_oauth_redirect';
const claudeCallback='https://claude.ai/api/mcp/auth_callback';
// RFC 7636's published example verifies the protocol proof without test-only
// production paths, external providers or file fingerprinting.
const verifier='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const challenge='E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
const clients=[{token:'phone',owner_id:owner},{token:'contact',owner_id:owner,contact_id:'contact-a'}];
let store,connector,db;
const quote=v=>"'"+String(v).replaceAll("'","''")+"'";
function sql(source){return execFileSync('docker',['exec','-i',container,'psql','-h','127.0.0.1','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres'],{input:source,encoding:'utf8',stdio:'pipe'}).trim();}
async function request(path,{method='GET',token,json,form}={}){
  const headers={Accept:'application/json, text/event-stream',...(token?{Authorization:'Bearer '+token}:{}),...(json?{'Content-Type':'application/json'}:{}),...(form?{'Content-Type':'application/x-www-form-urlencoded'}:{})};
  return connector.handle(new Request(path.startsWith('https:')?path:base+path,{method,headers,...(json?{body:JSON.stringify(json)}:{}),...(form?{body:new URLSearchParams(form)}:{})}));
}
const post=(path,json,token)=>request(path,{method:'POST',json,token});
async function register(overrides={}){
  const result=await post('/oauth/register',{redirect_uris:[callback],client_name:'ChatGPT',token_endpoint_auth_method:'none',...overrides});assert.equal(result.status,201,await result.clone().text());return (await result.json()).client_id;
}
async function registerClaude(overrides={}){
  const result=await post('/oauth/register',{redirect_uris:[claudeCallback],client_name:'Claude',token_endpoint_auth_method:'none',...overrides});assert.equal(result.status,201,await result.clone().text());return (await result.json()).client_id;
}
async function pending(client=undefined,overrides={}){
  client??=await register();
  const query=new URLSearchParams({client_id:client,redirect_uri:callback,response_type:'code',state:'synthetic-state',resource:base+'/mcp',scope:'tincall:mcp',code_challenge:challenge,code_challenge_method:'S256',...overrides});
  const response=await request('/oauth/authorize?'+query);assert.equal(response.status,303);
  const location=response.headers.get('location');
  const page=await request(location);assert.equal(page.status,200);assert.match(page.headers.get('content-type'),/text\/plain/);
  const text=await page.text();const code=text.match(/[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}/)[0];
  return {client,code,location};
}
async function approve(p,decision='approve',contact='contact-a'){
  const result=await post('/oauth/requests/decide',{user_code:p.code,contact_id:contact,decision},'phone');assert.equal(result.status,200);
  const consent=await request(p.location);assert.equal(consent.status,303);
  return new URL(consent.headers.get('location'));
}
async function exchange(p,authorization,overrides={}){
  return request('/oauth/token',{method:'POST',form:{grant_type:'authorization_code',client_id:p.client,code:authorization.searchParams.get('code'),redirect_uri:callback,resource:base+'/mcp',code_verifier:verifier,...overrides}});
}
function expire(table,column,where,value){
  if(postgres)sql(`update public.tincall_${table} set ${column}=now()-interval '1 second' where ${where}=${quote(value)};`);
  else db.prepare(`UPDATE tincall_${table} SET ${column}=? WHERE ${where}=?`).run('2000-01-01T00:00:00.000Z',value);
}
before(async()=>{
  if(postgres){
    execFileSync('docker',['run','--rm','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:18-alpine'],{stdio:'pipe'});
    let ready=false;for(let i=0;i<60;i++){try{sql('select 1');ready=true;break;}catch{await new Promise(r=>setTimeout(r,100));}}assert.ok(ready);
    sql(readFileSync(new URL('./bootstrap.sql',import.meta.url),'utf8'));
    for(const file of ['202610110001_tincall_connector.sql','202610140001_tincall_mcp_roles.sql','202610200003_tincall_mcp_oauth.sql','202610200004_tincall_call_presence.sql','202610220001_tincall_service_safety.sql','202610220002_tincall_mcp_safety.sql'])sql(readFileSync(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
    store=createSupabaseStore({supabaseURL:'https://local-database.invalid',serviceKey:'fixture',publicKey:'fixture',clients},async(url,init)=>{
      const p=JSON.parse(init.body);let call;
      if(url.endsWith('/tincall_oauth'))call=`tincall_oauth(${quote(p.p_action)},${quote(JSON.stringify(p.p_payload))}::jsonb)`;
      else if(url.endsWith('/tincall_remove_push_device'))call=`tincall_remove_push_device(${quote(p.p_owner)}::uuid,${quote(p.p_device)}::uuid,${quote(p.p_binding)})`;
      else if(url.endsWith('/tincall_call_presence'))call=`tincall_call_presence(${quote(p.p_action)},${p.p_owner?quote(p.p_owner)+'::uuid':'null'},${p.p_call?quote(p.p_call)+'::uuid':'null'})`;
      else if(url.endsWith('/tincall_mcp_role'))call=`tincall_mcp_role(${quote(p.p_action)},${quote(p.p_owner)}::uuid,${quote(JSON.stringify(p.p_payload))}::jsonb)`;
      else if(url.endsWith('/tincall_mcp_authenticate'))call=`tincall_mcp_authenticate(${quote(p.p_token)})`;
      else throw new Error('Unexpected local RPC');
      try{const result=sql(`set role service_role;set request.jwt.claim.role='service_role';select public.${call};`);return Response.json(result?JSON.parse(result):null);}
      catch(error){const code=error.stderr.toString().match(/ERROR:\s+(\w+)/)?.[1];if(!['oauth_limit','forbidden'].includes(code))assert.fail(error.stderr.toString());return Response.json({message:code},{status:400});}
    });
  }else{const file=join(directory,'oauth.sqlite');store=createSQLiteStore({clients},file);db=new DatabaseSync(file);}
  connector=createConnector({store,config:{publicURL:base},schedule:()=>{}});
  for(const contact of ['contact-a','contact-b']){
    const result=await post('/mcp/roles/upsert',{role_id:crypto.randomUUID(),contact_id:contact,display_name:contact},'phone');assert.equal(result.status,200);
  }
});
after(()=>{db?.close();store?.close?.();if(postgres)execFileSync('docker',['rm','-f',container],{stdio:'pipe'});rmSync(directory,{recursive:true,force:true});});

test('MCP OAuth discovery works without a bearer at the Supabase-prefixed URL and advertises PKCE/DCR',async()=>{
  const missing=await request('/mcp');assert.equal(missing.status,401);
  assert.equal(missing.headers.get('www-authenticate'),`Bearer resource_metadata="${base}/.well-known/oauth-protected-resource", scope="tincall:mcp"`);
  const resource=await (await request('/.well-known/oauth-protected-resource')).json();assert.equal(resource.resource,base+'/mcp');assert.deepEqual(resource.authorization_servers,[base]);
  for(const path of ['/.well-known/oauth-authorization-server','/.well-known/openid-configuration']){
    const metadata=await (await request(path)).json();assert.equal(metadata.issuer,base);assert.deepEqual(metadata.code_challenge_methods_supported,['S256']);assert.deepEqual(metadata.token_endpoint_auth_methods_supported,['none']);assert.equal(metadata.registration_endpoint,base+'/oauth/register');assert.equal(metadata.authorization_response_iss_parameter_supported,true);
  }
  const rejected=await post('/oauth/register',{redirect_uris:['https://attacker.invalid/callback']});assert.equal(rejected.status,400);
  const malicious=await post('/oauth/register',{redirect_uris:[callback+'?forward=https://attacker.invalid']});assert.equal(malicious.status,400);
  const claude=await post('/oauth/register',{redirect_uris:[claudeCallback],client_name:'Claude',token_endpoint_auth_method:'none'});assert.equal(claude.status,201);
  const claudeQuery=new URLSearchParams({client_id:(await claude.json()).client_id,redirect_uri:claudeCallback,response_type:'code',resource:base+'/mcp',code_challenge:challenge,code_challenge_method:'S256'});
  assert.equal((await request('/oauth/authorize?'+claudeQuery)).status,303);
  assert.equal((await post('/oauth/register',{redirect_uris:[claudeCallback+'?state=unsafe']})).status,400);
});

test('Claude OAuth keeps the registered client label through owner approval',async()=>{
  const client=await registerClaude();
  const query=new URLSearchParams({client_id:client,redirect_uri:claudeCallback,response_type:'code',state:'claude-state',resource:base+'/mcp',scope:'tincall:mcp',code_challenge:challenge,code_challenge_method:'S256'});
  const started=await request('/oauth/authorize?'+query);assert.equal(started.status,303);
  const location=started.headers.get('location');const page=await request(location);assert.equal(page.status,200);
  const text=await page.text();const code=text.match(/[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}/)[0];
  const lookup=await post('/oauth/requests/lookup',{user_code:code},'phone');assert.equal(lookup.status,200);assert.equal((await lookup.json()).client_name,'Claude');
  const decided=await post('/oauth/requests/decide',{user_code:code,contact_id:'contact-a',decision:'approve'},'phone');assert.equal(decided.status,200);
  const consent=await request(location);assert.equal(consent.status,303);const redirect=new URL(consent.headers.get('location'));
  assert.equal(redirect.origin,'https://claude.ai');assert.equal(redirect.pathname,'/api/mcp/auth_callback');assert.equal(redirect.searchParams.get('state'),'claude-state');assert.equal(redirect.searchParams.get('iss'),base);
  const exchanged=await request('/oauth/token',{method:'POST',form:{grant_type:'authorization_code',client_id:client,code:redirect.searchParams.get('code'),redirect_uri:claudeCallback,resource:base+'/mcp',code_verifier:verifier}});
  assert.equal(exchanged.status,200);assert.equal((await exchanged.json()).token_type,'Bearer');
});

test('owner approval exchanges once, binds one contact, survives service restart and cannot read management APIs',async()=>{
  const p=await pending();
  const lookup=await post('/oauth/requests/lookup',{user_code:p.code},'phone');assert.equal(lookup.status,200);const info=await lookup.json();assert.equal(info.contacts.length,2);assert.ok(Date.now()-Date.parse(info.requested_at)<60000);
  assert.equal((await post('/oauth/requests/lookup',{user_code:p.code},'contact')).status,403);
  assert.equal((await post('/oauth/requests/decide',{user_code:p.code,contact_id:'unregistered',decision:'approve'},'phone')).status,400);
  const authorization=await approve(p);assert.equal(authorization.origin,'https://chatgpt.com');assert.equal(authorization.searchParams.get('state'),'synthetic-state');assert.equal(authorization.searchParams.get('iss'),base);
  assert.equal((await exchange(p,authorization,{code_verifier:'x'.repeat(43)})).status,400);
  assert.equal((await exchange(p,authorization,{resource:'https://attacker.invalid/mcp'})).status,400);
  const exchanged=await exchange(p,authorization);assert.equal(exchanged.status,200);const tokens=await exchanged.json();assert.equal(tokens.token_type,'Bearer');assert.equal(tokens.expires_in,3600);
  assert.equal((await exchange(p,authorization)).status,400);
  connector=createConnector({store,config:{publicURL:base},schedule:()=>{}});
  const tools=await post('/mcp',{jsonrpc:'2.0',id:1,method:'tools/list'},tokens.access_token);assert.equal(tools.status,200);
  const definition=(await tools.json()).result.tools.find(t=>t.name==='tincall_call');assert.ok(!definition.inputSchema.required.includes('contact_id'));
  const denied=await post('/mcp',{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'tincall_call',arguments:{contact_id:'contact-b'}}},tokens.access_token);assert.match(JSON.stringify(await denied.json()),/forbidden/);
  for(const path of ['/records','/capabilities','/calls/current'])assert.equal((await request(path,{token:tokens.access_token})).status,403);
  assert.equal((await post('/oauth/requests/lookup',{user_code:p.code},tokens.access_token)).status,403);
  const wrongAudience=createConnector({store,config:{publicURL:'https://different.invalid'},schedule:()=>{}});
  assert.equal((await wrongAudience.handle(new Request('https://different.invalid/mcp',{headers:{Authorization:'Bearer '+tokens.access_token}}))).status,401);
  const refresh=await request('/oauth/token',{method:'POST',form:{grant_type:'refresh_token',client_id:p.client,refresh_token:tokens.refresh_token,resource:base+'/mcp'}});assert.equal(refresh.status,200);const next=await refresh.json();assert.notEqual(next.access_token,tokens.access_token);
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},tokens.access_token)).status,401);
  assert.equal((await request('/oauth/token',{method:'POST',form:{grant_type:'refresh_token',client_id:p.client,refresh_token:tokens.refresh_token}})).status,400);
  assert.equal((await request('/oauth/revoke',{method:'POST',form:{client_id:p.client,token:next.refresh_token}})).status,200);
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},next.access_token)).status,401);
});

test('denial, expiration, wrong client and redirect cannot mint tokens; concurrent code exchange only succeeds once',async()=>{
  const denied=await pending();const refusal=await approve(denied,'deny');assert.equal(refusal.searchParams.get('error'),'access_denied');assert.equal(refusal.searchParams.get('iss'),base);assert.equal(refusal.searchParams.has('code'),false);
  const expired=await pending();expire('oauth_requests','expires_at','id',new URL(expired.location).searchParams.get('request'));assert.equal((await request(expired.location)).status,410);
  const p=await pending();const authorization=await approve(p);
  assert.equal((await exchange(p,authorization,{client_id:await register()})).status,400);
  assert.equal((await exchange(p,authorization,{redirect_uri:'https://chatgpt.com/connector/oauth/other'})).status,400);
  const concurrent=await Promise.all([exchange(p,authorization),exchange(p,authorization)]);assert.deepEqual(concurrent.map(r=>r.status).sort(),[200,400]);
  const tokens=await concurrent.find(r=>r.status===200).json();expire('oauth_grants','access_expires_at','access_token',tokens.access_token);
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},tokens.access_token)).status,401);
  expire('oauth_grants','refresh_expires_at','refresh_token',tokens.refresh_token);
  assert.equal((await request('/oauth/token',{method:'POST',form:{grant_type:'refresh_token',client_id:p.client,refresh_token:tokens.refresh_token}})).status,400);
});

test('registration reclaims idle clients, preserves live authorization and persists its rate limit across service restarts',async()=>{
  const p=await pending();const authorization=await approve(p);
  const exchanged=await exchange(p,authorization);assert.equal(exchanged.status,200);
  const tokens=await exchanged.json();
  const waiting=await pending();const unused=await register();
  // Simulate an existing installation with old registrations, using synthetic data only.
  if(postgres)sql("update public.tincall_oauth_clients set created_at=now()-interval '2 days';");
  else db.prepare('UPDATE tincall_oauth_clients SET created_at=?').run('2000-01-01T00:00:00.000Z');
  await register();
  assert.equal(await store.oauthCommand('client.get',{client_id:unused}),null);
  assert.ok(await store.oauthCommand('client.get',{client_id:p.client}),'keep a client with a live refresh grant');
  assert.ok(await store.oauthCommand('client.get',{client_id:waiting.client}),'keep a pending authorization');
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},tokens.access_token)).status,200);
  let accepted=1;
  for(let n=0;n<20;n++){
    const r=await post('/oauth/register',{redirect_uris:[callback]});
    if(r.status===201)accepted++;
    else {assert.equal(r.status,429);break;}
  }
  assert.equal(accepted,20,'at most 20 registrations in a rolling minute');
  connector=createConnector({store,config:{publicURL:base},schedule:()=>{}});
  assert.equal((await post('/oauth/register',{redirect_uris:[callback]})).status,429,'restarting cannot reset admission limits');
  if(postgres)sql("update public.tincall_oauth_clients set created_at=now()-interval '2 minutes' where created_at>now()-interval '1 minute';");
  else db.prepare('UPDATE tincall_oauth_clients SET created_at=? WHERE created_at>?').run(new Date(Date.now()-120000).toISOString(),new Date(Date.now()-60000).toISOString());
  await register();
});


test('OAuth capacity pressure evicts idle registrations while preserving live grants and pending approvals',async()=>{
  if(postgres)sql("update public.tincall_oauth_clients set created_at=now()-interval '2 minutes';");
  else db.prepare('UPDATE tincall_oauth_clients SET created_at=?').run(new Date(Date.now()-120000).toISOString());
  const live=await pending(),waiting=await pending();
  const authorization=await approve(live);
  assert.equal((await exchange(live,authorization)).status,200);
  if(postgres)sql(`insert into public.tincall_oauth_clients(client_id,client_name,redirect_uris,created_at)
    select 'capacity-'||n,'Fixture','[]'::jsonb,now()-interval '2 minutes'
    from generate_series(1,1000-(select count(*)::integer from public.tincall_oauth_clients)) n;`);
  else {
    const count=db.prepare('SELECT count(*) n FROM tincall_oauth_clients').get().n;
    const insert=db.prepare("INSERT INTO tincall_oauth_clients(client_id,client_name,redirect_uris,created_at) VALUES (?,'Fixture','[]',?)");
    for(let n=count;n<1000;n++)insert.run('capacity-'+n,new Date(Date.now()-120000).toISOString());
  }
  await register();
  assert.ok(await store.oauthCommand('client.get',{client_id:live.client}));
  assert.ok(await store.oauthCommand('client.get',{client_id:waiting.client}));
  const idle=await register();
  if(postgres)sql(`update public.tincall_oauth_clients set created_at=now()-interval '20 minutes' where client_id=${quote(idle)};`);
  else db.prepare('UPDATE tincall_oauth_clients SET created_at=? WHERE client_id=?').run(new Date(Date.now()-1200000).toISOString(),idle);
  await register();
  assert.equal(await store.oauthCommand('client.get',{client_id:idle}),null,'unused registrations expire well before 24 hours');
  assert.ok(await store.oauthCommand('client.get',{client_id:live.client}));
  assert.ok(await store.oauthCommand('client.get',{client_id:waiting.client}));
});

test('obsolete push cleanup preserves a concurrently replaced binding and is not callable by anonymous clients',async()=>{
  const device=crypto.randomUUID();const old='synthetic-old-binding';const current='synthetic-new-binding';
  if(postgres)sql(`insert into public.tincall_devices(owner_id,id,binding_id) values(${quote(owner)}::uuid,${quote(device)}::uuid,${quote(current)});`);
  else db.prepare('INSERT INTO tincall_devices(owner_id,id,binding_id) VALUES (?,?,?)').run(owner,device,current);
  const count=()=>postgres?Number(sql(`select count(*) from public.tincall_devices where id=${quote(device)}::uuid;`)):db.prepare('SELECT count(*) n FROM tincall_devices WHERE id=?').get(device).n;
  await store.removePushDevice(owner,{device_id:device,binding_id:old});assert.equal(count(),1);
  await store.removePushDevice(owner,{device_id:device,binding_id:current});assert.equal(count(),0);
  if(postgres)assert.equal(sql("select has_function_privilege('anon','public.tincall_remove_push_device(uuid,uuid,text)','execute');"),'f');
});


test('ordinary Supabase users cannot invoke the call RPC or write their own paths in Tincall storage',()=>{
  if(!postgres)return;
  assert.throws(()=>sql(`set role authenticated;set request.jwt.claim.role='authenticated';set request.jwt.claim.sub=${quote(owner)};select public.tincall_command('call.current','{}');`),/Command failed/);
  assert.throws(()=>sql(`set role authenticated;set request.jwt.claim.role='authenticated';set request.jwt.claim.sub=${quote(owner)};insert into storage.objects(bucket_id,name) values('tincall-private',${quote(owner+'/synthetic-denied.wav')});`),/Command failed/);
  assert.equal(sql("select count(*) from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'tincall_media_%';"),'0');
  assert.ok(sql(`set role service_role;set request.jwt.claim.role='service_role';select public.tincall_command('call.current','{}',${quote(owner)}::uuid);`));
});
