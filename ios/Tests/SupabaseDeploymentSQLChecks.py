"""Run production transactions exported by SupabaseDeploymentChecks in local PostgreSQL.

Usage: SupabaseDeploymentChecks REPO_ROOT SQL_DIRECTORY
       python3 ios/Tests/SupabaseDeploymentSQLChecks.py SQL_DIRECTORY
Requires Docker and the locally available postgres:18-alpine image; no hosted project access.
"""
from pathlib import Path
import subprocess
import sys
import time

transactions = Path(sys.argv[1])
container = "tincall-deployment-sql-check"
versions = ["202610110001", "202610110002", "202610140001", "202610160001",
            "202610180001", "202610190001", "202610190002", "202610200001", "202610200002", "202610200003", "202610200004", "202610200005", "202610200006", "202610210001", "202610210002", "202610210003", "202610220001", "202610220002", "202610250001"]


def sql(source, succeeds=True):
    result = subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-X", "-q", "-A", "-t",
         "-v", "ON_ERROR_STOP=1", "-U", "postgres"],
        input=source, text=True, capture_output=True)
    if succeeds and result.returncode:
        raise AssertionError(result.stderr)
    if not succeeds:
        assert result.returncode and "tincall_install_conflict" in result.stderr, result.stderr
    return result.stdout.strip()


