// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import { activityStartPayload } from '../connector/live-activity-push.mjs';

export class PushError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}
export function requireValue(value, code, status = 400) {
  if (!value) throw new PushError(code, status);
}

const encode = value => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))))
  .replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
const signatures = new Map();

// Only the selected environment's credential is used. Never retry a token in another environment.
export async function sendAPNs(env, device, payload, fetcher = fetch) {
  const activity = payload.event === 'activity_start';
  const sandbox = device.environment === 'sandbox';
  const keyID = sandbox ? env.APNS_SANDBOX_KEY_ID : env.APNS_PRODUCTION_KEY_ID;
  const privateKey = sandbox ? env.APNS_SANDBOX_KEY_P8 : env.APNS_PRODUCTION_KEY_P8;
  requireValue(env.APNS_TEAM_ID && keyID && privateKey && env.APNS_TOPIC?.endsWith('.voip'), 'apns_configuration_missing', 503);
  const now = Math.floor(Date.now() / 1000);
  const cacheID = `${env.APNS_TEAM_ID}/${keyID}`;
  let cached = signatures.get(cacheID);
  if (!cached || cached.key !== privateKey || now - cached.issued >= 2700) {
    let jwt;
    try {
      const der = Uint8Array.from(atob(privateKey.replace(/-----[^-]+-----/g, '').replace(/\s/g, '')), c => c.charCodeAt(0));
      const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
      const data = `${encode({ alg: 'ES256', kid: keyID })}.${encode({ iss: env.APNS_TEAM_ID, iat: now })}`;
      // ES256 is APNs protocol authentication, not an artifact checksum.
      const signed = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(data)));
      jwt = `${data}.${btoa(String.fromCharCode(...signed)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')}`;
    } catch { throw new PushError('apns_configuration_invalid', 503); }
    cached = { key: privateKey, issued: now, jwt };
    signatures.set(cacheID, cached);
  }
  let response;
  try {
    response = await fetcher(`https://${sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'}/3/device/${device.device_token}`, {
      method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(8000),
      headers: { authorization: `bearer ${cached.jwt}`, 'apns-topic': activity ? env.APNS_TOPIC.replace(/\.voip$/, '.push-type.liveactivity') : env.APNS_TOPIC,
        'apns-push-type': activity ? 'liveactivity' : 'voip', 'apns-priority': '10', 'apns-expiration': '0',
        'apns-id': payload.call_id, 'content-type': 'application/json' },
      body: JSON.stringify(activity ? activityStartPayload(payload.call_id, undefined, payload.avatar_contact_id, payload.display_name) : { aps: { 'content-available': 1 }, event: 'incoming_call',
        device_id: device.device_id, call_id: payload.call_id, contact_id: payload.contact_id, source: payload.source })
    });
  } catch { throw new PushError('apns_unavailable', 503); }
  if (response.status === 200) { await response.body?.cancel(); return; }
  const rejection = await response.json().catch(() => null);
  const knownReasons = ['BadDeviceToken', 'DeviceTokenNotForTopic', 'TopicDisallowed', 'BadTopic',
    'InvalidProviderToken', 'ExpiredProviderToken', 'MissingProviderToken', 'BadCertificate',
    'BadCertificateEnvironment', 'BadPriority', 'InvalidPushType', 'BadMessageId',
    'PayloadEmpty', 'PayloadTooLarge', 'Unregistered', 'Forbidden', 'BadPath',
    'TooManyRequests', 'TooManyProviderTokenUpdates', 'InternalServerError', 'ServiceUnavailable', 'Shutdown'];
  console.warn('[apns-rejected]', JSON.stringify({
    status: response.status, reason: knownReasons.includes(rejection?.reason) ? rejection.reason : 'unrecognized',
    environment: sandbox ? 'sandbox' : 'production', pushType: activity ? 'liveactivity' : 'voip'
  }));
  throw new PushError(response.status === 410 ? 'apns_device_expired' : 'apns_rejected', 502);
}
