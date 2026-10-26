-- ============================================================================
-- MailChat — 0009 read cursor
-- ----------------------------------------------------------------------------
-- Unread badges were cleared by a PATCH from the app:
--
--   PATCH conversation_members?conversation_id=eq.…&user_id=eq.…
--   { last_read_message_id: <the newest message the phone had loaded> }
--
-- The database side of that was sound, but the *value* came from the phone: it
-- pointed the cursor at whichever message the app believed was newest. When the
-- app had not seen the latest rows — a missed Realtime event, a resumed screen,
-- a page of history that stopped short — the cursor landed behind the newest
-- message and the badge came straight back. It could also move backwards: two
-- devices marking the same thread read in a different order left the cursor on
-- the older message, so a count the user had already cleared "came back".
--
-- mark_conversation_read() moves that decision into the database:
--
--   * the cursor becomes the newest message *in the table*, not in the app;
--   * it only ever moves forward (monotonic), so a stale device cannot
--     resurrect a badge;
--   * it returns how many messages the server still counts as unread, computed
--     with the same rule conversation_list uses, so the client can tell
--     "cleared" from "the write did not land".
--
-- Still one row per member, still no new table. The RPC is SECURITY DEFINER
-- because it must see the whole thread regardless of RLS paging, so it checks
-- membership itself before touching the cursor.
-- ============================================================================

create or replace function public.mark_conversation_read(p_conversation_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  me            uuid := auth.uid();
  newest_id     uuid;
  newest_at     timestamptz;
  cursor_at     timestamptz;
  remaining     integer;
begin
  if me is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Membership is checked here because RLS does not apply inside a definer
  -- function; without this, any authenticated caller could clear someone
  -- else's membership row by guessing a conversation id.
  if not exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = me
  ) then
    raise exception 'not a member of this conversation' using errcode = '42501';
  end if;

  -- Newest visible message from anyone. Your own messages never count as
  -- unread, but they do move the cursor: the cursor is compared by timestamp,
  -- so pointing it at your latest message is both correct and monotonic.
  select m.id, m.created_at
    into newest_id, newest_at
  from public.messages m
  where m.conversation_id = p_conversation_id
    and m.deleted_at is null
  order by m.created_at desc, m.id desc
  limit 1;

  -- Where the cursor stands now, for the forward-only check.
  select rm.created_at
    into cursor_at
  from public.conversation_members cm
  join public.messages rm on rm.id = cm.last_read_message_id
  where cm.conversation_id = p_conversation_id
    and cm.user_id = me;

  if newest_id is not null and (cursor_at is null or newest_at >= cursor_at) then
    update public.conversation_members
       set last_read_message_id = newest_id
     where conversation_id = p_conversation_id
       and user_id = me;
  end if;

  -- Same rule as conversation_list.unread_count: newer than the cursor, not
  -- mine, not deleted. Anything still counted here arrived while the call was
  -- running.
  select count(*)::integer
    into remaining
  from public.messages um
  join public.conversation_members cm
    on cm.conversation_id = um.conversation_id
   and cm.user_id = me
  left join public.messages rm on rm.id = cm.last_read_message_id
  where um.conversation_id = p_conversation_id
    and um.created_at > coalesce(rm.created_at, '-infinity'::timestamptz)
    and um.sender_id <> me
    and um.deleted_at is null;

  return coalesce(remaining, 0);
end;
$$;

-- Postgres grants EXECUTE to PUBLIC on new functions; revoke before granting.
revoke all on function public.mark_conversation_read(uuid) from public;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
