-- ============================================================================
-- MailChat — 0007 call signalling
-- ----------------------------------------------------------------------------
-- The database half of voice/video calling: a call is a row, and the two
-- participants move it between states. The *media* half — WebRTC, STUN/TURN —
-- is not here and is not pretended to be; see docs/calls.md.
--
-- Why a table rather than only Realtime broadcast: a broadcast is a message to
-- whoever is currently connected. A call that arrives while the callee's app is
-- backgrounded, or whose signalling packet is lost, would leave no trace and
-- nothing to recover. A row gives the callee something to poll or subscribe to,
-- gives "missed call" a definition, and makes the whole flow auditable.
--
-- SDP is stored on the call row because there is exactly one offer and one
-- answer. ICE candidates are a stream, so they get their own table.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- calls
-- ----------------------------------------------------------------------------
create table if not exists public.calls (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  caller_id       uuid not null references public.profiles (id) on delete cascade,
  callee_id       uuid not null references public.profiles (id) on delete cascade,
  kind            text not null default 'voice' check (kind in ('voice', 'video')),

  -- ringing -> accepted | declined | missed
  -- accepted -> ended
  -- anything -> failed (ICE never connected)
  status          text not null default 'ringing'
    check (status in ('ringing', 'accepted', 'declined', 'missed', 'ended', 'failed')),

  offer_sdp       text,
  answer_sdp      text,

  created_at      timestamptz not null default now(),
  accepted_at     timestamptz,
  ended_at        timestamptz,
  ended_by        uuid references public.profiles (id) on delete set null,

  constraint calls_no_self check (caller_id <> callee_id)
);

create index if not exists calls_callee_ringing_idx
  on public.calls (callee_id, created_at desc)
  where status = 'ringing';

create index if not exists calls_conversation_idx
  on public.calls (conversation_id, created_at desc);

-- ----------------------------------------------------------------------------
-- call_ice_candidates
-- Append-only: a candidate is never edited, only added. The negotiation reads
-- them in order, which is why they are keyed by insertion and not by a rewrite.
-- ----------------------------------------------------------------------------
create table if not exists public.call_ice_candidates (
  id              uuid primary key default gen_random_uuid(),
  call_id         uuid not null references public.calls (id) on delete cascade,
  sender_id       uuid not null references public.profiles (id) on delete cascade,
  candidate       text not null,
  sdp_mid         text,
  sdp_mline_index integer,
  created_at      timestamptz not null default now()
);

create index if not exists call_ice_candidates_call_idx
  on public.call_ice_candidates (call_id, created_at);

-- ----------------------------------------------------------------------------
-- State transitions and who may cause them.
--
-- Enforced here rather than trusted to the client because the interesting
-- mistakes are all privilege mistakes: a caller marking its own call "accepted",
-- a third party ending someone else's call, or a call being reopened after it
-- ended. The client mirrors these rules for nicer UI, but this is the boundary.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_call_transitions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  if me <> new.caller_id and me <> new.callee_id then
    raise exception 'not a participant of this call' using errcode = '42501';
  end if;

  -- Terminal states stay terminal.
  if old.status in ('declined', 'missed', 'ended', 'failed')
     and new.status <> old.status then
    raise exception 'call is already finished' using errcode = '22023';
  end if;

  -- Each side owns its own SDP: the caller writes the offer, the callee writes
  -- the answer. Without this the callee could rewrite the offer it is answering.
  if new.offer_sdp is distinct from old.offer_sdp and me <> new.caller_id then
    raise exception 'only the caller may set the offer' using errcode = '42501';
  end if;
  if new.answer_sdp is distinct from old.answer_sdp and me <> new.callee_id then
    raise exception 'only the callee may set the answer' using errcode = '42501';
  end if;

  if new.status = old.status then
    -- Signalling-only update (SDP). ICE candidates live in their own table.
    return new;
  end if;

  if new.status = 'accepted' then
    if me <> new.callee_id then
      raise exception 'only the callee can accept a call' using errcode = '42501';
    end if;
    if old.status <> 'ringing' then
      raise exception 'call is not ringing' using errcode = '22023';
    end if;
    new.accepted_at := coalesce(new.accepted_at, now());
  elsif new.status = 'declined' then
    if me <> new.callee_id then
      raise exception 'only the callee can decline a call' using errcode = '42501';
    end if;
  elsif new.status = 'ended' then
    if old.status <> 'accepted' then
      raise exception 'only an accepted call can be ended' using errcode = '22023';
    end if;
    new.ended_at := coalesce(new.ended_at, now());
    new.ended_by := coalesce(new.ended_by, me);
  elsif new.status in ('missed', 'failed') then
    new.ended_at := coalesce(new.ended_at, now());
  end if;

  -- The caller and callee are fixed at insert; a rename would break both sides
  -- of a negotiation in flight.
  new.caller_id := old.caller_id;
  new.callee_id := old.callee_id;
  new.conversation_id := old.conversation_id;
  new.kind := old.kind;
  return new;
