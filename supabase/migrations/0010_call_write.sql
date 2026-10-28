-- ===========================================================================
-- MailChat — 0010 call write
-- ----------------------------------------------------------------------------
-- A phone showed: new row violates row-level security policy for table "calls".
-- That is the server refusing to save the call, before any audio is exchanged.
--
-- Two causes produce that exact sentence:
--   * the insert or update policy is missing, or an extra policy rejects the row;
--   * the phone sent a caller id that is not the signed-in user.
--
-- place_call and set_call_status run as the table owner, so a bad policy cannot
-- block a member. They still refuse a stranger, a blocked user, and a caller
-- who is not in the chat. The policies below are recreated so an older app,
-- which writes the table directly, is allowed the same thing.
--
-- Safe to re-run.
-- ===========================================================================

-- Drop every policy on calls, including a restrictive one added by hand.
-- A restrictive policy is AND-ed with the permissive ones, so leaving it in
-- place keeps refusing a row the new policy would allow.
do $$
declare
  r record;
begin
  for r in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'calls'
  loop
    execute format('drop policy if exists %I on public.calls', r.policyname);
  end loop;
end $$;

alter table public.calls enable row level security;
alter table public.calls no force row level security;

grant select, insert, update on public.calls to authenticated;
grant select, insert on public.call_ice_candidates to authenticated;

drop policy if exists calls_select_participant on public.calls;
drop policy if exists calls_insert_caller on public.calls;
drop policy if exists calls_update_participant on public.calls;

-- Membership check that does not depend on the older helper. Security definer
-- so the policy can see the membership row.
create or replace function public.call_actor_is_member(cid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select auth.uid() is not null
     and exists (
       select 1 from public.conversation_members
       where conversation_id = cid and user_id = auth.uid()
     );
$$;

revoke all on function public.call_actor_is_member(uuid) from public;
grant execute on function public.call_actor_is_member(uuid) to authenticated;

create policy calls_select_participant on public.calls
  for select to authenticated
  using (caller_id = auth.uid() or callee_id = auth.uid());

create policy calls_insert_caller on public.calls
  for insert to authenticated
  with check (
    caller_id = auth.uid()
    and public.call_actor_is_member(conversation_id)
  );

create policy calls_update_participant on public.calls
  for update to authenticated
  using (caller_id = auth.uid() or callee_id = auth.uid())
  with check (caller_id = auth.uid() or callee_id = auth.uid());

-- The block helper 0007 creates. Replaced here so this file stands alone if
-- that function was never applied.
create or replace function public.has_block_relation_by(a uuid, b uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = a and blocked_user_id = b)
       or (blocker_id = b and blocked_user_id = a)
  );
$$;

revoke all on function public.has_block_relation_by(uuid, uuid) from public;
grant execute on function public.has_block_relation_by(uuid, uuid) to authenticated;

create or replace function public.place_call(
  p_conversation_id uuid,
  p_callee_id uuid,
  p_kind text,
  p_offer_sdp text default null
) returns public.calls
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  row public.calls;
begin
  -- The owner bypasses a policy that would refuse this member. Ignored if the
  -- function owner is not allowed to turn row security off.
  begin
    perform set_config('row_security', 'off', true);
  exception
    when others then
      null;
  end;

  if me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_callee_id is null or p_callee_id = me then
    raise exception 'cannot call yourself' using errcode = '22023';
  end if;
  if p_kind is null or p_kind not in ('voice', 'video') then
    raise exception 'call kind must be voice or video' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = me
  ) then
    raise exception 'you are not a member of this chat' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.conversation_members
    where conversation_id = p_conversation_id and user_id = p_callee_id
  ) then
    raise exception 'the person you are calling is not in this chat' using errcode = '42501';
  end if;
  if public.has_block_relation_by(me, p_callee_id) then
    raise exception 'call blocked' using errcode = '42501';
  end if;

  insert into public.calls (
    conversation_id, caller_id, callee_id, kind, status, offer_sdp
  ) values (
    p_conversation_id, me, p_callee_id, p_kind, 'ringing', p_offer_sdp
  )
  returning * into row;

  return row;
end;
$$;

revoke all on function public.place_call(uuid, uuid, text, text) from public;
revoke all on function public.place_call(uuid, uuid, text, text) from anon;
grant execute on function public.place_call(uuid, uuid, text, text) to authenticated;

create or replace function public.set_call_status(
  p_call_id uuid,
  p_status text,
  p_answer_sdp text default null
) returns public.calls
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  row public.calls;
begin
  begin
    perform set_config('row_security', 'off', true);
  exception
    when others then
      null;
  end;

  if me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_status is null
     or p_status not in ('accepted', 'declined', 'missed', 'ended', 'failed') then
    raise exception 'that call status is not allowed' using errcode = '22023';
  end if;

  select * into row from public.calls where id = p_call_id;
  if not found then
    raise exception 'that call does not exist' using errcode = 'P0002';
  end if;
  if me <> row.caller_id and me <> row.callee_id then
    raise exception 'not a participant of this call' using errcode = '42501';
  end if;
  if row.status in ('declined', 'missed', 'ended', 'failed')
     and p_status <> row.status then
    raise exception 'call is already finished' using errcode = '22023';
  end if;
  if p_status = 'accepted' then
    if me <> row.callee_id then
      raise exception 'only the callee can accept a call' using errcode = '42501';
    end if;
    if row.status <> 'ringing' then
      raise exception 'call is not ringing' using errcode = '22023';
    end if;
  elsif p_status = 'declined' and me <> row.callee_id then
    raise exception 'only the callee can decline a call' using errcode = '42501';
  elsif p_status = 'ended' and row.status <> 'accepted' then
    raise exception 'only an accepted call can be ended' using errcode = '22023';
  end if;
  if p_answer_sdp is not null and me <> row.callee_id then
    raise exception 'only the callee may set the answer' using errcode = '42501';
  end if;

  update public.calls
     set status = p_status,
         answer_sdp = coalesce(p_answer_sdp, answer_sdp)
   where id = p_call_id
  returning * into row;

  return row;
end;
$$;

revoke all on function public.set_call_status(uuid, text, text) from public;
revoke all on function public.set_call_status(uuid, text, text) from anon;
grant execute on function public.set_call_status(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';

select '15. call save functions (0010)' as check,
       case when exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'place_call'
       ) and exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'set_call_status'
       ) and exists (
         select 1 from pg_policies
         where schemaname = 'public'
           and tablename = 'calls'
           and policyname = 'calls_update_participant'
       ) then 'ok'
       else 'MISSING - 0010 did not apply: the server will refuse to save a call'
       end as result;
