# Feature matrix — spec vs. this repository

An audit of MailChat against the product plan (the numbered brief: MVP list,
phases, and the 28-screen wireframe). Every row was checked in the code, not
recalled.

**Headline: not all of it — but the messaging core now is.** Messaging, auth,
groups, search, blocking, reporting, reactions, replies, read receipts, presence,
last seen, attachments, unread counts and calls are real (calls unverified on a
device). Push delivery, stories, voice messages, multi-device session management
and E2EE are not built. The sections below say which, and where.

Legend:

| Mark | Meaning |
| --- | --- |
| ✅ | Implemented, and exercised by CI (analysis, tests, build) |
| 🧪 | Implemented in code, but not verified against a live project from this environment |
| 🟡 | Partly there — the parts that exist are named |
| ❌ | Not implemented |
| 🚫 | Deliberately not built, with a reason (see §4) |

---

## 1. MVP list from the brief

| Feature | Status | Where |
| --- | --- | --- |
| Email/password authentication | 🧪 | `lib/shared/services/auth_service.dart`, `features/auth/` |
| Email verification | 🧪 | `email_verification_screen.dart`, deep-link handling in `core/deeplink/` |
| Password reset | 🧪 | `forgot_password_screen.dart`, `reset_password_screen.dart` |
| Session restoration | 🧪 | token refresh in `core/network/supabase_client.dart` |
| Username | ✅ | `profiles.username`, format enforced by a check constraint |
| Profile / avatar | 🟡 | Profile and edit screens exist; avatar upload still has no picker (the file picker now exists for chat attachments, so this is a small follow-up) |
| User search | ✅ | `public.search_users` (0005): username, display name, exact email — see [search.md](search.md) |
| 1-to-1 conversations | 🧪 | `get_or_create_direct_conversation`, `direct_chat_screen.dart` |
| Real-time messaging | 🧪 | Realtime subscription in `message_service.dart`; chat history is grouped under Today / Yesterday / weekday / date headings, and every bubble shows its local send time (`direct_chat_screen.dart`, `formatters.dart`, `message_bubble.dart`) |
| Online / offline presence | 🧪 | Two halves. Live: `PresenceService` joins a per-conversation Realtime channel (shows "Online" while both are in the thread). Durable: a 30 s heartbeat into `user_presence` (0008) plus `get_presence()`, which is what makes "last seen 10:41 AM" and the chat-list dots work at all. Online = heartbeat within 75 s; the privacy switch stores `share_last_seen` and the function returns nulls to everyone else. **Server side written blind — needs a live project** |
| Typing indicator | 🧪 | Broadcast event on the same channel, debounced to one event per pause, with a 4 s expiry so a dropped socket cannot leave someone typing forever. Shows in the app bar — [presence.md](presence.md) |
| Inbox filters, favourites and pins | 🧪 | Search plus All / Unread / Favourites and direct/group filters are implemented in Flutter and web. Favourites and pinned ordering are per-user `conversation_members` fields in migration 0011 and `conversation_list`; apply `supabase/apply_all.sql` and confirm `verify.sql` row 16 before use. |
| Sent / delivered / read | ✅ | Reading a thread writes `message_receipts` (`markReceivedAndRead`), receipts are embedded on each message so the tick is derived from them (`ReceiptState`), and a realtime subscription updates the sender's ticks live. Unread counts work off `last_read_message_id`, cleared by `mark_conversation_read()` (0009) which picks the newest message **in the database** and only moves forward — so a missed realtime event or a stale page can no longer leave a badge behind. The chat list reloads on new messages **and** on its own read cursor moving, zeroes the badge on tap, and logs `unread_count_not_cleared` if the server still disagrees |
| Reply | ✅ | Long-press → Reply shows a strip above the composer; the sent message carries `reply_to_message_id`, and the bubble renders the quoted parent (or "Earlier message" when it is off the loaded page) |
| Reactions | ✅ | Fixed this branch: one per user, chips rendered, realtime updates, DB constraint in 0006 |
| Delete message | ✅ | Soft delete, confirm dialog, realtime propagation, "This message was deleted" |
| Edit message | ✅ | `editMessage()`, bubbles show "edited" |
| Image / file sharing | 🧪 | Picked files stay staged until Send. `AttachmentService` uploads a set and creates one message with multiple `message_attachments`; image selections render as an inline album in one bubble with private signed URLs. 10 MB per file, up to 10 files per message. Browser has the same staged-send and album behavior. Uses first-party `file_selector` on Flutter (see §4) |
| Notification inbox / foreground delivery | 🧪 | Migration 0013 writes RLS-protected events for new messages, missed calls and system messages; mobile/browser subscribe in realtime, show an inbox/badge, and tap through to chat or call history. Preferences and mute rules are applied in database triggers. Live Supabase application/runtime remains unverified. This is not OS/background push. |
| OS/background push (FCM) | ❌ | No Firebase SDK, device-token registration, or trusted FCM sender; requires Firebase project credentials and a server-side delivery function. |
| Block / report | ✅ | `user_blocks`, `user_reports`, enforcement trigger, `blocked_users_screen.dart`, `report_user_screen.dart` |
| Responsive / professional UI | 🟡 | One breakpoint-aware theme, Material 3; the wireframe's tablet layout is not implemented |
| Groups | ✅ | Create, members, roles, add/remove, leave, **and a message thread**: groups now open the same chat screen as direct chats (the screen was always conversation-agnostic), so group messages can be read and sent and the group badge can clear. `group_details_screen.dart` is reached from the chat's info button |
| Voice messages | ❌ | No recorder, no player, no upload path |
| Voice / video calls | 🟡 | Signalling (0007) **and media** (`flutter_webrtc` via `call_media.dart`): a real peer connection, offer/answer/ICE through the database, incoming/active call screens, a participant-based call log on mobile and browser, profile name/avatar call-back, and mute/camera toggles. Not verified on a device. A public global relay is built in (`public_relay.dart`) so two phones on different networks can connect without a pasted TURN password; a project's own `TURN_URL` is added in front of it. Saving the call goes through `place_call` / `set_call_status` (0010) so a bad policy on `calls` cannot refuse a member. See [calls.md](calls.md). Transport policy is `all` even when TURN is configured, so a computer without a pasted relay can still connect on the same network; early candidates are buffered and the call row is polled so a missed realtime event cannot drop the answer. A ringing row older than 45 seconds is not shown. Each call logs `call_ice_config` (relay count, credentials redacted). After 15 seconds the screen names the gap (no TCP, rejected login, other phone silent) instead of a generic network sentence |
| Browser client, same system as the phone | 🧪 | `webapp/index.html` with `webapp/app.js`. Not Flutter web (`dart:io` still blocks `flutter run -d chrome`). Same GoTrue project, same `messages` / `calls` / `call_ice_candidates` / `user_statuses` tables, so browser and phone share chats, calls and Updates. Connected is gated on the peer connection. Not exercised against a live project from this environment. See [web.md](web.md) |
| Stories / status | 🧪 | Flutter and browser Updates feed with text/photo sharing, 24-hour expiry, view counts, private photo storage and profile-based visibility to direct MailChat conversations. Migration 0012 is not applied/verified on the user's Supabase project; media and RLS behavior still need live testing. See [status.md](status.md) |
| Multi-device | 🟡 | `user_devices` table; no session list, no "log out all devices", no token registration |
| End-to-end encryption | ❌ | Not implemented and not claimed (§4) |

