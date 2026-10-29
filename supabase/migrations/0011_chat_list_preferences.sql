-- MailChat — 0011 per-user chat list preferences
-- Favourite and pin status belongs to the member, not the shared conversation.
-- The view appends columns only so existing clients can keep reading old fields.

alter table public.conversation_members
  add column if not exists is_favorite boolean not null default false,
  add column if not exists is_pinned boolean not null default false;

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
  c.updated_at             as updated_at,
  m.is_favorite            as is_favorite,
  m.is_pinned              as is_pinned
from public.conversation_members m
join public.conversations c on c.id = m.conversation_id
left join lateral (
  select msg.text, msg.created_at, msg.sender_id
  from public.messages msg
  where msg.conversation_id = c.id
    and msg.deleted_at is null
  order by msg.created_at desc
  limit 1
) last_msg on true
left join lateral (
  select rm.created_at
  from public.messages rm
  where rm.id = m.last_read_message_id
) last_read on true
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
