// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import { PushError, requireValue, sendAPNs } from './apns.mjs';
import { ActivityPushError, LiveActivityPushRegistry, validateActivityToken } from '../connector/live-activity-push.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const serviceProject = token => /^tcpush_([a-z0-9]{19,20})_[a-f0-9]{64}$/.exec(token ?? '')?.[1];
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
});
const failure = error => json({ error: { code: error instanceof PushError || error instanceof ActivityPushError ? error.code : 'push_failed' } },
  error instanceof PushError || error instanceof ActivityPushError ? error.status : 503);

async function body(request) {
  requireValue(request.headers.get('content-type')?.startsWith('application/json'), 'json_required', 415);
  const reader = request.body?.getReader();
  requireValue(reader, 'body_required');
  const decoder = new TextDecoder();
  let text = '', size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      requireValue(size <= 4096, 'body_too_large', 413);
      text += decoder.decode(value, { stream: true });
    }
    text += decoder.decode();
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  try { const value = JSON.parse(text); requireValue(value && typeof value === 'object' && !Array.isArray(value), 'invalid_json'); return value; }
  catch { throw new PushError('invalid_json'); }
}

export default {
  async fetch(request, env) {
    try {
      requireValue(request.method === 'POST', 'method_not_allowed', 405);
      requireValue(!request.headers.has('origin'), 'origin_forbidden', 403);
      const path = new URL(request.url).pathname;
      requireValue(['/services/register', '/devices', '/devices/remove', '/push', '/activities/start'].includes(path), 'route_not_found', 404);
      const token = request.headers.get('authorization')?.match(/^Bearer (\S+)$/)?.[1];
      const project = serviceProject(token);
      if (path === '/services/register') {
        requireValue(project, 'unauthorized', 401);
        await body(request);
        requireValue(env.PUSH_SERVICES, 'push_not_configured', 503);
        return env.PUSH_SERVICES.get(env.PUSH_SERVICES.idFromName(project)).fetch(new Request('https://service/register', {
          method: 'POST', headers: { authorization: `Bearer ${token}` }
        }));
      }
      let clients;
      try { clients = JSON.parse(env.PUSH_CLIENTS || '[]'); } catch { throw new PushError('push_not_configured', 503); }
      requireValue(Array.isArray(clients) && clients.every(c =>
        typeof c.id === 'string' && c.id.length > 0 && typeof c.token === 'string' && c.token.length >= 24), 'push_not_configured', 503);
      let client = clients.find(c => token === c.token);
      if (!client && project && env.PUSH_SERVICES) {
        const verified = await env.PUSH_SERVICES.get(env.PUSH_SERVICES.idFromName(project)).fetch(new Request('https://service/authorize', {
          headers: { authorization: `Bearer ${token}` }
        }));
        if (verified.ok) client = { id: `supabase:${project}` };
        await verified.body?.cancel();
      }
      requireValue(client, 'unauthorized', 401);
      const value = await body(request);
      requireValue(UUID.test(value.owner_id), 'invalid_owner_id');
      // Per-backend credentials cannot address another installation's device registry.
      const registry = env.PUSH_REGISTRIES.get(env.PUSH_REGISTRIES.idFromName(JSON.stringify([client.id, value.owner_id.toLowerCase()])));
      return registry.fetch(new Request(`https://registry${path}`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(value)
      }));
    } catch (error) { return failure(error); }
  }
};

// One credential per verified Supabase project. It cannot authorize user data APIs.
// Keeping the service identity stable preserves device bindings when credentials rotate.
export class PushService {
  constructor(ctx) { this.ctx = ctx; }

  async fetch(request) {
    try {
      const token = request.headers.get('authorization')?.match(/^Bearer (\S+)$/)?.[1];
      const project = serviceProject(token);
      requireValue(project, 'unauthorized', 401);
      const path = new URL(request.url).pathname;
      if (path === '/authorize' && request.method === 'GET') {
        requireValue(await this.ctx.storage.get('credential') === token, 'unauthorized', 401);
        return json({ authorized: true });
      }
      requireValue(path === '/register' && request.method === 'POST', 'route_not_found', 404);
      return await this.ctx.blockConcurrencyWhile(async () => {
        const challenge = crypto.randomUUID();
        let response;
        try {
          response = await fetch(`https://${project}.supabase.co/functions/v1/tincall/push/verify`, {
            method: 'POST', headers: { authorization: `Bearer ${token}`, 'x-tincall-push-challenge': challenge, 'cache-control': 'no-store' },
            redirect: 'manual', signal: AbortSignal.timeout(8000)
          });
        } catch { throw new PushError('service_verification_unavailable', 503); }
        if (!response.ok) {
          await response.body?.cancel();
          throw new PushError('service_verification_failed', 403);
        }
        const proof = await body(response);
        requireValue(proof.verified === true && proof.challenge === challenge, 'service_verification_failed', 403);
        // Nothing is persisted for an unsuccessful ownership check.
        await this.ctx.storage.put('credential', token);
        return json({ registered: true });
      });
    } catch (error) { return failure(error); }
  }
}

