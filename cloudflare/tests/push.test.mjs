// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { generateKeyPairSync } from 'node:crypto';
import worker, { PushRegistry } from '../push-worker.mjs';
import { sendAPNs } from '../apns.mjs';

const keyPair = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const privateKey = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' });
const token = 'synthetic-service-credential-at-least-24-characters';
const env = {
  APNS_TEAM_ID: 'SYNTHETIC', APNS_TOPIC: 'com.example.synthetic.voip',
  APNS_SANDBOX_KEY_ID: 'SANDBOX', APNS_SANDBOX_KEY_P8: privateKey,
  APNS_PRODUCTION_KEY_ID: 'PRODUCTION', APNS_PRODUCTION_KEY_P8: privateKey,
  PUSH_CLIENTS: JSON.stringify([{ id: 'one', token }, { id: 'two', token: token + '-two' }])
};

function registryBindings() {
  const databases = [], objects = new Map();
  return {
    idFromName: name => name,
    get(name) {
      if (!objects.has(name)) {
        const db = new DatabaseSync(':memory:'); databases.push(db);
        const sql = { exec(query, ...values) {
          const statement = db.prepare(query);
          if (statement.columns().length) return { toArray: () => statement.all(...values) };
          statement.run(...values); return { toArray: () => [] };
        } };
        let alarm = null;
        objects.set(name, new PushRegistry({ storage: { sql,
          getAlarm: async () => alarm, setAlarm: async value => { alarm = value; } } }, env));
      }
      return objects.get(name);
    },
    close() { for (const db of databases) db.close(); }
  };
}

test('trial expiry stops Worker delivery until a purchased device rebind', async t => {
  let now = 1800000000000, sent = 0;
  t.mock.method(Date, 'now', () => now);
  t.mock.method(globalThis, 'fetch', async () => { sent++; return new Response(null, { status: 200 }); });
  const bindings = registryBindings();
  t.after(() => bindings.close());
  async function post(path, value) {
    const response = await worker.fetch(new Request(`https://synthetic.invalid${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(value)
    }), { ...env, PUSH_REGISTRIES: bindings });
    return { status: response.status, body: await response.json() };
  }
  const device = { owner_id: crypto.randomUUID(), device_id: crypto.randomUUID(), device_token: 'a'.repeat(64), environment: 'sandbox' };
  const registered = await post('/devices', { ...device, calls_valid_until: new Date(now + 35000).toISOString() });
  assert.equal(registered.body.call_access_expiry, true);
  const call = { owner_id: device.owner_id, binding_id: registered.body.binding_id, call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp', event: 'incoming_call' };
  assert.equal((await post('/push', call)).status, 200);
  now += 35000;
  assert.equal((await post('/push', { ...call, call_id: crypto.randomUUID() })).body.error.code, 'call_access_expired');
  assert.equal(sent, 1);
  await post('/devices', { ...device, calls_valid_until: null });
  assert.equal((await post('/push', { ...call, call_id: crypto.randomUUID() })).status, 200);
  assert.equal(sent, 2);
  assert.equal((await post('/devices', { ...device, calls_valid_until: 'invalid' })).status, 400);
});

test('a reinstall registration replaces the old device with the same APNs token', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response(null, { status: 200 }));
  const bindings = registryBindings();
  t.after(() => bindings.close());
  async function post(path, value) {
    const response = await worker.fetch(new Request(`https://synthetic.invalid${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(value)
    }), { ...env, PUSH_REGISTRIES: bindings });
    return { status: response.status, body: await response.json() };
  }
  const owner = crypto.randomUUID(), deviceToken = 'b'.repeat(64);
  const old = await post('/devices', { owner_id: owner, device_id: crypto.randomUUID(), device_token: deviceToken, environment: 'production' });
  const current = await post('/devices', { owner_id: owner, device_id: crypto.randomUUID(), device_token: deviceToken, environment: 'production' });
  const call = { owner_id: owner, call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'independent', event: 'incoming_call' };
  assert.equal((await post('/push', { ...call, binding_id: old.body.binding_id })).body.error.code, 'device_not_registered');
  assert.equal((await post('/push', { ...call, binding_id: current.body.binding_id })).status, 200);
});

