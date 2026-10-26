-- ============================================================================
-- MailChat — 0006 one reaction per user
-- ----------------------------------------------------------------------------
-- The original constraint was unique (message_id, user_id, reaction), which
-- permits one user to hold several emoji on the same message. The app has
-- always intended one: the picker replaces rather than stacks, and the UI shows
-- a single chip per person. Until now only the client enforced that, so a race
-- between two devices — or any other client — could leave two rows and inflate
-- the count on everyone's screen.
--
-- The spec models this as primary key (message_id, user_id); a unique
-- constraint with the existing surrogate id is equivalent and less disruptive.
-- ============================================================================

-- Collapse any duplicates that already exist, keeping the newest row per user
-- per message. Without this the new constraint cannot be created.
delete from public.message_reactions older
using public.message_reactions newer
where older.message_id = newer.message_id
  and older.user_id = newer.user_id
  and (older.created_at, older.id) < (newer.created_at, newer.id);

-- Postgres auto-names a unique(...) table constraint, so match that name and
-- also the name we are about to create, making this re-runnable.
alter table public.message_reactions
  drop constraint if exists message_reactions_message_id_user_id_reaction_key;

alter table public.message_reactions
  drop constraint if exists message_reactions_one_per_user;

alter table public.message_reactions
  add constraint message_reactions_one_per_user unique (message_id, user_id);

comment on constraint message_reactions_one_per_user on public.message_reactions is
  'One emoji per user per message: changing a reaction replaces it.';
