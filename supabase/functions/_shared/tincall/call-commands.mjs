// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {ConnectorError, ensure, uuid, requiredText, integer, publicCall} from './protocol.mjs';

const EVENTS_POLL_MS = 250;

export function getBinding(config, owner, contact) {
  return (config.bindings ?? []).find(binding => binding.owner_id === owner && binding.contact_id === contact);
}
export function validateBinding(binding, source) {
  ensure(binding, 'generation_not_configured', 422);
  ensure(binding.mode === 'http' || binding.mode === 'tools', 'generation_not_configured', 422);
  ensure(source !== 'backend' || binding.mode === 'http', 'backend_binding_required', 422);
  if (binding.mode === 'http') {
    ensure(binding.generation_url && binding.cancel_url, 'generation_not_configured', 422);
    let url, cancelURL;
    try { url = new URL(binding.generation_url); cancelURL = new URL(binding.cancel_url); }
    catch { throw new ConnectorError('generation_url_invalid', 422); }
    ensure(url.protocol === 'https:' || (binding.allow_local_http === true && url.protocol === 'http:' && ['127.0.0.1','localhost','[::1]'].includes(url.hostname)), 'generation_url_requires_https', 422);
    ensure(cancelURL.origin === url.origin, 'cancel_origin_mismatch', 422);
  }
  return binding;
}

