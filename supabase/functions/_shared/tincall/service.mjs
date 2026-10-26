// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {ConnectorError, ensure, uuid, json, integer, requiredText, readJSON, MAX_BODY, incomingCallMetadata} from './protocol.mjs';
import {createMessageImages} from './message-images.mjs';
import {createCallCommands, validateBinding} from './call-commands.mjs';
import {createCallJobs} from './call-jobs.mjs';
import {createMCP} from './mcp.mjs';
export {ConnectorError} from './protocol.mjs';
export {createSupabaseStore} from './supabase-store.mjs';
import {createMCPOAuth,OAuthError} from './oauth.mjs';
import serverVersion from './server-version.json' with {type:'json'};

const MAX_IMAGE_BODY = 28 * 1024 * 1024;
// Bounded well below the Edge request limit; also covers writes from other instances.
const EVENTS_WAIT_MAX_SECONDS = 25;

export function createConnector({store, config, schedule = promise => promise.catch(() => console.error('tincall_background_task_failed')), fetcher = fetch}) {
  const images = createMessageImages(store);
  const {linkedCallRecord, mcpContent} = images;
  const {runOwner, runWorker} = createCallJobs({store, config, fetcher, backendMessages: images.backendMessages});
  const {command, bindingFor, upsertMCPRole, ensureOpening, waitForEvents} =
    createCallCommands({store, config, schedule, runOwner, fetcher, images});
  const {mcp, sse, ssePost, wakeEvents, waitForInput} = createMCP({store, command, bindingFor, ensureOpening, schedule, mcpContent});

  async function incomingEvents(request,principal) {
    ensure(request.method==='GET','method_not_allowed',405);
    ensure(!principal.contact_id,'forbidden',403);
    ensure(request.headers.get('accept')?.includes('text/event-stream'),'sse_accept_required',406);
    ensure(store.subscribeIncoming,'incoming_subscription_update_required',422);
    const lifetime=new AbortController();
    const signal=AbortSignal.any([request.signal,lifetime.signal]);
    let output,stop,heartbeat,expiry,closed=false,initializing=true;
    const pending=new Map();
    const close=()=>{
      if(closed)return;closed=true;
      clearInterval(heartbeat);clearTimeout(expiry);stop?.();lifetime.abort();
      try{output?.close();}catch{}
    };
    const encode=new TextEncoder();
    const send=call=>{
      if(closed)return;
      if(initializing){if(call)pending.set(call.id,call);return;}
      // Bound queued data when a disconnected/slow client stops reading.
      if(output.desiredSize < -32){close();return;}
      output.enqueue(encode.encode(`event: call_state\ndata: ${JSON.stringify({call:incomingCallMetadata(call)})}\n\n`));
    };
    try {
      stop=await store.subscribeIncoming(principal.owner_id,send,()=>{
        if(output && !closed)output.enqueue(encode.encode('event: error\ndata: {"error":{"code":"incoming_subscription_unavailable"}}\n\n'));
        close();
      },signal);
      ensure(!signal.aborted,'wait_cancelled');
      // Subscribe before the snapshot so calls created during connection setup
      // cannot be missed. Drain notifications after this one-time recovery read.
      const snapshot=await command(principal,'call.current',{},signal);
      ensure(!signal.aborted,'wait_cancelled');
      const body=new ReadableStream({
        start(controller){
          output=controller;initializing=false;send(snapshot.call);
          for(const call of pending.values())if(call.id!==snapshot.call?.id || call.last_sequence>snapshot.call.last_sequence)send(call);pending.clear();
          heartbeat=setInterval(()=>{if(!closed)output.enqueue(encode.encode(': keepalive\n\n'));},15000);
          // Edge workers have finite lifetimes; reconnect gets a fresh snapshot.
          expiry=setTimeout(close,120000);
          signal.addEventListener('abort',close,{once:true});if(signal.aborted)close();
        },
        cancel:close,
      });
      return new Response(body,{headers:{'Content-Type':'text/event-stream','Cache-Control':'no-store','X-Accel-Buffering':'no'}});
    } catch(error){close();throw error;}
  }

  async function handle(request) {
    let oauth;let path;
    try {
      const url=new URL(request.url);const origin=request.headers.get('origin');
      ensure(!origin || (config.allowedOrigins ?? []).includes(origin),'origin_forbidden',403);
      // The Supabase gateway strips /functions/v1 before forwarding to the worker.
      path=url.pathname.replace(/^\/(?:functions\/v1\/)?tincall(?=\/|$)/,'').replace(/\/$/,'') || '/';
      const prefix=url.pathname.match(/^(\/(?:functions\/v1\/)?tincall)(?=\/|$)/)?.[1] ?? '';
      const baseURL=config.publicURL || (config.supabaseURL ? config.supabaseURL.replace(/\/$/,'')+'/functions/v1/tincall' : url.origin+prefix);
      oauth=createMCPOAuth({store,baseURL});
      const publicResponse=await oauth.publicResponse(request,path);if(publicResponse)return publicResponse;
      const token=request.headers.get('authorization')?.match(/^Bearer ([^\s]+)$/)?.[1];
      ensure(token,'unauthorized',401);
      if(path==='/push/verify') {
        ensure(request.method==='POST','method_not_allowed',405);
        ensure(config.pushToken && token===config.pushToken,'forbidden',403);
        const challenge=uuid(request.headers.get('x-tincall-push-challenge'),'challenge');
        return json({verified:true,challenge});
      }
      if(path==='/worker') {
        ensure(request.method==='POST','method_not_allowed',405);
        ensure(config.workerToken && token===config.workerToken,'forbidden',403);
        schedule(runWorker());return json({accepted:true},202);
      }
      const oauthToken=token.startsWith('tcoa_');
      const bridgeToken=token.startsWith('tcwake_');
      if(bridgeToken)ensure(store.wakeCommand,'wake_bridge_update_required',422);
      const principal=oauthToken ? await oauth.authenticate(token) : bridgeToken ? await store.wakeCommand('authenticate',null,{token}) : await store.authenticate(token);
      ensure(principal,'unauthorized',401);
      if(oauthToken)ensure(['/mcp','/mcp/sse','/mcp/messages'].includes(path),'forbidden',403);
      if(bridgeToken)ensure(['/wake/events','/wake/input','/mcp/wake','/mcp','/mcp/sse','/mcp/messages'].includes(path),'forbidden',403);
      const ownerResponse=await oauth.ownerResponse(request,path,principal);if(ownerResponse)return ownerResponse;
      if(path==='/wake/events')return await wakeEvents(request,principal,token);
      if(path==='/wake/input'){
        ensure(principal.wake_bridge,'forbidden',403);ensure(request.method==='GET','method_not_allowed',405);
        ensure([...url.searchParams.keys()].every(key=>['sequence','epoch'].includes(key)) &&
          url.searchParams.has('sequence')===url.searchParams.has('epoch'),'invalid_cursor');
        const args=url.searchParams.has('sequence')?{cursor:{sequence:integer(Number(url.searchParams.get('sequence')),'cursor'),epoch:integer(Number(url.searchParams.get('epoch')),'cursor')}}:{};
        const value=await waitForInput(principal,args,request.signal);
        const content=await mcpContent(principal,{...value,voice_instructions:null});
        if(value.voice_instructions && !value.has_more) {
          value.voice_instructions=(await store.claimVoiceInstructions(principal.owner_id,value.call.id)).voice_instructions;
        } else value.voice_instructions=null;
        if(value.call && value.cursor && !value.has_more)await store.mcpCommand(principal.owner_id,principal.contact_id,'delivered',{call_id:value.call.id,...value.cursor});
        return json({content,structuredContent:value,isError:false});
      }
      if(path==='/wake/contacts' || path==='/wake/config'){
        ensure(!principal.contact_id,'forbidden',403);ensure(store.wakeCommand,'wake_bridge_update_required',422);
        if(path==='/wake/contacts'){
          ensure(request.method==='GET','method_not_allowed',405);
          return json(await store.wakeCommand('list',principal.owner_id));
        }
        ensure(request.method==='POST','method_not_allowed',405);
        const payload=await readJSON(request);
        ensure(Object.keys(payload).every(key=>['contact_id','rotate'].includes(key)),'invalid_arguments');
        requiredText(payload.contact_id,'contact_id',200);
        ensure(payload.rotate===undefined || typeof payload.rotate==='boolean','invalid_rotate');
        ensure((await bindingFor(principal.owner_id,payload.contact_id))?.mode==='tools','contact_not_found',404);
        const next='tcwake_'+Array.from(crypto.getRandomValues(new Uint8Array(32)),byte=>byte.toString(16).padStart(2,'0')).join('');
        const saved=await store.wakeCommand('configuration',principal.owner_id,{...payload,token:next});
        return json({version:2,contact_id:payload.contact_id,
          wake:{transport:'sse',url:baseURL+'/wake/events',headers:{Authorization:'Bearer '+saved.token},event:'wake'},
          input:{transport:'http',url:baseURL+'/wake/input',headers:{Authorization:'Bearer '+saved.token}},
          mcp:{transport:'streamable-http',url:baseURL+'/mcp/wake',headers:{Authorization:'Bearer '+saved.token}},
          instructions:'Keep the wake connection outside AI tasks. Fetch input.url and drain has_more pages, deduplicating message IDs internally. Bind each AI task to input.call.id using the Tincall-Call-ID header in every MCP request for that task; never replace it with a later call. Keep the linked conversation context across wakes. Supply the AI the content blocks in order: XML messages followed by their native images; include voice_instructions when present at call start. Do not pass call IDs, reply targets, epochs or cursors to the AI. The AI replies with tincall_reply text, then finishes the task. On idle or ended, do not start a task.'});
      }
      if(path==='/calls/incoming/events')return await incomingEvents(request,principal);
      if(path==='/mcp/wake'){ensure(principal.wake_bridge,'forbidden',403);return await mcp(request,principal);}
      if(path==='/mcp') return await mcp(request,principal);
      if(path==='/mcp/sse')return await sse(request,principal);
      if(path==='/mcp/messages')return await ssePost(request,principal,url);
      if(path==='/mcp/roles/upsert') {
        ensure(request.method==='POST','method_not_allowed',405);
        ensure(!principal.contact_id,'forbidden',403);
        return json(await upsertMCPRole(principal,await readJSON(request)));
      }
      if(path==='/mcp/roles/mode') {
        ensure(request.method==='POST','method_not_allowed',405);ensure(!principal.contact_id,'forbidden',403);
        const payload=await readJSON(request);
        ensure(Object.keys(payload).every(key=>['role_id','call_mode'].includes(key)),'invalid_arguments');
        uuid(payload.role_id,'role_id');ensure(['standalone','mcp','backend'].includes(payload.call_mode),'invalid_call_mode');
        return json(await store.contactMode(principal.owner_id,'set',payload));
      }
      const media=path.match(/^\/records\/([^/]+)\/media\/([^/]+)$/);
      if(media) {
        ensure(!principal.contact_id,'forbidden',403);uuid(media[1],'record_id');uuid(media[2],'asset_id');
        ensure(['PUT','GET','DELETE'].includes(request.method),'method_not_allowed',405);
        const current=await store.command(principal.owner_id,'record.get',{record_id:media[1]});
        if(current.record?.deleted && request.method!=='DELETE') {
          let linked;
          if(request.method==='GET')linked=await linkedCallRecord(principal.owner_id,media[1]);
          ensure(linked?.messages.some(message=>(message.images ?? []).some(image=>image.id.toLowerCase()===media[2].toLowerCase())),'record_deleted',410);
        }
        const result=await store.media(principal.owner_id,media[1],media[2],request);
        if(request.method==='PUT') {
          const latest=await store.command(principal.owner_id,'record.get',{record_id:media[1]});
          if(latest.record?.deleted){await store.media(principal.owner_id,media[1],media[2],new Request(request.url,{method:'DELETE'}));throw new ConnectorError('record_deleted',410);}
        }
        return result;
      }
      if(path==='/capabilities' && request.method==='GET') {
        const bindings = new Map((config.bindings ?? []).filter(b => b.owner_id === principal.owner_id).map(b => [b.contact_id,b]));
        const saved = await store.mcpRoleCommand(principal.owner_id,'list');
        for (const binding of saved.bindings) {
          if (!bindings.has(binding.contact_id) || bindings.get(binding.contact_id).mode === 'tools') bindings.set(binding.contact_id,binding);
        }
        return json({version:1,server_version:serverVersion.server_version,...(!principal.contact_id?{owner_id:principal.owner_id}:{}),events:'poll',incoming_events:'sse',wake_bridge:'sse',max_event_page:100,reply_protocol:'append_only',
          mcp_role_management:!principal.contact_id,mcp_oauth:true,backup_only_deletion:!principal.contact_id,schedule_controls:true,
          bindings:[...bindings.values()].filter(b=>!principal.contact_id || b.contact_id===principal.contact_id).map(b=>{
            let configured = false;
            try { validateBinding(b); configured = true; }
            catch(error) { if (!(error instanceof ConnectorError)) throw error; }
            return {contact_id:b.contact_id,...(typeof b.display_name==='string' && b.display_name.trim()?{display_name:b.display_name.trim()}:{}),...(b.mcp_wait_timeout_seconds !== undefined ? {mcp_wait_timeout_seconds:b.mcp_wait_timeout_seconds} : {}),mode:b.mode,generation_configured:configured,wake_supported:configured && b.mode==='http'};
          }),
          push_configured:Boolean(config.pushURL && config.pushToken)});
      }
      let action;let payload={};
      if(request.method==='GET') {
        if(path==='/calls/current')action='call.current';
        else if(path==='/calls')action='call.list';
        else if(path==='/schedules')action='schedule.list';
        else if(path==='/records') {action='record.list';payload={after:url.searchParams.get('after') ?? undefined,after_id:url.searchParams.get('after_id') ?? undefined};}
        else {const match=path.match(/^\/calls\/([^/]+)\/(events|record|inputs)$/);const record=path.match(/^\/records\/([^/]+)$/);
          if(match) {action=`call.${match[2]}`;payload={call_id:match[1],...(match[2]==='events'?{after:Number(url.searchParams.get('after') ?? 0),limit:Number(url.searchParams.get('limit') ?? 100)}:{})};}
          else if(record){action='record.get';payload={record_id:record[1]};}
        }
      } else if(request.method==='POST') {
        const imageRoute = /^\/calls\/[^/]+\/input$/.test(path) || /^\/records\/[^/]+$/.test(path);
        payload=await readJSON(request, imageRoute ? MAX_IMAGE_BODY : MAX_BODY);
        if(path==='/calls')action='call.create';
        else if(path==='/calls/incoming')action='call.incoming';
        else if(path==='/devices')action='device.put';
        else if(path==='/devices/remove')action='device.delete';
        else if(path==='/schedules')action='schedule.put';
        else if(path==='/schedules/remove')action='schedule.delete';
        else if(path==='/schedules/enabled')action='schedule.enabled';
        else {const match=path.match(/^\/calls\/([^/]+)\/(input|interrupt|end|answer|reply|summary|activity)$/);const record=path.match(/^\/records\/([^/]+)(\/delete(?:-backup)?)?$/);
          if(match){payload.call_id=match[1];action=match[2]==='answer'?'call.accept':match[2]==='reply'?(payload.complete?'reply.completed':'reply.delta'):match[2]==='summary'?'summary.put':`call.${match[2]}`;}
          else if(record){payload.record_id=record[1];action=record[2]?'record.delete':'record.put';
            delete payload.preserve_call_media;if(record[2]==='/delete-backup')payload.preserve_call_media=true;}
        }
      }
      ensure(action,'route_not_found',404);
      if(action==='call.events') {
        const wait=Math.min(integer(Number(url.searchParams.get('wait') ?? 0),'wait'),EVENTS_WAIT_MAX_SECONDS);
        return json(await waitForEvents(principal,payload,wait,request.signal));
      }
      return json(await command(principal,action,payload));
    } catch(error) {
      if(error instanceof OAuthError || path?.startsWith('/oauth/')){
        const code=error instanceof OAuthError?error.code:error instanceof ConnectorError && error.code==='oauth_limit'?'temporarily_unavailable':'server_error';
        const status=error instanceof OAuthError || error instanceof ConnectorError?error.status:500;
        const result=json({error:code},status);if(status===401 && oauth)result.headers.set('WWW-Authenticate',oauth.challenge());return result;
      }
      const result=json({error:{code:error instanceof ConnectorError?error.code:'internal_error',message:error instanceof ConnectorError?error.code:'internal_error',...(error instanceof ConnectorError?error.details:{})}},error instanceof ConnectorError?error.status:500);
      if(result.status===401 && path?.startsWith('/mcp') && oauth)result.headers.set('WWW-Authenticate',oauth.challenge());return result;
    }
  }
  return {handle,runWorker,runOwner};
}

export function configFromEnvironment(get) {
  function parse(name) {try{return JSON.parse(get(name) || '[]');}catch{throw new ConnectorError('invalid_server_configuration',503);}}
  return {supabaseURL:get('SUPABASE_URL'),publicKey:get('SUPABASE_ANON_KEY'),serviceKey:get('SUPABASE_SERVICE_ROLE_KEY'),
    workerToken:get('TINCALL_WORKER_TOKEN'),clients:parse('TINCALL_CLIENTS'),bindings:parse('TINCALL_BINDINGS'),
    publicURL:get('TINCALL_PUBLIC_URL'),allowedOrigins:parse('TINCALL_ALLOWED_ORIGINS'),pushURL:get('TINCALL_PUSH_URL'),pushToken:get('TINCALL_PUSH_TOKEN')};
}
