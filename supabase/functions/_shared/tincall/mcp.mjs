// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {ConnectorError, ensure, uuid, object, json, integer, publicCall, readJSON} from './protocol.mjs';

const PROTOCOLS = ['2025-11-25', '2025-06-18', '2025-03-26'];
// Leave response headroom below Supabase's 150-second request idle timeout.
const MCP_WAIT_MAX_SECONDS = 130;
const MCP_WAIT_DEFAULT_SECONDS = 120;
const MCP_WAIT_POLL_MS = 1000;

function waitTimeout(value = MCP_WAIT_DEFAULT_SECONDS) {
  integer(value, 'timeout_seconds');
  ensure(value >= 1 && value <= MCP_WAIT_MAX_SECONDS, 'invalid_timeout_seconds');
  return value;
}
const waitProperties = {
  cursor:{type:'object',properties:{sequence:{type:'integer',minimum:0},epoch:{type:'integer',minimum:0}},required:['sequence','epoch'],additionalProperties:false},
  timeout_seconds:{type:'integer',minimum:1,maximum:MCP_WAIT_MAX_SECONDS,default:MCP_WAIT_DEFAULT_SECONDS},
};
const toolDefinitions = [
  ['tincall_call', 'Call the linked phone and wait for the person to answer. When answered, speak by calling tincall_reply with your complete text. If the wait times out, call tincall_wait to keep waiting.', {contact_id:{type:'string'},timeout_seconds:waitProperties.timeout_seconds}, ['contact_id']],
  ['tincall_get_call', 'Read saved conversation history and current call state using the 8-character call ID, or omit it to find the current call. An ended call may also have a summary. For live conversation use tincall_wait; after a timeout keep waiting. History is paged, newest page first.', {call_id:{type:'string',description:'8-character call ID from a call result or history list.'},limit:{type:'integer',minimum:1,maximum:100,default:50},before_sequence:{type:'integer',minimum:1}}, []],
  ['tincall_wait', 'Wait for the next message, phone answer or hangup. Reuse the short call marker for this task; omit call only to discover a new call. After a timeout keep waiting.', {call:{type:'string',minLength:8,maxLength:8},timeout_seconds:waitProperties.timeout_seconds}, []],
  ['tincall_reply', 'Speak your complete reply, then wait for the next input by default. Omit wait_for_input; set it to false only to return immediately, such as before tincall_end. Reuse the 8-character call marker returned when this call was opened or discovered. Later messages do not repeat it. Never substitute a new call marker to retry an old reply or hangup.', {call:{type:'string',minLength:8,maxLength:8},text:{type:'string'},wait_for_input:{type:'boolean',default:true,description:'Omit to wait for the next input. Set false only to return immediately.'},timeout_seconds:waitProperties.timeout_seconds}, ['call','text']],
  ['tincall_end', 'Hang up after the phone finishes reading your reply. Reuse the 8-character call marker returned when this call was opened or discovered. Never substitute another call to retry an old hangup.', {call:{type:'string',minLength:8,maxLength:8}}, ['call']],
  ['tincall_list_calls', 'List saved calls. Use get_call to read a selected conversation and any available summary.', {limit:{type:'integer',minimum:1,maximum:50,default:10},before:{type:'object',properties:{started_at:{type:'string'},call_id:{type:'string'}},required:['started_at','call_id'],additionalProperties:false}}, []],
].map(([name, description, properties, required]) => ({name, description, inputSchema:{type:'object',properties,required,additionalProperties:false}}));

