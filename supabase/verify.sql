-- MailChat — database health check.
--
-- Paste into the Supabase SQL editor and run. Read-only: it changes nothing.
-- Every row must read ok; anything else names the file that did not apply.
--
-- This is also the tail of supabase/apply_all.sql, so a successful setup prints
-- the same table as its last step.
--
-- Run it after applying migrations, after a git pull that changed them, and
-- whenever the app reports a missing column, table or function.

-- ============================================================================
-- Verification — every row must read ok
-- ============================================================================

select '01. tables with row level security disabled' as check,
       coalesce(string_agg(tablename, ', '), 'ok') as result
from pg_tables
where schemaname = 'public' and not rowsecurity

union all
select '02. conversation_list.updated_at',
       case when exists (
         select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name = 'conversation_list'
           and column_name = 'updated_at'
       ) then 'ok' else 'MISSING - 0004 did not apply' end

union all
select '16. chat list preferences (0011)',
       case when (
         select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'conversation_members'
           and column_name in ('is_favorite', 'is_pinned')
       ) = 2 and (
         select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'conversation_list'
           and column_name in ('is_favorite', 'is_pinned')
       ) = 2 then 'ok'
       else 'MISSING - 0011 did not apply: favourites and pins are unavailable' end

union all
select '17. expiring user updates (0012)',
       case when (
         select count(*) from pg_tables
         where schemaname = 'public'
           and tablename in ('user_statuses', 'user_status_views')
           and rowsecurity
       ) = 2 and exists (
         select 1 from storage.buckets b where b.id = 'status-media' and b.public = false
       ) and exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'can_view_user_status'
       ) then 'ok'
       else 'MISSING - 0012 did not apply: Updates are unavailable' end

union all
select '03. tables in public',
       count(*)::text || ' ok'
from pg_tables where schemaname = 'public'

union all
select '04. functions',
       case when count(*) >= 8 then count(*)::text || ' ok'
            else count(*)::text || ' - expected at least 8' end
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'

union all
select '05. storage buckets',
       case when count(*) = 3 then 'ok'
            else count(*)::text || ' - expected avatars, attachments and status-media' end
from storage.buckets where id in ('avatars', 'attachments', 'status-media')

union all
select '06. tables published for realtime',
       case when count(*) = 8 then 'ok'
            else count(*)::text || ' - expected 8 (includes call signalling, user_statuses, and user_notifications)' end
from pg_publication_tables
where pubname = 'supabase_realtime' and schemaname = 'public'

union all
select '08. email discovery columns (0005)',
       case when (
         select count(*) from information_schema.columns
         where table_schema = 'public'
           and table_name = 'profiles'
           and column_name in ('discoverable_by_email', 'discoverable_by_username')
       ) = 2 then 'ok' else 'MISSING - 0005 did not apply' end

union all
select '13. read cursor function (0009)',
       case when exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'mark_conversation_read'
       ) then 'ok' else 'MISSING - 0009 did not apply: opening a chat cannot clear its badge' end

union all
select '14. conversation_list unread logic',
       case when exists (
         select 1 from pg_views
         where schemaname = 'public'
           and viewname = 'conversation_list'
           and definition ilike '%last_read_message_id%'
           and definition ilike '%sender_id%'
       ) then 'ok'
       else 'STALE - re-paste apply_all.sql: conversation_list is not the current definition, so unread counts are wrong' end

union all
select '12. presence and last seen (0008)',
       case when (
         select count(*) from pg_tables
         where schemaname = 'public' and tablename = 'user_presence' and rowsecurity
       ) = 1 and exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'touch_last_seen'
       ) and exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'get_presence'
       ) then 'ok' else 'MISSING - 0008 did not apply: no online status or last seen' end

union all
select '15. call save functions (0010)',
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
       end

union all
select '11. call signalling tables (0007)',
       case when (
         select count(*) from pg_tables
         where schemaname = 'public'
           and tablename in ('calls', 'call_ice_candidates')
           and rowsecurity
       ) = 2 then 'ok' else 'MISSING - 0007 did not apply: no calls' end

union all
select '10. one reaction per user (0006)',
       case when exists (
         select 1 from pg_constraint
         where conname = 'message_reactions_one_per_user'
       ) then 'ok' else 'MISSING - 0006 did not apply: a user can hold two reactions' end

union all
select '09. search_users function (0005)',
       case when exists (
         select 1 from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'search_users'
       ) then 'ok' else 'MISSING - 0005 did not apply: email search needs it' end

union all
select '07. policies on public tables',
       count(*)::text || ' ok'
from pg_policies where schemaname = 'public'

union all
select '18. message and missed-call notifications (0014)',
       case when to_regclass('public.user_notifications') is not null
         and exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'user_notifications')
         and exists (select 1 from pg_trigger where tgrelid = 'public.messages'::regclass and tgname = 'messages_create_notifications' and not tgisinternal)
         and exists (select 1 from pg_trigger where tgrelid = 'public.calls'::regclass and tgname = 'calls_create_missed_call_notifications' and not tgisinternal)
         and not exists (select 1 from pg_trigger where tgrelid = 'public.conversation_members'::regclass and tgname = 'conversation_members_create_notifications' and not tgisinternal)
         and not exists (select 1 from public.user_notifications where notification_type = 'system')
         and exists (select 1 from information_schema.columns where table_schema='public' and table_name='notification_preferences' and column_name='calls_enabled')
         and not exists (select 1 from information_schema.columns where table_schema='public' and table_name='notification_preferences' and column_name='system_enabled')
         then 'ok' else 'MISSING - 0014 message/call-only notification setup did not apply' end
order by 1;
