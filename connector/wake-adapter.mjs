#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import {readFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {mcpMessageXML} from '../supabase/functions/_shared/tincall/message-images.mjs';

class StopError extends Error {}

// Keep credentials and conversation content out of diagnostics, including
// errors returned by fetch or by the external platform's command.
async function get(endpoint, accept, signal, fetcher) {
  const response = await fetcher(endpoint.url, {
    headers: {...endpoint.headers, Accept: accept}, signal, redirect: 'error',
  });
  if ([401, 403].includes(response.status)) {
    await response.body?.cancel();
    throw new StopError('Authorization rejected; copy valid bridge configuration again.');
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`HTTP ${response.status}`);
  }
  return response;
}

// SSE frames may cross chunks, use CRLF, and contain multiple data lines.
export async function* sseFrames(body) {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = '', event = '', data = [];
  try {
    while (true) {
      const {value, done} = await reader.read();
      if (done) return;
      buffer += value;
      let match;
      while ((match = /\r\n|\r(?!$)|\n/.exec(buffer))) {
        const line = buffer.slice(0, match.index);
        buffer = buffer.slice(match.index + match[0].length);
        if (!line) {
          if (data.length) yield {event: event || 'message', data: data.join('\n')};
          event = ''; data = [];
        } else if (!line.startsWith(':')) {
          const colon = line.indexOf(':');
          const field = colon < 0 ? line : line.slice(0, colon);
          const value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
          if (field === 'event') event = value;
          if (field === 'data') data.push(value);
        }
      }
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export async function readWakeInput(config, signal, fetcher = fetch) {
  // Restart pagination if an interruption replaced the input while reading.
  for (let attempt = 0; attempt < 3; attempt++) {
    const messages = new Map(), images = new Map();
    let cursor, target, callID, latest, voiceInstructions, changed = false;
    do {
      const url = new URL(config.input.url);
      if (cursor) {
        url.searchParams.set('sequence', cursor.sequence);
        url.searchParams.set('epoch', cursor.epoch);
      }
      const response = await get({...config.input, url}, 'application/json',
        AbortSignal.any([signal, AbortSignal.timeout(20000)]), fetcher);
      const page = await response.json();
      const value = page.structuredContent;
      if (!value || !Array.isArray(value.messages)) throw new Error('Invalid input response');
      if (['idle', 'ended'].includes(value.event) || (!value.reply && !value.has_more)) return null;
      if (!['answered', 'input'].includes(value.event)) throw new Error('Invalid input event');
      if (cursor && (cursor.epoch !== value.cursor?.epoch || callID !== value.call?.id
        || (target && value.reply && target !== value.reply.reply_to))) {
        changed = true; break;
      }
      target = value.reply?.reply_to ?? target;
      callID = value.call?.id;
      const media = (page.content ?? []).filter(block => block.type === 'image');
      let imageIndex = 0;
      for (const message of value.messages) {
        if (!message.id) throw new Error('Input message has no ID');
        messages.set(message.id, message);
        const count = message.images?.length ?? 0;
        images.set(message.id, media.slice(imageIndex, imageIndex + count));
        imageIndex += count;
      }
      if (imageIndex !== media.length) throw new Error('Input images do not match messages');
      voiceInstructions = value.voice_instructions ?? voiceInstructions;
      latest = value;
      if (value.has_more && (!value.cursor || (cursor && value.cursor.sequence <= cursor.sequence))) {
        throw new Error('Input cursor did not advance');
      }
      cursor = value.cursor;
    } while (latest.has_more);
    if (changed) continue;
    const content = [...messages.values()].filter(message => message.text || message.images?.length).flatMap(message => [
      {type:'text', text:mcpMessageXML(message, latest.call)}, ...(images.get(message.id) ?? []),
    ]);
    return {...latest, messages: [...messages.values()], content, voice_instructions: voiceInstructions};
  }
  throw new Error('Input changed during pagination');
}

export function runAICommand(command, config, input, signal) {
  signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(command[0], command.slice(1), {
      shell: false, stdio: ['pipe', 'ignore', 'ignore'],
      env: {...process.env,
        TINCALL_MCP_URL: config.mcp.url,
        TINCALL_MCP_TRANSPORT: config.mcp.transport,
        TINCALL_MCP_HEADERS: JSON.stringify({...config.mcp.headers,'Tincall-Call-ID':input.call.id}),
      },
    });
    let timer, spawnError;
    const cancel = () => {
      child.kill('SIGTERM');
      timer ??= setTimeout(() => child.kill('SIGKILL'), 3000);
    };
    signal.addEventListener('abort', cancel, {once: true});
    child.on('error', () => { spawnError = true; });
    child.stdin.on('error', () => {}); // Early command exit is reported by close.
    child.on('close', code => {
      signal.removeEventListener('abort', cancel); clearTimeout(timer);
      if (signal.aborted) reject(signal.reason);
      else if (spawnError || code !== 0) reject(new Error('AI command failed'));
      else resolve();
    });
    if (signal.aborted) cancel();
    child.stdin.end(JSON.stringify({
      ...(input.event==='answered'?{message:'通话已接通，可以通过 tincall_reply 工具打招呼了。'}:{}),
      ...(input.content.length?{content:input.content}:{}),
      ...(input.voice_instructions?{voice_instructions:input.voice_instructions}:{}),
    }) + '\n');
  });
}

export function validateConfiguration(config) {
  if (config.version !== 2 || !config.contact_id || config.wake?.transport !== 'sse' || config.input?.transport !== 'http'
    || !['sse', 'streamable-http'].includes(config.mcp?.transport)) {
    throw new Error('Use the version 2 bridge JSON copied from Tincall.');
  }
  for (const endpoint of [config.wake, config.input, config.mcp]) {
    const url = new URL(endpoint?.url);
    if (!(url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)))
      || url.username || url.password || !endpoint.headers?.Authorization) {
      throw new Error('Endpoints require HTTPS (or loopback HTTP) and Authorization.');
    }
  }
}

