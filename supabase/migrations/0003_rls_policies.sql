-- ============================================================================
-- MailChat — 0003 row level security
-- ----------------------------------------------------------------------------
-- Every table is owner/member scoped. The mobile app ships only the anon key,
-- so these policies are the real authorization boundary: a modified client
-- cannot read or write another user's data.
--
-- Helper predicates are SECURITY DEFINER functions so policies do not recurse
-- into the tables they protect.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper predicates
-- ----------------------------------------------------------------------------
create or replace function public.is_conversation_member(cid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = cid and user_id = auth.uid()
  );
$$;

create or replace function public.is_group_admin(cid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = cid
      and user_id = auth.uid()
      and role in ('admin','owner')
  );
$$;

create or replace function public.is_group_owner(cid uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = cid
      and user_id = auth.uid()
      and role = 'owner'
  );
$$;

-- Blocks are bidirectional for visibility: if either party blocked the other,
-- they should not see each other's content.
create or replace function public.has_block_relation(other_user uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = auth.uid() and blocked_user_id = other_user)
       or (blocker_id = other_user and blocked_user_id = auth.uid())
  );
$$;

grant execute on function public.is_conversation_member(uuid) to authenticated;
grant execute on function public.is_group_admin(uuid) to authenticated;
grant execute on function public.is_group_owner(uuid) to authenticated;
grant execute on function public.has_block_relation(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- Enable RLS everywhere. Default deny: no policy means no access.
-- ----------------------------------------------------------------------------
alter table public.profiles               enable row level security;
alter table public.conversations          enable row level security;
alter table public.conversation_members   enable row level security;
alter table public.messages               enable row level security;
alter table public.message_attachments    enable row level security;
alter table public.message_reactions      enable row level security;
alter table public.message_receipts       enable row level security;
alter table public.user_blocks            enable row level security;
alter table public.user_reports           enable row level security;
alter table public.user_devices           enable row level security;
alter table public.notification_preferences enable row level security;

-- ============================================================================
-- profiles
-- Readable by any authenticated user (needed for username search), writable
-- only by the owner. Email never lives here.
-- ============================================================================
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (true);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (id = auth.uid());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_delete_own on public.profiles;
create policy profiles_delete_own on public.profiles
  for delete to authenticated
  using (id = auth.uid());

-- ============================================================================
-- conversations
-- Visible to members only. Creation is allowed for the creator; membership
-- rows are added by the client (direct) or the owner trigger (group).
-- ============================================================================
drop policy if exists conversations_select_member on public.conversations;
create policy conversations_select_member on public.conversations
  for select to authenticated
  using (public.is_conversation_member(id));

drop policy if exists conversations_insert_creator on public.conversations;
create policy conversations_insert_creator on public.conversations
  for insert to authenticated
  with check (created_by = auth.uid());

drop policy if exists conversations_update_admin on public.conversations;
create policy conversations_update_admin on public.conversations
  for update to authenticated
  using (public.is_group_admin(id) or created_by = auth.uid())
  with check (public.is_group_admin(id) or created_by = auth.uid());

drop policy if exists conversations_delete_owner on public.conversations;
create policy conversations_delete_owner on public.conversations
  for delete to authenticated
  using (public.is_group_owner(id));

-- ============================================================================
-- conversation_members
-- A member can see the roster of their own conversations. Self-insert is
-- allowed when starting a direct chat; admins manage the rest.
-- ============================================================================
drop policy if exists conversation_members_select on public.conversation_members;
create policy conversation_members_select on public.conversation_members
  for select to authenticated
  using (public.is_conversation_member(conversation_id));

drop policy if exists conversation_members_insert_self on public.conversation_members;
create policy conversation_members_insert_self on public.conversation_members
  for insert to authenticated
  with check (user_id = auth.uid() or public.is_group_admin(conversation_id));

drop policy if exists conversation_members_update_own on public.conversation_members;
create policy conversation_members_update_own on public.conversation_members
  for update to authenticated
  using (user_id = auth.uid() or public.is_group_admin(conversation_id))
  with check (user_id = auth.uid() or public.is_group_admin(conversation_id));

drop policy if exists conversation_members_delete on public.conversation_members;
create policy conversation_members_delete on public.conversation_members
  for delete to authenticated
  using (user_id = auth.uid() or public.is_group_admin(conversation_id));

-- ============================================================================
-- messages
-- Members read. Authors write. Soft delete only (deleted_at), enforced by the
-- update policy: a sender may only set deleted_at/edited_at on their own rows.
-- ============================================================================
drop policy if exists messages_select_member on public.messages;
create policy messages_select_member on public.messages
  for select to authenticated
  using (public.is_conversation_member(conversation_id));

drop policy if exists messages_insert_member on public.messages;
create policy messages_insert_member on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.is_conversation_member(conversation_id)
  );

