// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import {setTimeout as delay} from 'node:timers/promises';
import {sseFrames, readWakeInput, runWakeAdapter} from '../wake-adapter.mjs';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

test('SSE parser handles chunked CRLF, comments and multiline data', async () => {
  const chunks = [': ping\r', '\nevent: wake\r\ndata: {\r\n', 'data: "ok": true}\r\n\r', '\n'];
  const body = new ReadableStream({start(controller) {
    for (const chunk of chunks) controller.enqueue(new TextEncoder().encode(chunk));
    controller.close();
  }});
  const frames = [];
  for await (const frame of sseFrames(body)) frames.push(frame);
  assert.deepEqual(frames, [{event: 'wake', data: '{\n"ok": true}'}]);
});

test('pagination recovers a changed epoch, deduplicates messages and carries actual images', async () => {
  const config = {input: {url: 'https://fixture.invalid/wake/input', headers: {Authorization: 'Bearer fixture'}}};
  let reads = 0;
  const image = {type: 'image', data: 'synthetic-image-bytes', mimeType: 'image/png'};
  const fetcher = async url => {
    reads++;
    const query = new URL(url).searchParams;
    const epoch = reads === 1 ? 0 : 1;
    const more = [1, 3].includes(reads);
    if (reads === 2) assert.equal(query.get('epoch'), '0');
    if (reads === 3) assert.equal(query.get('epoch'), null, 'changed epoch restarts without the old cursor');
    if (reads === 4) assert.equal(query.get('sequence'), '1');
    return Response.json({structuredContent: {
      event: 'input', messages: [{id: epoch + '-one', role:'user', text: epoch ? 'current' : 'superseded', images:[{id:'first-image'}]},
        ...(reads === 4 ? [{id: '1-two', role:'user', text: '[2026-10-26 15:30:00]\nsupplement', images:[{id:'second-image'}]}] : [])],
      call: {epoch}, reply: {epoch, reply_to: epoch + '.target'},
      cursor: {epoch, sequence: more ? 1 : 2}, has_more: more,
      voice_instructions: 'Synthetic voice instruction',
    }, content: reads === 4 ? [image,image] : [image]});
  };
  const input = await readWakeInput(config, new AbortController().signal, fetcher);
  assert.equal(reads, 4);
  assert.deepEqual(input.messages.map(item => item.text), ['current', '[2026-10-26 15:30:00]\nsupplement']);
  assert.deepEqual(input.content, [
    {type:'text',text:'<message>\n  <text>current</text>\n</message>'}, image,
    {type:'text',text:'<message timestamp="2026-10-26 15:30:00">\n  <text>supplement</text>\n</message>'}, image,
  ]);
  assert.equal(input.reply.reply_to, '1.target');
});

test('a failed old task rechecks input and releases its slot for a new call', {timeout:6000}, async()=>{
  const abort=new AbortController(),reads=[],logs=[];
  const a=crypto.randomUUID(),b=crypto.randomUUID();let current=a,output,starts=0;
  const config={version:2,contact_id:'linked',wake:{transport:'sse',url:'https://fixture.invalid/wake/events',headers:{Authorization:'Bearer fixture'}},
    input:{transport:'http',url:'https://fixture.invalid/wake/input',headers:{Authorization:'Bearer fixture'}},
    mcp:{transport:'streamable-http',url:'https://fixture.invalid/mcp/wake',headers:{Authorization:'Bearer fixture'}}};
  const event=id=>`event: wake\ndata: ${JSON.stringify({contact_id:'linked',event_id:id,reply_to:id,call_id:id,reason:'input'})}\n\n`;
  const fetcher=async (url,init)=>{
    if(String(url).endsWith('/events'))return new Response(new ReadableStream({start(controller){
      output=controller;controller.enqueue(new TextEncoder().encode(event(a)));
      init.signal.addEventListener('abort',()=>controller.close(),{once:true});
    }}),{headers:{'Content-Type':'text/event-stream'}});
    reads.push(current);
    return Response.json({structuredContent:{event:'input',call:{id:current,epoch:1},reply:{kind:'input',reply_to:current,reply_id:current},
      messages:[{id:current,role:'user',text:'Synthetic input'}],cursor:{epoch:1,sequence:1},has_more:false},content:[]});
  };
  const timer=setTimeout(()=>abort.abort(),4500);
  try {
    await runWakeAdapter({config,command:[process.execPath,'-e','process.exit(1)'],signal:abort.signal,fetcher,log:line=>{
      logs.push(line);
      if(line==='Input ready; starting AI task.' && ++starts===2)abort.abort();
      if(line.includes('attempt failed') && current===a){current=b;output.enqueue(new TextEncoder().encode(event(b)));}
    }});
    assert.equal(starts,2);
    assert.ok(reads.includes(b),'the queued new call must be reread before launching another task');
  } finally {clearTimeout(timer);abort.abort();}
});

