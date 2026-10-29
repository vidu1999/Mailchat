-- Durable per-account notification inbox and realtime event generation.
-- Android OS/background push is provided separately by the trusted FCM Edge
-- Function; Firebase credentials never belong in the mobile app.

alter table public.notification_preferences
  add column if not exists calls_enabled boolean not null default true,
  add column if not exists system_enabled boolean not null default true;

create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  conversation_id uuid references public.conversations(id) on delete cascade,
  message_id uuid references public.messages(id) on delete cascade,
  call_id uuid references public.calls(id) on delete cascade,
  notification_type text not null check (notification_type in ('message','missed_call','system')),
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint user_notifications_event_target check (
    (notification_type = 'message' and message_id is not null and conversation_id is not null and call_id is null)
    or (notification_type = 'system' and conversation_id is not null and call_id is null)
    or (notification_type = 'missed_call' and call_id is not null and message_id is null)
  )
);
create index if not exists user_notifications_user_created_idx
  on public.user_notifications(user_id, created_at desc);
create index if not exists user_notifications_unread_idx
  on public.user_notifications(user_id, created_at desc) where read_at is null;
create unique index if not exists user_notifications_message_once_idx
  on public.user_notifications(user_id, message_id) where message_id is not null;
create unique index if not exists user_notifications_call_once_idx
  on public.user_notifications(user_id, call_id) where call_id is not null;

alter table public.user_notifications enable row level security;
drop policy if exists user_notifications_select_own on public.user_notifications;
create policy user_notifications_select_own on public.user_notifications
  for select to authenticated using (user_id = auth.uid());
drop policy if exists user_notifications_update_own on public.user_notifications;
create policy user_notifications_update_own on public.user_notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists user_notifications_delete_own on public.user_notifications;
create policy user_notifications_delete_own on public.user_notifications
  for delete to authenticated using (user_id = auth.uid());
revoke update on public.user_notifications from authenticated;
grant select, delete on public.user_notifications to authenticated;
grant update (read_at) on public.user_notifications to authenticated;

create or replace function public.create_message_notifications()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  convo public.conversations%rowtype;
  actor_name text;
  notification_kind text;
  notification_title text;
  notification_body text;
  target record;
begin
  select * into convo from public.conversations where id = new.conversation_id;
  select coalesce(nullif(p.display_name, ''), 'MailChat user') into actor_name
    from public.profiles p where p.id = new.sender_id;
  if new.type = 'system' then
    notification_kind := 'system';
    notification_title := coalesce(nullif(convo.name, ''), 'System update');
    notification_body := left(coalesce(nullif(new.text, ''), 'A conversation update occurred'), 240);
  else
    notification_kind := 'message';
    notification_title := coalesce(actor_name, 'New message');
    notification_body := case new.type
      when 'image' then 'Photo'
      when 'video' then 'Video'
      when 'audio' then 'Audio'
      when 'voice' then 'Voice message'
      when 'file' then 'File'
      else left(coalesce(new.text, 'New message'), 240)
    end;
  end if;

  for target in
    select cm.user_id,
      cm.notifications_muted as member_muted,
      cm.muted_until as member_muted_until,
      coalesce(pc.muted, pg.muted, false) as preference_muted,
      coalesce(pc.muted_until, pg.muted_until) as preference_muted_until,
      case when new.type = 'system'
        then coalesce(pc.system_enabled, pg.system_enabled, true)
        else coalesce(pc.messages_enabled, pg.messages_enabled, true)
      end as enabled
    from public.conversation_members cm
    left join public.notification_preferences pg
      on pg.user_id = cm.user_id and pg.conversation_id is null
    left join public.notification_preferences pc
      on pc.user_id = cm.user_id and pc.conversation_id = new.conversation_id
    where cm.conversation_id = new.conversation_id and cm.user_id <> new.sender_id
  loop
    if target.enabled
      and not target.member_muted
      and (target.member_muted_until is null or target.member_muted_until <= now())
      and not target.preference_muted
      and (target.preference_muted_until is null or target.preference_muted_until <= now()) then
      insert into public.user_notifications
        (user_id, actor_id, conversation_id, message_id, notification_type, title, body, payload)
      values
        (target.user_id, new.sender_id, new.conversation_id, new.id, notification_kind,
         notification_title, notification_body,
         jsonb_build_object('conversationId', new.conversation_id,
           'conversationType', convo.type, 'conversationName', convo.name,
           'messageId', new.id, 'actorId', new.sender_id));
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists messages_create_notifications on public.messages;
create trigger messages_create_notifications after insert on public.messages
  for each row execute function public.create_message_notifications();

