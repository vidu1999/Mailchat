# Unread counts and the read cursor

**Status:** 🧪 built — the count is computed by the database and cleared by a
database function; the app never invents a number.
**Code:** `lib/features/conversations/presentation/screens/chat_list_screen.dart`,
`lib/shared/services/conversation_service.dart`,
`lib/features/messaging/presentation/screens/direct_chat_screen.dart`
**Database:** `supabase/migrations/0004_views_storage_realtime.sql`
(`conversation_list`), `supabase/migrations/0009_read_cursor.sql`
(`mark_conversation_read`)
**Tests:** `test/unit/models_test.dart` (`ConversationListItem.copyWith`),
`test/unit/rpc_payload_test.dart` (`RpcPayload.integer`)

## The rule

> A conversation is unread by as many messages as are **newer than your read
> cursor**, **not sent by you**, and **not deleted**.

That rule lives in `conversation_list` (migration 0004), not in the app:

```sql
count(*) from messages um
 left join messages rm on rm.id = cm.last_read_message_id
where um.conversation_id = c.id
  and um.created_at > coalesce(rm.created_at, '-infinity')
  and um.sender_id <> cm.user_id
  and um.deleted_at is null
```

The cursor is a **message id**, not a timestamp: ids are monotonic and immune to
clock skew between devices, whereas a `last_read_at` timestamp is not.

## Clearing a badge

Opening a thread calls `mark_conversation_read(conversation_id)` (migration
0009). The function:

1. checks membership itself — it is `security definer`, so RLS does not protect
   it, and a non-member gets `42501`;
2. picks the newest non-deleted message **in the table**, not the newest message
   the app has loaded;
3. moves the cursor only if that is at or after where the cursor already is;
4. returns how many messages the server still counts as unread.

Then it re-reads the view on the way back. `0` means cleared; a positive number
means something arrived while the write ran.

### Why the phone is not allowed to choose the cursor

The first version sent `last_read_message_id` from the app, using whichever
message it believed was newest. That produced a reproducible bug: open a chat,
come back, the badge is still there. Three ways in:

* the screen had not loaded the newest rows (page of 50, missed realtime event,
  resumed app), so the cursor landed behind the newest message;
* two devices marking the same thread read out of order left the cursor on the
  older message;
* a conversation with no loaded messages asked to mark read and skipped the
  write entirely.

All three are now impossible: the newest row is the database's business, and the
cursor cannot move backwards.

## Keeping the list live

`ChatListScreen` reloads on two realtime signals:

| Channel | Table | Why |
| --- | --- | --- |
| `realtime:mailchat:inbox:<userId>` | `messages` | A new message changes both the preview and the count |
| `realtime:mailchat:reads:<userId>` | `conversation_members` (filtered to your rows) | Reading on another device must clear the badge here too |

Neither channel can be filtered by conversation — `messages` has no per-user
column and realtime filters support single-column equality — so RLS is what
scopes the stream. Bursts are debounced into one reload.

While a chat is open, its row is pinned to zero so that a reload triggered by
the read write itself cannot flash the old count back. The pin is released when
the chat screen pops, which is the first moment the user could see the list
again; at that point the server's answer wins, even if it is a badge.

## Failure modes

| Symptom | Cause | Check |
| --- | --- | --- |
| Badge stays after opening the chat | `mark_conversation_read` missing | `supabase/verify.sql` row 13 |
| Badge shows a number that does not match the thread | Stale `conversation_list` view (hand-applied) | `supabase/verify.sql` row 14; re-paste `apply_all.sql` |
| Badge returns after being cleared on another device | The other screen wrote a cursor from a stale page | Fixed by 0009; both devices must run that build |
| `42501` in the log next to `chat_mark_read` | The conversation id does not match a membership row | The row was probably deleted or the user left the group |

The app logs `unread_count_not_cleared` with the conversation id when a badge
survives a read and the server still counts something — that is the difference
between "the write failed" and "the view is stale", and it is the first thing to
grep for.