test('a persistently failing AI task stops after three attempts', {timeout:7000}, async()=>{
  const abort=new AbortController(),id=crypto.randomUUID();let starts=0,limited=false;
  const config={version:2,contact_id:'linked',wake:{transport:'sse',url:'https://fixture.invalid/events',headers:{Authorization:'Bearer fixture'}},
    input:{transport:'http',url:'https://fixture.invalid/input',headers:{Authorization:'Bearer fixture'}},
    mcp:{transport:'streamable-http',url:'https://fixture.invalid/mcp/wake',headers:{Authorization:'Bearer fixture'}}};
  const fetcher=async(url,init)=>{
    if(String(url).endsWith('/events'))return new Response(new ReadableStream({start(controller){
      controller.enqueue(new TextEncoder().encode(`event: wake\ndata: ${JSON.stringify({contact_id:'linked',event_id:id,reply_to:id,call_id:id,reason:'input'})}\n\n`));
      init.signal.addEventListener('abort',()=>controller.close(),{once:true});
    }}),{headers:{'Content-Type':'text/event-stream'}});
    return Response.json({structuredContent:{event:'input',call:{id,epoch:1},reply:{kind:'input',reply_to:id,reply_id:id},
      messages:[{id,role:'user',text:'Synthetic input'}],cursor:{epoch:1,sequence:1},has_more:false},content:[]});
  };
  const timer=setTimeout(()=>abort.abort(),6000);
  try {
    await runWakeAdapter({config,command:[process.execPath,'-e','process.exit(1)'],signal:abort.signal,fetcher,log:line=>{
      if(line==='Input ready; starting AI task.')starts++;
      if(line.includes('retry limit reached')){limited=true;abort.abort();}
    }});
    assert.equal(limited,true,'the retry loop must terminate without waiting for another event');
    assert.equal(starts,3);
  } finally {clearTimeout(timer);abort.abort();}
});

