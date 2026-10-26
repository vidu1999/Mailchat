-- ============================================================================
-- MailChat — 0008 online status and last seen
-- ----------------------------------------------------------------------------
-- Until now "presence" was ephemeral broadcast state on a per-conversation
-- Realtime channel. It could only answer "is the other person in this exact
-- chat right now", and it vanished the moment they closed the screen, so the
-- app had no way to say "last seen 20 minutes ago" — the information did not
-- exist anywhere.
--
-- This migration adds the durable half: a heartbeat row per user, written by
-- the client while it is in the foreground, plus one function that decides what
-- other people may know about it.
--
--   online       = last_seen_at within 75 seconds  (PresenceService.onlineWindow)
--   last seen    = the heartbeat timestamp itself
--   hidden       = the owner turned sharing off (share_last_seen = false)
--
-- Privacy is enforced in the database, not in the client: the table's only
-- SELECT policy exposes your own row, so other people's heartbeats can only be
-- read through public.get_presence(), which applies the flag and refuses users
-- you share no conversation with.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- user_presence
-- One row per user, created by the first heartbeat. No row means the account
-- has never had the app open (reported as offline), which is different from a
-- hidden row (reported as unknown).
-- ----------------------------------------------------------------------------
create table if not exists public.user_presence (
  user_id         uuid primary key
                    references public.profiles (id) on delete cascade,
  last_seen_at    timestamptz not null default now(),
  share_last_seen boolean not null default true
);

create index if not exists user_presence_last_seen_idx
  on public.user_presence (last_seen_at desc);

comment on table public.user_presence is
  'Heartbeat written while the client is in the foreground. online = last_seen_at within 75 seconds.';
comment on column public.user_presence.share_last_seen is
  'When false, get_presence() returns null for both online and last_seen_at to everyone but the owner.';

alter table public.user_presence enable row level security;

-- Own row only. Deliberately no INSERT/UPDATE policy: every write goes through
-- touch_last_seen(), so last_seen_at is always server time and nobody can
-- backdate another user's status.
drop policy if exists user_presence_select_self on public.user_presence;
create policy user_presence_select_self on public.user_presence
  for select to authenticated
  using (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- shares_conversation_with
-- "Do these two users have a conversation in common?" Written as a SECURITY
-- DEFINER function because the plain query needs both users' membership rows,
-- and conversation_members' SELECT policy only shows the caller their own
-- conversations' rosters.
-- ----------------------------------------------------------------------------
create or replace function public.shares_conversation_with(other_user uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.conversation_members mine
    join public.conversation_members theirs
      on theirs.conversation_id = mine.conversation_id
    where mine.user_id = auth.uid()
      and theirs.user_id = other_user
      and mine.user_id <> theirs.user_id
  );
$$;

revoke all on function public.shares_conversation_with(uuid) from public;
grant execute on function public.shares_conversation_with(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- touch_last_seen
-- Heartbeat. Also the only way to change the sharing flag, so the privacy
-- setting is written in the same row as the timestamp it governs.
--
-- p_share null  -> heartbeat only, keep the current setting
-- p_share true  -> share status with other people
-- p_share false -> show nothing to other people
-- ----------------------------------------------------------------------------
create or replace function public.touch_last_seen(p_share boolean default null)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  seen timestamptz;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  insert into public.user_presence as up (user_id, last_seen_at, share_last_seen)
  values (auth.uid(), now(), coalesce(p_share, true))
  on conflict (user_id) do update
    set last_seen_at    = now(),
        share_last_seen = coalesce(p_share, up.share_last_seen)
  returning last_seen_at into seen;

  return seen;
end;
$$;

revoke all on function public.touch_last_seen(boolean) from public;
grant execute on function public.touch_last_seen(boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- get_presence
-- What the caller may know about a list of users.
--
-- Rows come back only for users the caller shares a conversation with (plus
-- themselves), and never across a block in either direction. `online` and
-- `last_seen_at` are null when the target has sharing off — null means
-- "unknown", which is why `online` is nullable rather than defaulting to false.
--
-- The input array is clamped so the endpoint cannot be used to sweep the whole
-- user table.
-- ----------------------------------------------------------------------------
create or replace function public.get_presence(p_user_ids uuid[])
returns table (user_id uuid, online boolean, last_seen_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  with wanted as (
    select unnest((coalesce(p_user_ids, array[]::uuid[]))[1:200]) as id
  )
  select
    up.user_id,
    case
      when up.share_last_seen or up.user_id = auth.uid()
        then up.last_seen_at > now() - interval '75 seconds'
      else null
    end as online,
    case
      when up.share_last_seen or up.user_id = auth.uid()
        then up.last_seen_at
      else null
    end as last_seen_at
  from public.user_presence up
  join wanted w on w.id = up.user_id
  where (
      up.user_id = auth.uid()
      or public.shares_conversation_with(up.user_id)
    )
    and not exists (
      select 1
      from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_user_id = up.user_id)
         or (b.blocker_id = up.user_id and b.blocked_user_id = auth.uid())
    );
$$;

revoke all on function public.get_presence(uuid[]) from public;
grant execute on function public.get_presence(uuid[]) to authenticated;
