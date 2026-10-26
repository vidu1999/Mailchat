-- ============================================================================
-- MailChat — 0005 email discovery
-- ----------------------------------------------------------------------------
-- Adds "find a person by their email address" to user search.
--
-- Why this needs a function: emails live in auth.users, not public.profiles,
-- and they must stay there. public.profiles is readable by every authenticated
-- user (policy profiles_select using (true)), so putting an email column on it
-- would publish every address to every account. A SECURITY DEFINER function can
-- read auth.users and return only profile fields — the address is an input that
-- is matched against, never an output.
--
-- Matching rules:
--   * email       — exact, case-insensitive. Never a substring, so the endpoint
--                   cannot be used to enumerate addresses from fragments.
--   * username    — substring, case-insensitive, as before.
--   * display_name— substring, case-insensitive, as before.
--   * unverified addresses are not discoverable: otherwise anyone could
--     pre-register a colleague's address and be found in their place.
--   * users who blocked the caller, or whom the caller blocked, are excluded.
--   * the caller is excluded from their own results.
--
-- Both lookups are opt-out, matching how address-book style discovery works
-- everywhere else, and are controlled by two columns the owner can change from
-- Privacy settings.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Discoverability flags. Default true: an app whose whole identity model is
-- email is unusable if nobody can be found by default.
-- ----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists discoverable_by_email boolean not null default true;

alter table public.profiles
  add column if not exists discoverable_by_username boolean not null default true;

comment on column public.profiles.discoverable_by_email is
  'Whether this user can be matched by their exact email address in search.';
comment on column public.profiles.discoverable_by_username is
  'Whether this user can be matched by username or display name in search.';

-- ----------------------------------------------------------------------------
-- search_users
--
-- Returns profile fields plus how the row matched, never the email itself.
-- p_limit is clamped so a caller cannot ask for the whole table.
-- ----------------------------------------------------------------------------
create or replace function public.search_users(
  p_query text,
  p_limit integer default 20
)
returns table (
  id           uuid,
  username     text,
  display_name text,
  avatar_path  text,
  created_at   timestamptz,
  updated_at   timestamptz,
  matched_by   text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with q as (
    -- One normalised form for both matches. It is only ever compared to a full
    -- address with '=' below, which is what stops fragment enumeration.
    select nullif(btrim(lower(p_query)), '') as raw
  )
  select
    p.id,
    p.username,
    p.display_name,
    p.avatar_path,
    p.created_at,
    p.updated_at,
    case when u.email is not null and lower(u.email) = q.raw
         then 'email' else 'profile' end as matched_by
  from public.profiles p
  join auth.users u on u.id = p.id
  cross join q
  where q.raw is not null
    and p.id <> auth.uid()
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_user_id = p.id)
         or (b.blocker_id = p.id and b.blocked_user_id = auth.uid())
    )
    and (
      (
        p.discoverable_by_email
        and u.email_confirmed_at is not null
        and lower(u.email) = q.raw
      )
      or (
        p.discoverable_by_username
        and (
          p.username ilike '%' || q.raw || '%'
          or p.display_name ilike '%' || q.raw || '%'
        )
      )
    )
  order by
    -- An exact address match is what the user asked for; show it first.
    case when u.email is not null and lower(u.email) = q.raw then 0 else 1 end,
    p.username
  limit greatest(1, least(coalesce(p_limit, 20), 50));
$$;

comment on function public.search_users(text, integer) is
  'Profile search by username, display name, or exact email. Never returns the email.';

-- Postgres grants EXECUTE to PUBLIC on new functions, so revoke before granting
-- deliberately. Anonymous callers must not be able to probe for accounts.
revoke all on function public.search_users(text, integer) from public;
revoke all on function public.search_users(text, integer) from anon;
grant execute on function public.search_users(text, integer) to authenticated;