end;
$$;

drop trigger if exists calls_enforce_transitions on public.calls;
create trigger calls_enforce_transitions
  before update on public.calls
  for each row execute function public.enforce_call_transitions();

-- `has_block_relation(uuid)` reads auth.uid(), so it cannot answer "did A block
-- B". This is the two-argument form the call trigger needs.
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

-- A blocked user must not be able to ring the person who blocked them.
create or replace function public.enforce_call_not_blocked()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.has_block_relation_by(new.caller_id, new.callee_id) then
    raise exception 'call blocked' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists calls_block_check on public.calls;
create trigger calls_block_check
  before insert on public.calls
  for each row execute function public.enforce_call_not_blocked();

-- ============================================================================
-- Row level security
-- ============================================================================
alter table public.calls enable row level security;
alter table public.call_ice_candidates enable row level security;

-- Only the two participants ever see a call.
drop policy if exists calls_select_participant on public.calls;
create policy calls_select_participant on public.calls
  for select to authenticated
  using (caller_id = auth.uid() or callee_id = auth.uid());

-- Only the caller creates a call, only for themselves, and only in a
-- conversation they belong to.
drop policy if exists calls_insert_caller on public.calls;
create policy calls_insert_caller on public.calls
  for insert to authenticated
  with check (
    caller_id = auth.uid()
    and public.is_conversation_member(conversation_id)
  );

-- Either participant may update; the trigger above decides which columns and
-- which transitions are actually allowed.
drop policy if exists calls_update_participant on public.calls;
create policy calls_update_participant on public.calls
  for update to authenticated
  using (caller_id = auth.uid() or callee_id = auth.uid())
  with check (caller_id = auth.uid() or callee_id = auth.uid());

-- Candidates belong to the call's participants, and each row is written by its
-- own sender.
drop policy if exists call_ice_select_participant on public.call_ice_candidates;
create policy call_ice_select_participant on public.call_ice_candidates
  for select to authenticated
  using (
    exists (
      select 1 from public.calls c
      where c.id = call_id
        and (c.caller_id = auth.uid() or c.callee_id = auth.uid())
    )
  );

drop policy if exists call_ice_insert_participant on public.call_ice_candidates;
create policy call_ice_insert_participant on public.call_ice_candidates
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.calls c
      where c.id = call_id
        and (c.caller_id = auth.uid() or c.callee_id = auth.uid())
        and c.status in ('ringing', 'accepted')
    )
  );

-- ============================================================================
-- Realtime: both tables, guarded the same way as 0004 so re-running is safe
-- ============================================================================
do $$
declare
  t text;
begin
  foreach t in array array['calls', 'call_ice_candidates'] loop
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
    raise notice 'realtime publication not updated: % (%)', sqlerrm, sqlstate;
end $$;
