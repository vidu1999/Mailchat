-- MailChat — 0012 expiring user statuses
--
-- Statuses are shared only with users who have a direct MailChat conversation
-- with the author. Blocking either direction removes visibility immediately.
-- Text and photo status expire 24 hours after server creation time.

create table if not exists public.user_statuses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  status_type text not null check (status_type in ('text', 'image')),
  text text,
  media_path text,
  background_color bigint not null default 4284704497,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  constraint user_statuses_text_length check (text is null or char_length(text) <= 700),
  constraint user_statuses_payload check (
    (status_type = 'text' and text is not null and length(btrim(text)) > 0 and media_path is null)
    or (status_type = 'image' and media_path is not null)
  )
);

create index if not exists user_statuses_user_expiry_idx
  on public.user_statuses (user_id, expires_at desc);
create index if not exists user_statuses_expiry_idx
  on public.user_statuses (expires_at);

create table if not exists public.user_status_views (
  status_id uuid not null references public.user_statuses (id) on delete cascade,
  viewer_id uuid not null references public.profiles (id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (status_id, viewer_id)
);

create index if not exists user_status_views_viewer_idx
  on public.user_status_views (viewer_id, viewed_at desc);

create or replace function public.enforce_user_status_insert()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.user_id <> auth.uid() then
    raise exception 'a status must belong to the signed-in user' using errcode = '42501';
  end if;
  new.created_at := now();
  new.expires_at := new.created_at + interval '24 hours';
  return new;
end;
$$;

drop trigger if exists user_statuses_enforce_insert on public.user_statuses;
create trigger user_statuses_enforce_insert
  before insert on public.user_statuses
  for each row execute function public.enforce_user_status_insert();

create or replace function public.can_view_user_status(p_owner_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select auth.uid() is not null
    and p_owner_id is not null
    and (
      p_owner_id = auth.uid()
      or (
        exists (
          select 1
          from public.conversations c
          join public.conversation_members author_member
            on author_member.conversation_id = c.id
           and author_member.user_id = p_owner_id
          join public.conversation_members viewer_member
            on viewer_member.conversation_id = c.id
           and viewer_member.user_id = auth.uid()
          where c.type = 'direct'
        )
        and not exists (
          select 1 from public.user_blocks b
          where (b.blocker_id = p_owner_id and b.blocked_user_id = auth.uid())
             or (b.blocker_id = auth.uid() and b.blocked_user_id = p_owner_id)
        )
      )
    );
$$;

revoke all on function public.can_view_user_status(uuid) from public;
revoke all on function public.can_view_user_status(uuid) from anon;
grant execute on function public.can_view_user_status(uuid) to authenticated;

alter table public.user_statuses enable row level security;
drop policy if exists user_statuses_read_visible on public.user_statuses;
create policy user_statuses_read_visible on public.user_statuses
  for select to authenticated
  using (expires_at > now() and public.can_view_user_status(user_id));
drop policy if exists user_statuses_insert_own on public.user_statuses;
create policy user_statuses_insert_own on public.user_statuses
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (media_path is null or split_part(media_path, '/', 1) = auth.uid()::text)
  );
drop policy if exists user_statuses_delete_own on public.user_statuses;
create policy user_statuses_delete_own on public.user_statuses
  for delete to authenticated
  using (user_id = auth.uid());

grant select, insert, delete on public.user_statuses to authenticated;

alter table public.user_status_views enable row level security;
drop policy if exists user_status_views_read_participant on public.user_status_views;
create policy user_status_views_read_participant on public.user_status_views
  for select to authenticated
  using (
    viewer_id = auth.uid()
    or exists (
      select 1 from public.user_statuses s
      where s.id = status_id and s.user_id = auth.uid()
    )
  );
drop policy if exists user_status_views_insert_visible on public.user_status_views;
create policy user_status_views_insert_visible on public.user_status_views
  for insert to authenticated
  with check (
    viewer_id = auth.uid()
    and exists (
      select 1 from public.user_statuses s
      where s.id = status_id
        and s.user_id <> auth.uid()
        and s.expires_at > now()
        and public.can_view_user_status(s.user_id)
    )
  );
grant select, insert on public.user_status_views to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('status-media', 'status-media', false, 10485760, array['image/jpeg','image/png','image/webp','image/gif','image/heic'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- A user may upload only beneath their own folder. The app writes the status
-- row after the upload; visibility checks for downloads bind the object to that
-- row, its current audience, and the 24-hour expiry.
drop policy if exists status_media_insert_own on storage.objects;
create policy status_media_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'status-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
drop policy if exists status_media_read_visible on storage.objects;
create policy status_media_read_visible on storage.objects
  for select to authenticated
  using (
    bucket_id = 'status-media'
    and exists (
      select 1 from public.user_statuses s
      where s.media_path = storage.objects.name
        and s.expires_at > now()
        and public.can_view_user_status(s.user_id)
    )
  );
drop policy if exists status_media_delete_own on storage.objects;
create policy status_media_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'status-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Add Realtime safely so new statuses appear without relying on a long poll.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'user_statuses'
  ) then
    alter publication supabase_realtime add table public.user_statuses;
  end if;
end;
$$;
