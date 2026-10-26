-- Safe to re-run. Every object is created only if absent, and every trigger is
-- dropped first: `create trigger` has no `if not exists`, so without the drop a
-- second run aborts the whole file with 42710.
-- ============================================================================
-- MailChat — 0001 core schema
-- ----------------------------------------------------------------------------
-- Email-based identity: every row is owned by an auth.users id. No phone
-- numbers, SMS or SIM data exist anywhere in this schema.
--
-- Apply with the Supabase CLI:
--   supabase db push
-- or paste into the SQL editor in dependency order.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- Utility: keep updated_at accurate without trusting the client
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- profiles
-- One row per auth user. Username is the human-facing handle; email lives in
-- auth.users and is never exposed through this table.
-- ============================================================================
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  username     text not null,
  display_name text not null default '',
  avatar_path  text,
  bio          text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint profiles_username_format
    check (username ~ '^[a-z0-9][a-z0-9_.]{2,29}$'),
  constraint profiles_display_name_length
    check (char_length(display_name) <= 60),
  constraint profiles_bio_length
    check (bio is null or char_length(bio) <= 500)
);

-- Case-insensitive uniqueness: usernames are stored lowercased, but enforce
-- it defensively at the database level too.
create unique index if not exists profiles_username_lower_idx
  on public.profiles (lower(username));

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ============================================================================
-- conversations
-- ============================================================================
create table if not exists public.conversations (
  id          uuid primary key default gen_random_uuid(),
  type        text not null check (type in ('direct', 'group')),
  name        text,
  description text,
  avatar_path text,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

drop trigger if exists conversations_set_updated_at on public.conversations;
create trigger conversations_set_updated_at
  before update on public.conversations
  for each row execute function public.set_updated_at();

create index if not exists conversations_updated_at_idx
  on public.conversations (updated_at desc);

-- ============================================================================
-- conversation_members
-- ============================================================================
create table if not exists public.conversation_members (
  conversation_id       uuid not null references public.conversations (id) on delete cascade,
  user_id               uuid not null references public.profiles (id) on delete cascade,
  role                  text not null default 'member'
                          check (role in ('member', 'admin', 'owner')),
  joined_at             timestamptz not null default now(),
  last_read_message_id  uuid,
  notifications_muted   boolean not null default false,
  muted_until           timestamptz,

  primary key (conversation_id, user_id)
);

create index if not exists conversation_members_user_idx
  on public.conversation_members (user_id);

-- ============================================================================
-- messages
-- ============================================================================
create table if not exists public.messages (
  id                  uuid primary key default gen_random_uuid(),
  conversation_id     uuid not null references public.conversations (id) on delete cascade,
  sender_id           uuid not null references public.profiles (id) on delete cascade,
  type                text not null default 'text'
                        check (type in ('text','image','video','audio','voice','file','system')),
  text                text,
  reply_to_message_id uuid references public.messages (id) on delete set null,
  client_id           text,
  created_at          timestamptz not null default now(),
  edited_at           timestamptz,
  deleted_at          timestamptz,

  constraint messages_text_present
    check (deleted_at is not null or type <> 'text' or (text is not null and char_length(text) > 0)),
  constraint messages_text_length
    check (text is null or char_length(text) <= 4000)
);

create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc);

create index if not exists messages_sender_idx
  on public.messages (sender_id);

-- Idempotent sends: a retried optimistic send cannot create duplicates.
create unique index if not exists messages_client_id_idx
  on public.messages (conversation_id, client_id)
  where client_id is not null;

-- ============================================================================
-- message_attachments
-- ============================================================================
create table if not exists public.message_attachments (
  id           uuid primary key default gen_random_uuid(),
  message_id   uuid not null references public.messages (id) on delete cascade,
  storage_path text not null,
  file_name    text not null,
  mime_type    text not null,
  file_size    bigint not null check (file_size > 0),
  width        integer,
  height       integer,
  duration_seconds integer,
  created_at   timestamptz not null default now()
);

create index if not exists message_attachments_message_idx
  on public.message_attachments (message_id);

-- ============================================================================
-- message_reactions
-- ============================================================================
create table if not exists public.message_reactions (
  id         uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  reaction   text not null check (char_length(reaction) between 1 and 16),
  created_at timestamptz not null default now(),

  -- One reaction of a given emoji per user per message.
  unique (message_id, user_id, reaction)
);

create index if not exists message_reactions_message_idx
  on public.message_reactions (message_id);

-- ============================================================================
-- message_receipts
-- ============================================================================
create table if not exists public.message_receipts (
  id           uuid primary key default gen_random_uuid(),
  message_id   uuid not null references public.messages (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  delivered_at timestamptz,
  read_at      timestamptz,

  unique (message_id, recipient_id)
);

create index if not exists message_receipts_recipient_idx
  on public.message_receipts (recipient_id);

-- ============================================================================
-- user_blocks
-- ============================================================================
create table if not exists public.user_blocks (
  id              uuid primary key default gen_random_uuid(),
  blocker_id      uuid not null references public.profiles (id) on delete cascade,
  blocked_user_id uuid not null references public.profiles (id) on delete cascade,
  created_at      timestamptz not null default now(),

  unique (blocker_id, blocked_user_id),
  constraint user_blocks_no_self check (blocker_id <> blocked_user_id)
);

create index if not exists user_blocks_blocker_idx
  on public.user_blocks (blocker_id);

-- ============================================================================
-- user_reports
-- ============================================================================
create table if not exists public.user_reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid not null references public.profiles (id) on delete cascade,
  reported_user_id uuid not null references public.profiles (id) on delete cascade,
  message_id       uuid references public.messages (id) on delete set null,
  reason           text not null,
  description      text,
  status           text not null default 'open'
                     check (status in ('open','reviewed','closed','dismissed')),
  created_at       timestamptz not null default now(),

  constraint user_reports_no_self check (reporter_id <> reported_user_id),
  constraint user_reports_description_length
    check (description is null or char_length(description) <= 2000)
);

create index if not exists user_reports_status_idx
  on public.user_reports (status, created_at desc);

-- ============================================================================
-- user_devices (push tokens)
-- ============================================================================
create table if not exists public.user_devices (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  device_id      text not null,
  platform       text not null check (platform in ('ios','android','web')),
  push_token     text,
  last_active_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  unique (user_id, device_id)
);

drop trigger if exists user_devices_set_updated_at on public.user_devices;
create trigger user_devices_set_updated_at
  before update on public.user_devices
  for each row execute function public.set_updated_at();

-- ============================================================================
-- notification_preferences
-- ============================================================================
create table if not exists public.notification_preferences (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  conversation_id   uuid references public.conversations (id) on delete cascade,
  messages_enabled  boolean not null default true,
  mentions_enabled  boolean not null default true,
  reactions_enabled boolean not null default true,
  muted             boolean not null default false,
  muted_until       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create unique index if not exists notification_preferences_user_conversation_idx
  on public.notification_preferences (user_id, conversation_id)
  where conversation_id is not null;

create unique index if not exists notification_preferences_user_global_idx
  on public.notification_preferences (user_id)
  where conversation_id is null;

drop trigger if exists notification_preferences_set_updated_at on public.notification_preferences;
create trigger notification_preferences_set_updated_at
  before update on public.notification_preferences
  for each row execute function public.set_updated_at();