test('APNs transport selects the exact environment and signs a real ES256 provider token', async () => {
  for (const environment of ['sandbox', 'production']) {
    const deviceID = crypto.randomUUID();
    await sendAPNs(env, { environment, device_id: deviceID, device_token: 'a'.repeat(64) }, {
      device_id: crypto.randomUUID(), call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp'
    }, async (url, init) => {
      assert.equal(new URL(url).hostname, environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com');
      assert.equal(init.headers['apns-topic'], env.APNS_TOPIC);
      assert.equal(init.headers['apns-push-type'], 'voip');
      assert.equal(init.headers['apns-expiration'], '0');
      assert.equal(init.redirect, 'manual');
      const jwt = init.headers.authorization.slice('bearer '.length).split('.');
      assert.equal(JSON.parse(Buffer.from(jwt[0], 'base64url')).kid, environment === 'sandbox' ? 'SANDBOX' : 'PRODUCTION');
      const key = await crypto.subtle.importKey('spki', keyPair.publicKey.export({ type: 'spki', format: 'der' }), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
      assert.equal(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key,
        Buffer.from(jwt[2], 'base64url'), new TextEncoder().encode(`${jwt[0]}.${jwt[1]}`)), true);
      const body = JSON.parse(init.body);
      assert.deepEqual(Object.keys(body).sort(), ['aps', 'event', 'device_id', 'call_id', 'contact_id', 'source'].sort());
      assert.equal(body.device_id, deviceID, 'Routing must use the registered device, not the caller-supplied field');
      return new Response(null, { status: 200 });
    });
  }
  await assert.rejects(() => sendAPNs({ ...env, APNS_SANDBOX_KEY_P8: undefined },
    { environment: 'sandbox' }, {}), { code: 'apns_configuration_missing' });
});

test('Worker registry isolates installations and owners, persists rotations, deduplicates and removes routing', async t => {
  const bindings = registryBindings();
  t.after(() => bindings.close());
  const owner = crypto.randomUUID(), device = crypto.randomUUID();
  async function post(path, value, auth = token) {
    const response = await worker.fetch(new Request(`https://synthetic.invalid${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${auth}`, 'content-type': 'application/json' }, body: JSON.stringify(value)
    }), { ...env, PUSH_REGISTRIES: bindings });
    return { status: response.status, body: await response.json() };
  }
  let sent = 0, status = 200;
  t.mock.method(globalThis, 'fetch', async () => { sent++; return new Response(null, { status }); });
  const registration = { owner_id: owner, device_id: device, device_token: 'a'.repeat(64), environment: 'sandbox' };
  assert.equal((await post('/devices', registration, 'wrong')).status, 401);
  const registered = await post('/devices', registration);
  assert.equal(registered.status, 200);
  const payload = { owner_id: owner, binding_id: registered.body.binding_id, call_id: crypto.randomUUID(),
    contact_id: 'synthetic', source: 'mcp', event: 'incoming_call' };
  assert.equal((await post('/push', payload, token + '-two')).status, 404);
  assert.equal((await post('/push', { ...payload, owner_id: crypto.randomUUID() })).status, 404);
  assert.equal((await post('/push', payload)).body.accepted_by_apns, true);
  assert.equal((await post('/push', payload)).body.accepted_by_apns, true);
  assert.equal(sent, 1);
  assert.equal((await post('/push', { ...payload, call_id: crypto.randomUUID() })).status, 200);
  const rotated = await post('/devices', { ...registration, device_token: 'b'.repeat(64), environment: 'production' });
  assert.notEqual(rotated.body.binding_id, registered.body.binding_id);
  assert.equal((await post('/push', { ...payload, binding_id: rotated.body.binding_id, call_id: crypto.randomUUID() })).status, 200);
  await post('/devices/remove', { owner_id: owner, device_id: device });
  assert.equal((await post('/push', payload)).status, 404);
  const next = await post('/devices', registration);
  assert.notEqual(next.body.binding_id, registered.body.binding_id);
  status = 410;
  assert.equal((await post('/push', { ...payload, binding_id: next.body.binding_id, call_id: crypto.randomUUID() })).body.error.code, 'apns_device_expired');
  assert.equal((await post('/push', { ...payload, binding_id: next.body.binding_id, call_id: crypto.randomUUID() })).status, 404);
});

