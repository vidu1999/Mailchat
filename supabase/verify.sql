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
       case when count(*) = 2 then 'ok'
            else count(*)::text || ' - expected avatars and attachments' end
from storage.buckets where id in ('avatars', 'attachments')

union all
select '06. tables published for realtime',
       case when count(*) = 4 then 'ok'
            else count(*)::text || ' - expected 4' end
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
order by 1;
