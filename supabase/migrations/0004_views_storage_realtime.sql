-- ============================================================================
-- MailChat — 0004 conversation_list view, storage buckets, realtime
-- ----------------------------------------------------------------------------
-- The view powers the chat list screen. Postgres views run with the
-- privileges of the owner by default, which would bypass RLS — so this view is
-- declared `security_invoker` (Postgres 15+) so the caller's RLS applies.
-- ============================================================================

create or replace view public.conversation_list
with (security_invoker = true)
as
select
  c.id                     as conversation_id,
  m.user_id                as user_id,
  c.id                     as id,
  jsonb_build_object(
    'id', c.id,
    'type', c.type,
    'name', c.name,
    'description', c.description,
    'avatar_path', c.avatar_path,
    'created_by', c.created_by,
    'created_at', c.created_at,
    'updated_at', c.updated_at
  )                        as conversation,
  last_msg.text            as last_message_text,
  last_msg.created_at      as last_message_at,
  last_msg.sender_id       as last_message_sender_id,
  (
    select count(*)
    from public.messages um
    where um.conversation_id = c.id
      and um.created_at > coalesce(last_read.created_at, '-infinity'::timestamptz)
      and um.sender_id <> m.user_id
      and um.deleted_at is null
  )                        as unread_count,
  m.notifications_muted    as is_muted,
  other_profile            as other_participant,
  -- Tie-breaker for the chat list's ORDER BY. Postgres allows CREATE OR REPLACE
  -- VIEW to append columns only, so this must stay last.
  c.updated_at             as updated_at
from public.conversation_members m
join public.conversations c on c.id = m.conversation_id

-- Last visible message per conversation.
left join lateral (
  select msg.text, msg.created_at, msg.sender_id
  from public.messages msg
  where msg.conversation_id = c.id
    and msg.deleted_at is null
  order by msg.created_at desc
  limit 1
) last_msg on true

-- The read cursor row (so unread_count can compare timestamps).
left join lateral (
  select rm.created_at
  from public.messages rm
  where rm.id = m.last_read_message_id
) last_read on true

-- The other participant for direct conversations (null for groups).
left join lateral (
  select jsonb_build_object(
    'id', p.id,
    'username', p.username,
    'display_name', p.display_name,
    'avatar_path', p.avatar_path,
    'bio', p.bio,
    'created_at', p.created_at,
    'updated_at', p.updated_at
  ) as other_profile
  from public.conversation_members om
  join public.profiles p on p.id = om.user_id
  where om.conversation_id = c.id
    and om.user_id <> m.user_id
    and c.type = 'direct'
  limit 1
) other on true

where c.type = 'group' or other.other_profile is not null;

grant select on public.conversation_list to authenticated;

-- ============================================================================
-- Storage buckets
-- Private buckets; access is granted through signed URLs issued after the RLS
-- policy below confirms the caller may read the object.
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', false), ('attachments', 'attachments', false)
on conflict (id) do nothing;

-- Avatars: any authenticated user can read; users write only their own folder.
drop policy if exists avatars_read on storage.objects;
create policy avatars_read on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars');

drop policy if exists avatars_write_own on storage.objects;
create policy avatars_write_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists avatars_update_own on storage.objects;
create policy avatars_update_own on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Attachments: path layout is attachments/<conversation_id>/<file>.
-- Only members of that conversation may read or upload.
drop policy if exists attachments_read_member on storage.objects;
create policy attachments_read_member on storage.objects
  for select to authenticated
  using (
    bucket_id = 'attachments'
    and public.is_conversation_member(
      nullif((storage.foldername(name))[1], '')::uuid
    )
  );

drop policy if exists attachments_write_member on storage.objects;
create policy attachments_write_member on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'attachments'
    and public.is_conversation_member(
      nullif((storage.foldername(name))[1], '')::uuid
    )
  );

-- ============================================================================
-- Realtime
-- Broadcast message changes to subscribed clients. RLS still applies to the
-- rows Postgres changes deliver.
-- ============================================================================
-- Adding a table that is already published raises 42710, so each is checked
-- first. Realtime delivery depends on this: without the publication, subscribed
-- clients never receive row changes.
do $$
declare
  t text;
begin
  foreach t in array array[
    'messages', 'message_reactions', 'message_receipts', 'conversation_members'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
exception
  when others then
    -- A missing publication (42704), or a project where the caller may not
    -- alter it. Neither should abort the migration: the schema is the point,
    -- realtime is an add-on. The notice names the exact cause.
    raise notice 'realtime publication not updated: % (%)', sqlerrm, sqlstate;
end $$;

-- Needed so DELETE events carry the old row identity.
alter table public.messages replica identity full;
