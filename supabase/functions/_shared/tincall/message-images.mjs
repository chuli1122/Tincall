// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {ConnectorError, ensure, uuid, object, imageBytes, base64, MAX_IMAGE} from './protocol.mjs';
import {callReference} from './mcp.mjs';

export function createMessageImages(store) {
  async function linkedCallRecord(owner, id, signal) {
    try { return await store.command(owner, 'call.record', {call_id:id}, {signal}); }
    catch(error) { if (!(error instanceof ConnectorError && error.code === 'call_not_found')) throw error; }
  }
  // The enclosing call/backup UUID is also the existing private media namespace.
  async function saveImages(owner, recordId, images, allowReferences = false) {
    ensure(Array.isArray(images) && images.length <= 4, 'invalid_images');
    const prepared = images.map(image => {
      object(image); uuid(image.id, 'image_id');
      if (allowReferences && image.data_base64 === undefined) {
        ensure(['image/jpeg','image/png'].includes(image.mime_type), 'unsupported_image_type', 415);
        ensure(Number.isSafeInteger(image.bytes) && image.bytes > 0 && image.bytes <= MAX_IMAGE, 'invalid_image_data');
        return {image, bytes:null};
      }
      return {image, bytes: imageBytes(image)};
    });
    ensure(new Set(prepared.map(({image}) => image.id.toLowerCase())).size === images.length, 'duplicate_image_id');
    const current = await store.command(owner, 'record.get', {record_id: recordId});
    ensure(!current.record?.deleted, 'record_deleted', 410);
    const saved = [];
    for (const {image, bytes} of prepared) {
      const id = image.id.toLowerCase();
      if (!bytes) {
        imageBytes(await loadImage(owner, recordId, image));
        saved.push({id, mime_type:image.mime_type, bytes:image.bytes});
        continue;
      }
      try {
        await store.media(owner, recordId, id, new Request('http://localhost/media', {method:'PUT', headers:{'Content-Type':image.mime_type}, body:bytes, signal:AbortSignal.timeout(15000)}));
      } catch (error) {
        if (!(error instanceof ConnectorError && error.code === 'media_exists')) throw error;
        // Immutable objects: a lost-response retry must contain the same bytes.
        let existing;
        try { existing = await loadImage(owner, recordId, {id, mime_type:image.mime_type, bytes:bytes.length}); }
        catch (failure) {
          if (failure instanceof ConnectorError && ['image_type_mismatch','image_size_mismatch'].includes(failure.code)) throw new ConnectorError('image_conflict', 409);
          throw failure;
        }
        ensure(existing.data_base64 === image.data_base64, 'image_conflict', 409);
      }
      saved.push({id, mime_type:image.mime_type, bytes:bytes.length});
    }
    const latest = await store.command(owner, 'record.get', {record_id: recordId});
    if (latest.record?.deleted) {
      const linked = await linkedCallRecord(owner, recordId);
      await store.deleteRecordMedia(owner, recordId, linked?.messages.flatMap(message => (message.images ?? []).map(image => image.id)) ?? []);
      throw new ConnectorError('record_deleted', 410);
    }
    return saved;
  }
  async function loadImage(owner, recordId, image) {
    const response = await store.media(owner, recordId, image.id, new Request('http://localhost/media', {signal:AbortSignal.timeout(15000)}));
    ensure(response.ok && response.headers.get('content-type') === image.mime_type, 'image_type_mismatch', 502);
    const reader = response.body.getReader(); const chunks = []; let size = 0;
    try {
      while (true) {
        const {done, value} = await reader.read(); if (done) break;
        size += value.length; ensure(size <= MAX_IMAGE, 'image_too_large', 413); chunks.push(value);
      }
    } finally { await reader.cancel(); reader.releaseLock(); }
    ensure(size === image.bytes, 'image_size_mismatch', 502);
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return {mime_type:image.mime_type, data_base64:base64(bytes)};
  }
  async function backendMessages(owner, callId, messages) {
    const result = [];
    for (const message of messages) {
      const output = {id:message.id,role:message.role,text:message.text,status:message.status,interruption_reason:message.interruption_reason};
      if (message.images?.length) {
        output.images = [];
        for (const image of message.images) output.images.push(await loadImage(owner, callId, image));
      }
      result.push(output);
    }
    return result;
  }
  async function mcpContent(principal, value) {
    const content = [];
    for (const part of mcpParts(value)) {
      const text = typeof part === 'string' ? part : mcpMessageXML(part, value.call);
      if (content.at(-1)?.type === 'text') content.at(-1).text += '\n\n' + text;
      else content.push({type:'text', text});
      if (typeof part !== 'string') {
        for (const reference of part.images ?? []) {
          const image = await loadImage(principal.owner_id, value.call.id, reference);
          content.push({type:'image', data:image.data_base64, mimeType:image.mime_type});
        }
      }
    }
    return content;
  }
  return {linkedCallRecord, saveImages, backendMessages, mcpContent};
}

