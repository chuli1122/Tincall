// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {ConnectorError, UUID, ensure, json, incomingCallMetadata} from './protocol.mjs';

export function createSupabaseStore(config, fetcher = fetch) {
  ensure(config.supabaseURL && config.serviceKey && config.publicKey, 'server_configuration_missing', 503);
  const base = config.supabaseURL.replace(/\/$/, '');
  async function rpc(name, payload, signal) {
    let response;
    try {
      response = await fetcher(`${base}/rest/v1/rpc/${name}`, {
        method: 'POST', headers: {apikey: config.serviceKey, Authorization: `Bearer ${config.serviceKey}`, 'Content-Type': 'application/json'},
        body: JSON.stringify(payload), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000), redirect: 'error',
      });
    } catch { if(signal?.aborted)throw new ConnectorError('wait_cancelled');throw new ConnectorError('database_unavailable', 503); }
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (name === 'tincall_schedule_command' && ['PGRST202','42883'].includes(body.code)) {
        throw new ConnectorError('schedule_update_required',422);
      }
      if (name === 'tincall_contact_mode' && ['PGRST202','42883'].includes(body.code)) throw new ConnectorError('contact_mode_update_required',422);
      if (name === 'tincall_wake_bridge' && ['PGRST202','42883'].includes(body.code)) throw new ConnectorError('wake_bridge_update_required',422);
      if (name === 'tincall_record_summaries' && ['PGRST202','42883'].includes(body.code)) throw new ConnectorError('record_summaries_update_required',422);
      const allowed = new Set(['forbidden','unauthorized','idempotency_conflict','call_busy','call_not_found','call_ended',
        'stale_epoch','call_not_ringing','call_not_active','reply_not_found','final_text_rewrite','revision_conflict','invalid_cursor','operation_retired','device_limit','role_identity_conflict','invalid_expression_prompt',
        'sse_session_not_found','sse_session_limit','sse_queue_full','schedule_not_found','contact_not_found','oauth_limit','call_context_not_found']);
      const code = allowed.has(body.message) ? body.message : 'database_request_failed';
      const status = code === 'forbidden' || code === 'unauthorized' ? 403 : code.endsWith('_not_found') ? 404 : ['sse_session_limit','sse_queue_full','oauth_limit'].includes(code) ? 429 : allowed.has(code) ? 409 : 400;
      throw new ConnectorError(code, status);
    }
    return body;
  }
  return {
    resolveCallContext(owner,contact,prefix){return rpc('tincall_resolve_call_context',{p_owner:owner,p_contact:contact,p_prefix:prefix});},
    removePushDevice(owner,device){return rpc('tincall_remove_push_device',{p_owner:owner,p_device:device.device_id,p_binding:device.binding_id});},
    async authenticate(token) {
      const configured = (config.clients ?? []).find(client => client.token === token);
      if (configured) return {owner_id: configured.owner_id, contact_id: configured.contact_id ?? null};
      if (token.startsWith('tcmcp_')) {
        ensure(/^tcmcp_[0-9a-f]{64}$/.test(token), 'unauthorized', 401);
        const principal = await rpc('tincall_mcp_authenticate', {p_token: token});
        ensure(principal?.owner_id && principal.contact_id, 'unauthorized', 401);
        return principal;
      }
      throw new ConnectorError('unauthorized',401);
    },
    subscribeIncoming: (owner, onCall, onError, signal) => subscribeSupabaseIncoming(config, owner, onCall, onError, signal),
    subscribeWake: (owner, onCall, onError, signal) => subscribeSupabaseIncoming(config, owner, onCall, onError, signal, 'wake'),
    wakeCommand: (action, owner = null, payload = {}) => rpc('tincall_wake_bridge', {p_action:action,p_owner:owner,p_payload:payload}),
    mcpCommand: (owner, contact, action, payload = {}, {signal} = {}) => rpc('tincall_mcp', {p_action:action, p_owner:owner, p_contact:contact, p_payload:payload}, signal),
    recentCalls: (owner, contact, limit) => rpc('tincall_recent_calls', {p_owner: owner, p_contact: contact, p_limit: limit}),
    recordSummaries: (owner, ids = null) => rpc('tincall_record_summaries', {p_owner: owner, p_ids: ids}),
    command: async (owner, action, payload, {signal} = {}) => {
      const imageCommand = (action === 'call.input' && payload.images?.length) || (action === 'record.delete' && !payload.preserve_call_media);
      const value = await rpc(['schedule.put','schedule.enabled'].includes(action) ? 'tincall_schedule_command' : imageCommand ? 'tincall_image_command' : 'tincall_command', {p_action: action, p_payload: payload, p_owner: owner}, signal);
      if (value.messages) value.messages = value.messages.map(message => {
        if (!message.images?.length) { const {images, ...textOnly} = message; return textOnly; }
        return message;
      });
      return value;
    },
    async setVoicePrompt(owner, callId, prompt) {
      return rpc('tincall_set_voice_prompt', {p_call: callId, p_prompt: prompt, p_owner: owner});
    },
    async claimVoiceInstructions(owner, callId) {
      return rpc('tincall_claim_voice_instructions', {p_call: callId, p_owner: owner});
    },
    callPresence: (action, owner = null, call = null) => rpc('tincall_call_presence', {p_action: action, p_owner: owner, p_call: call}),
    contactMode: (owner, action, payload = {}) => rpc('tincall_contact_mode', {p_action:action,p_owner:owner,p_payload:payload}),
    oauthCommand: (action, payload = {}) => rpc('tincall_oauth', {p_action: action, p_payload: payload}),
    mcpRoleCommand: (owner, action, payload = {}) => rpc('tincall_mcp_role', {p_action: action, p_owner: owner, p_payload: payload}),
    sseCommand: (principal, action, payload, {signal} = {}) => rpc('tincall_mcp_sse_command', {
      p_action:action, p_owner:principal.owner_id, p_contact:principal.contact_id ?? null, p_payload:payload,
    }, signal),
    workerOwners: () => rpc('tincall_worker_owners', {}),
    async media(owner,recordId,assetId,request) {
      const path=`${owner}/${recordId}/${assetId}`.toLowerCase();
      const headers={apikey:config.serviceKey,Authorization:`Bearer ${config.serviceKey}`};
      const init={method:request.method==='PUT'?'POST':request.method,headers,redirect:'error',signal:request.signal};
      if(request.method==='PUT') {
        const type=request.headers.get('content-type') ?? 'application/octet-stream';
        ensure(/^(audio\/|image\/|application\/octet-stream$)/.test(type),'unsupported_media_type',415);
        const length=Number(request.headers.get('content-length') ?? 0);
        ensure(Number.isSafeInteger(length) && length>=0 && length<=512*1024*1024,'media_too_large',413);
        ensure(request.body,'body_required');
        headers['Content-Type']=type;headers['x-upsert']='false';if(length)headers['Content-Length']=String(length);
        let count=0;
        init.body=request.body.pipeThrough(new TransformStream({transform(chunk,controller){count+=chunk.byteLength;if(count>512*1024*1024)controller.error(new ConnectorError('media_too_large',413));else controller.enqueue(chunk);}}));
        init.duplex='half';
      }
      if(request.method==='DELETE'){headers['Content-Type']='application/json';init.body=JSON.stringify({prefixes:[path]});}
      const response=await fetcher(`${base}/storage/v1/object/tincall-private${request.method==='DELETE'?'':`/${path}`}`,init).catch(()=>{throw new ConnectorError('media_unavailable',503);});
      if(!response.ok)throw new ConnectorError(response.status===404?'media_not_found':response.status===409?'media_exists':'media_request_failed',response.status===404?404:response.status===409?409:502);
      if(request.method==='GET') {
        const outputHeaders={'Content-Type':response.headers.get('content-type') ?? 'application/octet-stream','Cache-Control':'no-store'};
        if(response.headers.get('content-length'))outputHeaders['Content-Length']=response.headers.get('content-length');
        return new Response(response.body,{status:200,headers:outputHeaders});
      }
      await response.body?.cancel();return json({ok:true});
    },
    async deleteRecordMedia(owner,recordId,preserve = []) {
      const prefix=`${owner}/${recordId}/`.toLowerCase();
      const preserved=new Set(preserve.map(id=>id.toLowerCase()));let offset=0;
      const headers={apikey:config.serviceKey,Authorization:`Bearer ${config.serviceKey}`,'Content-Type':'application/json'};
      for(let i=0;i<3+Math.ceil(preserved.size/100);i++){
        const listed=await fetcher(`${base}/storage/v1/object/list/tincall-private`,{method:'POST',headers,body:JSON.stringify({prefix,limit:100,offset,sortBy:{column:'name',order:'asc'}}),signal:AbortSignal.timeout(10000),redirect:'error'});
        ensure(listed.ok,'media_cleanup_failed',503);const files=await listed.json();if(!files.length)return;
        const removed=files.filter(file=>!preserved.has(file.name.toLowerCase()));
        if(removed.length){
          const deleted=await fetcher(`${base}/storage/v1/object/tincall-private`,{method:'DELETE',headers,body:JSON.stringify({prefixes:removed.map(file=>prefix+file.name)}),signal:AbortSignal.timeout(10000),redirect:'error'});
          ensure(deleted.ok,'media_cleanup_failed',503);await deleted.body?.cancel();
        }
        offset+=files.length-removed.length;
        if(files.length<100)return;
      }
      throw new ConnectorError('media_cleanup_pending',503);
    },
  };
}

