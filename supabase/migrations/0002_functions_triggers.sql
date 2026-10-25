-- ============================================================================
-- MailChat — 0002 functions & triggers
-- ----------------------------------------------------------------------------
-- Server-side invariants that the client must never be trusted to enforce:
--   * profile creation is tied to auth.users
--   * only conversation members can post
--   * direct conversations are unique per member pair
--   * unread counts derive from members.last_read_message_id
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Auto-create a profile row when a user signs up.
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text;
  v_display  text;
begin
  v_username := lower(coalesce(
    new.raw_user_meta_data ->> 'username',
    split_part(new.email, '@', 1)
  ));

  -- Sanitise to the allowed username character set. If the attempt collides,
  -- a numeric suffix keeps signup from failing outright.
  v_username := regexp_replace(v_username, '[^a-z0-9_.]', '', 'g');
  if v_username !~ '^[a-z0-9][a-z0-9_.]{2,29}$' then
    v_username := 'user_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;

  if exists (select 1 from public.profiles p where lower(p.username) = v_username) then
    v_username := substr(v_username, 1, 20) || '_' ||
                  substr(replace(new.id::text, '-', ''), 1, 8);
  end if;

  v_display := coalesce(new.raw_user_meta_data ->> 'display_name', v_username);

  insert into public.profiles (id, username, display_name)
  values (new.id, v_username, v_display)
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- Atomic "get or create" direct conversation.
-- Prevents the race where two devices open the same 1:1 chat simultaneously.
-- ----------------------------------------------------------------------------
create or replace function public.get_or_create_direct_conversation(
  other_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me        uuid := auth.uid();
  existing  uuid;
  new_id    uuid;
begin
  if me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if me = other_user_id then
    raise exception 'cannot message yourself' using errcode = '22023';
  end if;

  -- Serialise concurrent creations for this member pair.
  perform pg_advisory_xact_lock(
    hashtext(least(me::text, other_user_id::text) || ':' ||
             greatest(me::text, other_user_id::text))
  );

  select c.id into existing
  from public.conversations c
  join public.conversation_members m1
    on m1.conversation_id = c.id and m1.user_id = me
  join public.conversation_members m2
    on m2.conversation_id = c.id and m2.user_id = other_user_id
  where c.type = 'direct'
  limit 1;

  if existing is not null then
    return existing;
  end if;

  insert into public.conversations (type, created_by)
  values ('direct', me)
  returning id into new_id;

  insert into public.conversation_members (conversation_id, user_id, role)
  values (new_id, me, 'member'), (new_id, other_user_id, 'member');

  return new_id;
end;
$$;

revoke all on function public.get_or_create_direct_conversation(uuid) from public;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Enforce: the sender must be an active member of the conversation.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_message_sender_is_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = new.conversation_id
      and user_id = new.sender_id
  ) then
    raise exception 'sender is not a member of this conversation'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists messages_sender_member_check on public.messages;
create trigger messages_sender_member_check
  before insert on public.messages
  for each row execute function public.enforce_message_sender_is_member();

-- ----------------------------------------------------------------------------
-- Bump conversation.updated_at on new message (drives ordering).
-- ----------------------------------------------------------------------------
create or replace function public.touch_conversation_on_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversations
     set updated_at = now()
   where id = new.conversation_id;
  return new;
end;
$$;

drop trigger if exists messages_touch_conversation on public.messages;
create trigger messages_touch_conversation
  after insert on public.messages
  for each row execute function public.touch_conversation_on_message();

-- ----------------------------------------------------------------------------
-- Owner must always be a member with role 'owner'.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_group_owner_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type = 'group' and new.created_by is not null then
    insert into public.conversation_members (conversation_id, user_id, role)
    values (new.id, new.created_by, 'owner')
    on conflict (conversation_id, user_id)
      do update set role = 'owner';
  end if;
  return new;
end;
$$;

drop trigger if exists conversations_ensure_owner on public.conversations;
create trigger conversations_ensure_owner
  after insert on public.conversations
  for each row execute function public.enforce_group_owner_membership();

-- ----------------------------------------------------------------------------
-- Blocking: a blocked user cannot insert messages into a direct conversation
-- with the blocker. Enforced server-side so a modified client cannot bypass it.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_block_between_users()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.conversation_members other
    join public.user_blocks b
      on b.blocker_id = other.user_id
     and b.blocked_user_id = new.sender_id
    where other.conversation_id = new.conversation_id
  ) then
    raise exception 'message blocked' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists messages_block_check on public.messages;
create trigger messages_block_check
  before insert on public.messages
  for each row execute function public.enforce_block_between_users();