function replyReference(reply) {
  const bytes = reply.reply_id.replaceAll('-', '').match(/../g).map(value => parseInt(value, 16));
  return `${reply.epoch}.${btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/, '')}`;
}
export function callReference(id) {
  const bytes=id.replaceAll('-','').slice(0,12).match(/../g).map(value=>parseInt(value,16));
  return btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_');
}
// Owns reply targets, long waits, and both MCP transports, including wake subscriptions.
export function createMCP({store, command, bindingFor, ensureOpening, schedule, mcpContent}) {
  async function callWaitTimeout(principal, args, call) {
    if (args.timeout_seconds !== undefined) return waitTimeout(args.timeout_seconds);
    const binding = await bindingFor(principal.owner_id, call.contact_id);
    return waitTimeout(binding?.mcp_wait_timeout_seconds);
  }
  async function mcpSnapshot(principal, payload, signal) {
    const read = () => store.mcpCommand(principal.owner_id, principal.contact_id ?? null, 'snapshot', payload, {signal});
    let value = await read();
    if (value.call?.status === 'active' && value.call.source === 'mcp' && value.call.epoch === 0) {
      await ensureOpening(principal, value.call);
      value = await read();
    }
    return {...value,call:publicCall(value.call),reply:value.reply ? {...value.reply,reply_to:replyReference(value.reply)} : null};
  }
  async function boundCallID(principal,args) {
    const bound=principal.mcp_call_id;
    ensure(!principal.wake_bridge || bound,'call_context_required',409);
    if(bound) {
      ensure(args.call===undefined || args.call===callReference(bound),'call_context_mismatch',409);
      ensure(args.call_id===undefined || args.call_id.toLowerCase()===bound,'call_context_mismatch',409);
      return bound;
    }
    ensure(typeof args.call==='string' && /^[A-Za-z0-9_-]{8}$/.test(args.call),'call_context_required',409);
    const prefix=Array.from(atob(args.call.replaceAll('-','+').replaceAll('_','/')),char=>char.charCodeAt(0).toString(16).padStart(2,'0')).join('');
    const {call_id}=await store.resolveCallContext(principal.owner_id,principal.contact_id??null,prefix);
    return uuid(call_id,'call_id').toLowerCase();
  }
  async function waitForInput(principal, args, signal) {
    let callId = principal.mcp_call_id || args.call!==undefined ? await boundCallID(principal,args) : args.call_id;
    if (callId === undefined) {
      const current = await mcpSnapshot(principal, {}, signal);
      if (!current.call) return {...current,event:'ended',message:'当前没有进行中的通话。'};
      callId = current.call.id;
    }
    uuid(callId, 'call_id');
    const initial = await mcpSnapshot(principal,{call_id:callId,unread:true},signal);
    const cursor = args.cursor === undefined ? initial.read_cursor : object(args.cursor);
    ensure(Object.keys(cursor).every(key => ['sequence','epoch'].includes(key)), 'invalid_cursor');
    integer(cursor.sequence,'cursor'); ensure(Number.isInteger(cursor.epoch) && cursor.epoch>=-1,'invalid_cursor');
    const deadline = Date.now() + await callWaitTimeout(principal,args,initial.call) * 1000;
    while (true) {
      ensure(!signal?.aborted, 'wait_cancelled');
      let value = await mcpSnapshot(principal, {call_id:callId,after_sequence:cursor.sequence,...(!principal.wake_bridge ? {unread:true} : {}),limit:principal.wake_bridge?50:100}, signal);
      if (!principal.wake_bridge) {
        const messages = [...value.messages];
        while (value.has_more) {
          value = await mcpSnapshot(principal,{call_id:callId,after_sequence:value.after_sequence,limit:100},signal);
          for (const message of value.messages) if (!messages.some(item=>item.id===message.id)) messages.push(message);
        }
        value = {...value,messages};
      }
      ensure(!signal?.aborted, 'wait_cancelled');
      ensure(cursor.epoch <= value.call.epoch, 'invalid_cursor');
      const result = {...value, cursor:{sequence:value.after_sequence,epoch:value.call.epoch}};
      delete result.after_sequence;
      if (value.call.status === 'ended') return {...result,event:'ended'};
      if (principal.wake_bridge) return {...result,event:value.has_more?'input':value.reply?(value.reply.kind==='opening'?'answered':'input'):'idle',
        message:value.reply || value.has_more ? '由接入程序先取齐本轮输入，再携带消息、图片、语音要求和回复目标启动 AI；AI 通过 tincall_reply 回复后结束任务，无需再读取或等待输入。':'当前没有待回复的输入，不启动 AI，等待下一次唤醒事件。'};
      if (value.messages.length || value.has_more) return {...result,event:'input'};
      if (value.call.status==='active' && cursor.epoch<0) return {...result,event:'answered'};
      // Internal turn changes do not finish a wait for the next spoken message.
      const remaining = deadline - Date.now();
      if (remaining <= 0) return {...result,event:'timeout',
        message:'等待已超时，对方尚未回复，通话仍在继续。请调用 tincall_wait 继续等待。',
        next_action:{tool:'tincall_wait',arguments:{}}};
      await new Promise((resolve, reject) => {
        const cancel = () => { clearTimeout(timer); reject(new ConnectorError('wait_cancelled')); };
        const timer = setTimeout(() => { signal?.removeEventListener('abort',cancel); resolve(); }, Math.min(MCP_WAIT_POLL_MS,remaining));
        signal?.addEventListener('abort',cancel,{once:true});
      });
    }
  }
  async function replyAndWait(principal, args, signal) {
    ensure(typeof args.text==='string' && args.text.trim().length>0 && args.text.length<=100000,'invalid_text');
    ensure(args.wait_for_input===undefined || typeof args.wait_for_input==='boolean','invalid_wait_for_input');
    // Validate explicit integration overrides before submitting a reply. The
    // ordinary wait resolves the saved preference using this call's contact.
    if(args.timeout_seconds !== undefined)waitTimeout(args.timeout_seconds);
    const callID=await boundCallID(principal,args);
    const accepted=await store.mcpCommand(principal.owner_id,principal.contact_id??null,'send',{
      call_id:callID,request_id:crypto.randomUUID(),text:args.text,
    });
    if (principal.wake_bridge || args.wait_for_input===false) return {value:{...accepted,event:'sent'},cursor:accepted.cursor};
    try {
      // A submitted reply confirms the call is connected, even without a prior wait.
      await store.mcpCommand(principal.owner_id,principal.contact_id??null,'delivered',{call_id:callID,...accepted.cursor});
      return {value:{reply_accepted:true,...await waitForInput(principal,{call_id:callID,...(args.timeout_seconds !== undefined ? {timeout_seconds:args.timeout_seconds} : {})},signal)},cursor:accepted.cursor};
    } catch(error) {
      return {value:{...accepted,wait_error:{code:error instanceof ConnectorError?error.code:'wait_failed'}},cursor:accepted.cursor};
    }
  }

  // Render media before advancing delivery, so a failed image load is retryable.
  async function renderResult(principal,value,showCallMarker) {
    const content=await mcpContent(principal,{...value,voice_instructions:null});
    if(!principal.wake_bridge && value.call && showCallMarker && !value.error) {
      content.push({type:'text',text:`call: ${callReference(value.call.id)}`});
    }
    if(value.voice_instructions && value.call?.status==='active') {
      const {voice_instructions:instructions}=await store.claimVoiceInstructions(principal.owner_id,value.call.id);
      if(instructions) {
        const text=`本次通话的朗读要求：\n${instructions}`;
        if(content[0]?.type==='text')content[0].text += (content[0].text?'\n\n':'')+text;
        else content.unshift({type:'text',text});
      }
    }
    if(value.cursor && value.call && !value.wait_error) {
      await store.mcpCommand(principal.owner_id,principal.contact_id??null,'delivered',{call_id:value.call.id,...value.cursor,epoch:value.call.status==='ringing'?-1:value.cursor.epoch});
    }
    return content;
  }

  async function mcp(request,principal) {
    ensure(request.method==='POST','method_not_allowed',405);
    const protocol=request.headers.get('MCP-Protocol-Version');
    ensure(!protocol || PROTOCOLS.includes(protocol),'unsupported_mcp_version');
    const accept=request.headers.get('accept') ?? '';
    ensure(accept.includes('application/json') && accept.includes('text/event-stream'),'mcp_accept_required',406);
    const message=await readJSON(request);
    if(request.headers.has('Tincall-Call-ID'))principal={...principal,mcp_call_id:uuid(request.headers.get('Tincall-Call-ID'),'call_id').toLowerCase()};
    return mcpMessage(message,principal,PROTOCOLS,request.signal);
  }

  async function mcpMessage(message,principal,protocols,signal) {
    ensure(message.jsonrpc==='2.0' && typeof message.method==='string','invalid_rpc');
    if (message.id===undefined) {
      ensure(message.method==='notifications/initialized' || message.method==='notifications/cancelled','unknown_notification');
      return new Response(null,{status:202});
    }
    let result;
    if(message.method==='initialize') result={protocolVersion:protocols.includes(message.params?.protocolVersion) ? message.params.protocolVersion : protocols[0],capabilities:{tools:{listChanged:false}},serverInfo:{name:principal.wake_bridge?'tincall-wake-connector':'tincall-connector',version:'1.0.0'},
      ...(principal.wake_bridge?{instructions:'The wake adapter supplies messages in the linked conversation. Reply through tincall_reply using text, then finish this task. New messages trigger another wake.'}:{})};
    else if(message.method==='ping') result={};
    else if(message.method==='tools/list') result={tools:toolDefinitions.filter(tool=>!principal.wake_bridge || tool.name!=='tincall_wait').map(tool => {
      const hidden = new Set(['timeout_seconds']);
      if(principal.wake_bridge)hidden.add('wait_for_input');
      if(principal.wake_bridge)hidden.add('call');
      if (tool.name === 'tincall_call' || tool.name === 'tincall_end') hidden.add('request_id');
      if (['tincall_call','tincall_end','tincall_reply','tincall_wait'].includes(tool.name)) hidden.add('call_id');
      if (tool.name === 'tincall_reply') { hidden.add('reply_id'); hidden.add('epoch'); }
      if (tool.name === 'tincall_end') hidden.add('epoch');
      if (tool.name === 'tincall_call' && principal.contact_id) hidden.add('contact_id');
      const bridgeDescription=principal.wake_bridge ? {
        tincall_reply:'Speak your complete reply using text, then finish this task. The adapter binds this task to its original call. New messages trigger another wake.',
        tincall_end:'Hang up the call bound to this task after the phone finishes reading your reply. No parameters needed.',
      }[tool.name] : null;
      return {...tool,...(bridgeDescription?{description:bridgeDescription}:{}),inputSchema:{...tool.inputSchema,
        properties:Object.fromEntries(Object.entries(tool.inputSchema.properties).filter(([key]) => !hidden.has(key))),
        required:tool.inputSchema.required.filter(key => !hidden.has(key))}};
    })};
    else if(message.method==='tools/call') {
      const params=object(message.params);const args=object(params.arguments ?? {});let value;let acceptedCursor;
      try {
        const definition = toolDefinitions.find(tool => tool.name === params.name);
        if (!definition) return json({jsonrpc:'2.0',id:message.id,error:{code:-32601,message:'Unknown tool'}});
        if (!Object.keys(args).every(key => Object.hasOwn(definition.inputSchema.properties, key))) {
          throw new ConnectorError('invalid_arguments', 400, params.name === 'tincall_reply'
            ? {message:'回复未发送：请按当前工具定义提交正文和必要参数，移除多余参数后重试。'} : {});
        }
        switch(params.name) {
          case 'tincall_call':
            if(args.timeout_seconds !== undefined)waitTimeout(args.timeout_seconds);
            if(principal.wake_bridge || principal.mcp_call_id) {
              const bound=await boundCallID(principal,args);
              try {
                const original=await mcpSnapshot(principal,{call_id:bound},signal);
                ensure(original.call.status!=='ended','call_ended',409);
              } catch(error) {
                if(!(error instanceof ConnectorError && error.code==='call_not_found'))throw error;
              }
            }
            try { value=await command(principal,'call.incoming',{...args,request_id:args.request_id ?? crypto.randomUUID(),call_id:principal.mcp_call_id ?? crypto.randomUUID(),contact_id:args.contact_id ?? principal.contact_id,source:'mcp'}); }
            catch (error) {
              if (!(error instanceof ConnectorError && error.code === 'call_busy')) throw error;
              const current=await mcpSnapshot(principal,{},signal);
              if ((!principal.mcp_call_id || current.call?.id===principal.mcp_call_id) && args.request_id === undefined && current.call?.source === 'mcp' &&
                  current.call.contact_id === (args.contact_id ?? principal.contact_id)) {
                value = {...current,reused:true};
              } else value={error:{code:'call_busy',message:'云端仍有未结束的通话记录。请在 Tincall 检查云端通话状态。'},call:current.call};
            }
            if(value.call && !value.error) {
              const call_id=value.call.id;
              const seconds=await callWaitTimeout(principal,args,value.call);
              await store.mcpCommand(principal.owner_id,principal.contact_id??null,'dial_wait',{call_id,until:new Date(Date.now()+seconds*1000).toISOString()});
              try {
                value=await waitForInput({...principal,wake_bridge:false},{call_id,timeout_seconds:seconds},signal);
              } finally {
                await store.mcpCommand(principal.owner_id,principal.contact_id??null,'dial_wait',{call_id,...(value.call?.status==='active'?{until:new Date(0).toISOString()}:{})});
              }
            }
            break;
          case 'tincall_get_call': {
            if(typeof args.call_id==='string' && args.call_id.length===8)args.call_id=await boundCallID(principal,{call:args.call_id});
            if(principal.mcp_call_id)args.call_id=await boundCallID(principal,args);
            if (args.call_id !== undefined) uuid(args.call_id,'call_id');
            if (args.before_sequence !== undefined) ensure(integer(args.before_sequence,'before_sequence')>0,'invalid_before_sequence');
            const limit=args.limit === undefined ? 50 : args.limit; ensure(Number.isSafeInteger(limit) && limit>=1 && limit<=100,'invalid_limit');
            value=await mcpSnapshot(principal,{...args,limit},signal);
            if(value.call?.status==='active' && value.read_cursor.epoch<0 && args.before_sequence===undefined) {
              // Acknowledge only the connection; history reads leave input unread.
              value={...value,event:'answered',cursor:{...value.read_cursor,epoch:value.call.epoch}};
            }
            break;
          }
          case 'tincall_wait':value=principal.wake_bridge
            ? {next_action:'finish_task',message:'无需等待，新消息会自动唤醒你。现在可以结束本次任务。'}
            : await waitForInput(principal,args,signal);break;
          case 'tincall_reply': {
            const replied=await replyAndWait(principal,args,signal);value=replied.value;acceptedCursor=replied.cursor;break;
          }
          case 'tincall_end': {
            const callID=await boundCallID(principal,args);
            if (args.epoch !== undefined) integer(args.epoch,'epoch');
            const request_id = uuid(args.request_id ?? crypto.randomUUID(),'request_id');
            const snapshot = await mcpSnapshot(principal,{call_id:callID},signal);
            ensure(snapshot.call.status!=='ended','call_ended',409);
            const call_id = snapshot.call.id, epoch = args.epoch ?? snapshot.call.epoch;
            // Finalize any stored streaming tail before the ordered end event.
            // A newer user turn still causes stale_epoch; never close over new input.
            if (snapshot.reply && snapshot.call.status === 'active') {
              await store.mcpCommand(principal.owner_id,principal.contact_id ?? null,'reply',{
                request_id:crypto.randomUUID(),call_id,reply_id:snapshot.reply.reply_id,epoch,status:'complete',text:''});
            }
            value={...await command(principal,'call.end',{...args,call_id,epoch,reason:'mcp_hangup',request_id}),playback_pending:true};break;
          }
          case 'tincall_list_calls': {
            const limit=args.limit === undefined ? 10 : args.limit; ensure(Number.isSafeInteger(limit) && limit>=1 && limit<=50,'invalid_limit');
            if (args.before !== undefined) {
              const before=object(args.before);
              ensure(Object.keys(before).every(key=>['call_id','started_at'].includes(key)) && typeof before.started_at==='string' && Number.isFinite(Date.parse(before.started_at)),'invalid_cursor');
              if(typeof before.call_id==='string' && before.call_id.length===8)before.call_id=await boundCallID(principal,{call:before.call_id});
              uuid(before.call_id,'cursor');
            }
            value=await store.mcpCommand(principal.owner_id,principal.contact_id ?? null,'list',{...args,limit}); break;
          }
        }
        if (value?.call) value={...value,call:publicCall(value.call)};
        const showCallMarker=params.name==='tincall_get_call' || (value.call?.status!=='ended' &&
          (params.name==='tincall_call' || (params.name==='tincall_wait' && args.call===undefined)));
        result={content:await renderResult(principal,value,showCallMarker),isError:Boolean(value.error)};
      } catch(error) {
        const code = error instanceof ConnectorError ? error.code : 'request_failed';
        if (value?.reply_accepted) {
          // Rendering the next input's media must not undo an accepted reply.
          // Roll back the unread page cursor so every intervening supplement is recoverable.
          const accepted = {...value,messages:[],reply:null,cursor:acceptedCursor,wait_error:{code},next_action:{tool:'tincall_wait',arguments:{cursor:acceptedCursor}}};
          result={content:await mcpContent(principal,accepted),isError:false};
        } else {
          const failure={error:{code,...(error instanceof ConnectorError?error.details:{})}};
          result={content:await mcpContent(principal,failure),isError:true};
        }
      }
    } else return json({jsonrpc:'2.0',id:message.id,error:{code:-32601,message:'Method not found'}});
    return json({jsonrpc:'2.0',id:message.id,result});
  }

  async function sse(request,principal) {
    ensure(request.method==='GET','method_not_allowed',405);
    ensure(request.headers.get('accept')?.includes('text/event-stream'),'sse_accept_required',406);
    const previous=request.headers.get('last-event-id');
    const match=previous?.match(/^([^:]+):(\d+)$/);
    ensure(!previous || match,'invalid_cursor');
    const session=match ? uuid(match[1],'session_id') : crypto.randomUUID();
    let after=match ? integer(Number(match[2]),'cursor') : 0;
    await store.sseCommand(principal,match?'check':'open',{session_id:session});
    // Relative to the client's SSE URL: the Edge gateway may strip its public
    // /functions/v1 prefix before this request reaches us.
    const endpoint=`${new URL(request.url).pathname.endsWith('/')?'../':''}messages?session_id=${session}`;
    const closed=new AbortController();
    const signal=AbortSignal.any([request.signal,closed.signal]);
    const deadline=Date.now()+120000;
    let heartbeat=Date.now();
    const encoder=new TextEncoder();
    const body=new ReadableStream({
      start(controller){
        controller.enqueue(encoder.encode(`id: ${session}:${after}\nevent: endpoint\ndata: ${endpoint}\n\n`));
      },
      async pull(controller){
        try {
          while(!signal.aborted && Date.now()<deadline){
            const page=await store.sseCommand(principal,'read',{session_id:session,after},{signal});
            if(signal.aborted){if(!closed.signal.aborted)controller.close();return;}
            if(page.messages.length){
              for(const item of page.messages){
                controller.enqueue(encoder.encode(`id: ${session}:${item.sequence}\nevent: message\ndata: ${JSON.stringify(item.message)}\n\n`));
                after=item.sequence;
              }
              heartbeat=Date.now();return;
            }
            if(Date.now()-heartbeat>=10000){
              controller.enqueue(encoder.encode(': keep-alive\n\n'));heartbeat=Date.now();return;
            }
            await new Promise(resolve=>{
              const done=()=>{clearTimeout(timer);signal.removeEventListener('abort',done);resolve();};
              const timer=setTimeout(done,1000);
              signal.addEventListener('abort',done,{once:true});
              if(signal.aborted)done();
            });
          }
          if(!closed.signal.aborted)controller.close();
        } catch(error){if(!closed.signal.aborted)controller.error(error);}
      },
      cancel(){closed.abort();},
    });
    return new Response(body,{headers:{'Content-Type':'text/event-stream','Cache-Control':'no-store','X-Accel-Buffering':'no'}});
  }

  async function ssePost(request,principal,url) {
    ensure(request.method==='POST','method_not_allowed',405);
    const session=uuid(url.searchParams.get('session_id'),'session_id');
    await store.sseCommand(principal,'check',{session_id:session});
    if(request.headers.has('Tincall-Call-ID'))principal={...principal,mcp_call_id:uuid(request.headers.get('Tincall-Call-ID'),'call_id').toLowerCase()};
    const message=await readJSON(request);
    ensure(message.jsonrpc==='2.0' && typeof message.method==='string','invalid_rpc');
    // POST acknowledgement must not wait for a long-running tool. Its response
    // is queued durably for the GET, which may be running on another instance.
    schedule((async()=>{
      let response;
      try {
        const result=await mcpMessage(message,principal,['2024-11-05'],AbortSignal.timeout(140000));
        if(result.status===202)return;
        response=await result.json();
      } catch(error){
        if(message.id===undefined)return;
        response={jsonrpc:'2.0',id:message.id,error:{code:-32603,message:error instanceof ConnectorError?error.code:'internal_error'}};
      }
      await store.sseCommand(principal,'push',{session_id:session,message:response});
    })());
    return new Response(null,{status:202});
  }

  async function wakeEvents(request,principal,token) {
    ensure(request.method==='GET','method_not_allowed',405);
    ensure(principal.wake_bridge,'forbidden',403);
    ensure(request.headers.get('accept')?.includes('text/event-stream'),'sse_accept_required',406);
    ensure(store.subscribeWake,'wake_bridge_update_required',422);
    const lifetime=new AbortController();
    const signal=AbortSignal.any([request.signal,lifetime.signal]);
    const encode=new TextEncoder();
    let output,stop,heartbeat,expiry,closed=false,dirty=false,running=false,lastReply;
    const close=()=>{
      if(closed)return;closed=true;
      clearInterval(heartbeat);clearTimeout(expiry);stop?.();lifetime.abort();
      try{output?.close();}catch{}
    };
    const fail=code=>{
      if(output && !closed)output.enqueue(encode.encode(`event: error\ndata: ${JSON.stringify({error:{code}})}\n\n`));
      close();
    };
    const refresh=async()=>{
      dirty=true;if(running || !output || closed)return;running=true;
      try {
        while(dirty && !closed){
          dirty=false;
          // Recheck only on an event/reconnect, so reset credentials and mode
          // changes cannot continue to deliver wakes through an old stream.
          ensure(await store.wakeCommand('authenticate',null,{token}),'unauthorized',401);
          const value=await mcpSnapshot(principal,{},signal);
          if(closed)break;
          if(value.call?.source!=='mcp' || value.call.status!=='active' || value.dial_waiting || !value.reply || value.reply.reply_id===lastReply ||
            (value.reply.kind==='opening' && value.dialed && value.read_cursor?.epoch>=0))continue;
          if(output.desiredSize < -32){close();break;}
          lastReply=value.reply.reply_id;
          const event={version:1,event_id:lastReply,call_id:value.call.id,contact_id:principal.contact_id,
            reason:value.reply.kind==='opening'?'answered':'input',reply_to:value.reply.reply_to};
          output.enqueue(encode.encode(`id: ${lastReply}\nevent: wake\ndata: ${JSON.stringify(event)}\n\n`));
        }
      } catch(error){if(!closed)fail(error instanceof ConnectorError?error.code:'wake_subscription_unavailable');}
      finally{running=false;}
    };
    try {
      stop=await store.subscribeWake(principal.owner_id,call=>{
        if(call?.contact_id===principal.contact_id)void refresh();
      },()=>fail('wake_subscription_unavailable'),signal);
      ensure(!signal.aborted,'wait_cancelled');
      const body=new ReadableStream({
        start(controller){
          output=controller;
          output.enqueue(encode.encode('event: ready\ndata: {"version":1}\n\n'));
          // Subscribe first, then recover the current unanswered target. Every
          // reconnect replays pending work, never completed or historical turns.
          void refresh();
          heartbeat=setInterval(()=>{if(!closed)output.enqueue(encode.encode(': keepalive\n\n'));},15000);
          expiry=setTimeout(close,120000);
          signal.addEventListener('abort',close,{once:true});if(signal.aborted)close();
        },cancel:close,
      });
      return new Response(body,{headers:{'Content-Type':'text/event-stream','Cache-Control':'no-store','X-Accel-Buffering':'no'}});
    }catch(error){close();throw error;}
  }

  return {mcp, sse, ssePost, wakeEvents, waitForInput};
}