export async function runWakeAdapter({config, command, signal, inputOnly = false, fetcher = fetch,
  log = message => console.error(message)}) {
  validateConfiguration(config);
  const lifetime = new AbortController();
  const stopped = AbortSignal.any([signal, lifetime.signal]);
  let pending, active, worker, fatal;
  const fail = error => { fatal = error; lifetime.abort(); active?.controller.abort(); };
  const remember = new Set();
  const retire=reference=>{
    remember.add(reference);
    if(remember.size>256)remember.delete(remember.values().next().value);
  };
  const notify = event => {
    if (event.contact_id !== config.contact_id || !event.reply_to || !event.event_id
      || !['answered', 'input'].includes(event.reason) || (inputOnly && event.reason !== 'input')) return;
    if (remember.has(event.reply_to) || pending?.reply_to === event.reply_to || active?.reply_to === event.reply_to) return;
    pending = event;
    if(active?.call_id && event.call_id && active.call_id!==event.call_id)active.controller.abort();
    if (!worker) worker = work().catch(fail).finally(() => { worker = undefined; });
  };
  async function work() {
    while (pending && !stopped.aborted) {
      const event = pending; pending = undefined;
      const controller = new AbortController();
      const deadline=AbortSignal.timeout(180000);
      active = {reply_to: event.reply_to, call_id:event.call_id, controller};
      // Bound the entire task, including retries, rather than each command alone.
      const taskSignal = AbortSignal.any([stopped, controller.signal,deadline]);
      let retryMs = 1000, attempts=0, input = event.input;
      try {
        while (!taskSignal.aborted) {
          try {
            const latest=await readWakeInput(config, taskSignal, fetcher);
            if(input && (!latest || input.call.id!==latest.call.id || input.reply.reply_to!==latest.reply.reply_to)) {
              if(latest)pending={contact_id:config.contact_id,call_id:latest.call.id,event_id:latest.reply.reply_id,
                reply_to:latest.reply.reply_to,reason:latest.reply.kind==='opening'?'answered':'input',input:latest};
              break;
            }
            input??=latest;
            if (!input || (inputOnly && input.reply.kind === 'opening')) break;
            active.call_id=input.call.id;
            active.reply_to = input.reply.reply_to;
            if (remember.has(active.reply_to)) break;
            attempts++;
            log('Input ready; starting AI task.');
            // A stuck platform task cannot permanently block later work.
            await runAICommand(command, config, input, taskSignal);
            const after = await readWakeInput(config, taskSignal, fetcher);
            if (after?.reply.reply_to === input.reply.reply_to) throw new Error('AI exited without an accepted reply');
            retire(input.reply.reply_to);
            log('AI task finished.');
            // Keep later input queued while the current complete reply is submitted.
            if (after) pending={contact_id: config.contact_id, call_id:after.call.id,event_id: after.reply.reply_id,
              reply_to: after.reply.reply_to, reason: after.reply.kind === 'opening' ? 'answered' : 'input',input:after};
            break;
          } catch (error) {
            if (error instanceof StopError) throw error;
            if (taskSignal.aborted) break;
            if(attempts>=3) {
              retire(active.reply_to);
              log('AI task retry limit reached; waiting for a new input.');
              break;
            }
            log('AI/input attempt failed; retrying pending work. Check the AI command and its MCP setup.');
            await delay(retryMs, undefined, {signal: taskSignal});
            retryMs = Math.min(retryMs * 2, 30000);
          }
        }
      } catch (error) { if (!taskSignal.aborted) throw error; }
      finally {
        if(deadline.aborted && !stopped.aborted) {
          retire(active.reply_to);
          log('AI task time limit reached; waiting for a new input.');
        }
        active = undefined;
      }
    }
  }
  let reconnectMs = 1000;
  try {
    while (!stopped.aborted) {
      try {
        const response = await get(config.wake, 'text/event-stream',
          AbortSignal.any([stopped, AbortSignal.timeout(150000)]), fetcher);
        if (!response.headers.get('content-type')?.includes('text/event-stream')) {
          await response.body?.cancel(); throw new Error('Expected SSE');
        }
        log('Wake subscription connected.');
        for await (const frame of sseFrames(response.body)) {
          if (frame.event === 'ready') reconnectMs = 1000;
          if (frame.event === 'error') {
            const code = JSON.parse(frame.data).error?.code;
            if (['unauthorized', 'forbidden'].includes(code)) throw new StopError('Authorization rejected; copy valid bridge configuration again.');
            throw new Error('Wake subscription interrupted');
          }
          if (frame.event === (config.wake.event ?? 'wake')) notify(JSON.parse(frame.data));
        }
      } catch (error) {
        if (error instanceof StopError) throw error;
        if (stopped.aborted) break;
        log('Wake subscription disconnected; reconnecting.');
      }
      if (!stopped.aborted) await delay(reconnectMs, undefined, {signal: stopped});
      reconnectMs = Math.min(reconnectMs * 2, 30000);
    }
  } catch (error) { if (!stopped.aborted) fatal = error; }
  finally { lifetime.abort(); active?.controller.abort(); await worker; }
  if (fatal) throw fatal;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2), separator = args.indexOf('--');
  if (separator < 1 || separator === args.length - 1 || args.slice(1, separator).some(arg => arg !== '--input-only')) {
    console.error('Usage: node connector/wake-adapter.mjs PRIVATE_CONFIG.json [--input-only] -- AI_COMMAND [ARG...]');
    process.exitCode = 1;
  } else {
    const controller = new AbortController();
    const stop = () => controller.abort();
    process.once('SIGINT', stop); process.once('SIGTERM', stop);
    try {
      const config = JSON.parse(await readFile(args[0], 'utf8'));
      await runWakeAdapter({config, command: args.slice(separator + 1), signal: controller.signal, inputOnly: args.slice(1, separator).includes('--input-only')});
    } catch (error) {
      console.error(error instanceof StopError ? error.message : 'Adapter stopped. Check the private JSON and AI command configuration.');
      process.exitCode = 1;
    } finally { process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop); }
  }
}
