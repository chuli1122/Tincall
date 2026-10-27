// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { generateKeyPairSync } from 'node:crypto';
import { createPushGateway, PushError } from '../apns-sender.mjs';
import { createSQLiteStore } from '../sqlite-store.mjs';
import { createConnector } from '../../supabase/functions/_shared/tincall/service.mjs';
import { PushRegistry } from '../../cloudflare/push-worker.mjs';
import { sendAPNs, PushError as WorkerPushError } from '../../cloudflare/apns.mjs';
import { activityStartPayload } from '../live-activity-push.mjs';

const credential = 'synthetic-push-credential-long-enough';
const owner = crypto.randomUUID(), stranger = crypto.randomUUID();
const key = generateKeyPairSync('ec', {namedCurve: 'P-256'}).privateKey.export({type: 'pkcs8', format: 'pem'});
const env = {APNS_TEAM_ID: 'SYNTHETIC', APNS_TOPIC: 'com.example.test.voip', APNS_SANDBOX_KEY_ID: 'TEST', APNS_SANDBOX_KEY_P8: key};
const request = (path, value, token = credential) => new Request(`https://synthetic.invalid${path}`, {
  method: 'POST', headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'}, body: JSON.stringify(value)
});

test('connected activity rejects invalid gateway receipts as an upstream failure',async t=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-activity-receipt-'));
  const store=createSQLiteStore({clients:[{token:credential,owner_id:owner}]},join(directory,'calls.sqlite'));
  t.after(()=>{store.close();rmSync(directory,{recursive:true,force:true});});
  const callID=crypto.randomUUID();
  await store.command(owner,'call.create',{request_id:crypto.randomUUID(),call_id:callID,contact_id:'synthetic',source:'independent'});
  for(const body of ['not JSON','null','{}']){
    const connector=createConnector({store,config:{pushURL:'https://example.invalid',pushToken:credential},fetcher:async()=>new Response(body)});
    const response=await connector.handle(request(`/calls/${callID}/activity`,{request_id:crypto.randomUUID(),device_id:crypto.randomUUID()}));
    assert.equal(response.status,502);assert.equal((await response.json()).error.code,'activity_push_failed');
  }
});

test('connected activity APNs carries a display name and a localized alert without sound', async () => {
  const callID = crypto.randomUUID();
  const contactID = crypto.randomUUID();
  const payload = activityStartPayload(callID, 1800000000, contactID, 'Synthetic caller');
  assert.equal(payload.aps['content-state'].startedAt + 978307200, 1800000000);
  assert.equal(payload.aps.attributes.callID, callID);
  assert.equal(payload.aps['attributes-type'], 'TincallCallAttributes');
  assert.equal(payload.aps['input-push-token'], 1);
  assert.equal(payload.aps['stale-date'], 1800000030);
  assert.equal(payload.aps.attributes.name, 'Synthetic caller');
  // ActivityKit alert localization belongs inside title/body, unlike the
  // top-level loc-key used by ordinary APNs notification alerts.
  assert.deepEqual(payload.aps.alert.title, {'loc-key': '%@', 'loc-args': ['Synthetic caller']});
  assert.deepEqual(payload.aps.alert.body, {'loc-key': '通话中'});
  assert.equal(payload.aps.alert['loc-key'], undefined);
  assert.equal(payload.aps.sound, undefined);
  assert.equal(payload.aps.alert.sound, undefined);
  await sendAPNs(env, {environment: 'sandbox', device_token: 'b'.repeat(64)}, {event: 'activity_start', call_id: callID, avatar_contact_id: contactID, display_name: 'Synthetic caller'}, async (url, init) => {
    assert.equal(new URL(url).pathname, `/3/device/${'b'.repeat(64)}`);
    assert.equal(init.headers['apns-topic'], 'com.example.test.push-type.liveactivity');
    assert.equal(init.headers['apns-push-type'], 'liveactivity');
    assert.equal(init.headers['apns-expiration'], '0');
    const body = JSON.parse(init.body);
    assert.deepEqual(Object.keys(body.aps.attributes).sort(), ['avatarContactID', 'callID', 'isPreview', 'name']);
    assert.equal(body.aps.attributes.name, 'Synthetic caller');
    assert.deepEqual(body.aps.alert, payload.aps.alert);
    return new Response(null, {status: 200});
  });
});

