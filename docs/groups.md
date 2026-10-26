# Groups

**Status:** 🧪 built — creation, roles, membership changes, leaving and a working
group message thread.
**Code:** `lib/features/groups/presentation/screens/group_creation_screen.dart`,
`lib/features/groups/presentation/screens/group_details_screen.dart`,
`lib/features/messaging/presentation/screens/direct_chat_screen.dart` (the chat
thread, which serves groups as well as direct chats),
`lib/shared/services/conversation_service.dart`
**Database:** `supabase/migrations/0001_core_schema.sql` (`conversations`,
`conversation_members`), `0002_functions_triggers.sql`
(`enforce_group_owner_membership()`), `0003_rls_policies.sql`
**Tests:** `test/unit/models_test.dart`

## What works

| Capability | Behaviour |
| --- | --- |
| Create | Name (required, ≤100 chars), description (≤500), member picker |
| Owner | The creator is inserted as `owner` by a trigger, not by the app |
| Thread | Groups open the same chat screen as direct chats: history, send, replies, reactions, attachments |
| Info | Members, roles and Leave are behind the info button in the chat app bar |
| Roles | `owner`, `admin`, `member`; promoted/removed by an owner/admin |
| Add / remove | `addMembers()` / `removeMembers()`, subject to RLS |
| Leave | Removes your membership row and returns to the chat list |
| Badge | Group unread counts clear the same way direct chats do — see [unread.md](unread.md) |

Before this round, tapping a group opened the *details* screen — a member list
with no messages. A group could be created and messages could arrive in it, but
they could not be read, sent, or marked read, so a group badge could never
clear. The chat screen was always conversation-agnostic, so the fix was to route
groups to it and move the member list behind an app-bar button.

## Roles

| Role | Can |
| --- | --- |
| `owner` | Everything, including promoting and removing admins |
| `admin` | Add and remove members, change roles for members |
| `member` | Read, send, leave |

The creator's membership row is written by `enforce_group_owner_membership()` at
insert time, not by the app — so a client cannot create a group it does not own,
and cannot forget to add itself. There is no trigger stopping an owner from
leaving their own group; the roster policy lets anyone delete their own
membership row, which is what "Leave group" does.

## Rules the database enforces

| Rule | Where |
| --- | --- |
| Group has a name | App-level (`maxGroupNameLength`); `conversations.name` is nullable so direct chats are unaffected |
| Creator becomes owner | `enforce_group_owner_membership()` |
| Only admins and owners change roles | `conversation_members_update_own` policy + `is_group_admin()` |
| Only members see the roster | `is_conversation_member()` in the select policy |
| Only an owner may delete the group | `conversations_delete_owner` policy |
| Blocked pairs cannot post | `enforce_block_between_users()` on `messages` |

## Failure modes

| Symptom | Cause | What the app does |
| --- | --- | --- |
| "Group name is required" | Empty name | Refused before the request |
| Cannot add a member | You are not an admin/owner | The insert fails; the error is shown verbatim |
| Group disappears | You left it, or you were removed | It is gone from the list, which is correct — membership *is* visibility |
| Messages arrive but no badge | Old build without the cursor fix | Update; see [unread.md](unread.md) |

## Known gaps

* No group avatar upload (the column exists: `conversations.avatar_path`).
* No in-app invitation or join-by-link; members are added by an existing
  admin/owner from the member picker.
* No "muted group" toggle in the UI yet — `conversation_members.notifications_muted`
  exists and the chat list renders a muted icon if it is ever set.
* No per-group permissions beyond the three roles.
