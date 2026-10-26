# Messaging

**Status:** 🧪 built — sending, realtime, edits, deletes, replies and delivery
ticks all work in code; none of it has been exercised against a live project
from this build environment.
**Code:** `lib/shared/services/message_service.dart`,
`lib/features/messaging/presentation/screens/direct_chat_screen.dart`,
`lib/shared/widgets/message_bubble.dart`
**Database:** `supabase/migrations/0001_core_schema.sql` (tables),
`0002_functions_triggers.sql` (enforcement), `0004_views_storage_realtime.sql`
(realtime publication)
**Tests:** `test/unit/models_test.dart`, `test/unit/receipt_state_test.dart`,
`test/widget/message_bubble_test.dart`

## What works

| Capability | Behaviour |
| --- | --- |
| Send text | The bubble appears immediately with `pending`, then is replaced by the stored row with `sent` |
| Realtime | Both sides see new messages without polling |
| Edit | Long-press your own message → Edit; the bubble shows "edited" |
| Delete | Long-press your own message → Delete; renders "This message was deleted" for everyone |
| Reply | Long-press → Reply; the composer shows a strip and the sent bubble quotes the parent |
| Ticks | Sent / delivered / read, derived from receipt rows, not from a column on the message |
| Pagination | 50 messages per page, cursor by `created_at` |
| Offline failure | A send that cannot reach the server shows `failed` rather than pretending |

## How a message travels

```text
composer
  → MessageService.sendText()             optimistic bubble, client_id generated
  → POST /rest/v1/messages                RLS: sender_id = auth.uid() and member
  → messages_sender_member_check          sender must be a member
  → messages_block_check                  neither party blocked the other
  → messages_touch_conversation           bumps conversations.updated_at
  → Realtime INSERT                       both sides reconcile by client_id
```

`client_id` is a per-sender idempotency key. It exists so the optimistic bubble
and the realtime insert can be matched and one of them dropped; without it a
sender sees their message twice for as long as the round trip takes.

## Rules the database enforces

| Rule | Where | Client mirror |
| --- | --- | --- |
| Only members may send into a conversation | `enforce_message_sender_is_member()` | composer hidden when not a member |
| A blocked pair cannot message | `enforce_block_between_users()` | send fails with a readable error |
| Only the author may edit or delete | RLS `messages_update_author` | Edit/Delete hidden on other people's bubbles |
| Deletes are soft | `deleted_at`, never a row removal | bubble renders the placeholder |
| Length limit | `messages.text` constraint + `AppConstants.maxMessageLength` | counter / validation before send |

Deleting is soft on purpose: receipt rows, replies and attachment rows all point
at the message, and a hard delete would leave replies quoting something that no
longer exists.

## Delivery ticks

A receipt is written by the **recipient**, because RLS only lets a user create
their own receipt row. Opening a thread calls `markReceivedAndRead()`, which
looks at the last 50 messages from the other side, skips the ones already marked
read, and upserts the rest. `ReceiptState.statusFrom()` then folds a set of
receipt rows into one of `sent` / `delivered` / `read` for display.

Failure mode worth knowing: ticks only update live for messages on screen. For a
message that has scrolled out of the loaded page there is nothing to update, and
the tick is recomputed when the thread is reopened.

## Failure modes the user can hit

| Symptom | Cause | What to do |
| --- | --- | --- |
| Message stuck on `pending` | No network, or the insert was rejected | The optimistic bubble turns `failed`; check the log line `message_send_failed` |
| "Message blocked" | One side blocked the other | Unblock from Privacy → Blocked users |
| Duplicate bubble | `client_id` missing on an older client | Update the app; the reconciliation key is what removes it |
| Reply shows "Earlier message" | The parent is older than the loaded page | Scroll up to load it; the quote is not silently dropped |

## Known gaps

* No message search.
* No forward, no copy-multiple, no scheduled send.
* Reactions are limited to the fixed palette in `message_bubble.dart`.
* Nothing here is E2EE: the server stores plaintext `messages.text`. See
  [security.md](security.md) for the reasoning and what an E2EE phase would need.