## 2. Screens in the wireframe

| # | Screen | Status |
| --- | --- | --- |
| 1–6 | Splash, welcome, register, verify, login, forgot password | ✅ built |
| 7–9 | Profile, edit profile, privacy settings | ✅ built (avatar upload ❌) |
| 10–11 | Chat list, search users | ✅ built |
| 12–13 | New conversation, direct chat | ✅ built |
| 14–15 | Group chat, group details | ✅ built |
| 16 | Media viewer | ✅ reachable from an attachment; images render inline through a signed URL |
| — | Profile counters (Following / Followers, wireframe 7) | ❌ no follow graph; the screen shows identity only |
| — | Message info (long-press menu) | 🟡 the menu item exists and closes the sheet; it has no content behind it (receipts are shown as ticks in the bubble instead) |
| 17 | Attachment preview | 🟡 the picker flow supersedes it; the old placeholder screen is still routed |
| 18–19 | Voice call, video call | 🟡 built and reachable: incoming prompt, active call with mute/camera/flip, real WebRTC media. Unverified on two devices; mobile data needs a TURN relay pasted into `TURN_URL` |
| 20 | My status / stories | 🧪 Flutter and browser text/photo Updates; migration 0012 still needs applying and live verification |
| 21 | Notification settings | ✅ message switches persist per user; sound/vibration stay device-local by design |
| 22–23 | Blocked users, report user | ✅ built |
| 24 | Group creation | ✅ built |
| 25 | Application settings | 🟡 theme/language rows are present; language does nothing |
| 26 | Dark mode | ✅ dark theme defined and wired via `ThemeMode.system`; no manual switch |
| 27 | Tablet / large screen | ❌ |
| 28 | Linked devices | ❌ |

## 3. Engineering checklist from the brief

