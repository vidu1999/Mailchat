-- Remove generated system/group-update notifications at the user's request.
-- Keep message and missed-call inbox events; background OS push is a separate
-- FCM transport and is not enabled by this database migration.

drop trigger if exists conversation_members_create_notifications on public.conversation_members;
drop function if exists public.create_membership_notifications();

delete from public.user_notifications where notification_type = 'system';

alter table public.user_notifications
  drop constraint if exists user_notifications_notification_type_check,
  drop constraint if exists user_notifications_event_target;
alter table public.user_notifications
  add constraint user_notifications_notification_type_check
    check (notification_type in ('message', 'missed_call')),
  add constraint user_notifications_event_target check (
    (notification_type = 'message' and message_id is not null and conversation_id is not null and call_id is null)
    or (notification_type = 'missed_call' and call_id is not null and message_id is null)
  );

alter table public.notification_preferences
  drop column if exists system_enabled;

create or replace function public.create_message_notifications()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  convo public.conversations%rowtype;
  actor_name text;
  notification_body text;
  target record;
begin
  -- System chat messages may still be stored/rendered, but do not notify.
  if new.type = 'system' then return new; end if;

  select * into convo from public.conversations where id = new.conversation_id;
  select coalesce(nullif(p.display_name, ''), 'MailChat user') into actor_name
    from public.profiles p where p.id = new.sender_id;
  notification_body := case new.type
    when 'image' then 'Photo'
    when 'video' then 'Video'
    when 'audio' then 'Audio'
    when 'voice' then 'Voice message'
    when 'file' then 'File'
    else left(coalesce(new.text, 'New message'), 240)
  end;

  for target in
    select cm.user_id,
      cm.notifications_muted as member_muted,
      cm.muted_until as member_muted_until,
      coalesce(pc.muted, pg.muted, false) as preference_muted,
      coalesce(pc.muted_until, pg.muted_until) as preference_muted_until,
      coalesce(pc.messages_enabled, pg.messages_enabled, true) as enabled
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
        (target.user_id, new.sender_id, new.conversation_id, new.id, 'message',
         coalesce(actor_name, 'New message'), notification_body,
         jsonb_build_object('conversationId', new.conversation_id,
           'conversationType', convo.type, 'conversationName', convo.name,
           'messageId', new.id, 'actorId', new.sender_id));
    end if;
  end loop;
  return new;
end;
$$;
