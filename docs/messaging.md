# Messaging

**Status:** 🧪 built — sending, realtime, edits, deletes, replies and delivery
ticks all work in code; none of it has been exercised against a live project
from this build environment.
**Code:** `lib/shared/services/message_service.dart`,
`lib/features/messaging/presentation/screens/direct_chat_screen.dart`,
`lib/shared/widgets/message_bubble.dart`
**Database:** `supabase/migrations/0001_core_schema.sql` (tables),
`0002_functions_triggers.sql` (enforcement), `0004_views_storage_realtime.sql`
(realtime publication), `0011_chat_list_preferences.sql` (favourites and pins)
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
| Inbox filters and preferences | All / unread / favourites filters, text search, direct/group filtering, and per-user favourite/pin flags. Pins sort first; backed by migration 0011 and shared between phone and browser. |

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

The socket, not the request, is what makes this feel instant. Two details in
`lib/core/network/supabase_realtime.dart` matter when the network is flaky,
because a phone loses and regains connectivity constantly:

* **Re-join on reconnect.** Supabase forgets a channel when the socket closes,
  and `join()` is only called when a screen mounts. Without re-joining, a
  reconnected app looks connected in the log and delivers nothing — no messages,
  no receipts, no incoming calls — until it is restarted.
* **Retry when the network returns.** Backoff alone can wait a minute after
  connectivity is back. Any successful HTTPS response is proof the network works,
  so `lib/core/network/connectivity_signal.dart` carries that fact to the socket
  and ends the wait (throttled to one attempt every 2 s).

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
| Live messages stop arriving while the app is open | The realtime socket dropped (network change, sleep) | It reconnects by itself: 5 s, 10, 20, 40, then 60 s, and immediately after any successful request proves the network is back. On reconnect it **re-joins every channel**, so delivery resumes without a restart |

### When the phone is offline

The app now says so instead of looking frozen. Every transport failure — a REST
call or a realtime reconnect attempt — is published to `ConnectionStatus`
(`lib/core/network/connection_status.dart`), and `OfflineBanner` shows a strip at
the top of the chat list and of the open thread:

```text
☁ This phone cannot look up addresses right now. Messages will not send until it
  can — check Wi-Fi or mobile data, then turn off Data saver or Private DNS.
```

Four properties of that banner are deliberate:

* **Only a successful request clears it.** A dropped socket never does, because
  that is precisely the moment "back online" would be a lie.
* **One notification per outage, not one per failure.** During an outage every
  heartbeat and every retry fails; rebuilding the banner for each would be work
  spent in the wrong place.
* **The sentence depends on the cause** — DNS, no route, timeout, TLS
  interception and a refused connection have five different fixes, and the
  banner names the one that applies.
* **No retry button.** The app is already retrying on its own; a button would
  imply a control it does not have.

There is still no offline queue: a message sent while offline fails and says so,
it is not held and delivered later. That stays in [Known gaps](#known-gaps).

## Known gaps

* No message search.
* No forward, no copy-multiple, no scheduled send.
* Reactions are limited to the fixed palette in `message_bubble.dart`.
* Nothing here is E2EE: the server stores plaintext `messages.text`. See
  [security.md](security.md) for the reasoning and what an E2EE phase would need.

## Chat timeline timestamps

The message list groups consecutive messages by the device's local calendar day.
Headings read **Today**, **Yesterday**, a weekday for recent history, or
`dd/MM/yyyy` for older history. Every bubble shows the exact local send time
next to its receipt ticks; the date heading is separate from the per-message
time. Formatting lives in `core/utils/formatters.dart` and the timeline is built
in `features/messaging/presentation/screens/direct_chat_screen.dart`.