// Server-side private Realtime channel. Only authenticated owner metadata is
// forwarded to the phone; service credentials never leave the data service.
async function subscribeSupabaseIncoming(config, owner, onCall, onError, signal, kind = 'incoming') {
  const url = new URL(config.supabaseURL);
  url.protocol = 'wss:'; url.pathname = '/realtime/v1/websocket';
  // Opaque sb_* keys retain the gateway's handshake identity on channel join.
  // Authenticate this server-side connection with the service key from the start.
  url.search = new URLSearchParams({apikey:config.serviceKey,vsn:'1.0.0'}).toString();
  const socket = new WebSocket(url);
  const topic = `realtime:tincall:${kind}:${owner}`;
  let heartbeat, timeout, settled=false, stopped=false, reference=0;
  let resolveReady, rejectReady;
  const ready = new Promise((resolve,reject)=>{resolveReady=resolve;rejectReady=reject;});
  const send=(event,payload,channel=topic)=>socket.send(JSON.stringify({topic:channel,event,payload,ref:String(++reference)}));
  const stop=()=>{
    if(stopped)return;stopped=true;
    clearInterval(heartbeat);clearTimeout(timeout);signal?.removeEventListener('abort',cancel);
    socket.close();
  };
  const fail=()=>{
    if(stopped)return;
    const error=new ConnectorError(kind==='wake'?'wake_subscription_unavailable':'incoming_subscription_unavailable',503);
    if(!settled){settled=true;rejectReady(error);}else onError(error);
    stop();
  };
  const cancel=()=>{
    if(!settled){settled=true;rejectReady(new ConnectorError('wait_cancelled'));}
    stop();
  };
  socket.addEventListener('open',()=>{
    if(stopped)return;
    send('phx_join',{config:{broadcast:{ack:false,self:false},presence:{enabled:false},private:true},access_token:config.serviceKey});
    heartbeat=setInterval(()=>{if(socket.readyState===1)send('heartbeat',{},'phoenix');},25000);
  });
  socket.addEventListener('message',event=>{
    if(stopped)return;
    try {
      const message=JSON.parse(event.data);
      if(message.topic!==topic)return;
      if(message.event==='phx_reply' && !settled){
        if(message.payload?.status!=='ok'){fail();return;}
        settled=true;clearTimeout(timeout);resolveReady(stop);
      }else if(message.event==='broadcast' && message.payload?.event===(kind==='wake'?'wake':'call_state')){
        const call=message.payload.payload?.call;
        if(call && UUID.test(call.id) && ['ringing','active','ended'].includes(call.status))onCall(incomingCallMetadata(call));
      }else if(['phx_error','phx_close'].includes(message.event))fail();
    }catch{fail();}
  });
  socket.addEventListener('error',fail);socket.addEventListener('close',fail);
  timeout=setTimeout(fail,10000);
  signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
  return ready;
}