| Item | Status | Note |
| --- | --- | --- |
| Clean feature-first structure | ✅ | `lib/{core,features,shared}` as proposed |
| Riverpod | ❌ | The app uses `StatefulWidget` + service classes. Adding Riverpod now is a refactor, not a feature |
| PostgreSQL schema with ERD | ✅ | `supabase/migrations/0001`–`0006`; ERD and request paths in `docs/architecture.md` |
| Row Level Security everywhere | ✅ | 31 policies in `0003`, plus explicit `security definer` helpers; `verify.sql` reports any table with RLS off |
| Realtime over WebSockets | ✅ | `core/network/supabase_realtime.dart`; tables added to the publication in `0004` |
| Storage with policies | 🧪 | Attachments and status photos upload from the clients to private buckets. Status media is audience-checked and expires from app access after 24 hours; migration 0012 still needs applying and live verification. |
| Edge Functions | ❌ | None. Everything that needs elevation is a `security definer` SQL function |
| Unit / widget tests | ✅ | 14 test files, 163+ test declarations; `flutter analyze` is clean |
| Integration tests | ❌ | No `integration_test/` suite |
| CI/CD | ✅ | `.github/workflows/ci.yml`: analyze, tests, APK build |
| Environments (dev/staging/prod) | ❌ | One project; config is per-build via `.env` / `--dart-define` |
| Monitoring (Sentry) | ❌ | `AppLogger` writes structured lines to the console only |
| Docker | ❌ | Not needed for a Flutter + Supabase client |
| Postman/Bruno collection | ❌ | Absent |

## 4. Where this deliberately differs from the brief

Each of these is a decision, not an omission:

| Brief says | This repo does | Why |
| --- | --- | --- |
| `profiles.email` column | No email on `profiles` | The table is readable by every signed-in user, so that column would publish every address. Email search goes through `search_users` (0005), which returns profile fields and never the address |
| `profiles.is_online boolean` | `user_presence.last_seen_at` (0008), never a boolean | A stored `is_online` is wrong the moment a phone loses signal. A heartbeat is not: `online` is derived from how recent it is, so a killed process simply ages out. The column is on its own table because `profiles` is readable by every signed-in user and `get_presence()` has to be able to mask it |
| `blocks` / `reports` | `user_blocks`, `user_reports` | Naming only; `user_reports` also carries a moderation status |
| `last_read_at` timestamp | `last_read_message_id` | A message id is monotonic and immune to clock skew between devices; a timestamp is not |
| `unique (message_id, user_id)` on reactions | Same intent, enforced as `message_reactions_one_per_user` (0006) | Matches your PK, keeps the surrogate id |
| WebRTC calls as MVP-adjacent | Built with a real peer connection | A call screen without a media stack would be a fake, so the media layer was built first and the screen only ever shows "Connected" from `RTCPeerConnectionState` |
| Any file-picker plugin | `file_selector` (first-party) | `file_picker` 6.x declares the removed v1 Android embedding and 8.x needs a compileSdk the CI scaffold does not produce; both failed the APK build, so the first-party plugin was chosen |
| E2EE in the roadmap | Not built, not claimed | Brief §24 is right that it is a separate phase. Architecture is left E2EE-ready: ciphertext can replace `messages.text` without a schema change |

## 5. What is actually verified, and what is not

CI proves: the project analyzes clean, 260+ tests pass, and a debug APK builds (including the WebRTC dependency and the patched call permissions).

CI cannot prove, and neither could this environment: that Realtime delivers,
that storage uploads work, that deep links open on a real device, that any screen
renders correctly against a live database, or anything about iOS. The database
side was fixed blind against error messages; `supabase/verify.sql` exists so a
live project can be checked in one paste.

## 6. Order I would build the gaps in

1. ~~Receipts~~ — done: `markReceivedAndRead`, `ReceiptState`, live tick updates.
2. ~~Presence + typing~~ — done: `PresenceService` for the live channel, plus the durable heartbeat (`user_presence`, 0008) that gives last seen and the chat-list dots.
3. ~~Reply UI~~ — done: reply strip, quoted parent in the bubble.
4. ~~Notification settings~~ — global message, missed-call, and system-event switches persist to `notification_preferences`; the durable inbox and realtime foreground alerts are documented in [notifications.md](notifications.md).
5. ~~Media~~ — done: `file_picker` → `AttachmentService` → storage → attachment row.
6. **FCM** — needs a Firebase project, which is a decision and an account, not just code.
7. **Calls** — signalling first (`calls`, `ice_candidates`), then `flutter_webrtc`, then TURN. The only item that cannot be finished without two real devices.
8. **Stories** — text/photo Updates are implemented in Flutter and browser; migration 0012 needs applying and live RLS/media verification. Multi-device, monitoring and environments remain v2 work.
