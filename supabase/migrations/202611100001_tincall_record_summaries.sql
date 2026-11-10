-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- Compact per-record facts for the backup list and storage usage. Bodies stay in
-- record.get; this returns only the contact name, start time and media counts/bytes.
create function public.tincall_record_summaries(p_owner uuid, p_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception using errcode='42501',message='forbidden';
  end if;
  if p_owner is null then raise exception using errcode='42501',message='unauthorized'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id,
      'role_name', case when jsonb_typeof(r.record->'call'->'roleName')='string' then r.record->'call'->>'roleName' end,
      'started_at', case when jsonb_typeof(r.record->'call'->'startedAt')='number' then r.record->'call'->'startedAt' end,
      'audio_count', a.items, 'audio_bytes', a.bytes,
      'image_count', i.items, 'image_bytes', i.bytes) order by r.id), '[]')
    into result
    from public.tincall_records r
    cross join lateral (
      select count(*) as items,
             coalesce(sum(case when jsonb_typeof(m->'bytes')='number' then (m->>'bytes')::numeric else 0 end),0)::bigint as bytes
        from jsonb_array_elements(case when jsonb_typeof(r.record->'media')='array' then r.record->'media' else '[]'::jsonb end) m) a
    cross join lateral (
      select count(*) as items,
             coalesce(sum(case when jsonb_typeof(x->'bytes')='number' then (x->>'bytes')::numeric else 0 end),0)::bigint as bytes
        from jsonb_array_elements(case when jsonb_typeof(coalesce(r.record->'call'->'messages', r.record->'messages'))='array'
                                       then coalesce(r.record->'call'->'messages', r.record->'messages') else '[]'::jsonb end) msg
        cross join lateral jsonb_array_elements(case when jsonb_typeof(msg->'images')='array' then msg->'images' else '[]'::jsonb end) x) i
   where r.owner_id=p_owner and not r.deleted and r.record is not null
     and (p_ids is null or r.id = any(p_ids));
  return result;
end $$;
revoke all on function public.tincall_record_summaries(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.tincall_record_summaries(uuid,uuid[]) to service_role;
