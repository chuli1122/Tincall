// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import { DatabaseSync } from 'node:sqlite';
import {
  mkdirSync,
  closeSync,
  createReadStream,
  createWriteStream,
  linkSync,
  unlinkSync,
  openSync,
} from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { ConnectorError } from '../supabase/functions/_shared/tincall/service.mjs';

export const defaultDatabasePath = fileURLToPath(
  new URL('./data/tincall.sqlite', import.meta.url),
);
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowed = new Set([
  'forbidden',
  'unauthorized',
  'idempotency_conflict',
  'call_busy',
  'call_not_found',
  'call_ended',
  'stale_epoch',
  'call_not_ringing',
  'call_not_active',
  'reply_not_found',
  'final_text_rewrite',
  'revision_conflict',
  'invalid_cursor',
  'operation_retired',
  'device_limit',
  'role_identity_conflict',
  'invalid_expression_prompt',
  'schedule_not_found',
  'contact_not_found',
]);
function fail(code) {
  throw new ConnectorError(
    allowed.has(code) ? code : 'database_request_failed',
    code === 'forbidden' || code === 'unauthorized'
      ? 403
      : code.endsWith('_not_found')
        ? 404
        : allowed.has(code)
          ? 409
          : 400,
  );
}
function check(value, code) {
  if (!value) fail(code);
}
const now = () => new Date().toISOString();
const visible = (row) => {
  if (!row) return null;
  const { owner_id, ...rest } = row;
  return rest;
};
const json = (value) => JSON.stringify(value);
const length = (value) => (typeof value === 'string' ? [...value].length : 0);
const mutations = new Set([
  'call.create',
  'call.incoming',
  'call.accept',
  'call.input',
  'call.interrupt',
  'call.end',
  'reply.delta',
  'reply.completed',
  'reply.failed',
  'device.put',
  'device.delete',
  'schedule.put',
  'schedule.enabled',
  'schedule.delete',
  'record.put',
  'record.delete',
  'summary.put',
]);

// Node's ICU timezone database supplies offsets, including historical DST rules.
// Like PostgreSQL, ambiguous/nonexistent local times prefer the standard offset.
export function nextDaily(time, zone, after = new Date(), weekDay = null) {
  check(
    weekDay == null ||
      (Number.isInteger(weekDay) && weekDay >= 1 && weekDay <= 7),
    'invalid_week_day',
  );
  const match = /^(\d{1,2}):(\d{2})(?::(\d{2})(\.\d{1,6})?)?$/.exec(time ?? '');
  check(
    match &&
      +match[1] <= 24 &&
      +match[2] < 60 &&
      +(match[3] ?? 0) < 60 &&
      (+match[1] !== 24 ||
        (+match[2] === 0 && +(match[3] ?? 0) === 0 && +(match[4] ?? 0) === 0)),
    'invalid_time',
  );
  check(typeof zone === 'string' && zone.length > 0, 'invalid_timezone');
  let formatter;
  try {
    formatter = new Intl.DateTimeFormat('en-CA', {
      timeZone: zone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    });
  } catch {
    fail('invalid_timezone');
  }
  const parts = (date) =>
    Object.fromEntries(
      formatter
        .formatToParts(date)
        .filter((p) => p.type !== 'literal')
        .map((p) => [p.type, +p.value]),
    );
  const local = (date) => {
    const p = parts(date);
    return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  };
  const p = parts(after);
  const day = Date.UTC(p.year, p.month - 1, p.day);
  function at(date) {
    const wall =
      date +
      (+match[1] * 3600 +
        +match[2] * 60 +
        +(match[3] ?? 0) +
        +(match[4] ?? 0)) *
        1000;
    const offsets = [
      ...new Set(
        [-86400000, 0, 86400000].map((delta) => {
          const probe = new Date(Math.floor((wall + delta) / 1000) * 1000);
          return local(probe) - probe.getTime();
        }),
      ),
    ];
    const candidates = offsets.map((offset) => wall - offset);
    const exact = candidates.filter(
      (value) => Math.abs(local(new Date(value)) - (wall - (wall % 1000))) < 1,
    );
    return Math.max(...(exact.length ? exact : candidates));
  }
  let nextDay = day;
  if (weekDay != null)
    nextDay +=
      ((weekDay - (new Date(day).getUTCDay() || 7) + 7) % 7) * 86400000;
  let due = at(nextDay);
  if (due <= after.getTime())
    due = at(nextDay + (weekDay == null ? 1 : 7) * 86400000);
  return new Date(due).toISOString();
}

// Definitions are also the additive upgrade plan: missing columns are added with
// their defaults under one transaction. No table is dropped or rebuilt.
const tables = {
  owners: { owner_id: 'TEXT PRIMARY KEY' },
  calls: {
    phone_seen_at: 'TEXT',
    id: 'TEXT PRIMARY KEY',
    owner_id: 'TEXT NOT NULL',
    contact_id: 'TEXT NOT NULL',
    source: 'TEXT NOT NULL',
    status: 'TEXT NOT NULL',
    epoch: 'INTEGER NOT NULL DEFAULT 0',
    last_sequence: 'INTEGER NOT NULL DEFAULT 0',
    created_at: 'TEXT NOT NULL',
    ended_at: 'TEXT',
    summary: 'TEXT',
    tts_expression_prompt: "TEXT NOT NULL DEFAULT ''",
    voice_instructions_sent: 'INTEGER NOT NULL DEFAULT 0',
    user_name: "TEXT NOT NULL DEFAULT ''",
    mcp_read_sequence: 'INTEGER NOT NULL DEFAULT 0',
    mcp_read_epoch: 'INTEGER NOT NULL DEFAULT -1',
    mcp_dial_until: 'TEXT',
  },
  messages: {
    sequence: 'INTEGER PRIMARY KEY AUTOINCREMENT',
    id: 'TEXT NOT NULL UNIQUE',
    call_id: 'TEXT NOT NULL REFERENCES tincall_calls(id) ON DELETE CASCADE',
    owner_id: 'TEXT NOT NULL',
    input_id: 'TEXT',
    role: 'TEXT NOT NULL',
    epoch: 'INTEGER NOT NULL',
    text: "TEXT NOT NULL DEFAULT ''",
    status: 'TEXT NOT NULL',
    interruption_reason: 'TEXT',
    created_at: 'TEXT NOT NULL',
    images: 'TEXT',
    reply_touched_at: 'TEXT',
  },
  events: {
    call_id: 'TEXT NOT NULL REFERENCES tincall_calls(id) ON DELETE CASCADE',
    owner_id: 'TEXT NOT NULL',
    sequence: 'INTEGER NOT NULL',
    epoch: 'INTEGER NOT NULL',
    type: 'TEXT NOT NULL',
    payload: 'TEXT NOT NULL',
    created_at: 'TEXT NOT NULL',
  },
  requests: {
    owner_id: 'TEXT NOT NULL',
    request_id: 'TEXT NOT NULL',
    action: 'TEXT NOT NULL',
    payload: 'TEXT NOT NULL',
    response: 'TEXT NOT NULL',
    retired: 'INTEGER NOT NULL DEFAULT 0',
    created_at: 'TEXT NOT NULL',
  },
  jobs: {
    id: 'TEXT PRIMARY KEY',
    owner_id: 'TEXT NOT NULL',
    call_id: 'TEXT NOT NULL REFERENCES tincall_calls(id) ON DELETE CASCADE',
    input_id: 'TEXT NOT NULL REFERENCES tincall_messages(id)',
    reply_id: 'TEXT NOT NULL REFERENCES tincall_messages(id)',
    epoch: 'INTEGER NOT NULL',
    mode: 'TEXT NOT NULL',
    status: "TEXT NOT NULL DEFAULT 'pending'",
    created_at: 'TEXT NOT NULL',
    claimed_at: 'TEXT',
  },
  devices: {
    owner_id: 'TEXT NOT NULL',
    id: 'TEXT NOT NULL',
    binding_id: 'TEXT NOT NULL',
    enabled: 'INTEGER NOT NULL DEFAULT 1',
  },
  schedules: {
    id: 'TEXT PRIMARY KEY',
    owner_id: 'TEXT NOT NULL',
    contact_id: 'TEXT NOT NULL',
    source: 'TEXT NOT NULL',
    next_at: 'TEXT NOT NULL',
    repeat_seconds: 'INTEGER',
    daily_time: 'TEXT',
    time_zone: 'TEXT',
    enabled: 'INTEGER NOT NULL DEFAULT 1',
    week_day: 'INTEGER',
  },
  push_jobs: {
    id: 'TEXT PRIMARY KEY',
    owner_id: 'TEXT NOT NULL',
    call_id: 'TEXT NOT NULL REFERENCES tincall_calls(id) ON DELETE CASCADE',
    status: "TEXT NOT NULL DEFAULT 'pending'",
    error_code: 'TEXT',
    created_at: 'TEXT NOT NULL',
    claimed_at: 'TEXT',
  },
  records: {
    owner_id: 'TEXT NOT NULL',
    id: 'TEXT NOT NULL',
    revision: 'INTEGER NOT NULL DEFAULT 1',
    deleted: 'INTEGER NOT NULL DEFAULT 0',
    record: 'TEXT',
    updated_at: 'TEXT NOT NULL',
  },
  mcp_roles: {
    call_mode: "TEXT NOT NULL DEFAULT 'mcp'",
    mcp_wait_timeout_seconds:
      'INTEGER NOT NULL DEFAULT 120 CHECK (mcp_wait_timeout_seconds BETWEEN 1 AND 130)',
    owner_id: 'TEXT NOT NULL',
    role_id: 'TEXT NOT NULL',
    contact_id: 'TEXT NOT NULL',
    display_name: 'TEXT NOT NULL',
    token: 'TEXT NOT NULL UNIQUE',
    created_at: 'TEXT NOT NULL',
    updated_at: 'TEXT NOT NULL',
  },
  wake_bridges: {
    owner_id: 'TEXT NOT NULL',
    contact_id: 'TEXT NOT NULL',
    token: 'TEXT NOT NULL UNIQUE',
  },
  mcp_sse: {
    id: 'TEXT PRIMARY KEY',
    owner_id: 'TEXT NOT NULL',
    contact_id: 'TEXT',
    expires_at: 'TEXT NOT NULL',
    sequence: 'INTEGER NOT NULL DEFAULT 0',
    messages: "TEXT NOT NULL DEFAULT '[]'",
  },
  oauth_clients: {
    client_id: 'TEXT PRIMARY KEY',
    client_name: 'TEXT NOT NULL',
    redirect_uris: 'TEXT NOT NULL',
    created_at: 'TEXT NOT NULL',
  },
  oauth_requests: {
    id: 'TEXT PRIMARY KEY',
    user_code: 'TEXT NOT NULL UNIQUE',
    client_id: 'TEXT NOT NULL REFERENCES tincall_oauth_clients(client_id)',
    redirect_uri: 'TEXT NOT NULL',
    state: 'TEXT NOT NULL',
    resource: 'TEXT NOT NULL',
    code_challenge: 'TEXT NOT NULL',
    expires_at: 'TEXT NOT NULL',
    owner_id: 'TEXT',
    contact_id: 'TEXT',
    denied: 'INTEGER NOT NULL DEFAULT 0',
    code: 'TEXT UNIQUE',
  },
  oauth_grants: {
    access_token: 'TEXT PRIMARY KEY',
    refresh_token: 'TEXT NOT NULL UNIQUE',
    client_id: 'TEXT NOT NULL REFERENCES tincall_oauth_clients(client_id)',
    owner_id: 'TEXT NOT NULL',
    contact_id: 'TEXT NOT NULL',
    resource: 'TEXT NOT NULL',
    access_expires_at: 'TEXT NOT NULL',
    refresh_expires_at: 'TEXT NOT NULL',
  },
  media: {
    owner_id: 'TEXT NOT NULL',
    record_id: 'TEXT NOT NULL',
    asset_id: 'TEXT NOT NULL',
    content_type: 'TEXT NOT NULL',
    size: 'INTEGER NOT NULL',
    file: 'TEXT NOT NULL',
    deleted: 'INTEGER NOT NULL DEFAULT 0',
  },
};
const keys = {
  events: 'call_id,sequence',
  requests: 'owner_id,request_id',
  devices: 'owner_id,id',
  records: 'owner_id,id',
  mcp_roles: 'owner_id,role_id',
  wake_bridges: 'owner_id,contact_id',
  media: 'owner_id,record_id,asset_id',
};