test('APNs rejection and timeout stay failures and never report a delivered call', async () => {
  const device = { environment: 'production', device_token: 'a'.repeat(64) };
  const payload = { call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp' };
  await assert.rejects(() => sendAPNs(env, device, payload, async () => new Response(null, { status: 403 })), { code: 'apns_rejected' });
  await assert.rejects(() => sendAPNs(env, device, payload, async () => new Response(null, {
    status: 302, headers: { location: 'https://synthetic.invalid/redirect' }
  })), { code: 'apns_rejected' });
  await assert.rejects(() => sendAPNs(env, device, payload, async () => { throw new Error('synthetic'); }), { code: 'apns_unavailable' });
});


test('immediate redial delivers new calls without a cooldown while duplicate retries stay deduplicated', async t => {
  t.mock.method(Date, 'now', () => 1800000000000);
  let sent = 0;
  t.mock.method(globalThis, 'fetch', async () => { sent++; return new Response(null, { status: 200 }); });
  const bindings = registryBindings();
  t.after(() => bindings.close());
  async function post(path, value) {
    const response = await worker.fetch(new Request(`https://synthetic.invalid${path}`, {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(value)
    }), { ...env, PUSH_REGISTRIES: bindings });
    return { status: response.status, body: await response.json() };
  }
  const device = { owner_id: crypto.randomUUID(), device_id: crypto.randomUUID(), device_token: 'a'.repeat(64), environment: 'sandbox' };
  const registered = await post('/devices', device);
  const call = { owner_id: device.owner_id, binding_id: registered.body.binding_id, call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp', event: 'incoming_call' };
  assert.equal((await post('/push', call)).status, 200);
  const redial = { ...call, call_id: crypto.randomUUID() };
  assert.equal((await post('/push', redial)).status, 200, 'a new call immediately after the previous one must reach APNs');
  assert.equal((await post('/push', redial)).status, 200);
  assert.equal(sent, 2, 'retrying the same call must not ring twice');
  for (let count = 2; count < 12; count++) assert.equal((await post('/push', { ...call, call_id: crypto.randomUUID() })).status, 200);
  assert.equal((await post('/push', redial)).status, 200);
  assert.equal(sent, 12);
});

test('Worker token refresh survives a late APNs expiry and renews disabled registrations', async t => {
  const bindings = registryBindings();
  t.after(() => bindings.close());
  let started, releaseOld;
  const sending = new Promise(resolve => { started = resolve; });
  t.mock.method(globalThis, 'fetch', async url => {
    if (String(url).endsWith('a'.repeat(64))) { started(); return new Promise(resolve => { releaseOld = resolve; }); }
    return new Response(null, {status: 200});
  });
  async function post(path, value) {
    const response = await worker.fetch(new Request(`https://synthetic.invalid${path}`, {method: 'POST',
      headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'}, body: JSON.stringify(value)
    }), {...env, PUSH_REGISTRIES: bindings});
    return {status: response.status, body: await response.json()};
  }
  const registration = {owner_id: crypto.randomUUID(), device_id: crypto.randomUUID(), device_token: 'a'.repeat(64), environment: 'sandbox'};
  const original = (await post('/devices', registration)).body;
  assert.equal((await post('/devices', registration)).body.binding_id, original.binding_id);
  const payload = {owner_id: registration.owner_id, binding_id: original.binding_id, call_id: crypto.randomUUID(), contact_id: 'synthetic', source: 'mcp', event: 'incoming_call'};
  const running = post('/push', payload);
  await sending;
  const refreshed = (await post('/devices', {...registration, device_token: 'b'.repeat(64)})).body;
  releaseOld(new Response(null, {status: 410}));
  assert.equal((await running).body.error.code, 'apns_device_expired');
  assert.notEqual(refreshed.binding_id, original.binding_id, 'connector cleanup must be able to distinguish refreshed routing');
  assert.equal((await post('/push', {...payload, binding_id: refreshed.binding_id})).status, 200);
  t.mock.method(globalThis, 'fetch', async () => new Response(null, {status: 410}));
  await post('/push', {...payload, binding_id: refreshed.binding_id, call_id: crypto.randomUUID()});
  const renewed = (await post('/devices', {...registration, device_token: 'b'.repeat(64)})).body;
  assert.notEqual(renewed.binding_id, refreshed.binding_id, 're-enabling a disabled registration needs a new binding');
});