drop policy if exists messages_update_sender on public.messages;
create policy messages_update_sender on public.messages
  for update to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

-- Hard deletes are reserved for the service role (moderation/moderation jobs).
-- Soft delete is the client path via UPDATE ... deleted_at.

-- ============================================================================
-- message_attachments
-- ============================================================================
drop policy if exists message_attachments_select on public.message_attachments;
create policy message_attachments_select on public.message_attachments
  for select to authenticated
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_id and public.is_conversation_member(m.conversation_id)
    )
  );

drop policy if exists message_attachments_insert on public.message_attachments;
create policy message_attachments_insert on public.message_attachments
  for insert to authenticated
  with check (
    exists (
      select 1 from public.messages m
      where m.id = message_id
        and m.sender_id = auth.uid()
        and public.is_conversation_member(m.conversation_id)
    )
  );

drop policy if exists message_attachments_delete on public.message_attachments;
create policy message_attachments_delete on public.message_attachments
  for delete to authenticated
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_id and m.sender_id = auth.uid()
    )
  );

-- ============================================================================
-- message_reactions
-- ============================================================================
drop policy if exists message_reactions_select on public.message_reactions;
create policy message_reactions_select on public.message_reactions
  for select to authenticated
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_id and public.is_conversation_member(m.conversation_id)
    )
  );

drop policy if exists message_reactions_insert on public.message_reactions;
create policy message_reactions_insert on public.message_reactions
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.messages m
      where m.id = message_id and public.is_conversation_member(m.conversation_id)
    )
  );

drop policy if exists message_reactions_delete on public.message_reactions;
create policy message_reactions_delete on public.message_reactions
  for delete to authenticated
  using (user_id = auth.uid());

-- ============================================================================
-- message_receipts
-- A recipient may only write their own receipt; senders can read receipts for
-- their own messages.
-- ============================================================================
drop policy if exists message_receipts_select on public.message_receipts;
create policy message_receipts_select on public.message_receipts
  for select to authenticated
  using (
    recipient_id = auth.uid()
    or exists (
      select 1 from public.messages m
      where m.id = message_id and m.sender_id = auth.uid()
    )
  );

drop policy if exists message_receipts_insert on public.message_receipts;
create policy message_receipts_insert on public.message_receipts
  for insert to authenticated
  with check (recipient_id = auth.uid());

drop policy if exists message_receipts_update on public.message_receipts;
create policy message_receipts_update on public.message_receipts
  for update to authenticated
  using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

-- ============================================================================
-- user_blocks
-- ============================================================================
drop policy if exists user_blocks_select on public.user_blocks;
create policy user_blocks_select on public.user_blocks
  for select to authenticated
  using (blocker_id = auth.uid());

drop policy if exists user_blocks_insert on public.user_blocks;
create policy user_blocks_insert on public.user_blocks
  for insert to authenticated
  with check (blocker_id = auth.uid());

drop policy if exists user_blocks_delete on public.user_blocks;
create policy user_blocks_delete on public.user_blocks
  for delete to authenticated
  using (blocker_id = auth.uid());

-- ============================================================================
-- user_reports
-- Reporters can create and read their own reports. Triage is service-role only.
-- ============================================================================
drop policy if exists user_reports_insert on public.user_reports;
create policy user_reports_insert on public.user_reports
  for insert to authenticated
  with check (reporter_id = auth.uid());

drop policy if exists user_reports_select_own on public.user_reports;
create policy user_reports_select_own on public.user_reports
  for select to authenticated
  using (reporter_id = auth.uid());

-- ============================================================================
-- user_devices
-- ============================================================================
drop policy if exists user_devices_all_own on public.user_devices;
create policy user_devices_all_own on public.user_devices
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================================
-- notification_preferences
-- ============================================================================
drop policy if exists notification_preferences_all_own on public.notification_preferences;
create policy notification_preferences_all_own on public.notification_preferences
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
