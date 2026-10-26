# Online status, last seen and typing

**Status:** 🧪 built — two independent mechanisms: a live Realtime channel for
"who is in this chat now", and a heartbeat row that makes "last seen 10:41 AM"
possible at all.
**Code:** `lib/shared/services/presence_service.dart`,
`lib/shared/services/last_seen_heartbeat.dart`,
`lib/shared/models/peer_presence.dart`,
`lib/features/conversations/presentation/screens/chat_list_screen.dart`,
`lib/features/privacy/presentation/screens/privacy_settings_screen.dart`
**Database:** `supabase/migrations/0008_presence_last_seen.sql`
**Tests:** `test/unit/presence_test.dart`, `test/unit/last_seen_test.dart`

## The two halves

| Question | Source | Lifetime |
| --- | --- | --- |
| Are they in this conversation right now? | Realtime presence on `realtime:mailchat:presence:<conversationId>` | While both have the screen open |
| Are they typing? | Broadcast `typing` event on the same channel | 4 seconds, then it expires |
| When were they last active anywhere? | `user_presence.last_seen_at` heartbeat, every 30 s | Persisted |

The first two are ephemeral on purpose: a `typing` row would be a write per
keystroke, and a stored `is_online` boolean would be wrong the moment a phone
loses signal. The third is durable because "last seen" is a question about the
past, which needs a stored timestamp.

## The heartbeat

```text
LastSeenHeartbeat.start()
  → touch_last_seen()            server stamps now()         (immediately)
  → Timer.periodic(30s)          touch_last_seen()           (while foreground)
  → app resumed                  touch_last_seen()           (immediately)

other user
  → get_presence([ids])          online = last_seen_at > now() - 75s
```

Nothing is sent when the app closes. A process can be killed, lose signal or be
swiped away without a chance to say goodbye, so the only reliable signal is the
last time it managed to speak — the row simply ages out. Someone therefore shows
as offline about a minute after they leave, which is correct rather than a bug.

`onlineWindow` (75 s) must stay larger than `heartbeatInterval` (30 s) or one
dropped beat would flicker everyone offline and back. A test pins that
relationship.

## Privacy

`user_presence.share_last_seen` is the switch behind **Privacy → Show online
status and last seen**. When it is off, `get_presence()` returns `null` for both
`online` and `last_seen_at` to everyone but the owner.

Null means **unknown**, not **offline**, and the UI respects that: a hidden user
gets no presence line at all. Rendering a grey "Offline" for someone who simply
did not share would be a claim the app cannot support.

## What the database enforces

| Rule | Where |
| --- | --- |
| You can only read your own `user_presence` row directly | `user_presence_select_self` policy |
| Writes go through `touch_last_seen()`; timestamps are server time | No insert/update policy, so the client cannot backdate |
| `get_presence()` returns rows only for people you share a conversation with | `shares_conversation_with()` |
| No presence across a block, in either direction | `get_presence()` block clause |
| At most 200 ids per call | Array slice inside `get_presence()` |
| Hidden users are masked inside the function, not the client | `share_last_seen` clause |

`shares_conversation_with()` exists because `conversation_members`' select policy
only shows the caller their own rosters, so a plain query cannot answer "do these
two users have a conversation in common".

## Where it is shown

| Place | Shows |
| --- | --- |
| Chat header | `typing...` → `Online` → `last seen 10:41 AM` / `last seen yesterday` / `last seen Oct 24` → nothing |
| Chat list avatar | A dot for direct-chat peers who are online right now |
| Chat list | Refreshed on the same 30 s cadence as the heartbeat |

## Failure modes

| Symptom | Cause | What to check |
| --- | --- | --- |
| Everyone shows as offline | Migration 0008 not applied | `supabase/verify.sql` row 12 |
| Your own status never appears to others | Old build on *their* device — the heartbeat is written by the app | Both devices need this build |
| A person shows no line at all | They turned sharing off | By design |
| Status stuck on "Online" after they left | Their last heartbeat is under 75 s old | Wait a minute |

## Known gaps

* Presence is not pushed: a ring or a badge cannot tell you someone came online.
* No "last active" in group member lists.
* Typing indicators are per conversation and are not shown in the chat list.
