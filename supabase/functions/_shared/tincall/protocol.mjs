// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class ConnectorError extends Error {
  constructor(code, status = 400, details = {}) { super(code); this.code = code; this.status = status; this.details = details; }
}
export function ensure(value, code, status = 400) { if (!value) throw new ConnectorError(code, status); }
export function uuid(value, field) { ensure(typeof value === 'string' && UUID.test(value), `invalid_${field}`); return value; }
export function json(data, status = 200) { return new Response(JSON.stringify(data), {status, headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store'}}); }
export function incomingCallMetadata(call) {
  if(!call)return null;
  const {id,contact_id,source,status,epoch,last_sequence}=call;
  return {id,contact_id,source,status,epoch,last_sequence};
}

export const MAX_IMAGE = 5 * 1024 * 1024;
export function object(value) { ensure(value && typeof value === 'object' && !Array.isArray(value), 'invalid_object'); return value; }
export function imageBytes(image) {
  ensure(['image/jpeg','image/png'].includes(image.mime_type), 'unsupported_image_type', 415);
  const data = image.data_base64;
  ensure(typeof data === 'string' && data.length > 0, 'invalid_image_data');
  ensure(data.length <= 4 * Math.ceil(MAX_IMAGE / 3), 'image_too_large', 413);
  ensure(data.length % 4 === 0 && /^[A-Za-z0-9+/]*={0,2}$/.test(data), 'invalid_image_data');
  const binary = atob(data);
  ensure(btoa(binary) === data, 'invalid_image_data');
  ensure(binary.length <= MAX_IMAGE, 'image_too_large', 413);
  const bytes = Uint8Array.from(binary, char => char.charCodeAt(0));
  const jpeg = bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 && bytes.at(-2) === 255 && bytes.at(-1) === 217;
  const png = [137,80,78,71,13,10,26,10].every((value, index) => bytes[index] === value);
  ensure(image.mime_type === 'image/jpeg' ? jpeg : png, 'image_type_mismatch', 415);
  return bytes;
}
export function base64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
  return btoa(binary);
}

export const MAX_BODY = 8 * 1024 * 1024;

export function requiredText(value, field, max = 20000) {
  ensure(typeof value === 'string' && value.trim().length > 0 && value.length <= max, `invalid_${field}`);
  return value;
}
export function integer(value, field) { ensure(Number.isSafeInteger(value) && value >= 0, `invalid_${field}`); return value; }
export async function readJSON(request, maxBody = MAX_BODY) {
  ensure(request.headers.get('content-type')?.split(';')[0].trim() === 'application/json', 'json_required', 415);
  const reader = request.body?.getReader();
  ensure(reader, 'body_required');
  let size = 0; const chunks = [];
  try {
    while (true) { const {done, value} = await reader.read(); if (done) break; size += value.length; ensure(size <= maxBody, 'body_too_large', 413); chunks.push(value); }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try {
    const value = object(JSON.parse(new TextDecoder().decode(bytes)));
    if (size > MAX_BODY) {
      const messages = value.record?.messages ?? value.record?.call?.messages ?? [];
      ensure(value.images?.length || (Array.isArray(messages) && messages.some(message => message.images?.some(image => image.data_base64))), 'body_too_large', 413);
    }
    return value;
  } catch (error) {
    if (error instanceof ConnectorError) throw error;
    throw new ConnectorError('invalid_json');
  }
}

export function publicCall(call) {
  if (!call) return call;
  const {tts_expression_prompt, voice_instructions_sent, phone_seen_at, mcp_read_sequence, mcp_read_epoch, mcp_dial_until, ...visible} = call;
  return visible;
}

const recordMessages = document => {
  const messages = document?.call?.messages ?? document?.messages;
  return Array.isArray(messages) ? messages : [];
};
const byteCount = value => typeof value === 'number' && Number.isFinite(value) ? value : 0;

/// Same facts as the tincall_record_summaries SQL function, for stores without it.
export function summarizeRecord(id, document) {
  const media = Array.isArray(document?.media) ? document.media : [];
  const images = recordMessages(document).flatMap(message => Array.isArray(message?.images) ? message.images : []);
  return {
    id,
    role_name: typeof document?.call?.roleName === 'string' ? document.call.roleName : null,
    started_at: typeof document?.call?.startedAt === 'number' ? document.call.startedAt : null,
    audio_count: media.length, audio_bytes: media.reduce((sum, item) => sum + byteCount(item?.bytes), 0),
    image_count: images.length, image_bytes: images.reduce((sum, item) => sum + byteCount(item?.bytes), 0),
  };
}

/// A backup document without its recordings and/or images; text and summary are unchanged.
export function withoutRecordMedia(document, {audio, images}) {
  const next = structuredClone(document);
  if (audio) next.media = [];
  if (images) {
    const strip = messages => Array.isArray(messages) ? messages.map(({images: _images, ...message}) => message) : messages;
    if (next.call?.messages) next.call.messages = strip(next.call.messages);
    if (next.messages) next.messages = strip(next.messages);
  }
  return next;
}

/// Object ids a backup document still references (recordings and images).
export function recordMediaIDs(document) {
  const media = Array.isArray(document?.media) ? document.media : [];
  return [
    ...media.map(item => item?.object_id),
    ...recordMessages(document).flatMap(message => Array.isArray(message?.images) ? message.images.map(image => image?.id) : []),
  ].filter(value => typeof value === 'string');
}