// Owns authorization and call/record transitions for both HTTP and MCP callers.
export function createCallCommands({store, config, schedule, runOwner, fetcher, images}) {
  const {linkedCallRecord, saveImages} = images;

  async function bindingFor(owner, contact) {
    const configured = getBinding(config, owner, contact);
    if (configured && configured.mode !== 'tools') return configured;
    const saved = (await store.mcpRoleCommand(owner, 'binding', {contact_id: contact})).binding;
    return configured ? {...configured,...(saved ? {mcp_wait_timeout_seconds:saved.mcp_wait_timeout_seconds} : {})} : saved;
  }

  async function upsertMCPRole(principal, payload) {
    ensure(!principal.contact_id, 'forbidden', 403);
    ensure(Object.keys(payload).every(key => ['role_id','contact_id','display_name','mcp_wait_timeout_seconds'].includes(key)), 'invalid_role');
    if (payload.mcp_wait_timeout_seconds !== undefined) {
      ensure(Number.isInteger(payload.mcp_wait_timeout_seconds) && payload.mcp_wait_timeout_seconds >= 1 && payload.mcp_wait_timeout_seconds <= 130, 'invalid_mcp_wait_timeout_seconds');
    }
    const roleId = uuid(payload.role_id, 'role_id').toLowerCase();
    const contact = requiredText(payload.contact_id, 'contact_id', 200);
    const displayName = requiredText(payload.display_name, 'display_name', 200).trim();
    // A tools enrollment must not replace an existing HTTP adapter binding.
    const configured = getBinding(config, principal.owner_id, contact);
    ensure(!configured || configured.mode === 'tools', 'role_identity_conflict', 409);
    const token = 'tcmcp_' + Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2, '0')).join('');
    const role = await store.mcpRoleCommand(principal.owner_id, 'upsert', {
      role_id: roleId, contact_id: contact, display_name: displayName, token,
      ...(payload.mcp_wait_timeout_seconds !== undefined ? {mcp_wait_timeout_seconds:payload.mcp_wait_timeout_seconds} : {}),
    });
    // The client appends this to its saved public service URL, not an internal proxy URL.
    return {...role, mcp_path: 'mcp'};
  }

  async function scopedCall(principal, callId, signal) {
    const data = await store.command(principal.owner_id, 'call.record', {call_id: uuid(callId, 'call_id')}, {signal});
    ensure(!principal.contact_id || data.call.contact_id === principal.contact_id, 'forbidden', 403);
    return data;
  }
  async function command(principal, action, payload, signal) {
    const p = {...payload};
    let source = p.source;
    let liveActivityPush;
    let callAccessExpiry;
    if (!['call.current','call.list','call.record','call.inputs','call.events','record.get','record.list','schedule.list'].includes(action)) uuid(p.request_id, 'request_id');
    if (action === 'call.create' || action === 'call.incoming') {
      uuid(p.call_id, 'call_id'); requiredText(p.contact_id, 'contact_id', 200);
      ensure(!principal.contact_id || p.contact_id === principal.contact_id, 'forbidden', 403);
      if (p.source === 'mcp') {
        const currentMode=(await store.contactMode?.(principal.owner_id,'get',{contact_id:p.contact_id}))?.call_mode;
        if (currentMode && currentMode !== 'mcp') throw new ConnectorError('contact_mode_mismatch',409,{
          current_mode:currentMode,
          message:currentMode==='standalone'?'该联系人当前为独立模式，不接受 MCP 来电。':'该联系人当前为后端模式，不接受 MCP 来电。',
          recovery:'Ask the owner to switch this contact to MCP mode and save it in Tincall. This is a contact mode mismatch, not a busy phone line.'});
      }
      await store.callPresence?.('expire',principal.owner_id);
      ensure(['backend','mcp','independent'].includes(p.source), 'invalid_source');
      // Standalone scheduled calls are generated by the phone after answering.
      if (p.source !== 'independent') validateBinding(await bindingFor(principal.owner_id,p.contact_id), p.source);
    } else if (action.startsWith('call.') || action.startsWith('reply.') || action === 'summary.put') {
      if (!['call.current','call.list'].includes(action)) {
        const data = await scopedCall(principal, p.call_id, signal);
        source = data.call.source;
        if (action === 'call.activity') {
          // Only the phone's owner credential can start a card, and only for
          // an accepted call. MCP credentials cannot target registered devices.
          ensure(!principal.contact_id, 'forbidden', 403);
          ensure(data.call.status === 'active', 'call_not_active', 409);
          uuid(p.device_id, 'device_id');
          if (p.avatar_contact_id != null) uuid(p.avatar_contact_id, 'avatar_contact_id');
          if (p.display_name != null) {
            requiredText(p.display_name, 'display_name', 200);
            ensure(!/[\u0000-\u001f\u007f]/.test(p.display_name), 'invalid_display_name');
          }
          ensure(config.pushURL && config.pushToken, 'push_not_configured', 422);
          ensure(new URL(config.pushURL).protocol === 'https:', 'push_url_requires_https', 422);
          let response;
          try {
            response = await fetcher(`${config.pushURL.replace(/\/$/, '')}/activities/start`, {
              method: 'POST', headers: {Authorization: `Bearer ${config.pushToken}`, 'Content-Type': 'application/json'},
              body: JSON.stringify({owner_id: principal.owner_id, device_id: p.device_id, call_id: data.call.id,
                ...(p.avatar_contact_id ? {avatar_contact_id: p.avatar_contact_id} : {}),
                ...(p.display_name ? {display_name: p.display_name} : {})}),
              signal: AbortSignal.timeout(10000), redirect: 'error'
            });
          } catch { throw new ConnectorError('activity_push_unavailable', 503); }
          ensure(response.ok, 'activity_push_failed', 502);
          ensure((await response.json()).accepted_by_apns === true, 'activity_push_failed', 502);
          return {accepted_by_apns: true};
        }
        if (action === 'call.input') {
          uuid(p.message_id,'message_id'); integer(p.epoch,'epoch');
          if (p.images !== undefined) ensure(Array.isArray(p.images) && p.images.length <= 4, 'invalid_images');
          if (p.images?.length) {
            if (p.text === undefined) p.text = '';
            ensure(typeof p.text === 'string' && p.text.length <= 20000, 'invalid_text');
          } else { requiredText(p.text,'text'); delete p.images; }
          p.mode = validateBinding(await bindingFor(principal.owner_id,data.call.contact_id), data.call.source).mode;
          if (p.images?.length) p.images = await saveImages(principal.owner_id, p.call_id, p.images);
        }
      }
      if (['call.interrupt','call.end','call.accept'].includes(action) || action.startsWith('reply.')) integer(p.epoch,'epoch');
      if (action.startsWith('reply.')) uuid(p.reply_id,'reply_id');
      if (action === 'summary.put') ensure(p.text === null || (typeof p.text === 'string' && p.text.length <= 100000), 'invalid_text');
      if (action === 'reply.delta') requiredText(p.delta,'delta');
      if (action === 'reply.completed' && p.text !== undefined) ensure(typeof p.text==='string' && p.text.length<=100000,'invalid_text');
      if (action === 'call.events') { integer(p.after ?? 0,'after'); integer(p.limit ?? 100,'limit'); }
    } else {
      // A role-scoped platform credential cannot enumerate or mutate personal backups/devices.
      ensure(!principal.contact_id,'forbidden',403);
    }
    if (action === 'schedule.enabled' || (action === 'schedule.put' && p.enabled !== undefined)) {
      uuid(p.schedule_id, 'schedule_id');
      ensure(typeof p.enabled === 'boolean', 'invalid_enabled');
    }
    if (action === 'schedule.put' && p.week_day != null) {
      ensure(Number.isInteger(p.week_day) && p.week_day >= 1 && p.week_day <= 7 && typeof p.daily_time === 'string', 'invalid_week_day');
    }
    if(action==='device.put' || action==='device.delete') {
      uuid(p.device_id,'device_id');
      const activityToken = p.live_activity_start_token;
      const callsValidUntil = p.calls_valid_until;
      delete p.calls_valid_until;
      delete p.live_activity_start_token;
      if(action==='device.put') {
        ensure(typeof p.device_token==='string' && /^[a-f0-9]{32,256}$/i.test(p.device_token),'invalid_device_token');
        ensure(['sandbox','production'].includes(p.environment),'invalid_environment');
        ensure(activityToken == null || (typeof activityToken === 'string' && /^[a-f0-9]{32,512}$/i.test(activityToken)), 'invalid_activity_token');
        ensure(!('binding_id' in p),'invalid_binding_id');
        ensure(callsValidUntil == null || (typeof callsValidUntil === 'string' && Number.isFinite(Date.parse(callsValidUntil))), 'invalid_call_expiry');
        const previous=await store.command(principal.owner_id,'device.lookup',p);
        if(previous.response)return previous.response;
      }
      ensure(config.pushURL && config.pushToken,'push_not_configured',422);
      ensure(new URL(config.pushURL).protocol==='https:','push_url_requires_https',422);
      let response;
      try{response=await fetcher(`${config.pushURL.replace(/\/$/,'')}${action==='device.put'?'/devices':'/devices/remove'}`,{method:'POST',
        headers:{Authorization:`Bearer ${config.pushToken}`,'Content-Type':'application/json'},
        body:JSON.stringify({owner_id:principal.owner_id,device_id:p.device_id,...(action==='device.put'?{device_token:p.device_token,environment:p.environment,live_activity_start_token:activityToken ?? null,calls_valid_until:callsValidUntil ?? null}:{})}),signal:AbortSignal.timeout(10000),redirect:'error'});}
      catch{throw new ConnectorError('push_registration_unavailable',503);}
      ensure(response.ok,'push_registration_failed',502);
      if(action==='device.put'){const registered=await response.json();p.binding_id=uuid(registered.binding_id,'binding_id');liveActivityPush=registered.live_activity_push === true;callAccessExpiry=registered.call_access_expiry === true;}
    }
    if (['call.create','call.accept'].includes(action) && p.user_name!==undefined) {
      ensure(!principal.contact_id,'forbidden',403);
      ensure(typeof p.user_name==='string' && p.user_name.length<=200,'invalid_user_name');
      if(action==='call.accept')await store.mcpCommand(principal.owner_id,null,'profile',{call_id:p.call_id,user_name:p.user_name});
    }
    let voicePrompt = typeof p.expression_prompt === 'string' ? p.expression_prompt : undefined;
    if (p.time_awareness_enabled !== undefined || (['call.create','call.accept'].includes(action) && p.time_zone !== undefined)) {
      // Only the phone may select call preferences. A role credential cannot
      // change them while initiating a remote call.
      ensure(!principal.contact_id, 'forbidden', 403);
      ensure(['call.create','call.accept'].includes(action), 'invalid_time_awareness');
      ensure(typeof p.time_awareness_enabled === 'boolean', 'invalid_time_awareness');
      if (p.time_awareness_enabled) {
        ensure(typeof p.time_zone === 'string' && p.time_zone.length > 0 && p.time_zone.length <= 100, 'invalid_time_zone');
        try { new Intl.DateTimeFormat('en', {timeZone:p.time_zone}); }
        catch { throw new ConnectorError('invalid_time_zone'); }
        if (source === 'mcp') {
          const timeInstruction = '时间感知：timestamp 是消息的发送时间，使用手机本地时区。可据此理解消息之间的时间间隔，不必每次提及时间。回复中无需附带时间戳。';
          voicePrompt = [voicePrompt, timeInstruction].filter(Boolean).join('\n');
        }
      } else {
        ensure(p.time_zone === undefined, 'invalid_time_zone');
      }
    }
    if (action === 'call.accept' && voicePrompt !== undefined && store.setVoicePrompt) {
      // Save before changing ringing to active, so the first active wait cannot race the prompt update.
      await store.setVoicePrompt(principal.owner_id, p.call_id, voicePrompt);
    }
    if (action === 'record.put') {
      const messages = p.record?.messages ?? p.record?.call?.messages;
      if (Array.isArray(messages) && messages.some(message => message?.images !== undefined)) {
        const copied = [];
        for (const message of messages) {
          const next = {...message};
          if (message.images !== undefined) ensure(Array.isArray(message.images) && message.images.length <= 4, 'invalid_images');
          if (message.images?.length) {
            uuid(message.id, 'message_id');
            next.images = await saveImages(principal.owner_id, p.record_id, message.images, true);
          }
          copied.push(next);
        }
        p.record = p.record.messages ? {...p.record, messages:copied} : {...p.record, call:{...p.record.call, messages:copied}};
      }
    }
    let preservedImages = [];
    if (action === 'record.delete' && p.preserve_call_media) {
      const linked = await linkedCallRecord(principal.owner_id, p.record_id, signal);
      if (linked) {
        ensure(linked.call.status === 'ended', 'call_busy', 409);
        preservedImages = linked.messages.flatMap(message => (message.images ?? []).map(image => image.id));
      }
    }
    let data = await store.command(principal.owner_id, action, p, {signal});
    if ((action === 'call.create' || action === 'call.incoming') && voicePrompt !== undefined && store.setVoicePrompt) {
      await store.setVoicePrompt(principal.owner_id, p.call_id, voicePrompt);
    }
    if(action==='call.create' && p.user_name!==undefined)await store.mcpCommand(principal.owner_id,null,'profile',{call_id:p.call_id,user_name:p.user_name});
    if (action === 'call.accept' || action === 'call.create') {
      if(action==='call.accept')await store.callPresence?.('touch',principal.owner_id,p.call_id);
      await ensureOpening(principal, data.call);
    }
    if(action==='record.delete' && store.deleteRecordMedia) await store.deleteRecordMedia(principal.owner_id,p.record_id,preservedImages);
    if (data?.call) data = {...data, call: publicCall(data.call)};
    if (data?.calls) data = {...data, calls: data.calls.map(publicCall)};
    if (action === 'call.current' && principal.contact_id && data.call?.contact_id !== principal.contact_id) data = {call:null};
    if (action === 'call.list' && principal.contact_id) data = {calls:data.calls.filter(call=>call.contact_id===principal.contact_id)};
    if (action === 'call.input' || action === 'call.incoming') schedule(runOwner(principal.owner_id));
    return action === 'device.put' ? {...data, live_activity_push: liveActivityPush === true, call_access_expiry: callAccessExpiry === true} : data;
  }

  async function waitForEvents(principal, payload, seconds, signal) {
    const deadline = Date.now() + seconds * 1000;
    ensure(!signal.aborted, 'wait_cancelled');
    let page = await command(principal, 'call.events', payload, signal);
    if(page.call.status==='active')await store.callPresence?.('touch',principal.owner_id,payload.call_id);
    while (!page.events.length && Date.now() < deadline) {
      ensure(!signal.aborted, 'wait_cancelled');
      await new Promise((resolve, reject) => {
        const cancel = () => { clearTimeout(timer); reject(new ConnectorError('wait_cancelled')); };
        const timer = setTimeout(() => { signal.removeEventListener('abort', cancel); resolve(); }, Math.min(EVENTS_POLL_MS, deadline - Date.now()));
        signal.addEventListener('abort', cancel, {once: true});
      });
      ensure(!signal.aborted, 'wait_cancelled');
      // Authorization and cursor validation ran above. Read the durable page so
      // worker/other-process events are visible without an in-memory subscription.
      page = await store.command(principal.owner_id, 'call.events', payload, {signal});
      page = {...page, call: publicCall(page.call)};
    }
    ensure(!signal.aborted, 'wait_cancelled');
    return page;
  }

  async function ensureOpening(principal, call) {
    if (call?.status === 'active' && call.source === 'mcp' && call.epoch === 0 &&
        (await bindingFor(principal.owner_id, call.contact_id))?.mode === 'tools') {
      await store.mcpCommand(principal.owner_id, principal.contact_id ?? null, 'open', {call_id:call.id});
    }
  }
  return {command, bindingFor, upsertMCPRole, ensureOpening, waitForEvents};
}