for (const kind of ['node', 'cloudflare']) test(`${kind} activity routing deduplicates, rotates tokens and leaves VoIP valid after an activity token expires`, async t => {
  const directory = mkdtempSync(join(tmpdir(), 'tincall-activity-'));
  let sends = [], fail = false, release;
  const send = async (device, payload) => {
    sends.push({device, payload});
    if (release) await release;
    if (fail) throw new (kind === 'node' ? PushError : WorkerPushError)('apns_device_expired', 502);
  };
  let gateway, close;
  if (kind === 'node') {
    gateway = createPushGateway({databasePath: join(directory, 'push.sqlite'), token: credential, send});
    close = gateway.close;
  } else {
    const db = new DatabaseSync(':memory:');
    gateway = new PushRegistry({storage: {sql: {exec(query, ...args) {
      const statement = db.prepare(query);
      if (statement.columns().length) return {toArray: () => statement.all(...args)};
      statement.run(...args); return {toArray: () => []};
    }}, getAlarm: async () => null, setAlarm: async () => {}}}, env);
    gateway.handle = gateway.fetch.bind(gateway);
    gateway.activities.send = send;
    t.mock.method(globalThis, 'fetch', async () => new Response(null, {status: 200}));
    close = () => db.close();
  }
  const post = async (path, value) => {
    const response = await gateway.handle(request(path, {owner_id: owner, ...value}));
    return {status: response.status, body: await response.json()};
  };
  try {
    const deviceID = crypto.randomUUID();
    const registration = {device_id: deviceID, device_token: 'a'.repeat(64), environment: 'sandbox', live_activity_start_token: 'b'.repeat(64)};
    assert.equal((await post('/devices', {...registration, live_activity_start_token: 'invalid'})).status, 400);
    const binding = (await post('/devices', registration)).body;
    assert.equal(binding.live_activity_push, true);
    const activity = {device_id: deviceID, call_id: crypto.randomUUID(), avatar_contact_id: crypto.randomUUID(), display_name: 'Synthetic caller'};
    assert.equal((await post('/activities/start', {...activity, device_id: crypto.randomUUID()})).status, 404);
    if (kind === 'node') assert.equal((await post('/activities/start', {...activity, owner_id: stranger})).status, 404);
    assert.equal((await post('/activities/start', {...activity, avatar_contact_id: 'private name'})).status, 400);
    assert.equal((await post('/activities/start', activity)).body.accepted_by_apns, true);
    assert.equal((await post('/activities/start', activity)).body.accepted_by_apns, true);
    assert.equal(sends.length, 1);
    assert.equal(sends[0].device.device_token, 'b'.repeat(64));
    assert.equal(sends[0].payload.avatar_contact_id, activity.avatar_contact_id);
    assert.equal(sends[0].payload.display_name, activity.display_name);
    await post('/devices', {...registration, live_activity_start_token: 'c'.repeat(64)});
    fail = true;
    assert.equal((await post('/activities/start', {...activity, call_id: crypto.randomUUID()})).status, 502);
    assert.equal(sends.at(-1).device.device_token, 'c'.repeat(64));
    fail = false;
    assert.equal((await post('/activities/start', {...activity, call_id: crypto.randomUUID()})).status, 422);
    assert.equal((await post('/push', {binding_id: binding.binding_id, call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp', event: 'incoming_call'})).status, 200);
    await post('/devices', registration);
    let resolve; release = new Promise(done => {resolve = done;});
    const delayedCall = {...activity, call_id: crypto.randomUUID()};
    const inFlight = post('/activities/start', delayedCall);
    await new Promise(done => setImmediate(done));
    assert.equal((await post('/activities/start', delayedCall)).status, 409);
    await post('/devices/remove', {device_id: deviceID});
    resolve(); await inFlight;
    assert.equal((await post('/activities/start', delayedCall)).status, 404);
  } finally {close(); rmSync(directory, {recursive: true, force: true});}
});

test('phone service starts only connected owner activities and forwards a bounded display name', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'tincall-activity-service-'));
  const path = join(directory, 'store.sqlite');
  const store = createSQLiteStore({clients: [{token: 'phone', owner_id: owner}, {token: 'role', owner_id: owner, contact_id: 'synthetic'}, {token: 'other', owner_id: stranger}]}, path);
  let delivered;
  const gateway = createPushGateway({databasePath: join(directory, 'push.sqlite'), token: credential, send: async (_, payload) => {delivered = payload;}});
  let pushes = 0;
  const connector = createConnector({store, config: {pushURL: 'https://synthetic.invalid', pushToken: credential}, fetcher: async (url, init) => {
    if (url.endsWith('/activities/start')) pushes++;
    return gateway.handle(new Request(url, init));
  }});
  const post = async (route, value, token = 'phone') => {
    const response = await connector.handle(request(route, {request_id: crypto.randomUUID(), ...value}, token));
    return {status: response.status, body: await response.json()};
  };
  try {
    const deviceID = crypto.randomUUID(), callID = crypto.randomUUID();
    const callsValidUntil = new Date(Date.now() + 60000).toISOString();
    const registered = await post('/devices', {device_id: deviceID, device_token: 'a'.repeat(64), environment: 'sandbox', live_activity_start_token: 'b'.repeat(64), calls_valid_until: callsValidUntil});
    assert.equal(registered.status, 200);
    assert.equal(registered.body.live_activity_push, true);
    assert.equal(registered.body.call_access_expiry, true);
    const db = new DatabaseSync(path);
    const stored = JSON.parse(db.prepare("SELECT payload FROM tincall_requests WHERE action='device.put'").get().payload);
    assert.equal(stored.live_activity_start_token, undefined);
    assert.equal(stored.calls_valid_until, undefined);
    db.close();
    const gatewayDB = new DatabaseSync(join(directory, 'push.sqlite'));
    assert.equal(gatewayDB.prepare('SELECT calls_valid_until FROM devices').get().calls_valid_until > Date.now(), true);
    gatewayDB.close();
    await store.command(owner, 'call.incoming', {request_id: crypto.randomUUID(), call_id: callID, contact_id: 'synthetic', source: 'mcp'});
    const route = `/calls/${callID}/activity`, payload = {device_id: deviceID, avatar_contact_id: crypto.randomUUID(), display_name: 'Synthetic caller'};
    assert.equal((await post(route, payload, 'role')).status, 403);
    assert.notEqual((await post(route, payload, 'other')).status, 200);
    assert.equal(pushes, 0);
    assert.equal((await post(route, payload)).status, 409, 'Ringing must not start a connected activity');
    assert.equal(pushes, 0);
    await store.command(owner, 'call.accept', {request_id: crypto.randomUUID(), call_id: callID, epoch: 0});
    assert.equal((await post(route, {...payload, avatar_contact_id: 'private name'})).status, 400);
    assert.equal((await post(route, {...payload, display_name: 'x'.repeat(201)})).status, 400);
    assert.equal((await post(route, payload)).body.accepted_by_apns, true);
    assert.equal(pushes, 1);
    assert.deepEqual(delivered, {event: 'activity_start', call_id: callID, avatar_contact_id: payload.avatar_contact_id, display_name: payload.display_name});
    const activityDB = new DatabaseSync(path);
    assert.equal(activityDB.prepare("SELECT count(*) AS n FROM tincall_requests WHERE action='call.activity'").get().n, 0);
    activityDB.close();
    await store.command(owner, 'call.end', {request_id: crypto.randomUUID(), call_id: callID, epoch: 0});
    assert.equal((await post(route, payload)).status, 409);
    assert.equal(pushes, 1);
  } finally {gateway.close(); store.close(); rmSync(directory, {recursive: true, force: true});}
});