function xmlEscape(value) {
  return value.replace(/[&<>]/g, character => ({'&':'&amp;', '<':'&lt;', '>':'&gt;'}[character]));
}

export function mcpMessageXML(message, call) {
  const name = message.role === 'user' ? call?.user_name?.trim() : 'TA';
  let text = message.text ?? '';
  // The phone persists this local-time prefix for retries. Move only that
  // envelope into an attribute when presenting the message to the model.
  const stamp = message.role === 'user' ? /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\n/.exec(text) : null;
  if (stamp) text = text.slice(stamp[0].length);
  const attributes = [];
  if (name) attributes.push(['name', name]);
  if (stamp) attributes.push(['timestamp', stamp[1]]);
  if (['generating','interrupted','failed'].includes(message.status)) {
    attributes.push(['status', message.status]);
    if (message.interruption_reason) attributes.push(['reason', message.interruption_reason]);
  }
  const suffix = attributes.map(([key, value]) => ` ${key}="${xmlEscape(value).replace(/"/g, '&quot;').replace(/\n/g, '&#10;').replace(/\r/g, '&#13;').replace(/\t/g, '&#9;')}"`).join('');
  return `<message${suffix}>\n  <text>${xmlEscape(text)}</text>\n</message>`;
}

// Keep each message adjacent to its native image blocks on both MCP transports.
function mcpParts(value) {
  const parts = [];
  if (value.error) {
    parts.push(value.error.message || `请求未完成：${value.error.code}`);
    if (value.error.recovery) parts.push(value.error.recovery);
  } else if (value.playback_pending) parts.push('已通知手机，待当前回复播放完成后挂断。');
  else if (value.event === 'timeout') parts.push(value.call?.status === 'ringing' ? '尚未接听。请调用 tincall_wait 继续等待。' : '尚未回复，通话仍在继续。请调用 tincall_wait 继续等待。');
  else if (value.event === 'answered') parts.push('通话已接通，可以通过 tincall_reply 工具打招呼了。');
  else if (value.event === 'sent') parts.push('已发送。');
  else if (value.event === 'input') { /* Message text is the result. */ }
  else if (value.event === 'ended' || value.call?.status === 'ended') parts.push('通话已结束。');
  else if (value.call === null) parts.push('当前没有进行中的通话。');
  else if (value.call?.status === 'ringing') parts.push('正在呼叫，等待对方接听。');
  else if (value.call?.status === 'active' && !value.reply_accepted && !value.messages?.some(message=>message.text || message.images?.length)) parts.push('通话进行中。');
  for (const message of value.input ? [value.input] : value.messages ?? []) {
    if (!message.text && !message.images?.length && message.status !== 'failed') continue;
    parts.push(message);
  }
  if (value.call?.status === 'ended' && value.call.summary) parts.push(`通话摘要：\n${value.call.summary}`);
  if (value.voice_instructions) parts.push(`本次通话的朗读要求：\n${value.voice_instructions}`);
  if (value.calls) parts.push(value.calls.length ? value.calls.map(call =>
    `${call.started_at} · ${{active:'进行中',ringing:'呼叫中',ended:'已结束'}[call.status] ?? call.status}${call.has_summary ? ' · 有摘要' : ''}\ncall_id: ${callReference(call.call_id)}`).join('\n\n') : '暂无通话记录。');
  if (value.wait_error) parts.push(`回复已保存，等待下一条消息失败（${value.wait_error.code}）。请调用 tincall_wait 继续等待，无需重发回复。`);
  if (value.has_more) {
    if (value.next_before_sequence != null) parts.push(`还有更早的消息：tincall_get_call ${JSON.stringify({call_id:callReference(value.call.id),before_sequence:value.next_before_sequence})}`);
    else if (value.next_cursor) parts.push(`还有通话记录：tincall_list_calls ${JSON.stringify({before:{...value.next_cursor,call_id:callReference(value.next_cursor.call_id)}})}`);

  }
  if (value.next_action?.tool && value.event !== 'timeout') parts.push('请调用 tincall_wait 继续等待。');
  else if (value.next_action === 'finish_task') parts.push(value.message);
  if (!parts.length && !value.reply_accepted && value.message) parts.push(value.message);
  return parts;
}