try:
    subprocess.run(["docker", "run", "--rm", "-d", "--name", container,
                    "-e", "POSTGRES_HOST_AUTH_METHOD=trust", "postgres:18-alpine"],
                   check=True, stdout=subprocess.DEVNULL)
    for _ in range(80):
        if subprocess.run(["docker", "exec", container, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            break
        time.sleep(.25)
    # Only platform-owned Auth/Storage/Realtime objects are test substitutes.
    # Every Tincall table, function, guard and migration transaction is production SQL.
    sql("""
    create role anon; create role authenticated; create role service_role;
    create schema auth; create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql as $$select null::uuid$$;
    create function auth.role() returns text language sql as $$select 'service_role'::text$$;
    create schema storage;
    create table storage.buckets(id text primary key,name text,public boolean);
    create table storage.objects(bucket_id text,name text);
    create function storage.foldername(text) returns text[] language sql as $$select string_to_array($1,'/')$$;
    create schema realtime;
    create function realtime.send(jsonb,text,text,boolean) returns void language sql as $$select$$;
    """)
    sql((transactions / (versions[0] + ".sql")).read_text())
    # Cron's extensions are supplied by Supabase and are outside this migration test.
    sql("insert into supabase_migrations.schema_migrations(version,name) values('202610110002','tincall_cron');")
    for version in versions[2:7]:
        sql((transactions / (version + ".sql")).read_text())
    sql("""
    insert into auth.users values('10000000-0000-4000-8000-000000000001');
    insert into public.tincall_schedules(id,owner_id,contact_id,source,next_at,daily_time,time_zone)
      values('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',
             'synthetic-contact','independent','2030-01-01 08:00:00+00','08:00','UTC');
    """)
    original = sql("select row_to_json(s)::text from public.tincall_schedules s;")
    for version in versions[7:]:
        if version == "202610250001":
            sql("""
            insert into public.tincall_mcp_roles(owner_id,role_id,contact_id,display_name,token)
              values('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002',
                'synthetic-wait-upgrade','Synthetic wait upgrade','tcmcp_'||repeat('d',64));
            """)
        source = (transactions / (version + ".sql")).read_text()
        sql(source)
        sql(source)  # A committed migration must safely resume after a lost response.
    assert sql("select count(*) from supabase_migrations.schema_migrations;") == str(len(versions))
    assert sql("select (to_jsonb(s)-'week_day')::text from public.tincall_schedules s;") == sql(
        "select '" + original.replace("'", "''") + "'::jsonb::text;")
    assert sql("select week_day is null from public.tincall_schedules;") == "t"
    assert sql("select mcp_wait_timeout_seconds=120 and token='tcmcp_'||repeat('d',64) from public.tincall_mcp_roles where contact_id='synthetic-wait-upgrade';") == "t"
    print("PASS: MCP wait preference migration preserves existing identities and credentials with a 120-second default")
    assert sql("select has_function_privilege('authenticated','public.tincall_command(text,jsonb,uuid)','execute');") == "f"
    assert sql("select has_function_privilege('service_role','public.tincall_command(text,jsonb,uuid)','execute');") == "t"
    assert sql("select has_table_privilege('authenticated','public.tincall_calls','select');") == "f"
    footprint = (transactions / "footprint.sql").read_text().strip().rstrip(";")
    assert sql("select exposed_tables from (" + footprint + ") f;") == "f"
    sql("grant select on public.tincall_calls to anon;")
    assert sql("select exposed_tables from (" + footprint + ") f;") == "t"
    sql("revoke select on public.tincall_calls from anon;")
    print("PASS: production deployment inspection detects restored table grants while RLS remains enabled")
    print("PASS: real seven-migration installation upgrades through the current migration, retries safely, and preserves the saved schedule")
    assert sql("select count(*) from storage.buckets where id='tincall-private' and not public;") == "1"
    assert sql("select count(*) from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'tincall_media_%';") == "0"
    assert sql("select has_function_privilege('authenticated','public.tincall_image_command(text,jsonb,uuid)','execute');") == "f"
    assert sql("select has_function_privilege('service_role','public.tincall_image_command(text,jsonb,uuid)','execute');") == "t"
    sql("""
    select public.tincall_command('call.create',jsonb_build_object('request_id',gen_random_uuid(),
      'call_id','30000000-0000-4000-8000-000000000005','contact_id','synthetic-image-upgrade','source','mcp'),
      '10000000-0000-4000-8000-000000000001');
    select public.tincall_image_command('call.input',jsonb_build_object('request_id',gen_random_uuid(),
      'call_id','30000000-0000-4000-8000-000000000005','message_id','50000000-0000-4000-8000-000000000001',
      'epoch',0,'text','','mode','tools','images','[{"id":"60000000-0000-4000-8000-000000000001","mime_type":"image/png","bytes":4}]'::jsonb),
      '10000000-0000-4000-8000-000000000001');
    select public.tincall_command('record.put',jsonb_build_object('request_id',gen_random_uuid(),
      'record_id','30000000-0000-4000-8000-000000000005','expected_revision',0,
      'record','{"media":[{"object_id":"70000000-0000-4000-8000-000000000001","mime_type":"audio/wav"}]}'::jsonb),
      '10000000-0000-4000-8000-000000000001');
    insert into storage.objects(bucket_id,name) values('tincall-private',
      '10000000-0000-4000-8000-000000000001/30000000-0000-4000-8000-000000000005/70000000-0000-4000-8000-000000000001');
    """)
    image_before = sql("select jsonb_build_object('text',text,'images',images)::text from public.tincall_messages where id='50000000-0000-4000-8000-000000000001';")
    recording_before = sql("select row_to_json(r)::text from public.tincall_records r where id='30000000-0000-4000-8000-000000000005';")
    objects_before = sql("select json_agg(o)::text from storage.objects o;")
    # A legacy installation has the image SQL and data but no tracked image version.
    sql("delete from supabase_migrations.schema_migrations where version='202610210003';")
    sql((transactions / "202610210003.sql").read_text())
    sql((transactions / "202610210003.sql").read_text())
    assert sql("select jsonb_build_object('text',text,'images',images)::text from public.tincall_messages where id='50000000-0000-4000-8000-000000000001';") == image_before
    assert sql("select text='' and jsonb_array_length(images)=1 from public.tincall_messages where id='50000000-0000-4000-8000-000000000001';") == "t"
    assert sql("select row_to_json(r)::text from public.tincall_records r where id='30000000-0000-4000-8000-000000000005';") == recording_before
    assert sql("select json_agg(o)::text from storage.objects o;") == objects_before
    sql("""
    select public.tincall_command('call.end',jsonb_build_object('request_id',gen_random_uuid(),
      'call_id','30000000-0000-4000-8000-000000000005','epoch',1),'10000000-0000-4000-8000-000000000001');
    select public.tincall_image_command('record.delete',jsonb_build_object('request_id',gen_random_uuid(),
      'record_id','30000000-0000-4000-8000-000000000005','expected_revision',1),'10000000-0000-4000-8000-000000000001');
    """)
    assert sql("select deleted from public.tincall_records where id='30000000-0000-4000-8000-000000000005';") == "t"
    assert sql("select images is null from public.tincall_messages where id='50000000-0000-4000-8000-000000000001';") == "t"
    print("PASS: image-only input and backup deletion work; adopting manual SQL preserves images, recording manifests and private Storage objects")
    sql("""
    insert into public.tincall_calls(id,owner_id,contact_id,source,status,created_at,phone_seen_at)
      values('30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',
        'synthetic-abandoned','mcp','active',now()-interval '1 hour',now()-interval '4 minutes');
    select public.tincall_call_presence('expire');
    """)
    assert sql("select status from public.tincall_calls where id='30000000-0000-4000-8000-000000000001';") == "ended"
    assert sql("select payload->>'reason' from public.tincall_events where call_id='30000000-0000-4000-8000-000000000001' and type='call.ended';") == "phone_disconnected"
    sql("""
    insert into public.tincall_calls(id,owner_id,contact_id,source,status,created_at,phone_seen_at)
      values('30000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',
        'synthetic-connected','mcp','active',now()-interval '1 hour',now()-interval '4 minutes');
    select public.tincall_call_presence('touch','10000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002');
    select public.tincall_call_presence('expire');
    """)
    assert sql("select status from public.tincall_calls where id='30000000-0000-4000-8000-000000000002';") == "active"
    assert sql("select has_table_privilege('authenticated','public.tincall_oauth_grants','select');") == "f"
    assert sql("select has_function_privilege('authenticated','public.tincall_oauth(text,jsonb)','execute');") == "f"
    print("PASS: PostgreSQL reclaims a disconnected call, preserves a connected old call and keeps OAuth credentials service-only")
    sql("""
    select public.tincall_command('call.end',jsonb_build_object('request_id',gen_random_uuid(),'call_id','30000000-0000-4000-8000-000000000002','epoch',0),'10000000-0000-4000-8000-000000000001');
    select public.tincall_mcp_role('upsert','10000000-0000-4000-8000-000000000001',
      jsonb_build_object('role_id','40000000-0000-4000-8000-000000000001','contact_id','synthetic-mode-contact','display_name','Fixture','token','tcmcp_'||repeat('a',64)));
    select public.tincall_command('call.incoming',jsonb_build_object('request_id',gen_random_uuid(),'call_id','30000000-0000-4000-8000-000000000003','contact_id','synthetic-mode-contact','source','mcp'),'10000000-0000-4000-8000-000000000001');
    select public.tincall_contact_mode('set','10000000-0000-4000-8000-000000000001','{"role_id":"40000000-0000-4000-8000-000000000001","call_mode":"standalone"}');
    """)
    assert sql("select public.tincall_contact_mode('get','10000000-0000-4000-8000-000000000001','{\"contact_id\":\"synthetic-mode-contact\"}')->>'call_mode';") == "standalone"
    assert sql("select status from public.tincall_calls where id='30000000-0000-4000-8000-000000000003';") == "ended"
    assert sql("select payload->>'reason' from public.tincall_events where call_id='30000000-0000-4000-8000-000000000003' and type='call.ended';") == "contact_mode_changed"
    assert sql("select public.tincall_mcp_authenticate('tcmcp_'||repeat('a',64))->>'contact_id';") == "synthetic-mode-contact"
    assert sql("select has_function_privilege('authenticated','public.tincall_contact_mode(text,uuid,jsonb)','execute');") == "f"
    print("PASS: PostgreSQL persists standalone mode, releases its old MCP ring, preserves its identity and restricts mode writes")
    sql("""
    select public.tincall_contact_mode('set','10000000-0000-4000-8000-000000000001','{"role_id":"40000000-0000-4000-8000-000000000001","call_mode":"mcp"}');
    select public.tincall_wake_bridge('configuration','10000000-0000-4000-8000-000000000001',
      jsonb_build_object('contact_id','synthetic-mode-contact','token','tcwake_'||repeat('b',64)));
    """)
    assert sql("select public.tincall_wake_bridge('authenticate',null,jsonb_build_object('token','tcwake_'||repeat('b',64)))->>'contact_id';") == "synthetic-mode-contact"
    assert sql("select public.tincall_wake_bridge('configuration','10000000-0000-4000-8000-000000000001',jsonb_build_object('contact_id','synthetic-mode-contact','token','tcwake_'||repeat('c',64)))->>'token';") == "tcwake_" + "b" * 64
    sql("select public.tincall_wake_bridge('configuration','10000000-0000-4000-8000-000000000001',jsonb_build_object('contact_id','synthetic-mode-contact','token','tcwake_'||repeat('c',64),'rotate',true));")
    assert sql("select public.tincall_wake_bridge('authenticate',null,jsonb_build_object('token','tcwake_'||repeat('b',64))) is null;") == "t"
    assert sql("select has_table_privilege('authenticated','public.tincall_wake_bridges','select');") == "f"
    assert sql("select has_function_privilege('authenticated','public.tincall_wake_bridge(text,uuid,jsonb)','execute');") == "f"
    sql("""
    create table public.synthetic_wake_events(payload jsonb,event text,topic text,private boolean);
    create or replace function realtime.send(jsonb,text,text,boolean) returns void language sql as
      $$insert into public.synthetic_wake_events values($1,$2,$3,$4)$$;
    select public.tincall_command('call.create',jsonb_build_object('request_id',gen_random_uuid(),'call_id','30000000-0000-4000-8000-000000000004','contact_id','synthetic-mode-contact','source','mcp'),'10000000-0000-4000-8000-000000000001');
    select public.tincall_mcp('open','10000000-0000-4000-8000-000000000001','synthetic-mode-contact','{"call_id":"30000000-0000-4000-8000-000000000004"}');
    select public.tincall_command('call.input',jsonb_build_object('request_id',gen_random_uuid(),'call_id','30000000-0000-4000-8000-000000000004','message_id',gen_random_uuid(),'epoch',0,'text','synthetic private input','mode','tools'),'10000000-0000-4000-8000-000000000001');
    """)
    assert sql("select count(*) from public.synthetic_wake_events where event='wake';") == "2"
    assert sql("select bool_and(private and topic='tincall:wake:10000000-0000-4000-8000-000000000001' and not(payload::text like '%synthetic private input%')) from public.synthetic_wake_events where event='wake';") == "t"
    assert sql("select count(*) from jsonb_object_keys((select payload->'call' from public.synthetic_wake_events where event='wake' limit 1));") == "6"
    print("PASS: wake bridge credentials persist and rotate privately; opening and each input broadcast metadata-only wake events")
    sql("delete from supabase_migrations.schema_migrations where version='202610200001';")
    sql((transactions / "202610200001.sql").read_text(), succeeds=False)
    assert sql("select count(*) from public.tincall_schedules;") == "1"
    assert sql("select count(*) from supabase_migrations.schema_migrations where version='202610200001';") == "0"
    print("PASS: an untracked existing schedule migration still stops without changing data or claiming its version")
finally:
    subprocess.run(["docker", "rm", "-f", container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