test('adapter starts commands after pagination, retries, coalesces reconnects, queues later input and stops on revoked credentials', {timeout: 15000}, async () => {
  const directory = await mkdtemp(join(tmpdir(), 'tincall-adapter-'));
  const owner = crypto.randomUUID(), abort = new AbortController();
  const store = createSQLiteStore({clients: [{token: 'phone', owner_id: owner}]}, join(directory, 'db.sqlite'));
  const connector = createConnector({store, config: {}, schedule: () => {}});
  const tasks = [], replies = [], logs = [];
  let base, running, wakeResponse, attempts = 0, cancelled = 0;
  const server = createServer(async (req, res) => {
    const controller = new AbortController();
    res.on('close', () => {if (!res.writableEnded) controller.abort();});
    try {
      if (req.url === '/wake/events') wakeResponse = res;
      if (req.url === '/fixture-cancel') {cancelled++; res.end(); return;}
      if (req.url === '/fixture-task') {
        let text = ''; for await (const chunk of req) text += chunk;
        tasks.push(JSON.parse(text)); attempts++;
        res.writeHead(attempts === 1 ? 503 : 200); res.end(); return;
      }
      const body = ['GET', 'HEAD'].includes(req.method) ? {} : {body: Readable.toWeb(req), duplex: 'half'};
      const request = new Request(base + req.url, {method: req.method, headers: req.headers, signal: controller.signal, ...body});
      const response = await connector.handle(request);
      if (req.url === '/mcp/wake' && req.method === 'POST') {
        const value = await response.clone().json();
        if (value.result?.isError===false && value.result.content?.some(item=>item.type==='text' && item.text==='已发送。')) replies.push(value);
      }
      if (res.destroyed) return;
      res.writeHead(response.status, Object.fromEntries(response.headers));
      if (response.body) Readable.fromWeb(response.body).on('error', () => res.destroy()).pipe(res);
      else res.end();
    } catch { if (!res.destroyed) {res.writeHead(500); res.end();} }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  const post = async (path, body) => {
    const response = await fetch(base + path, {method: 'POST', headers: {
      Authorization: 'Bearer phone', 'Content-Type': 'application/json',
    }, body: JSON.stringify(body)});
    assert.equal(response.status, 200); return response.json();
  };
  const until = async predicate => {
    for (let i = 0; i < 160; i++) {if (predicate()) return; await delay(25);}
    assert.fail('Expected adapter activity did not occur: ' + JSON.stringify({attempts, logs}));
  };
  try {
    await post('/mcp/roles/upsert', {role_id: crypto.randomUUID(), contact_id: 'linked', display_name: 'Fixture'});
    const config = await post('/wake/config', {contact_id: 'linked'});
    const callID = crypto.randomUUID();
    await post('/calls', {request_id: crypto.randomUUID(), call_id: callID, contact_id: 'linked', source: 'mcp'});
    for (let i = 0; i < 55; i++) await post(`/calls/${callID}/input`, {
      request_id: crypto.randomUUID(), message_id: crypto.randomUUID(), epoch: i, text: `Synthetic message ${i}`,
    });
    // A deterministic test-only platform command, not a model or live-call test.
    const command = join(directory, 'fixture-ai.mjs');
    await writeFile(command, `
      let text = ''; for await (const chunk of process.stdin) text += chunk;
      const input = JSON.parse(text);
      const url = new URL(process.env.TINCALL_MCP_URL);
      const observed = await fetch(new URL('/fixture-task', url), {method:'POST', body:text});
      if (!observed.ok) process.exit(1);
      if (input.content.at(-1).text.includes('<text>Hold task</text>')) {
        process.on('SIGTERM', () => {
          fetch(new URL('/fixture-cancel', url)).finally(() => process.exit(0));
        });
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
      const headers = {...JSON.parse(process.env.TINCALL_MCP_HEADERS), 'Content-Type':'application/json', Accept:'application/json, text/event-stream'};
      if (!headers['Tincall-Call-ID']) process.exit(3);
      const response = await fetch(url, {method:'POST', headers, body:JSON.stringify({jsonrpc:'2.0', id:1, method:'tools/call', params:{name:'tincall_reply', arguments:{text:'Synthetic fixture reply'}}})});
      const result = await response.json();
      if (result.result?.isError !== false) process.exit(2);
    `);
    running = runWakeAdapter({config, command: [process.execPath, command], signal: abort.signal, log: line => logs.push(line)});
    running.catch(() => {});
    await until(() => replies.length === 1);
    assert.equal(tasks.length, 2, 'failed command must be retried without another wake');
    assert.equal(tasks[1].content.length, 55, 'all pages precede task launch');
    assert.equal(tasks[1].content[54].text, '<message>\n  <text>Synthetic message 54</text>\n</message>');
    assert.equal(Object.hasOwn(tasks[1],'messages'),false,'AI input must not duplicate XML with plain message text');
    assert.ok(tasks[1].voice_instructions);
    assert.ok(!JSON.stringify(tasks[1]).includes('Bearer'), 'credential must not enter the AI input');
    assert.ok(!logs.join('\n').includes('Synthetic message'));
    await delay(80);
    assert.equal(tasks.length, 2, 'accepted replies must not start another task');
    await post(`/calls/${callID}/input`, {request_id: crypto.randomUUID(), message_id: crypto.randomUUID(), epoch: 55, text: 'Hold task'});
    await until(() => tasks.length === 3);
    wakeResponse.destroy();
    await until(() => logs.filter(line => line === 'Wake subscription connected.').length === 2);
    await delay(80);
    assert.equal(tasks.length, 3, 'replayed in-flight wake must not launch a duplicate task');
    await post(`/calls/${callID}/input`, {request_id: crypto.randomUUID(), message_id: crypto.randomUUID(), epoch: 56, text: 'Replacement input'});
    await until(() => replies.length === 3);
    assert.equal(cancelled, 0, 'new input must not cancel a complete-message task');
    assert.equal(tasks.length, 4);
    assert.equal(tasks[3].content.at(-1).text, '<message>\n  <text>Replacement input</text>\n</message>');
    assert.equal(tasks[2].voice_instructions, undefined);
    assert.doesNotMatch(JSON.stringify(tasks[2]), /reply_to|epoch|sequence|cursor|call_id/);
    await post('/wake/config', {contact_id: 'linked', rotate: true});
    await post(`/calls/${callID}/input`, {request_id: crypto.randomUUID(), message_id: crypto.randomUUID(), epoch: 57, text: 'After reset'});
    await assert.rejects(running, /Authorization rejected/);
  } finally {
    abort.abort(); await running?.catch(() => {});
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    store.close(); await rm(directory, {recursive: true, force: true});
  }
});
