// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {ConnectorError, ensure, requiredText, readJSON, MAX_BODY} from './protocol.mjs';
import {getBinding, validateBinding} from './call-commands.mjs';

// Bounded background jobs own generation cancellation and push delivery.
export function createCallJobs({store, config, fetcher, backendMessages}) {
  async function runOwner(owner) {
    // One bounded task per generation; no function stays open for an entire call.
    const [claimed, push] = await Promise.all([store.command(owner,'job.claim',{}),store.command(owner,'push.claim',{})]);
    await Promise.all([claimed.job ? generate(owner,claimed) : null, push.push ? deliverPush(owner,push.push) : null]);
  }
  async function runWorker() {
    await store.callPresence?.('expire');
    await store.mcpCommand(null, null, 'expire');
    const owners = await store.workerOwners();
    // Keep CPU/memory and external request fanout bounded.
    for (let i=0;i<owners.length;i+=3) await Promise.all(owners.slice(i,i+3).map(owner=>runOwner(owner)));
    return {processed_owners:owners.length};
  }

  async function generate(owner, claimed) {
    const {job,call,messages} = claimed;
    const controller = new AbortController();
    let expired = false; let cancelled = false; let completed = false;
    let started=false;let cancellationTask;
    let checking = false;let healthFailures=0;let healthLost=false;
    const binding = getBinding(config, owner, call.contact_id);
    const deliver = (action,payload) => store.command(owner,action,{request_id:crypto.randomUUID(),call_id:call.id,reply_id:job.reply_id,epoch:job.epoch,...payload});
    async function cancelUpstream() {
      let code='cancel_not_configured';
      for (let attempt=0; attempt<3; attempt++) {
        if (attempt) await new Promise(resolve=>setTimeout(resolve,attempt*250));
        try {
          ensure(binding?.cancel_url,'cancel_not_configured',422);
          const response=await fetcher(binding.cancel_url,{method:'POST',headers:{'Content-Type':'application/json',...(binding.token ? {Authorization:`Bearer ${binding.token}`} : {})},
            body:JSON.stringify({job_id:job.id,call_id:call.id,epoch:job.epoch}),signal:AbortSignal.timeout(5000),redirect:'error'});
          code=response.ok?'cancel_accepted':'cancel_delivery_failed';
          await response.body?.cancel();
          if (response.ok || (response.status<500 && ![408,429].includes(response.status))) break;
        } catch {code='cancel_delivery_failed';}
      }
      await store.command(owner,'job.cancel_result',{call_id:call.id,epoch:job.epoch,code});
    }
    const timeout = setTimeout(()=>{expired=true;controller.abort();},90000);
    const interval = setInterval(async()=>{
      if (checking) return; checking=true;
      try {
        const current = await store.command(owner,'call.record',{call_id:call.id});
        if(completed || controller.signal.aborted)return;
        healthFailures=0;
        if (current.call.status!=='active' || current.call.epoch!==job.epoch) {
          cancelled=true;clearInterval(interval);cancellationTask=cancelUpstream();controller.abort();await cancellationTask;
        }
      } catch {
        // A failed read does not prove cancellation. Bound loss of monitoring
        // without abandoning a live upstream or silently retrying generation.
        if(!completed && !controller.signal.aborted && ++healthFailures>=3){healthLost=true;clearInterval(interval);controller.abort();}
      } finally { checking=false; }
    },1000);
    try {
      validateBinding(binding);
      started=true;
      const response = await fetcher(binding.generation_url,{
        method:'POST',headers:{'Content-Type':'application/json','Accept':'application/x-ndjson, application/json','Idempotency-Key':job.id,
          ...(binding.token ? {Authorization:`Bearer ${binding.token}`} : {})},
        body:JSON.stringify({version:1,job_id:job.id,call_id:call.id,contact_id:call.contact_id,epoch:job.epoch,input_id:job.input_id,reply_id:job.reply_id,
          expression_prompt:call.tts_expression_prompt ?? '',
          messages:await backendMessages(owner, call.id, messages)}),
        signal:controller.signal,redirect:'error',
      });
      ensure(response.ok,'generation_http_error',502);
      if (response.headers.get('content-type')?.includes('application/x-ndjson')) {
        const reader=response.body.getReader(); const decoder=new TextDecoder(); let buffer=''; let total=0;
        async function line(value) {
          if (!value.trim()) return;
          ensure(!completed,'generation_after_completion',502);
          let event;try {event=JSON.parse(value);} catch {throw new ConnectorError('generation_invalid_json',502);}
          if (event.type==='delta') {requiredText(event.delta,'delta');total+=event.delta.length;ensure(total<=100000,'generation_too_large',502);await deliver('reply.delta',{delta:event.delta});}
          else if (event.type==='completed') {ensure(event.text===undefined || (typeof event.text==='string' && event.text.length<=100000),'generation_too_large',502);await deliver('reply.completed',event.text===undefined ? {} : {text:event.text});completed=true;}
          else if (event.type==='failed') throw new ConnectorError('generation_failed',502);
          else throw new ConnectorError('generation_invalid_event',502);
        }
        try {
          while (true) {const {done,value}=await reader.read();if(done)break;buffer+=decoder.decode(value,{stream:true});ensure(buffer.length<=MAX_BODY,'generation_too_large',502);let end;while((end=buffer.indexOf('\n'))>=0){const value=buffer.slice(0,end);buffer=buffer.slice(end+1);await line(value);}}
          buffer+=decoder.decode();await line(buffer);ensure(completed,'generation_incomplete',502);
        } finally { await reader.cancel().catch(()=>{});reader.releaseLock(); }
      } else {
        ensure(response.headers.get('content-type')?.includes('application/json'),'generation_content_type',502);
        const data=await readJSON(response);ensure(typeof data.text==='string' && data.text.length<=100000,'generation_invalid_text',502);
        await deliver('reply.completed',{text:data.text});completed=true;
      }
    } catch (error) {
      if(started && !cancelled && !completed) await cancelUpstream();
      if (!cancelled && !completed) {
        const code=expired ? 'generation_timeout' : healthLost ? 'health_check_lost' : error instanceof ConnectorError ? error.code : 'generation_unavailable';
        try { await deliver('reply.failed',{code}); } catch (failure) { if (!(failure instanceof ConnectorError && failure.code==='stale_epoch')) throw failure; }
      }
    } finally {clearTimeout(timeout);clearInterval(interval);controller.abort();if(cancellationTask)await cancellationTask;}
  }

  async function deliverPush(owner,push) {
    let code=null;let delivered=0;
    try {
      ensure(config.pushURL && config.pushToken,'push_not_configured',422);
      ensure(new URL(config.pushURL).protocol==='https:','push_url_requires_https',422);
      ensure(push.devices.length>0,'device_not_registered',422);
      for(const device of push.devices) {
        try {
          // Only routing metadata crosses this endpoint. Contact, text and summary stay private.
          const response=await fetcher(`${config.pushURL.replace(/\/$/,'')}/push`,{method:'POST',headers:{Authorization:`Bearer ${config.pushToken}`,'Content-Type':'application/json','Idempotency-Key':`${push.id}/${device.device_id}`},
            body:JSON.stringify({owner_id:owner,binding_id:device.binding_id,call_id:push.call_id,contact_id:push.contact_id,source:push.source,event:'incoming_call'}),signal:AbortSignal.timeout(10000),redirect:'error'});
          if(response.ok){delivered++;await response.body?.cancel();continue;}
          const failure=await readJSON(response);
          if((response.status===404 && failure.error?.code==='device_not_registered') || failure.error?.code==='apns_device_expired') {
            // Match the claimed binding so an in-flight re-registration is never removed.
            await store.removePushDevice(owner,device);
          }
          code='push_delivery_failed';
        } catch(error) {code=error instanceof ConnectorError ? error.code : 'push_unavailable';}
      }
    } catch(error) {code=error instanceof ConnectorError ? error.code : 'push_unavailable';}
    await store.command(owner,'push.finish',{push_id:push.id,...(!delivered && code ? {error_code:code} : {})});
  }

  return {runOwner, runWorker};
}
