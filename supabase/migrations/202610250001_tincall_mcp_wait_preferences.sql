-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- Per-contact tool suspension. Existing identities and credentials are retained.
alter table public.tincall_mcp_roles add column mcp_wait_timeout_seconds integer not null default 120
  check (mcp_wait_timeout_seconds between 1 and 130);

create or replace function public.tincall_mcp_role(p_action text, p_owner uuid, p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  saved public.tincall_mcp_roles;
  rid uuid;
  cid text;
  name_value text;
  wait_seconds integer;
  created boolean := false;
  result jsonb;
begin
  -- Only the connector may call this after authenticating the phone credential.
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception using errcode='42501', message='forbidden';
  end if;
  if p_owner is null then raise exception using errcode='42501', message='unauthorized'; end if;
  if p_action = 'list' then
    select coalesce(jsonb_agg(jsonb_build_object('contact_id',contact_id,
      'display_name',display_name,'mode','tools','mcp_wait_timeout_seconds',mcp_wait_timeout_seconds) order by created_at,role_id),'[]')
      into result from public.tincall_mcp_roles where owner_id=p_owner;
    return jsonb_build_object('bindings',result);
  elsif p_action = 'binding' then
    select * into saved from public.tincall_mcp_roles
      where owner_id=p_owner and contact_id=p_payload->>'contact_id';
    return jsonb_build_object('binding',case when saved.role_id is null then null else
      jsonb_build_object('contact_id',saved.contact_id,'display_name',saved.display_name,'mode','tools','mcp_wait_timeout_seconds',saved.mcp_wait_timeout_seconds) end);
  elsif p_action <> 'upsert' then
    raise exception using errcode='22023', message='unknown_action';
  end if;

  if p_payload ? 'mcp_wait_timeout_seconds' then
    if jsonb_typeof(p_payload->'mcp_wait_timeout_seconds') <> 'number'
      or (p_payload->>'mcp_wait_timeout_seconds')::numeric not between 1 and 130
      or trunc((p_payload->>'mcp_wait_timeout_seconds')::numeric) <> (p_payload->>'mcp_wait_timeout_seconds')::numeric then
      raise exception using errcode='22023', message='invalid_mcp_wait_timeout_seconds';
    end if;
    wait_seconds := (p_payload->>'mcp_wait_timeout_seconds')::numeric::integer;
  end if;
  rid := (p_payload->>'role_id')::uuid;
  cid := p_payload->>'contact_id';
  name_value := trim(p_payload->>'display_name');
  if rid is null or cid is null or length(trim(cid)) not between 1 and 200
    or name_value is null or length(name_value) not between 1 and 200
    or coalesce(p_payload->>'token','') !~ '^tcmcp_[0-9a-f]{64}$' then
    raise exception using errcode='22023', message='invalid_role';
  end if;

  -- Serialize concurrent first saves and renames, using the existing owner lock.
  insert into public.tincall_owners(owner_id) values(p_owner) on conflict do nothing;
  perform 1 from public.tincall_owners where owner_id=p_owner for update;
  select * into saved from public.tincall_mcp_roles where owner_id=p_owner and role_id=rid;
  if saved.role_id is not null then
    if saved.contact_id <> cid then
      raise exception using errcode='P0001', message='role_identity_conflict';
    end if;
    update public.tincall_mcp_roles set display_name=name_value,mcp_wait_timeout_seconds=coalesce(wait_seconds,saved.mcp_wait_timeout_seconds),updated_at=clock_timestamp()
      where owner_id=p_owner and role_id=rid returning * into saved;
  else
    if exists(select 1 from public.tincall_mcp_roles where owner_id=p_owner and contact_id=cid) then
      raise exception using errcode='P0001', message='role_identity_conflict';
    end if;
    insert into public.tincall_mcp_roles(owner_id,role_id,contact_id,display_name,token,mcp_wait_timeout_seconds)
      values(p_owner,rid,cid,name_value,p_payload->>'token',coalesce(wait_seconds,120)) returning * into saved;
    created := true;
  end if;
  return jsonb_build_object('role_id',saved.role_id,'contact_id',saved.contact_id,
    'display_name',saved.display_name,'token',saved.token,'token_created',created,
    'mcp_wait_timeout_seconds',saved.mcp_wait_timeout_seconds);
end $$;
revoke all on function public.tincall_mcp_role(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.tincall_mcp_role(text,uuid,jsonb) to service_role;