export function createSQLiteStore(
  config = {},
  databasePath = defaultDatabasePath,
) {
  databasePath = resolve(databasePath);
  mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });
  // Create with private permissions before opening; never truncate an existing DB.
  const fd = openSync(databasePath, 'a', 0o600);
  closeSync(fd);
  const db = new DatabaseSync(databasePath);
  const mediaDirectory = databasePath + '.media';
  mkdirSync(mediaDirectory, { recursive: true, mode: 0o700 });
  db.exec(
    'PRAGMA busy_timeout=15000; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;',
  );
  const incomingListeners = new Map();
  const incomingChanges = new Map();
  const wakeListeners = new Map();
  const wakeChanges = new Map();
  function transaction(fn) {
    let result;let begun=false;
    try {
      db.exec('BEGIN IMMEDIATE');begun=true;
      result = fn();
      db.exec('COMMIT');
    } catch (error) {
      // SQLite may already have rolled back after an engine/IO failure.
      if(begun)try { db.exec('ROLLBACK'); } catch {}
      incomingChanges.clear();
      wakeChanges.clear();
      if (error instanceof ConnectorError) throw error;
      if([5,6].includes(error.errcode & 255))throw new ConnectorError('database_busy',503);
      throw new ConnectorError('database_request_failed', 400);
    }
    const changes = [...incomingChanges];
    incomingChanges.clear();
    for (const [owner, call] of changes)
      for (const listener of incomingListeners.get(owner) ?? []) listener(call);
    const wakes = [...wakeChanges];
    wakeChanges.clear();
    for (const [owner, call] of wakes)
      for (const listener of wakeListeners.get(owner) ?? []) listener(call);
    return result;
  }
  try {
    transaction(() => {
      for (const [name, columns] of Object.entries(tables)) {
        const table = 'tincall_' + name;
        db.exec(
          `CREATE TABLE IF NOT EXISTS ${table} (${Object.entries(columns)
            .map(([key, type]) => `${key} ${type}`)
            .join(',')}${keys[name] ? `, PRIMARY KEY (${keys[name]})` : ''})`,
        );
        const existing = new Set(
          db
            .prepare(`PRAGMA table_info(${table})`)
            .all()
            .map((row) => row.name),
        );
        for (const [key, type] of Object.entries(columns))
          if (!existing.has(key))
            db.exec(`ALTER TABLE ${table} ADD COLUMN ${key} ${type}`);
      }
      db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS tincall_one_live_call ON tincall_calls(owner_id) WHERE status<>'ended';
      CREATE UNIQUE INDEX IF NOT EXISTS tincall_role_contact ON tincall_mcp_roles(owner_id,contact_id);
      CREATE UNIQUE INDEX IF NOT EXISTS tincall_job_epoch ON tincall_jobs(call_id,epoch);
      CREATE INDEX IF NOT EXISTS tincall_pending_jobs ON tincall_jobs(created_at) WHERE status='pending';
      CREATE INDEX IF NOT EXISTS tincall_message_call ON tincall_messages(call_id,sequence);
      CREATE INDEX IF NOT EXISTS tincall_request_action ON tincall_requests(owner_id,action);
      CREATE INDEX IF NOT EXISTS tincall_record_index ON tincall_records(owner_id,updated_at,id);`);
    });
  } catch (error) {
    db.close();
    throw error;
  }
  const decode = (row) => {
    if (!row) return null;
    const result = { ...row };
    for (const key of ['payload', 'response', 'record'])
      if (typeof result[key] === 'string')
        result[key] = JSON.parse(result[key]);
    if (result.images) result.images = JSON.parse(result.images);
    else delete result.images;
    for (const key of [
      'retired',
      'enabled',
      'deleted',
      'voice_instructions_sent',
    ])
      if (key in result) result[key] = Boolean(result[key]);
    return result;
  };
  const all = (query, ...args) =>
    db
      .prepare(query)
      .all(...args)
      .map(decode);
  const get = (query, ...args) => decode(db.prepare(query).get(...args));
  const run = (query, ...args) => db.prepare(query).run(...args);
  function insert(name, row) {
    const columns = Object.keys(row);
    run(
      `INSERT INTO tincall_${name} (${columns.join(',')}) VALUES (${columns.map(() => '?').join(',')})`,
      ...Object.values(row).map((value) =>
        typeof value === 'boolean' ? Number(value) : value,
      ),
    );
  }
  function ownerRow(owner) {
    check(owner && UUID.test(owner), 'unauthorized');
    run('INSERT OR IGNORE INTO tincall_owners(owner_id) VALUES (?)', owner);
  }
  const callFor = (owner, id) => {
    const call = get(
      'SELECT * FROM tincall_calls WHERE owner_id=? AND id=?',
      owner,
      id,
    );
    check(call, 'call_not_found');
    return call;
  };
  function emit(id, type, payload) {
    run(
      'UPDATE tincall_calls SET last_sequence=last_sequence+1 WHERE id=?',
      id,
    );
    const call = get('SELECT * FROM tincall_calls WHERE id=?', id);
    if (['call.ringing', 'call.started', 'call.ended'].includes(type))
      incomingChanges.set(call.owner_id, visible(call));
    if (
      type === 'reply.started' &&
      call.source === 'mcp' &&
      call.status === 'active'
    )
      wakeChanges.set(call.owner_id, visible(call));
    insert('events', {
      call_id: id,
      owner_id: call.owner_id,
      sequence: call.last_sequence,
      epoch: call.epoch,
      type,
      payload: json(payload),
      created_at: now(),
    });
  }
  function stopReply(id, reason) {
    const messages = all(
      "SELECT * FROM tincall_messages WHERE call_id=? AND role='assistant' AND status='generating'",
      id,
    );
    run(
      "UPDATE tincall_messages SET status='interrupted',interruption_reason=? WHERE call_id=? AND role='assistant' AND status='generating'",
      reason,
      id,
    );
    for (const message of messages)
      emit(id, 'reply.interrupted', {
        reply_id: message.id,
        input_id: message.input_id,
        reason,
      });
    run(
      "UPDATE tincall_jobs SET status='cancelled' WHERE call_id=? AND status IN ('pending','running')",
      id,
    );
  }
  function execute(owner, action, p = {}) {
    ownerRow(owner);
    // UUIDs are typed values in PostgreSQL. Preserve its case-insensitive lookup
    // without changing the original JSON used for idempotency comparison.
    const id = (key) =>
      typeof p[key] === 'string' ? p[key].toLowerCase() : p[key];
    let receipt;
    if (action === 'device.lookup') {
      const old = get(
        'SELECT * FROM tincall_requests WHERE owner_id=? AND request_id=?',
        owner,
        id('request_id'),
      );
      if (!old) return { response: null };
      const { binding_id, ...original } = old.payload;
      check(
        old.action === 'device.put' && isDeepStrictEqual(original, p),
        'idempotency_conflict',
      );
      return { response: old.response };
    }
    if (mutations.has(action)) {
      receipt = id('request_id');
      check(receipt && UUID.test(receipt), 'request_id_required');
      const old = get(
        'SELECT * FROM tincall_requests WHERE owner_id=? AND request_id=?',
        owner,
        receipt,
      );
      if (old) {
        check(!old.retired, 'operation_retired');
        check(
          old.action === action && isDeepStrictEqual(old.payload, p),
          'idempotency_conflict',
        );
        return old.response;
      }
    }
    let result;
    if (action === 'call.create' || action === 'call.incoming') {
      check(
        !get(
          "SELECT id FROM tincall_calls WHERE owner_id=? AND status<>'ended'",
          owner,
        ),
        'call_busy',
      );
      check(
        UUID.test(id('call_id')) &&
          length(p.contact_id) >= 1 &&
          length(p.contact_id) <= 200 &&
          ['backend', 'mcp', 'independent'].includes(p.source),
        'invalid_call',
      );
      insert('calls', {
        id: id('call_id'),
        owner_id: owner,
        contact_id: p.contact_id,
        source: p.source,
        status: action === 'call.incoming' ? 'ringing' : 'active',
        created_at: now(),
        phone_seen_at: now(),
      });
      emit(
        id('call_id'),
        action === 'call.incoming' ? 'call.ringing' : 'call.started',
        {},
      );
      if (action === 'call.incoming')
        insert('push_jobs', {
          id: randomUUID(),
          owner_id: owner,
          call_id: id('call_id'),
          created_at: now(),
        });
      result = { call: visible(callFor(owner, id('call_id'))) };
    } else if (action === 'call.current') {
      return {
        call: visible(
          get(
            "SELECT * FROM tincall_calls WHERE owner_id=? AND status<>'ended'",
            owner,
          ),
        ),
      };
    } else if (action === 'call.list') {
      return {
        calls: all(
          'SELECT * FROM tincall_calls WHERE owner_id=? ORDER BY created_at DESC LIMIT 100',
          owner,
        ).map(visible),
      };
    } else if (action === 'device.put' || action === 'device.delete') {
      if (action === 'device.put') {
        check(
          get(
            'SELECT id FROM tincall_devices WHERE owner_id=? AND id=?',
            owner,
            id('device_id'),
          ) ||
            get(
              'SELECT count(*) n FROM tincall_devices WHERE owner_id=?',
              owner,
            ).n < 5,
          'device_limit',
        );
        check(
          length(p.binding_id) >= 1 && length(p.binding_id) <= 500,
          'invalid_binding',
        );
        run(
          'INSERT INTO tincall_devices(owner_id,id,binding_id) VALUES (?,?,?) ON CONFLICT(owner_id,id) DO UPDATE SET binding_id=excluded.binding_id,enabled=1',
          owner,
          id('device_id'),
          p.binding_id,
        );
      } else
        run(
          'DELETE FROM tincall_devices WHERE owner_id=? AND id=?',
          owner,
          id('device_id'),
        );
      result = { ok: true, binding_id: p.binding_id ?? null };
    } else if (action === 'schedule.enabled') {
      check(typeof p.enabled === 'boolean', 'invalid_enabled');
      const current = get(
        'SELECT * FROM tincall_schedules WHERE owner_id=? AND id=?',
        owner,
        id('schedule_id'),
      );
      check(current, 'schedule_not_found');
      const next =
        p.enabled && !current.enabled && current.daily_time
          ? nextDaily(
              current.daily_time,
              current.time_zone,
              new Date(),
              current.week_day,
            )
          : current.next_at;
      run(
        'UPDATE tincall_schedules SET enabled=?,next_at=? WHERE owner_id=? AND id=?',
        Number(p.enabled),
        next,
        owner,
        current.id,
      );
      result = { ok: true };
    } else if (action === 'schedule.put' || action === 'schedule.delete') {
      if (action === 'schedule.put') {
        check(
          p.enabled === undefined || typeof p.enabled === 'boolean',
          'invalid_enabled',
        );
        check(
          p.week_day == null ||
            (Number.isInteger(p.week_day) &&
              p.week_day >= 1 &&
              p.week_day <= 7 &&
              p.daily_time),
          'invalid_week_day',
        );
        const existing = get(
          'SELECT owner_id FROM tincall_schedules WHERE id=?',
          id('schedule_id'),
        );
        check(!existing || existing.owner_id === owner, 'forbidden');
        check(
          UUID.test(id('schedule_id')) &&
            length(p.contact_id) >= 1 &&
            length(p.contact_id) <= 200 &&
            ['backend', 'mcp', 'independent'].includes(p.source),
          'invalid_schedule',
        );
        check(
          p.repeat_seconds == null ||
            (Number.isInteger(p.repeat_seconds) && p.repeat_seconds >= 300),
          'invalid_schedule',
        );
        check(
          !p.daily_time || (p.time_zone && p.repeat_seconds == null),
          'invalid_schedule',
        );
        let next;
        try {
          next = p.daily_time
            ? nextDaily(p.daily_time, p.time_zone, new Date(), p.week_day)
            : new Date(p.next_at).toISOString();
        } catch (error) {
          if (error instanceof ConnectorError) throw error;
          fail('invalid_schedule');
        }
        const timeParts = p.daily_time?.split(':');
        const daily = timeParts
          ? `${timeParts[0].padStart(2, '0')}:${timeParts[1]}:${timeParts[2] ?? '00'}`
          : null;
        run(
          `INSERT INTO tincall_schedules(id,owner_id,contact_id,source,next_at,repeat_seconds,daily_time,time_zone,enabled,week_day) VALUES (?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET contact_id=excluded.contact_id,source=excluded.source,next_at=excluded.next_at,repeat_seconds=excluded.repeat_seconds,daily_time=excluded.daily_time,time_zone=excluded.time_zone,enabled=excluded.enabled,week_day=excluded.week_day`,
          id('schedule_id'),
          owner,
          p.contact_id,
          p.source,
          next,
          p.repeat_seconds ?? null,
          daily,
          p.time_zone ?? null,
          Number(p.enabled ?? true),
          p.week_day ?? null,
        );
      } else
        run(
          'DELETE FROM tincall_schedules WHERE owner_id=? AND id=?',
          owner,
          id('schedule_id'),
        );
      result = { ok: true };
    } else if (action === 'schedule.list')
      return {
        schedules: all(
          'SELECT * FROM tincall_schedules WHERE owner_id=?',
          owner,
        ).map(visible),
      };
    else if (action === 'record.list') {
      const after = new Date(p.after ?? '1970-01-01').toISOString();
      const records = all(
        'SELECT id,revision,deleted,updated_at FROM tincall_records WHERE owner_id=? AND (updated_at,id)>(?,?) ORDER BY updated_at,id LIMIT 100',
        owner,
        after,
        id('after_id') ?? '00000000-0000-0000-0000-000000000000',
      );
      const tail = records.at(-1);
      return {
        records,
        next_cursor: tail
          ? { after: tail.updated_at, after_id: tail.id }
          : null,
      };
    } else if (['record.get', 'record.put', 'record.delete'].includes(action)) {
      check(UUID.test(id('record_id')), 'invalid_record_id');
      const old = get(
        'SELECT * FROM tincall_records WHERE owner_id=? AND id=?',
        owner,
        id('record_id'),
      );
      if (action === 'record.get') return { record: visible(old) };
      check((old?.revision ?? 0) === p.expected_revision, 'revision_conflict');
      run(
        `INSERT INTO tincall_records(owner_id,id,revision,deleted,record,updated_at) VALUES (?,?,?,?,?,?)
        ON CONFLICT(owner_id,id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,record=excluded.record,updated_at=excluded.updated_at`,
        owner,
        id('record_id'),
        (old?.revision ?? 0) + 1,
        Number(action === 'record.delete'),
        action === 'record.delete' ? null : json(p.record ?? null),
        now(),
      );
      result = {
        record: visible(
          get(
            'SELECT * FROM tincall_records WHERE owner_id=? AND id=?',
            owner,
            id('record_id'),
          ),
        ),
      };
      if (action === 'record.delete') {
        if (!p.preserve_call_media)
          run(
            'UPDATE tincall_messages SET images=NULL WHERE owner_id=? AND call_id=?',
            owner,
            id('record_id'),
          );
        for (const oldRequest of all(
          "SELECT * FROM tincall_requests WHERE owner_id=? AND action='record.put'",
          owner,
        )) {
          if (oldRequest.payload.record_id?.toLowerCase() === id('record_id'))
            run(
              "UPDATE tincall_requests SET retired=1,payload=?,response='{}' WHERE owner_id=? AND request_id=?",
              json({ record_id: id('record_id') }),
              owner,
              oldRequest.request_id,
            );
        }
      }
    } else if (action === 'job.claim') {
      const job = get(
        "SELECT * FROM tincall_jobs WHERE owner_id=? AND mode='http' AND status='pending' ORDER BY created_at LIMIT 1",
        owner,
      );
      if (!job) return { job: null };
      run(
        "UPDATE tincall_jobs SET status='running',claimed_at=? WHERE id=?",
        now(),
        job.id,
      );
      return {
        job: get('SELECT * FROM tincall_jobs WHERE id=?', job.id),
        call: visible(callFor(owner, job.call_id)),
        messages: all(
          'SELECT * FROM tincall_messages WHERE call_id=? AND id<>? ORDER BY sequence',
          job.call_id,
          job.reply_id,
        ).map(visible),
      };
    } else if (action === 'push.claim') {
      run(
        "UPDATE tincall_push_jobs SET status='cancelled' WHERE owner_id=? AND status='pending' AND NOT EXISTS (SELECT 1 FROM tincall_calls c WHERE c.id=tincall_push_jobs.call_id AND c.status='ringing')",
        owner,
      );
      const push = get(
        "SELECT * FROM tincall_push_jobs WHERE owner_id=? AND status='pending' ORDER BY created_at LIMIT 1",
        owner,
      );
      if (!push) return { push: null };
      run(
        "UPDATE tincall_push_jobs SET status='running',claimed_at=? WHERE id=?",
        now(),
        push.id,
      );
      const call = callFor(owner, push.call_id);
      return {
        push: {
          id: push.id,
          call_id: call.id,
          contact_id: call.contact_id,
          source: call.source,
          devices: all(
            'SELECT id device_id,binding_id FROM tincall_devices WHERE owner_id=? AND enabled=1',
            owner,
          ),
        },
      };
    } else if (action === 'push.finish') {
      run(
        "UPDATE tincall_push_jobs SET status=?,error_code=? WHERE owner_id=? AND id=? AND status='running'",
        p.error_code == null ? 'sent' : 'failed',
        p.error_code ?? null,
        owner,
        id('push_id'),
      );
      return { ok: true };
    } else {
      let call = callFor(owner, id('call_id'));
      if (action === 'call.events') {
        const after = Math.max(p.after ?? 0, 0);
        check(after <= call.last_sequence, 'invalid_cursor');
        const events = all(
          'SELECT * FROM tincall_events WHERE call_id=? AND sequence>? ORDER BY sequence LIMIT ?',
          call.id,
          after,
          Math.min(Math.max(p.limit ?? 100, 1), 100),
        ).map(visible);
        const cursor = events.at(-1)?.sequence ?? after;
        return {
          call: visible(call),
          events,
          cursor,
          has_more: cursor < call.last_sequence,
        };
      } else if (action === 'call.record' || action === 'call.inputs') {
        const messages = all(
          `SELECT * FROM tincall_messages WHERE call_id=? ${action === 'call.inputs' ? "AND role='user'" : ''} ORDER BY sequence`,
          call.id,
        ).map(visible);
        const job = get(
          "SELECT * FROM tincall_jobs WHERE call_id=? AND epoch=? AND status IN ('pending','running')",
          call.id,
          call.epoch,
        );
        const push = get(
          'SELECT status,error_code FROM tincall_push_jobs WHERE call_id=? ORDER BY created_at DESC LIMIT 1',
          call.id,
        );
        return { call: visible(call), messages, job: visible(job), push };
      } else if (action === 'call.accept') {
        check(call.status === 'ringing', 'call_not_ringing');
        check(p.epoch === call.epoch, 'stale_epoch');
        run("UPDATE tincall_calls SET status='active' WHERE id=?", call.id);
        emit(call.id, 'call.started', {});
      } else if (action === 'job.cancel_result')
        emit(call.id, 'generation.cancel_result', {
          epoch: p.epoch,
          code: p.code,
        });
      else if (action === 'summary.put') {
        check(length(p.text) <= 100000, 'text_too_long');
        run(
          'UPDATE tincall_calls SET summary=? WHERE id=?',
          p.text ?? null,
          call.id,
        );
      } else if (
        ['call.input', 'call.interrupt', 'call.end'].includes(action)
      ) {
        check(call.status !== 'ended', 'call_ended');
        check(p.epoch === call.epoch, 'stale_epoch');
        if (action === 'call.input') {
          check(call.status === 'active', 'call_not_active');
          check(
            typeof p.text === 'string' &&
              length(p.text) <= 20000 &&
              (p.text.trim().length > 0 ||
                (Array.isArray(p.images) &&
                  p.images.length > 0 &&
                  p.images.length <= 4)),
            'invalid_text',
          );
        }
        stopReply(call.id, action === 'call.end' ? 'hangup' : 'interrupted');
        run('UPDATE tincall_calls SET epoch=epoch+1 WHERE id=?', call.id);
        call = callFor(owner, call.id);
        if (action === 'call.input') {
          const reply = randomUUID();
          check(['http', 'tools'].includes(p.mode), 'invalid_mode');
          insert('messages', {
            id: id('message_id'),
            call_id: call.id,
            owner_id: owner,
            role: 'user',
            epoch: call.epoch,
            text: p.text,
            status: 'complete',
            created_at: now(),
            ...(p.images?.length ? { images: json(p.images) } : {}),
          });
          insert('messages', {
            id: reply,
            call_id: call.id,
            owner_id: owner,
            input_id: id('message_id'),
            role: 'assistant',
            epoch: call.epoch,
            status: 'generating',
            created_at: now(),
          });
          insert('jobs', {
            id: randomUUID(),
            owner_id: owner,
            call_id: call.id,
            input_id: id('message_id'),
            reply_id: reply,
            epoch: call.epoch,
            mode: p.mode,
            created_at: now(),
          });
          emit(call.id, 'input.accepted', {
            input_id: id('message_id'),
            reply_id: reply,
          });
          emit(call.id, 'reply.started', {
            input_id: id('message_id'),
            reply_id: reply,
          });
          result = {
            input_id: id('message_id'),
            reply_id: reply,
            epoch: call.epoch,
          };
        } else if (action === 'call.end') {
          run(
            "UPDATE tincall_calls SET status='ended',ended_at=? WHERE id=?",
            now(),
            call.id,
          );
          emit(call.id, 'call.ended', { reason: p.reason ?? 'hangup' });
        } else emit(call.id, 'call.interrupted', { reason: 'interrupted' });
      } else if (
        ['reply.delta', 'reply.completed', 'reply.failed'].includes(action)
      ) {
        const job = get(
          'SELECT * FROM tincall_jobs WHERE owner_id=? AND call_id=? AND reply_id=?',
          owner,
          call.id,
          id('reply_id'),
        );
        check(job, 'reply_not_found');
        check(
          call.status === 'active' &&
            call.epoch === job.epoch &&
            p.epoch === job.epoch &&
            ['pending', 'running'].includes(job.status),
          'stale_epoch',
        );
        const message = get(
          'SELECT * FROM tincall_messages WHERE id=?',
          job.reply_id,
        );
        let payload;
        if (action === 'reply.delta') {
          check(
            length(p.delta) >= 1 &&
              length(p.delta) <= 20000 &&
              length(message.text) + length(p.delta) <= 100000,
            'invalid_delta',
          );
          run(
            'UPDATE tincall_messages SET text=text||? WHERE id=?',
            p.delta,
            message.id,
          );
          payload = { delta: p.delta };
        } else if (action === 'reply.completed') {
          check(
            p.text == null ||
              (length(p.text) <= 100000 && p.text.startsWith(message.text)),
            'final_text_rewrite',
          );
          const text = p.text ?? message.text;
          run(
            "UPDATE tincall_messages SET text=?,status='complete' WHERE id=?",
            text,
            message.id,
          );
          run("UPDATE tincall_jobs SET status='completed' WHERE id=?", job.id);
          payload = { text };
        } else {
          run(
            "UPDATE tincall_messages SET status='failed' WHERE id=?",
            message.id,
          );
          run("UPDATE tincall_jobs SET status='failed' WHERE id=?", job.id);
          payload = {
            code: [...(p.code ?? 'generation_failed')].slice(0, 100).join(''),
          };
        }
        emit(call.id, action, {
          ...payload,
          reply_id: job.reply_id,
          input_id: job.input_id,
        });
      } else fail('unknown_action');
      result = { ...result, call: visible(callFor(owner, call.id)) };
    }
    if (receipt)
      insert('requests', {
        owner_id: owner,
        request_id: receipt,
        action,
        payload: json(p),
        response: json(result),
        created_at: now(),
      });
    return result;
  }
  function mcpCommand(owner, contact, action, p = {}) {
    const cleanCall = (row) => {
      if (!row) return null;
      const {
        owner_id,
        tts_expression_prompt,
        voice_instructions_sent,
        mcp_read_sequence,
        mcp_read_epoch,
        mcp_dial_until,
        ...call
      } = row;
      return call;
    };
    const cleanMessage = (row) => {
      const { owner_id, reply_touched_at, ...message } = row;
      return message;
    };
    if (action === 'expire') {
      for (const message of all(
        `SELECT m.* FROM tincall_messages m JOIN tincall_calls c ON c.id=m.call_id
        WHERE c.source='mcp' AND c.status='active' AND m.role='assistant' AND m.status='generating'
        AND coalesce(m.reply_touched_at,m.created_at)<?
        AND NOT EXISTS(SELECT 1 FROM tincall_jobs j WHERE j.reply_id=m.id AND j.mode='http')`,
        new Date(Date.now() - 300000).toISOString(),
      )) {
        run(
          "UPDATE tincall_messages SET status='failed' WHERE id=?",
          message.id,
        );
        run(
          "UPDATE tincall_jobs SET status='failed' WHERE reply_id=? AND mode='tools'",
          message.id,
        );
        emit(message.call_id, 'reply.failed', {
          reply_id: message.id,
          input_id: message.input_id,
          code: 'platform_timeout',
        });
      }
      return { ok: true };
    }
    owner = owner.toLowerCase();
    ownerRow(owner);
    const limit = p.limit ?? 50;
    check(
      Number.isInteger(limit) && limit >= 1 && limit <= 100,
      'invalid_limit',
    );
    if (action === 'list') {
      let rows = all(
        `SELECT id AS call_id,created_at AS started_at,ended_at,status,
        CASE WHEN summary IS NOT NULL AND length(trim(summary))>0 THEN 1 ELSE 0 END AS has_summary
        FROM tincall_calls WHERE owner_id=? AND (? IS NULL OR contact_id=?)
        AND (? IS NULL OR (created_at,id)<(?,?)) ORDER BY created_at DESC,id DESC LIMIT ?`,
        owner,
        contact,
        contact,
        p.before?.started_at ?? null,
        p.before?.started_at ?? null,
        p.before?.call_id?.toLowerCase() ?? null,
        limit + 1,
      );
      const more = rows.length > limit;
      rows = rows
        .slice(0, limit)
        .map((row) => ({ ...row, has_summary: Boolean(row.has_summary) }));
      const tail = rows.at(-1);
      return {
        calls: rows,
        has_more: more,
        next_cursor: more
          ? { started_at: tail.started_at, call_id: tail.call_id }
          : null,
      };
    }
    const call = p.call_id
      ? get(
          'SELECT * FROM tincall_calls WHERE id=? AND owner_id=? AND (? IS NULL OR contact_id=?)',
          p.call_id.toLowerCase(),
          owner,
          contact,
          contact,
        )
      : get(
          "SELECT * FROM tincall_calls WHERE owner_id=? AND status<>'ended' AND (? IS NULL OR contact_id=?)",
          owner,
          contact,
          contact,
        );
    if (!call) {
      check(action === 'snapshot' && !p.call_id, 'call_not_found');
      return { call: null, messages: [], reply: null };
    }
    if (action === 'dial_wait') {
      run(
        'UPDATE tincall_calls SET mcp_dial_until=? WHERE id=?',
        p.until ?? null,
        call.id,
      );
      return { ok: true };
    }
    if (action === 'profile') {
      check(
        typeof p.user_name === 'string' && length(p.user_name) <= 200,
        'invalid_reply',
      );
      run(
        'UPDATE tincall_calls SET user_name=? WHERE id=?',
        p.user_name.trim(),
        call.id,
      );
      return { ok: true };
    }
    if (action === 'delivered') {
      run(
        'UPDATE tincall_calls SET mcp_read_sequence=max(mcp_read_sequence,?),mcp_read_epoch=max(mcp_read_epoch,?) WHERE id=?',
        p.sequence ?? 0,
        p.epoch ?? -1,
        call.id,
      );
      return { ok: true };
    }
    if (action === 'send') {
      check(call.status === 'active', 'call_not_active');
      check(call.source === 'mcp', 'forbidden');
      check(
        typeof p.text === 'string' && p.text.trim() && length(p.text) <= 100000,
        'invalid_reply',
      );
      const req = p.request_id?.toLowerCase();
      check(UUID.test(req), 'invalid_request_id');
      const old = get(
        'SELECT * FROM tincall_requests WHERE owner_id=? AND request_id=?',
        owner,
        req,
      );
      if (old) {
        check(!old.retired, 'operation_retired');
        check(
          old.action === 'mcp.send' && isDeepStrictEqual(old.payload, p),
          'idempotency_conflict',
        );
        return old.response;
      }
      let message = get(
        "SELECT * FROM tincall_messages WHERE call_id=? AND role='assistant' AND epoch=? AND status='generating' AND (input_id IS NULL OR input_id IN (SELECT id FROM tincall_messages WHERE call_id=? AND sequence<=?)) ORDER BY sequence DESC LIMIT 1",
        call.id,
        call.epoch,
        call.id,
        call.mcp_read_sequence,
      );
      if (message) {
        const job = get(
          'SELECT * FROM tincall_jobs WHERE reply_id=?',
          message.id,
        );
        check(!job || job.mode === 'tools', 'forbidden');
      } else {
        const id = randomUUID();
        insert('messages', {
          id,
          call_id: call.id,
          owner_id: owner,
          role: 'assistant',
          epoch: call.epoch,
          status: 'generating',
          created_at: now(),
        });
        message = get('SELECT * FROM tincall_messages WHERE id=?', id);
      }
      emit(call.id, 'reply.started', {
        reply_id: message.id,
        input_id: message.input_id,
        submitted: true,
      });
      run(
        "UPDATE tincall_messages SET text=?,status='complete',reply_touched_at=? WHERE id=?",
        p.text,
        now(),
        message.id,
      );
      run(
        "UPDATE tincall_jobs SET status='completed' WHERE reply_id=?",
        message.id,
      );
      emit(call.id, 'reply.completed', {
        reply_id: message.id,
        input_id: message.input_id,
        text: p.text,
        submitted: true,
      });
      const result = {
        call: cleanCall(call),
        reply_accepted: true,
        cursor: { sequence: call.mcp_read_sequence, epoch: call.epoch },
      };
      insert('requests', {
        owner_id: owner,
        request_id: req,
        action: 'mcp.send',
        payload: json(p),
        response: json(result),
        created_at: now(),
      });
      return result;
    }
    if (action === 'open') {
      if (
        call.status === 'active' &&
        call.source === 'mcp' &&
        call.epoch === 0 &&
        !get(
          "SELECT id FROM tincall_messages WHERE call_id=? AND role='assistant' AND epoch=0",
          call.id,
        )
      ) {
        const id = randomUUID();
        insert('messages', {
          id,
          call_id: call.id,
          owner_id: owner,
          role: 'assistant',
          epoch: 0,
          status: 'generating',
          created_at: now(),
          reply_touched_at: now(),
        });
        emit(call.id, 'reply.started', {
          reply_id: id,
          input_id: null,
          opening: true,
        });
      }
      return { ok: true };
    }
    if (action === 'snapshot') {
      if (p.unread) p = { ...p, after_sequence: call.mcp_read_sequence };
      const message = get(
        `SELECT m.* FROM tincall_messages m WHERE call_id=? AND role='assistant' AND epoch=? AND status='generating'
        AND NOT EXISTS(SELECT 1 FROM tincall_jobs j WHERE j.reply_id=m.id AND j.mode='http') ORDER BY sequence DESC LIMIT 1`,
        call.id,
        call.epoch,
      );
      let reply = message
        ? {
            reply_id: message.id,
            input_id: message.input_id,
            epoch: message.epoch,
            kind: message.input_id ? 'input' : 'opening',
          }
        : null;
      let rows, more;
      if (p.after_sequence === undefined) {
        rows = all(
          'SELECT * FROM tincall_messages WHERE call_id=? AND (? IS NULL OR sequence<?) ORDER BY sequence DESC LIMIT ?',
          call.id,
          p.before_sequence ?? null,
          p.before_sequence ?? null,
          limit + 1,
        );
        more = rows.length > limit;
        rows = rows.slice(0, limit).reverse();
      } else {
        check(
          p.after_sequence <=
            get(
              'SELECT coalesce(max(sequence),0) n FROM tincall_messages WHERE call_id=?',
              call.id,
            ).n,
          'invalid_cursor',
        );
        rows = all(
          "SELECT * FROM tincall_messages WHERE call_id=? AND role='user' AND sequence>? ORDER BY sequence LIMIT ?",
          call.id,
          p.after_sequence,
          limit + 1,
        );
        more = rows.length > limit;
        rows = rows.slice(0, limit);
        if (more) reply = null;
        if (
          !p.unread &&
          !more &&
          message?.input_id &&
          !rows.some((row) => row.id === message.input_id)
        )
          rows.push(
            get('SELECT * FROM tincall_messages WHERE id=?', message.input_id),
          );
      }
      return {
        call: cleanCall(call),
        messages: rows.map(cleanMessage),
        reply,
        has_more: more,
        read_cursor: {
          sequence: call.mcp_read_sequence,
          epoch: call.mcp_read_epoch,
        },
        dialed: call.mcp_dial_until != null,
        dial_waiting:
          call.mcp_dial_until != null && call.mcp_dial_until > now(),
        next_before_sequence:
          more && p.after_sequence === undefined ? rows[0].sequence : null,
        after_sequence:
          p.after_sequence === undefined
            ? null
            : Math.max(p.after_sequence, rows.at(-1)?.sequence ?? 0),
        voice_instructions:
          call.status === 'active' && !call.voice_instructions_sent
            ? '你的回复会被实时朗读成语音，请写适合说出口的口语。' +
              (call.tts_expression_prompt
                ? '\n' + call.tts_expression_prompt
                : '')
            : null,
      };
    }
    check(action === 'reply', 'unknown_action');
    const req = p.request_id?.toLowerCase();
    check(UUID.test(req), 'invalid_request_id');
    const old = get(
      'SELECT * FROM tincall_requests WHERE owner_id=? AND request_id=?',
      owner,
      req,
    );
    if (old) {
      check(!old.retired, 'operation_retired');
      check(
        old.action === 'mcp.reply' && isDeepStrictEqual(old.payload, p),
        'idempotency_conflict',
      );
      return old.response;
    }
    const message = get(
      "SELECT * FROM tincall_messages WHERE id=? AND call_id=? AND role='assistant'",
      p.reply_id.toLowerCase(),
      call.id,
    );
    check(message, 'reply_not_found');
    const job = get('SELECT * FROM tincall_jobs WHERE reply_id=?', message.id);
    check(
      call.status === 'active' &&
        message.status === 'generating' &&
        message.epoch === call.epoch &&
        p.epoch === message.epoch &&
        (job
          ? job.mode === 'tools'
          : call.source === 'mcp' &&
            message.input_id === null &&
            message.epoch === 0),
      'stale_epoch',
    );
    check(
      ['partial', 'complete', 'failed'].includes(p.status) &&
        typeof p.text === 'string' &&
        length(p.text) + length(message.text) <= 100000 &&
        (p.status !== 'partial' || p.text.trim()) &&
        (p.status !== 'failed' || p.text === ''),
      'invalid_reply',
    );
    check(
      p.error_code === undefined ||
        (p.status === 'failed' && /^[a-z][a-z0-9_]{0,63}$/.test(p.error_code)),
      'invalid_reply',
    );
    // An accepted reply acknowledges the instructions; reads and failed deliveries do not.
    if (p.status !== 'failed')
      run(
        'UPDATE tincall_calls SET voice_instructions_sent=1 WHERE id=?',
        call.id,
      );
    const text = message.text + p.text;
    run(
      'UPDATE tincall_messages SET text=?,reply_touched_at=?,status=? WHERE id=?',
      text,
      now(),
      p.status === 'partial' ? 'generating' : p.status,
      message.id,
    );
    if (p.status !== 'partial')
      run(
        'UPDATE tincall_jobs SET status=? WHERE reply_id=?',
        p.status === 'complete' ? 'completed' : 'failed',
        message.id,
      );
    emit(
      call.id,
      p.status === 'partial'
        ? 'reply.delta'
        : p.status === 'complete'
          ? 'reply.completed'
          : 'reply.failed',
      {
        reply_id: message.id,
        input_id: message.input_id,
        opening: message.input_id === null,
        ...(p.status === 'partial'
          ? { delta: p.text }
          : p.status === 'complete'
            ? { text }
            : { code: p.error_code ?? 'generation_failed' }),
      },
    );
    const result = {
      call: cleanCall(call),
      reply_accepted: true,
      cursor: {
        sequence: message.input_id
          ? get(
              'SELECT sequence FROM tincall_messages WHERE id=?',
              message.input_id,
            ).sequence
          : 0,
        epoch: message.epoch,
      },
    };
    insert('requests', {
      owner_id: owner,
      request_id: req,
      action: 'mcp.reply',
      payload: json(p),
      response: json(result),
      created_at: now(),
    });
    return result;
  }
  function removeFile(file) {
    try {
      unlinkSync(join(mediaDirectory, file));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  function finishMediaDeletion(rows) {
    try {
      for (const row of rows) {
        removeFile(row.file);
        run(
          'DELETE FROM tincall_media WHERE owner_id=? AND record_id=? AND asset_id=? AND file=? AND deleted=1',
          row.owner_id,
          row.record_id,
          row.asset_id,
          row.file,
        );
      }
    } catch {
      // Committed tombstones retain filenames for a later deletion retry.
      throw new ConnectorError('media_cleanup_failed', 503);
    }
  }
  function mediaKey(owner, record, asset) {
    if (
      ![owner, record, asset].every(
        (value) => typeof value === 'string' && UUID.test(value),
      )
    )
      throw new ConnectorError('invalid_media_path', 400);
    return [owner, record, asset].map((value) => value.toLowerCase());
  }
  return {
    close: () => db.close(),
    async subscribeIncoming(owner, onCall, onError, signal) {
      owner = owner.toLowerCase();
      const listeners = incomingListeners.get(owner) ?? new Set();
      const listener = (call) => {
        try {
          onCall(call);
        } catch (error) {
          onError(error);
        }
      };
      incomingListeners.set(owner, listeners);
      listeners.add(listener);
      const stop = () => {
        listeners.delete(listener);
        if (!listeners.size) incomingListeners.delete(owner);
        signal?.removeEventListener('abort', stop);
      };
      signal?.addEventListener('abort', stop, { once: true });
      if (signal?.aborted) stop();
      return stop;
    },
    async subscribeWake(owner, onCall, onError, signal) {
      owner = owner.toLowerCase();
      const listeners = wakeListeners.get(owner) ?? new Set();
      const listener = (call) => {
        try {
          onCall(call);
        } catch (error) {
          onError(error);
        }
      };
      wakeListeners.set(owner, listeners);
      listeners.add(listener);
      const stop = () => {
        listeners.delete(listener);
        if (!listeners.size) wakeListeners.delete(owner);
        signal?.removeEventListener('abort', stop);
      };
      signal?.addEventListener('abort', stop, { once: true });
      if (signal?.aborted) stop();
      return stop;
    },
    async wakeCommand(action, owner = null, p = {}) {
      return transaction(() => {
        if (action === 'authenticate') {
          const principal = get(
            "SELECT b.owner_id,b.contact_id FROM tincall_wake_bridges b JOIN tincall_mcp_roles r USING(owner_id,contact_id) WHERE b.token=? AND r.call_mode='mcp'",
            p.token ?? '',
          );
          return principal ? { ...principal, wake_bridge: true } : null;
        }
        ownerRow(owner);
        if (action === 'list')
          return {
            contacts: all(
              "SELECT contact_id,display_name FROM tincall_mcp_roles WHERE owner_id=? AND call_mode='mcp' ORDER BY created_at,role_id",
              owner,
            ),
          };
        check(action === 'configuration', 'unknown_action');
        check(
          get(
            "SELECT 1 FROM tincall_mcp_roles WHERE owner_id=? AND contact_id=? AND call_mode='mcp'",
            owner,
            p.contact_id,
          ),
          'contact_not_found',
        );
        check(/^tcwake_[0-9a-f]{64}$/.test(p.token), 'invalid_token');
        run(
          'INSERT OR IGNORE INTO tincall_wake_bridges(owner_id,contact_id,token) VALUES (?,?,?)',
          owner,
          p.contact_id,
          p.token,
        );
        if (p.rotate)
          run(
            'UPDATE tincall_wake_bridges SET token=? WHERE owner_id=? AND contact_id=?',
            p.token,
            owner,
            p.contact_id,
          );
        return get(
          'SELECT token FROM tincall_wake_bridges WHERE owner_id=? AND contact_id=?',
          owner,
          p.contact_id,
        );
      });
    },
    async authenticate(token) {
      const configured = (config.clients ?? []).find(
        (client) => client.token === token,
      );
      if (configured)
        return {
          owner_id: configured.owner_id,
          contact_id: configured.contact_id ?? null,
        };
      if (/^tcmcp_[0-9a-f]{64}$/.test(token)) {
        const principal = get(
          'SELECT owner_id,contact_id FROM tincall_mcp_roles WHERE token=?',
          token,
        );
        if (principal) return principal;
      }
      throw new ConnectorError('unauthorized', 401);
    },
    async callPresence(action, owner = null, call = null) {
      return transaction(() => {
        owner = owner?.toLowerCase() ?? null;
        if (action === 'touch') {
          run(
            "UPDATE tincall_calls SET phone_seen_at=? WHERE id=? AND owner_id=? AND status='active'",
            now(),
            call.toLowerCase(),
            owner,
          );
        } else if (action === 'expire') {
          const cutoff = new Date(Date.now() - 180000).toISOString(),
            ringCutoff = new Date(Date.now() - 60000).toISOString();
          const expired = all(
            "SELECT * FROM tincall_calls WHERE ((status='active' AND coalesce(phone_seen_at,created_at)<?) OR (status='ringing' AND created_at<?)) AND (? IS NULL OR owner_id=?)",
            cutoff,
            ringCutoff,
            owner,
            owner,
          );
          for (const c of expired)
            execute(c.owner_id, 'call.end', {
              request_id: randomUUID(),
              call_id: c.id,
              epoch: c.epoch,
              reason: c.status === 'ringing' ? 'missed' : 'phone_disconnected',
            });
        } else throw new ConnectorError('unknown_action');
        return {};
      });
    },
    async removePushDevice(owner, device) {
      run(
        'DELETE FROM tincall_devices WHERE owner_id=? AND id=? AND binding_id=?',
        owner,
        device.device_id,
        device.binding_id,
      );
      return {};
    },
    async resolveCallContext(owner, contact, prefix) {
      if (!/^[0-9a-f]{12}$/.test(prefix))
        throw new ConnectorError('invalid_call_context');
      const rows = all(
        "SELECT id FROM tincall_calls WHERE owner_id=? AND (? IS NULL OR contact_id=?) AND substr(replace(id,'-',''),1,12)=? LIMIT 2",
        owner.toLowerCase(),
        contact,
        contact,
        prefix,
      );
      if (rows.length !== 1)
        throw new ConnectorError('call_context_not_found', 409);
      return { call_id: rows[0].id };
    },
    async oauthCommand(action, p = {}) {
      return transaction(() => {
        const after = (seconds) =>
          new Date(Date.now() + seconds * 1000).toISOString();
        if (action === 'client.create') {
          run('DELETE FROM tincall_oauth_requests WHERE expires_at<=?', now());
          run(
            'DELETE FROM tincall_oauth_grants WHERE refresh_expires_at<=?',
            now(),
          );
          run(
            `DELETE FROM tincall_oauth_clients WHERE created_at<?
          AND NOT EXISTS(SELECT 1 FROM tincall_oauth_requests r WHERE r.client_id=tincall_oauth_clients.client_id)
          AND NOT EXISTS(SELECT 1 FROM tincall_oauth_grants g WHERE g.client_id=tincall_oauth_clients.client_id)`,
            after(-600),
          );
          if (
            get(
              'SELECT count(*) n FROM tincall_oauth_clients WHERE created_at>?',
              after(-60),
            ).n >= 20
          )
            throw new ConnectorError('oauth_limit', 429);
          if (get('SELECT count(*) n FROM tincall_oauth_clients').n >= 1000) {
            run(
              `DELETE FROM tincall_oauth_clients WHERE client_id IN (
            SELECT c.client_id FROM tincall_oauth_clients c WHERE c.created_at<?
              AND NOT EXISTS(SELECT 1 FROM tincall_oauth_requests r WHERE r.client_id=c.client_id)
              AND NOT EXISTS(SELECT 1 FROM tincall_oauth_grants g WHERE g.client_id=c.client_id)
            ORDER BY c.created_at,c.client_id LIMIT 1)`,
              after(-60),
            );
          }
          if (get('SELECT count(*) n FROM tincall_oauth_clients').n >= 1000)
            throw new ConnectorError('oauth_limit', 429);
          insert('oauth_clients', {
            client_id: p.client_id,
            client_name: p.client_name,
            redirect_uris: json(p.redirect_uris),
            created_at: now(),
          });
          return {};
        }
        if (action === 'client.get') {
          const client = get(
            'SELECT * FROM tincall_oauth_clients WHERE client_id=?',
            p.client_id ?? '',
          );
          return client
            ? { ...client, redirect_uris: JSON.parse(client.redirect_uris) }
            : null;
        }
        if (action === 'request.create') {
          run('DELETE FROM tincall_oauth_requests WHERE expires_at<=?', now());
          if (
            get(
              'SELECT count(*) n FROM tincall_oauth_requests WHERE client_id=?',
              p.client_id,
            ).n >= 20
          )
            throw new ConnectorError('oauth_limit', 429);
          insert('oauth_requests', { ...p, expires_at: after(600) });
          return {};
        }
        if (action === 'request.get') {
          const field = 'id' in p ? 'id' : 'code' in p ? 'code' : 'user_code';
          return get(
            `SELECT * FROM tincall_oauth_requests WHERE ${field}=? AND expires_at>?`,
            p[field] ?? '',
            now(),
          );
        }
        if (action === 'request.decide') {
          const changed = run(
            'UPDATE tincall_oauth_requests SET owner_id=?,contact_id=?,denied=?,code=? WHERE user_code=? AND expires_at>? AND code IS NULL AND denied=0',
            p.owner_id,
            p.contact_id,
            Number(p.denied),
            p.denied ? null : p.code,
            p.user_code,
            now(),
          );
          return changed.changes ? {} : null;
        }
        if (action === 'exchange') {
          const q = get(
            'DELETE FROM tincall_oauth_requests WHERE code=? AND client_id=? AND redirect_uri=? AND resource=? AND expires_at>? AND denied=0 RETURNING *',
            p.code,
            p.client_id,
            p.redirect_uri,
            p.resource,
            now(),
          );
          if (
            !q ||
            !get(
              'SELECT 1 FROM tincall_mcp_roles WHERE owner_id=? AND contact_id=?',
              q.owner_id,
              q.contact_id,
            )
          )
            return null;
          run(
            'DELETE FROM tincall_oauth_grants WHERE refresh_expires_at<=?',
            now(),
          );
          insert('oauth_grants', {
            access_token: p.access_token,
            refresh_token: p.refresh_token,
            client_id: q.client_id,
            owner_id: q.owner_id,
            contact_id: q.contact_id,
            resource: q.resource,
            access_expires_at: after(3600),
            refresh_expires_at: after(30 * 86400),
          });
          return {};
        }
        if (action === 'refresh') {
          const changed = run(
            `UPDATE tincall_oauth_grants SET access_token=?,refresh_token=?,access_expires_at=? WHERE refresh_token=? AND client_id=? AND resource=? AND refresh_expires_at>? AND EXISTS(SELECT 1 FROM tincall_mcp_roles r WHERE r.owner_id=tincall_oauth_grants.owner_id AND r.contact_id=tincall_oauth_grants.contact_id)`,
            p.access_token,
            p.next_refresh_token,
            after(3600),
            p.refresh_token,
            p.client_id,
            p.resource,
            now(),
          );
          return changed.changes ? {} : null;
        }
        if (action === 'authenticate')
          return get(
            'SELECT g.owner_id,g.contact_id FROM tincall_oauth_grants g JOIN tincall_mcp_roles r ON r.owner_id=g.owner_id AND r.contact_id=g.contact_id WHERE access_token=? AND resource=? AND access_expires_at>? AND refresh_expires_at>?',
            p.access_token,
            p.resource,
            now(),
            now(),
          );
        if (action === 'revoke') {
          run(
            'DELETE FROM tincall_oauth_grants WHERE client_id=? AND (access_token=? OR refresh_token=?)',
            p.client_id,
            p.token,
            p.token,
          );
          return {};
        }
        throw new ConnectorError('unknown_action');
      });
    },
    async mcpCommand(owner, contact, action, payload = {}) {
      return transaction(() =>
        mcpCommand(owner, contact, action, JSON.parse(json(payload))),
      );
    },
    async command(owner, action, payload = {}) {
      return transaction(() =>
        execute(owner.toLowerCase(), action, JSON.parse(json(payload))),
      );
    },
    async setVoicePrompt(owner, callId, prompt) {
      return transaction(() => {
        ownerRow(owner.toLowerCase());
        check(
          typeof prompt === 'string' && length(prompt) <= 100000,
          'invalid_expression_prompt',
        );
        const changed = run(
          "UPDATE tincall_calls SET tts_expression_prompt=? WHERE id=? AND owner_id=? AND status<>'ended'",
          prompt,
          callId.toLowerCase(),
          owner.toLowerCase(),
        );
        check(changed.changes, 'call_not_found');
        return { ok: true };
      });
    },
    async claimVoiceInstructions(owner, callId) {
      return transaction(() => {
        ownerRow(owner.toLowerCase());
        const claimed = get(
          `UPDATE tincall_calls SET voice_instructions_sent=1 WHERE id=? AND owner_id=? AND status='active' AND voice_instructions_sent=0 RETURNING tts_expression_prompt`,
          callId.toLowerCase(),
          owner.toLowerCase(),
        );
        return {
          voice_instructions: claimed
            ? '你的回复会被实时朗读成语音，请写适合说出口的口语。' +
              (claimed.tts_expression_prompt
                ? '\n' + claimed.tts_expression_prompt
                : '')
            : null,
        };
      });
    },
    async contactMode(owner, action, p = {}) {
      return transaction(() => {
        owner = owner.toLowerCase();
        ownerRow(owner);
        if (action === 'get')
          return {
            call_mode:
              get(
                'SELECT call_mode FROM tincall_mcp_roles WHERE owner_id=? AND contact_id=?',
                owner,
                p.contact_id,
              )?.call_mode ?? null,
          };
        check(action === 'set', 'unknown_action');
        check(
          ['standalone', 'mcp', 'backend'].includes(p.call_mode),
          'invalid_call_mode',
        );
        const saved = get(
          'SELECT * FROM tincall_mcp_roles WHERE owner_id=? AND role_id=?',
          owner,
          p.role_id.toLowerCase(),
        );
        check(saved, 'contact_not_found');
        run(
          'UPDATE tincall_mcp_roles SET call_mode=?,updated_at=? WHERE owner_id=? AND role_id=?',
          p.call_mode,
          now(),
          owner,
          saved.role_id,
        );
        if (p.call_mode !== 'mcp')
          for (const c of all(
            "SELECT * FROM tincall_calls WHERE owner_id=? AND contact_id=? AND source='mcp' AND status='ringing'",
            owner,
            saved.contact_id,
          ))
            execute(owner, 'call.end', {
              request_id: randomUUID(),
              call_id: c.id,
              epoch: c.epoch,
              reason: 'contact_mode_changed',
            });
        return { call_mode: p.call_mode };
      });
    },
    async mcpRoleCommand(owner, action, p = {}) {
      return transaction(() => {
        owner = owner.toLowerCase();
        ownerRow(owner);
        const binding = (row) =>
          row
            ? {
                contact_id: row.contact_id,
                display_name: row.display_name,
                mode: 'tools',
                mcp_wait_timeout_seconds: row.mcp_wait_timeout_seconds,
              }
            : null;
        if (action === 'list')
          return {
            bindings: all(
              'SELECT * FROM tincall_mcp_roles WHERE owner_id=? ORDER BY created_at,role_id',
              owner,
            ).map(binding),
          };
        if (action === 'binding')
          return {
            binding: binding(
              get(
                'SELECT * FROM tincall_mcp_roles WHERE owner_id=? AND contact_id=?',
                owner,
                p.contact_id,
              ),
            ),
          };
        check(action === 'upsert', 'unknown_action');
        check(
          p.mcp_wait_timeout_seconds === undefined ||
            (Number.isInteger(p.mcp_wait_timeout_seconds) &&
              p.mcp_wait_timeout_seconds >= 1 &&
              p.mcp_wait_timeout_seconds <= 130),
          'invalid_mcp_wait_timeout_seconds',
        );
        check(
          UUID.test(p.role_id) &&
            length(p.contact_id?.trim()) >= 1 &&
            length(p.contact_id?.trim()) <= 200 &&
            length(p.display_name?.trim()) >= 1 &&
            length(p.display_name?.trim()) <= 200 &&
            /^tcmcp_[0-9a-f]{64}$/.test(p.token),
          'invalid_role',
        );
        const roleId = p.role_id.toLowerCase();
        let saved = get(
          'SELECT * FROM tincall_mcp_roles WHERE owner_id=? AND role_id=?',
          owner,
          roleId,
        );
        const created = !saved;
        if (saved) {
          check(saved.contact_id === p.contact_id, 'role_identity_conflict');
          run(
            'UPDATE tincall_mcp_roles SET display_name=?,mcp_wait_timeout_seconds=?,updated_at=? WHERE owner_id=? AND role_id=?',
            p.display_name.trim(),
            p.mcp_wait_timeout_seconds ?? saved.mcp_wait_timeout_seconds,
            now(),
            owner,
            roleId,
          );
        } else {
          check(
            !get(
              'SELECT role_id FROM tincall_mcp_roles WHERE owner_id=? AND contact_id=?',
              owner,
              p.contact_id,
            ),
            'role_identity_conflict',
          );
          insert('mcp_roles', {
            owner_id: owner,
            role_id: roleId,
            contact_id: p.contact_id,
            display_name: p.display_name.trim(),
            token: p.token,
            mcp_wait_timeout_seconds: p.mcp_wait_timeout_seconds ?? 120,
            created_at: now(),
            updated_at: now(),
          });
        }
        saved = get(
          'SELECT * FROM tincall_mcp_roles WHERE owner_id=? AND role_id=?',
          owner,
          roleId,
        );
        return {
          role_id: saved.role_id,
          contact_id: saved.contact_id,
          display_name: saved.display_name,
          token: saved.token,
          token_created: created,
          mcp_wait_timeout_seconds: saved.mcp_wait_timeout_seconds,
        };
      });
    },
    async sseCommand(principal, action, p) {
      return transaction(() => {
        const owner = principal.owner_id,
          contact = principal.contact_id ?? null;
        check(UUID.test(p.session_id), 'invalid_session_id');
        const id = p.session_id.toLowerCase();
        if (action === 'open') {
          run('DELETE FROM tincall_mcp_sse WHERE expires_at<=?', now());
          if (
            get(
              'SELECT count(*) AS count FROM tincall_mcp_sse WHERE owner_id=?',
              owner,
            ).count >= 16
          )
            throw new ConnectorError('sse_session_limit', 429);
          insert('mcp_sse', {
            id,
            owner_id: owner,
            contact_id: contact,
            expires_at: new Date(Date.now() + 180000).toISOString(),
          });
          return {};
        }
        const row = get(
          'SELECT * FROM tincall_mcp_sse WHERE id=? AND owner_id=? AND contact_id IS ? AND expires_at>?',
          id,
          owner,
          contact,
          now(),
        );
        if (!row) throw new ConnectorError('sse_session_not_found', 404);
        if (action === 'check') return {};
        let messages = JSON.parse(row.messages);
        if (action === 'read') {
          check(
            Number.isSafeInteger(p.after) &&
              p.after >= row.sequence - messages.length &&
              p.after <= row.sequence,
            'invalid_cursor',
          );
          run(
            'UPDATE tincall_mcp_sse SET messages=?,expires_at=? WHERE id=?',
            json(
              messages.filter(
                (item) => item.sequence > Math.max(0, p.after - 64),
              ),
            ),
            new Date(Date.now() + 180000).toISOString(),
            id,
          );
          return {
            messages: messages.filter((item) => item.sequence > p.after),
          };
        }
        check(action === 'push', 'unknown_action');
        messages.push({ sequence: row.sequence + 1, message: p.message });
        if (
          messages.length > 128 ||
          Buffer.byteLength(json(messages)) > 33554432
        )
          throw new ConnectorError('sse_queue_full', 429);
        run(
          'UPDATE tincall_mcp_sse SET messages=?,sequence=sequence+1 WHERE id=?',
          json(messages),
          id,
        );
        return {};
      });
    },
    async recentCalls(owner, contact, limit) {
      const rows = all(
        `SELECT id AS call_id,created_at AS started_at,ended_at,status,
        CASE WHEN summary IS NOT NULL AND length(trim(summary))>0 THEN 1 ELSE 0 END AS has_summary
        FROM tincall_calls WHERE owner_id=? AND (? IS NULL OR contact_id=?)
        ORDER BY created_at DESC,id DESC LIMIT ?`,
        owner,
        contact,
        contact,
        limit,
      );
      return {
        calls: rows.map((row) => ({
          ...row,
          has_summary: Boolean(row.has_summary),
        })),
      };
    },
    async workerOwners() {
      return transaction(() => {
        const current = new Date();
        const expired = new Date(current.getTime() - 110000).toISOString();
        for (const job of all(
          "SELECT * FROM tincall_jobs WHERE status='running' AND claimed_at<?",
          expired,
        ))
          execute(job.owner_id, 'reply.failed', {
            request_id: randomUUID(),
            call_id: job.call_id,
            reply_id: job.reply_id,
            epoch: job.epoch,
            code: 'worker_expired',
          });
        run(
          "UPDATE tincall_push_jobs SET status='failed',error_code='worker_expired' WHERE status='running' AND claimed_at<?",
          expired,
        );
        for (const schedule of all(
          'SELECT * FROM tincall_schedules WHERE enabled=1 AND next_at<=? ORDER BY next_at LIMIT 20',
          current.toISOString(),
        )) {
          if (
            !get(
              "SELECT id FROM tincall_calls WHERE owner_id=? AND status<>'ended'",
              schedule.owner_id,
            )
          )
            execute(schedule.owner_id, 'call.incoming', {
              request_id: randomUUID(),
              call_id: randomUUID(),
              contact_id: schedule.contact_id,
              source: schedule.source,
            });
          const enabled =
            schedule.repeat_seconds != null || schedule.daily_time != null;
          const next = schedule.daily_time
            ? nextDaily(
                schedule.daily_time,
                schedule.time_zone,
                current,
                schedule.week_day,
              )
            : schedule.repeat_seconds == null
              ? schedule.next_at
              : new Date(
                  current.getTime() + schedule.repeat_seconds * 1000,
                ).toISOString();
          run(
            'UPDATE tincall_schedules SET enabled=?,next_at=? WHERE id=?',
            Number(enabled),
            next,
            schedule.id,
          );
        }
        for (const call of all(
          "SELECT * FROM tincall_calls WHERE status='ringing' AND created_at<?",
          new Date(current.getTime() - 60000).toISOString(),
        ))
          execute(call.owner_id, 'call.end', {
            request_id: randomUUID(),
            call_id: call.id,
            epoch: call.epoch,
            reason: 'missed',
          });
        return all(
          "SELECT owner_id FROM tincall_jobs WHERE status='pending' AND mode='http' UNION SELECT owner_id FROM tincall_push_jobs WHERE status='pending' LIMIT 3",
        ).map((row) => row.owner_id);
      });
    },
    async media(owner, record, asset, request) {
      const key = mediaKey(owner, record, asset);
      const lookup = () =>
        get(
          'SELECT * FROM tincall_media WHERE owner_id=? AND record_id=? AND asset_id=?',
          ...key,
        );
      if (request.method === 'GET') {
        const row = lookup();
        if (!row || row.deleted) throw new ConnectorError('media_not_found', 404);
        // Open before returning the stream so a concurrent delete cannot race it.
        let handle;
        try {
          handle = openSync(join(mediaDirectory, row.file), 'r');
        } catch {
          throw new ConnectorError('media_unavailable', 503);
        }
        return new Response(
          Readable.toWeb(createReadStream('', { fd: handle })),
          {
            headers: {
              'Content-Type': row.content_type,
              'Content-Length': String(row.size),
              'Cache-Control': 'no-store',
            },
          },
        );
      }
      if (request.method === 'DELETE') {
        const row = transaction(() => {
          const row = lookup();
          run(
            'UPDATE tincall_media SET deleted=1 WHERE owner_id=? AND record_id=? AND asset_id=?',
            ...key,
          );
          return row;
        });
        if (row) finishMediaDeletion([row]);
        return Response.json({ ok: true });
      }
      if (request.method !== 'PUT')
        throw new ConnectorError('method_not_allowed', 405);
      const type =
        request.headers.get('content-type') ?? 'application/octet-stream';
      if (!/^(audio\/|image\/|application\/octet-stream$)/.test(type))
        throw new ConnectorError('unsupported_media_type', 415);
      const declared = Number(request.headers.get('content-length') ?? 0);
      const max = 512 * 1024 * 1024;
      if (!Number.isSafeInteger(declared) || declared < 0 || declared > max)
        throw new ConnectorError('media_too_large', 413);
      if (!request.body) throw new ConnectorError('body_required', 400);
      if (lookup()) throw new ConnectorError('media_exists', 409);
      const file = randomUUID();
      const temporary = file + '.upload';
      let size = 0;
      let published = false;
      try {
        await pipeline(
          Readable.fromWeb(request.body),
          new Transform({
            transform(chunk, encoding, callback) {
              size += chunk.length;
              callback(
                size > max ? new ConnectorError('media_too_large', 413) : null,
                chunk,
              );
            },
          }),
          createWriteStream(join(mediaDirectory, temporary), {
            flags: 'wx',
            mode: 0o600,
          }),
          { signal: request.signal },
        );
        transaction(() => {
          if (lookup()) throw new ConnectorError('media_exists', 409);
          const tombstone = get(
            'SELECT deleted FROM tincall_records WHERE owner_id=? AND id=?',
            key[0],
            key[1],
          );
          if (tombstone?.deleted)
            throw new ConnectorError('record_deleted', 410);
          linkSync(join(mediaDirectory, temporary), join(mediaDirectory, file));
          published = true;
          insert('media', {
            owner_id: key[0],
            record_id: key[1],
            asset_id: key[2],
            content_type: type,
            size,
            file,
          });
        });
      } catch (error) {
        if (published) removeFile(file);
        if (error instanceof ConnectorError) throw error;
        throw new ConnectorError('media_unavailable', 503);
      } finally {
        removeFile(temporary);
      }
      return Response.json({ ok: true });
    },
    async deleteRecordMedia(owner, record, preserve = []) {
      if (![owner, record].every((value) => UUID.test(value)))
        throw new ConnectorError('invalid_media_path', 400);
      let rows;
      try {
        rows = transaction(() => {
          const rows = all(
            'SELECT * FROM tincall_media WHERE owner_id=? AND record_id=? AND (deleted=1 OR asset_id NOT IN (SELECT value FROM json_each(?))) LIMIT 300',
            owner.toLowerCase(),
            record.toLowerCase(),
            json(preserve.map((id) => id.toLowerCase())),
          );
          for (const row of rows) {
            run(
              'UPDATE tincall_media SET deleted=1 WHERE owner_id=? AND record_id=? AND asset_id=?',
              row.owner_id,
              row.record_id,
              row.asset_id,
            );
          }
          return rows;
        });
      } catch {
        throw new ConnectorError('media_cleanup_failed', 503);
      }
      finishMediaDeletion(rows);
      // Match the bounded three-page Supabase cleanup contract.
      if (rows.length === 300) throw new ConnectorError('media_cleanup_pending', 503);
    },
  };
}
