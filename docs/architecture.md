# Architecture

What exists, how the pieces talk, and where the trust boundaries are. Kept
short on purpose: the migrations are the source of truth for the schema.

## Components

```text
        Flutter app (Android / iOS / desktop)
                    │
        HTTPS + WebSocket, never a service key
                    │
        ┌───────────▼────────────┐
        │       Supabase         │
        │  Auth · PostgREST      │
        │  Realtime · Storage    │
        └───────────┬────────────┘
                    │
             PostgreSQL + RLS
```

There is no application server and no Edge Function. Anything that needs
elevated rights is a `security definer` SQL function with a pinned
`search_path`, called through PostgREST. That keeps one security model: RLS
for row access, and a short, auditable list of functions for the cases RLS
cannot express.

All twelve functions, so the auditable list is complete:

| Function | Kind | Why it is not a plain query |
| --- | --- | --- |
| `handle_new_user()` | `security definer` | Runs on `auth.users` insert; the client cannot write there |
| `get_or_create_direct_conversation(uuid)` | `security definer` | Must insert the *other* user's membership row |
| `search_users(text, int)` | `security definer` | Matches against `auth.users.email`, which is never exposed |
| `is_conversation_member(uuid)` | `security definer` | Called **by** policies; reading membership must not recurse into RLS |
| `is_group_admin(uuid)` | `security definer` | Same |
| `is_group_owner(uuid)` | `security definer` | Same |
| `has_block_relation(uuid, uuid)` | `security definer` | Same |
| `enforce_message_sender_is_member()` | trigger | Sender/member invariant the client must not be trusted with |
| `enforce_block_between_users()` | trigger | Refuses messages across a block, either direction |
| `enforce_group_owner_membership()` | trigger | Owner is always a member with role `owner` |
| `touch_conversation_on_message()` | trigger | Keeps `conversations.updated_at` honest without trusting the client |
| `set_updated_at()` | trigger | Plain `updated_at` maintenance, no elevation |

## Entity relationships

```text
auth.users
    │ 1
    │
    ▼ 1
profiles ──────────────┬──────────────┬─────────────┬──────────────┐
    │                  │              │             │              │
    │ (member of)      │ (blocker)    │ (reporter)  │ (device)     │ (prefs)
    ▼                  ▼              ▼             ▼              ▼
conversation_members  user_blocks  user_reports  user_devices  notification_preferences
    │
    │ (belongs to)
    ▼
conversations
    │ 1
    ▼ n
messages ─────┬──────────────┬───────────────┐
    │         │              │               │
    ▼         ▼              ▼               ▼
message_attachments  message_reactions  message_receipts
```

Fourteen tables, all in `public`, all with RLS enabled.

| Table | Purpose | Notable constraint |
| --- | --- | --- |
| `profiles` | Public identity: username, display name, avatar, bio, discoverability | `username ~ '^[a-z0-9][a-z0-9_.]{2,29}$'`; unique on `lower(username)` |
| `conversations` | Direct or group thread | `type in ('direct','group')` |
| `conversation_members` | Membership, role, read cursor, mute | PK `(conversation_id, user_id)`; `last_read_message_id` drives unread counts |
| `messages` | Text (and future media) messages | Soft delete via `deleted_at`; `client_id` is a per-sender idempotency key |
| `message_attachments` | File metadata; bytes live in Storage | Nothing writes here yet — see the feature matrix |
| `message_reactions` | One emoji per user per message | `message_reactions_one_per_user` (0006) |
| `message_receipts` | Delivered/read per recipient | Nothing writes here yet |
| `user_blocks` | Directional block | Enforcement trigger refuses messages across a block |
| `user_reports` | Abuse reports with moderation status | `status in ('pending','reviewed','actioned','dismissed')` |
| `user_devices` | Device and FCM token registry | Unique `(user_id, device_id)`; no registration path yet |
| `notification_preferences` | Per-conversation and global mute | Two partial unique indexes (per-conversation, and one global row) |
| `calls` | Call signalling: status, SDP offer/answer (0007) | Status transitions and SDP ownership enforced by trigger; no media |
| `call_ice_candidates` | WebRTC ICE candidates (0007) | Append-only; insert only while ringing or accepted |
| `user_presence` | Last heartbeat per user (0008) | Readable only by its owner; everyone else goes through `get_presence()`, which masks it when `share_last_seen` is false |

## Request paths

**Sending a message**

```text
composer
  → MessageService.sendText()            optimistic bubble, client_id generated
  → POST /rest/v1/messages               RLS: sender_id = auth.uid() and member
  → trigger messages_sender_member_check  member of the conversation
  → trigger messages_block_check          neither party blocked the other
  → trigger messages_touch_conversation   bumps conversations.updated_at
  → Realtime INSERT                       both sides' bubbles reconcile by client_id
```

**Opening a chat from search**

```text
search result
  → POST /rpc/get_or_create_direct_conversation   advisory lock per member pair
  → conversation id (a bare JSON string — see RpcPayload)
  → GET /rest/v1/messages?conversation_id=eq.…
  → mark read: PATCH conversation_members.last_read_message_id
```

**The chat list**

One query against the `conversation_list` view (0004), which is
`security_invoker` so the caller's RLS applies. It joins the last visible
message, the caller's read cursor and — for direct chats — the other profile.
Ordering is `last_message_at desc nullslast, updated_at desc`.

The screen never computes an unread count itself. `unread_count` comes from the
view and is derived from `conversation_members.last_read_message_id`, so the only
way to change a badge is to move that cursor (which the chat screen does when it
opens a thread) and re-read. Two Realtime subscriptions decide when to re-read:
`messages` (anything the caller can see — no filter is possible, because the
table has no per-user column and RLS is what scopes it) and the caller's own
`conversation_members` rows. That is why a badge clears on another device too.

**Presence and last seen**

Two sources, deliberately:

| Signal | Source | Lifetime |
| --- | --- | --- |
| "In this conversation right now" | Realtime presence on `realtime:mailchat:presence:<conversationId>` | The channel |
| Typing | Broadcast on the same channel, 4 s expiry | Ephemeral |
| Last seen / online elsewhere | `user_presence.last_seen_at` heartbeat (30 s) written by `touch_last_seen()` | Durable |

`get_presence(uuid[])` is the only way to read someone else's row. It returns
rows only for users you share a conversation with, never across a block in
either direction, and nulls both fields when the target has `share_last_seen`
off — null meaning "unknown", which the UI renders as nothing rather than
"Offline".

## Where the trust boundary sits

| Trusted | Not trusted |
| --- | --- |
| RLS policies and the `security definer` functions | Anything the client sends |
| Database constraints (`check`, `unique`, FKs) | Client-side validation, which is only for nicer error messages |
| The publishable (`anon`) key in the app | Any key that can bypass RLS — `service_role` never ships |

See `docs/security.md` for the policies themselves and the email-discovery
trade-off.