export class PushRegistry {
  constructor(ctx, env) {
    this.storage = ctx.storage;
    this.sql = ctx.storage.sql;
    this.env = env;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS devices (
      device_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL UNIQUE, device_token TEXT NOT NULL,
      environment TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1)`);
    if (!this.sql.exec('PRAGMA table_info(devices)').toArray().some(column => column.name === 'calls_valid_until')) {
      this.sql.exec('ALTER TABLE devices ADD COLUMN calls_valid_until INTEGER');
    }
    this.sql.exec(`CREATE TABLE IF NOT EXISTS deliveries (
      binding_id TEXT NOT NULL, call_id TEXT NOT NULL, contact_id TEXT NOT NULL, state TEXT NOT NULL,
      created_at INTEGER NOT NULL, PRIMARY KEY(binding_id, call_id))`);
    this.sql.exec('CREATE INDEX IF NOT EXISTS delivery_time ON deliveries(binding_id, created_at)');
    this.activities = new LiveActivityPushRegistry((query, ...values) => this.sql.exec(query, ...values).toArray(),
      (device, payload) => sendAPNs(this.env, device, payload));
  }

  async fetch(request) {
    try {
      const p = await body(request), path = new URL(request.url).pathname;
      if (path === '/devices') {
        requireValue(UUID.test(p.device_id), 'invalid_device_id');
        requireValue(typeof p.device_token === 'string' && /^[a-f0-9]{32,256}$/i.test(p.device_token), 'invalid_device_token');
        requireValue(['sandbox', 'production'].includes(p.environment), 'invalid_environment');
        validateActivityToken(p.live_activity_start_token);
        const until = p.calls_valid_until == null ? null : Date.parse(p.calls_valid_until);
        requireValue(until === null || (typeof p.calls_valid_until === 'string' && Number.isFinite(until)), 'invalid_call_expiry');
        const sandbox = p.environment === 'sandbox';
        requireValue(this.env.APNS_TEAM_ID && this.env.APNS_TOPIC?.endsWith('.voip') &&
          (sandbox ? this.env.APNS_SANDBOX_KEY_ID && this.env.APNS_SANDBOX_KEY_P8
            : this.env.APNS_PRODUCTION_KEY_ID && this.env.APNS_PRODUCTION_KEY_P8), 'apns_configuration_missing', 503);
        const previous = this.sql.exec('SELECT * FROM devices WHERE device_id=?', p.device_id.toLowerCase()).toArray()[0];
        const binding = previous?.enabled && previous.device_token === p.device_token && previous.environment === p.environment
          ? previous.binding_id : crypto.randomUUID();
        const result = this.sql.exec(`INSERT INTO devices(device_id, binding_id, device_token, environment, calls_valid_until)
          VALUES(?, ?, ?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET
          binding_id=excluded.binding_id, device_token=excluded.device_token, environment=excluded.environment, calls_valid_until=excluded.calls_valid_until, enabled=1 RETURNING binding_id`,
          p.device_id.toLowerCase(), binding, p.device_token, p.environment, until).toArray()[0];
        if (previous && previous.binding_id !== binding) this.activities.remove(previous.binding_id);
        // A reinstall keeps the APNs token but creates a new device ID. Drop the old
        // registration so one call is not delivered twice with an unknown device ID.
        const stale = this.sql.exec('SELECT binding_id FROM devices WHERE device_token=? AND device_id<>?',
          p.device_token, p.device_id.toLowerCase()).toArray();
        for (const device of stale) {
          this.activities.remove(device.binding_id);
          this.sql.exec('DELETE FROM deliveries WHERE binding_id=?', device.binding_id);
          this.sql.exec('DELETE FROM devices WHERE binding_id=?', device.binding_id);
        }
        this.activities.register(result.binding_id, p.live_activity_start_token);
        return json({ ...result, live_activity_push: true, call_access_expiry: true });
      }
      if (path === '/devices/remove') {
        requireValue(UUID.test(p.device_id), 'invalid_device_id');
        const device = this.sql.exec('SELECT binding_id FROM devices WHERE device_id=?', p.device_id.toLowerCase()).toArray()[0];
        if (device) this.activities.remove(device.binding_id);
        this.sql.exec('DELETE FROM deliveries WHERE binding_id IN (SELECT binding_id FROM devices WHERE device_id=?)', p.device_id.toLowerCase());
        this.sql.exec('DELETE FROM devices WHERE device_id=?', p.device_id.toLowerCase());
        return json({ ok: true });
      }
      if (path === '/activities/start') {
        requireValue(UUID.test(p.device_id), 'invalid_device_id');
        const device = this.sql.exec('SELECT * FROM devices WHERE device_id=? AND enabled=1', p.device_id.toLowerCase()).toArray()[0];
        requireValue(device, 'device_not_registered', 404);
        const result = await this.activities.start(device, p.call_id, p.avatar_contact_id, p.display_name);
        if (await this.storage.getAlarm() === null) await this.storage.setAlarm(Date.now() + 7 * 86400000);
        return json(result);
      }
      requireValue(path === '/push', 'route_not_found', 404);
      requireValue(UUID.test(p.call_id) && UUID.test(p.binding_id), 'invalid_identifier');
      requireValue(p.event === 'incoming_call' && typeof p.contact_id === 'string' && p.contact_id.length > 0 && p.contact_id.length <= 200, 'invalid_event');
      requireValue(['backend', 'mcp', 'independent'].includes(p.source), 'invalid_source');
      const device = this.sql.exec('SELECT * FROM devices WHERE binding_id=? AND enabled=1', p.binding_id).toArray()[0];
      requireValue(device, 'device_not_registered', 404);
      requireValue(device.calls_valid_until == null || device.calls_valid_until > Date.now(), 'call_access_expired', 403);
      const old = this.sql.exec('SELECT * FROM deliveries WHERE binding_id=? AND call_id=?', p.binding_id, p.call_id).toArray()[0];
      requireValue(!old || old.contact_id === p.contact_id, 'idempotency_conflict', 409);
      if (old?.state === 'sent') return json({ accepted_by_apns: true });
      const now = Date.now();
      requireValue(old?.state !== 'sending' || now - old.created_at > 15000, 'push_in_progress', 409);
      this.sql.exec(`INSERT INTO deliveries VALUES(?, ?, ?, 'sending', ?) ON CONFLICT(binding_id, call_id)
        DO UPDATE SET state='sending', created_at=excluded.created_at`, p.binding_id, p.call_id, p.contact_id, now);
      if (await this.storage.getAlarm() === null) await this.storage.setAlarm(now + 7 * 24 * 60 * 60 * 1000);
      try {
        await sendAPNs(this.env, device, p);
        // A concurrent removal or rotation must not recreate an obsolete device binding.
        this.sql.exec("UPDATE deliveries SET state='sent' WHERE binding_id=? AND call_id=?", p.binding_id, p.call_id);
      } catch (error) {
        this.sql.exec("UPDATE deliveries SET state='failed' WHERE binding_id=? AND call_id=?", p.binding_id, p.call_id);
        if (error.code === 'apns_device_expired') this.sql.exec('UPDATE devices SET enabled=0 WHERE binding_id=? AND device_token=?', p.binding_id, device.device_token);
        throw error;
      }
      this.sql.exec('DELETE FROM deliveries WHERE created_at<?', now - 7 * 24 * 60 * 60 * 1000);
      return json({ accepted_by_apns: true });
    } catch (error) { return failure(error); }
  }

  async alarm() {
    this.activities.prune();
    const retention = 7 * 24 * 60 * 60 * 1000;
    this.sql.exec('DELETE FROM deliveries WHERE created_at<=?', Date.now() - retention);
    const next = this.sql.exec('SELECT MIN(created_at) AS created_at FROM deliveries').toArray()[0]?.created_at;
    const expirations = [next == null ? null : next + retention, this.activities.nextExpiry()].filter(value => value != null);
    if (expirations.length) await this.storage.setAlarm(Math.min(...expirations));
  }
}
