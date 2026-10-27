// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {connect} from 'node:http2';
import {createPrivateKey,sign,randomUUID} from 'node:crypto';
import {readFileSync,mkdirSync,chmodSync,openSync,closeSync} from 'node:fs';
import {dirname} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {ActivityPushError, LiveActivityPushRegistry, validateActivityToken, activityStartPayload} from './live-activity-push.mjs';

const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export class PushError extends Error {constructor(code,status=400){super(code);this.code=code;this.status=status;}}
const requireValue=(condition,code,status=400)=>{if(!condition)throw new PushError(code,status);};
const response=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});

// The sender uses native HTTP/2. Edge runtimes call this metadata-only service.
export function createAPNsTransport(config) {
  requireValue(config.teamID && config.keyID && config.keyFile && config.topic?.endsWith('.voip'),'apns_configuration_missing',503);
  const key=createPrivateKey(readFileSync(config.keyFile));
  let cached;let issued=0;
  function token(){
    const now=Math.floor(Date.now()/1000);
    if(!cached || now-issued>2700){
      const header=Buffer.from(JSON.stringify({alg:'ES256',kid:config.keyID})).toString('base64url');
      const payload=Buffer.from(JSON.stringify({iss:config.teamID,iat:now})).toString('base64url');
      const data=`${header}.${payload}`;
      // ES256 is the required APNs authentication signature, not an artifact check.
      const signature=sign('sha256',Buffer.from(data),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
      cached=`${data}.${signature}`;issued=now;
    }
    return cached;
  }
  return function send(device,payload){
    const activity=payload.event==='activity_start';
    return new Promise((resolve,reject)=>{
      const session=connect(device.environment==='sandbox'?'https://api.sandbox.push.apple.com':'https://api.push.apple.com');
      let settled=false;
      function finish(error){if(settled)return;settled=true;clearTimeout(timer);session.destroy();error?reject(error):resolve({accepted_by_apns:true});}
      const timer=setTimeout(()=>finish(new PushError('apns_timeout',503)),8000);
      session.on('error',()=>finish(new PushError('apns_unavailable',503)));
      const request=session.request({':method':'POST',':path':`/3/device/${device.device_token}`,
        authorization:`bearer ${token()}`,'apns-topic':activity?config.topic.replace(/\.voip$/,'.push-type.liveactivity'):config.topic,'apns-push-type':activity?'liveactivity':'voip','apns-priority':'10','apns-expiration':'0','apns-id':payload.call_id,
        'content-type':'application/json'});
      let status=0;let size=0;
      request.on('response',headers=>{status=Number(headers[':status']);});
      request.on('data',chunk=>{size+=chunk.length;if(size>8192)finish(new PushError('apns_invalid_response',502));});
      request.on('error',()=>finish(new PushError('apns_unavailable',503)));
      request.on('end',()=>finish(status===200?null:new PushError(status===410?'apns_device_expired':'apns_rejected',502)));
      request.end(JSON.stringify(activity?activityStartPayload(payload.call_id,undefined,payload.avatar_contact_id,payload.display_name):{aps:{'content-available':1},event:'incoming_call',device_id:device.device_id,call_id:payload.call_id,contact_id:payload.contact_id,source:payload.source}));
    });
  };
}

export function createPushGateway({databasePath,token,send}) {
  requireValue(token && token.length>=24,'push_token_required',503);
  mkdirSync(dirname(databasePath),{recursive:true,mode:0o700});
  const fd=openSync(databasePath,'a',0o600);closeSync(fd);
  chmodSync(databasePath,0o600);
  const db=new DatabaseSync(databasePath);
  db.exec(`pragma journal_mode=WAL;
    create table if not exists devices(binding_id text primary key,owner_id text not null,device_id text not null,device_token text not null,environment text not null,enabled integer not null default 1,unique(owner_id,device_id));
    create table if not exists deliveries(binding_id text not null,call_id text not null,contact_id text not null,state text not null,created_at integer not null,primary key(binding_id,call_id));`);
  if(!db.prepare('pragma table_info(devices)').all().some(column=>column.name==='calls_valid_until')) db.exec('alter table devices add column calls_valid_until integer');
  const activities=new LiveActivityPushRegistry((query,...values)=>{
    const statement=db.prepare(query);
    if(statement.columns().length)return statement.all(...values);
    statement.run(...values);return [];
  },send);
  async function handle(request){
    try{
      requireValue(request.method==='POST','method_not_allowed',405);
      requireValue(!request.headers.get('origin'),'origin_forbidden',403);
      requireValue(request.headers.get('authorization')===`Bearer ${token}`,'unauthorized',401);
      requireValue(request.headers.get('content-type')?.startsWith('application/json'),'json_required',415);
      const reader=request.body?.getReader();requireValue(reader,'body_required');
      let body='';const decoder=new TextDecoder();
      try{while(true){const {done,value}=await reader.read();if(done)break;body+=decoder.decode(value,{stream:true});requireValue(body.length<=4096,'body_too_large',413);}body+=decoder.decode();}finally{reader.releaseLock();}
      let p;try{p=JSON.parse(body);}catch{throw new PushError('invalid_json');}
      requireValue(p && UUID.test(p.owner_id),'invalid_owner_id');
      const path=new URL(request.url).pathname;
      if(path==='/devices'){
        requireValue(UUID.test(p.device_id),'invalid_device_id');
        requireValue(typeof p.device_token==='string' && /^[a-f0-9]{32,256}$/i.test(p.device_token),'invalid_device_token');
        requireValue(['sandbox','production'].includes(p.environment),'invalid_environment');
        validateActivityToken(p.live_activity_start_token);
        const until=p.calls_valid_until==null?null:Date.parse(p.calls_valid_until);
        requireValue(until===null || (typeof p.calls_valid_until==='string' && Number.isFinite(until)),'invalid_call_expiry');
        const previous=db.prepare('select * from devices where owner_id=? and device_id=?').get(p.owner_id,p.device_id);
        const binding=previous?.enabled && previous.device_token===p.device_token && previous.environment===p.environment ? previous.binding_id : randomUUID();
        db.prepare('insert into devices(binding_id,owner_id,device_id,device_token,environment,calls_valid_until) values(?,?,?,?,?,?) on conflict(owner_id,device_id) do update set binding_id=excluded.binding_id,device_token=excluded.device_token,environment=excluded.environment,calls_valid_until=excluded.calls_valid_until,enabled=1')
          .run(binding,p.owner_id,p.device_id,p.device_token,p.environment,until);
        if(previous && previous.binding_id!==binding)activities.remove(previous.binding_id);
        const device=db.prepare('select binding_id from devices where owner_id=? and device_id=?').get(p.owner_id,p.device_id);
        activities.register(device.binding_id,p.live_activity_start_token);
        return response({binding_id:device.binding_id,live_activity_push:true,call_access_expiry:true});
      }
      if(path==='/devices/remove'){
        requireValue(UUID.test(p.device_id),'invalid_device_id');
        const device=db.prepare('select binding_id from devices where owner_id=? and device_id=?').get(p.owner_id,p.device_id);
        if(device)activities.remove(device.binding_id);
        db.prepare('update devices set enabled=0 where owner_id=? and device_id=?').run(p.owner_id,p.device_id);
        return response({ok:true});
      }
      if(path==='/activities/start'){
        requireValue(UUID.test(p.device_id),'invalid_device_id');
        const device=db.prepare('select * from devices where owner_id=? and device_id=? and enabled=1').get(p.owner_id,p.device_id);
        requireValue(device,'device_not_registered',404);
        return response(await activities.start(device,p.call_id,p.avatar_contact_id,p.display_name));
      }
      requireValue(path==='/push','route_not_found',404);
      requireValue(UUID.test(p.call_id) && UUID.test(p.binding_id),'invalid_identifier');
      requireValue(p.event==='incoming_call' && typeof p.contact_id==='string' && p.contact_id.length>0 && p.contact_id.length<=200,'invalid_event');
      requireValue(['backend','mcp','independent'].includes(p.source),'invalid_source');
      const device=db.prepare('select * from devices where binding_id=? and owner_id=? and enabled=1').get(p.binding_id,p.owner_id);
      requireValue(device,'device_not_registered',404);
      requireValue(device.calls_valid_until==null || device.calls_valid_until>Date.now(),'call_access_expired',403);
      const old=db.prepare('select * from deliveries where binding_id=? and call_id=?').get(p.binding_id,p.call_id);
      requireValue(!old || old.contact_id===p.contact_id,'idempotency_conflict',409);
      if(old?.state==='sent')return response({accepted_by_apns:true});
      const now=Date.now();
      requireValue(old?.state!=='sending' || now-old.created_at>15000,'push_in_progress',409);
      db.prepare("insert into deliveries(binding_id,call_id,contact_id,state,created_at) values(?,?,?,'sending',?) on conflict(binding_id,call_id) do update set state='sending',created_at=excluded.created_at").run(p.binding_id,p.call_id,p.contact_id,now);
      try{await send(device,p);db.prepare("update deliveries set state='sent' where binding_id=? and call_id=?").run(p.binding_id,p.call_id);}
      catch(error){db.prepare("update deliveries set state='failed' where binding_id=? and call_id=?").run(p.binding_id,p.call_id);if(error?.code==='apns_device_expired')db.prepare('update devices set enabled=0 where binding_id=?').run(p.binding_id);throw error;}
      // Routing receipt retention is bounded; device bindings persist until disabled/removed.
      db.prepare('delete from deliveries where created_at<?').run(now-7*24*60*60*1000);
      return response({accepted_by_apns:true});
    }catch(error){return response({error:{code:error instanceof PushError || error instanceof ActivityPushError?error.code:'push_failed'}},error instanceof PushError || error instanceof ActivityPushError?error.status:503);}
  }
  return {handle,close:()=>db.close()};
}