-- Group membership changes are system events even when the product has not
-- inserted a visible system chat message for the change.
create or replace function public.create_membership_notifications()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  conversation uuid;
  changed_user uuid;
  actor uuid := auth.uid();
  changed_name text;
  convo_name text;
  event_body text;
  target record;
begin
  if tg_op = 'INSERT' then
    conversation := new.conversation_id;
    changed_user := new.user_id;
    event_body := 'joined the group';
  else
    conversation := old.conversation_id;
    changed_user := old.user_id;
    event_body := 'left the group';
  end if;
  if not exists (select 1 from public.conversations where id = conversation) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  select coalesce(nullif(display_name, ''), 'A member') into changed_name
    from public.profiles where id = changed_user;
  changed_name := coalesce(changed_name, 'A member');
  select coalesce(nullif(name, ''), 'Group update') into convo_name
    from public.conversations where id = conversation;

  for target in
    select cm.user_id, cm.notifications_muted, cm.muted_until,
      coalesce(pc.muted, pg.muted, false) as pref_muted,
      coalesce(pc.muted_until, pg.muted_until) as pref_muted_until,
      coalesce(pc.system_enabled, pg.system_enabled, true) as enabled
    from public.conversation_members cm
    left join public.notification_preferences pg
      on pg.user_id=cm.user_id and pg.conversation_id is null
    left join public.notification_preferences pc
      on pc.user_id=cm.user_id and pc.conversation_id=conversation
    where cm.conversation_id=conversation
      and (actor is null or cm.user_id <> actor)
  loop
    if target.enabled and not target.notifications_muted
      and (target.muted_until is null or target.muted_until <= now())
      and not target.pref_muted
      and (target.pref_muted_until is null or target.pref_muted_until <= now()) then
      insert into public.user_notifications
        (user_id, actor_id, conversation_id, notification_type, title, body, payload)
      values (target.user_id, actor, conversation, 'system', convo_name,
        changed_name || ' ' || event_body,
        jsonb_build_object('conversationId', conversation,
          'conversationType', 'group', 'conversationName', convo_name,
          'event', case when tg_op = 'INSERT' then 'member_joined' else 'member_left' end,
          'memberId', changed_user, 'actorId', actor));
    end if;
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
drop trigger if exists conversation_members_create_notifications on public.conversation_members;
create trigger conversation_members_create_notifications
  after insert or delete on public.conversation_members
  for each row execute function public.create_membership_notifications();

create or replace function public.create_missed_call_notifications()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  recipient uuid;
  actor uuid;
  actor_name text;
  target_name text;
  recipient_enabled boolean;
  recipient_muted boolean;
begin
  if new.status <> 'missed' or old.status = 'missed' then return new; end if;
  foreach recipient in array array[new.callee_id, new.caller_id] loop
    if recipient = new.callee_id then actor := new.caller_id; else actor := new.callee_id; end if;
    select coalesce(nullif(display_name, ''), 'MailChat user') into actor_name
      from public.profiles where id = actor;
    select coalesce(nullif(display_name, ''), 'MailChat user') into target_name
      from public.profiles where id = recipient;
    select coalesce(pc.calls_enabled, pg.calls_enabled, true),
      (coalesce(pc.muted, pg.muted, false)
       or (pc.muted_until is not null and pc.muted_until > now())
       or (pg.muted_until is not null and pg.muted_until > now())
       or coalesce(cm.notifications_muted, false)
       or (cm.muted_until is not null and cm.muted_until > now()))
      into recipient_enabled, recipient_muted
      from (select recipient as user_id) u
      left join public.notification_preferences pg on pg.user_id=u.user_id and pg.conversation_id is null
      left join public.notification_preferences pc on pc.user_id=u.user_id and pc.conversation_id=new.conversation_id
      left join public.conversation_members cm on cm.user_id=u.user_id and cm.conversation_id=new.conversation_id;
    if recipient_enabled and not recipient_muted then
      insert into public.user_notifications
        (user_id, actor_id, conversation_id, call_id, notification_type, title, body, payload)
      values (recipient, actor, new.conversation_id, new.id, 'missed_call',
        case when recipient = new.callee_id then 'Missed call' else 'Call not answered' end,
        case when recipient = new.callee_id then 'Missed call from ' || actor_name
          else 'No answer from ' || actor_name end,
        jsonb_build_object('callId', new.id, 'conversationId', new.conversation_id,
          'kind', new.kind, 'actorId', actor, 'actorName', actor_name,
          'recipientName', target_name));
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists calls_create_missed_call_notifications on public.calls;
create trigger calls_create_missed_call_notifications after update of status on public.calls
  for each row execute function public.create_missed_call_notifications();

-- Realtime delivers only rows allowed by user_notifications_select_own.
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'
      and tablename = 'user_notifications'
  ) then
    alter publication supabase_realtime add table public.user_notifications;
  end if;
end $$;
