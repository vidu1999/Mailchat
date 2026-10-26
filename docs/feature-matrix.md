# Feature matrix — spec vs. this repository

An audit of MailChat against the product plan (the numbered brief: MVP list,
phases, and the 28-screen wireframe). Every row was checked in the code, not
recalled.

**Headline: no, the system does not have all the features.** Messaging, auth,
groups, search, blocking and reporting are real. Media, push, presence, typing,
receipts-per-message, stories, calls and E2EE are not built. The sections below
say which, and where.

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
| Profile / avatar | 🟡 | Profile and edit screens exist; **avatar upload has no picker** — the storage bucket and policies exist, nothing writes to them |
| User search | ✅ | `public.search_users` (0005): username, display name, exact email |
| 1-to-1 conversations | 🧪 | `get_or_create_direct_conversation`, `direct_chat_screen.dart` |
| Real-time messaging | 🧪 | Realtime subscription in `message_service.dart` |
| Online / offline presence | ❌ | No presence channel, no heartbeat. The brief's `profiles.is_online` boolean does not exist here on purpose (§4) |
| Typing indicator | ❌ | Absent. Brief §20 is right that it belongs over Realtime as an ephemeral event, not a row |
| Sent / delivered / read | 🟡 | `message_receipts` table and `markReceipt()` exist; **nothing writes receipts**, so the ticks in the bubble only ever show "sent". The chat list's unread count is real and works off `last_read_message_id` |
| Reply | 🟡 | `reply_to_message_id` is in the schema, model and `sendText()`; **no UI** to start or render a reply |
| Reactions | ✅ | Fixed this branch: one per user, chips rendered, realtime updates, DB constraint in 0006 |
| Delete message | ✅ | Soft delete, confirm dialog, realtime propagation, "This message was deleted" |
| Edit message | ✅ | `editMessage()`, bubbles show "edited" |
| Image / file sharing | ❌ | `message_attachments` table, storage buckets and policies exist; `uploadFile()` exists in the client; **no screen picks a file or sends one**. The preview and media-viewer screens are unreachable |
| Push notifications (FCM) | ❌ | No Firebase dependency, no token registration, no send path. `notification_settings_screen.dart` is a UI with nothing behind it |
| Block / report | ✅ | `user_blocks`, `user_reports`, enforcement trigger, `blocked_users_screen.dart`, `report_user_screen.dart` |
| Responsive / professional UI | 🟡 | One breakpoint-aware theme, Material 3; the wireframe's tablet layout is not implemented |
| Groups | ✅ | Create, members, roles, add/remove, leave — `group_creation_screen.dart`, `group_details_screen.dart` |
| Voice messages | ❌ | No recorder, no player, no upload path |
| Voice / video calls | ❌ | Two screens exist with a timer and toggles but no media stack; unreachable, and flagged in-code as not a working call (§4) |
| Stories / status | ❌ | Absent: no table, no screen. Wireframe screens 20 and 27 |
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
| 16 | Media viewer | 🟡 screen exists, no way to reach it |
| — | Profile counters (Following / Followers, wireframe 7) | ❌ no follow graph; the screen shows identity only |
| — | Message info (long-press menu) | 🟡 the menu item exists and closes the sheet; it has no content behind it |
| 17 | Attachment preview | 🟡 same |
| 18–19 | Voice call, video call | ❌ |
| 20 | My status / stories | ❌ |
| 21 | Notification settings | 🟡 UI only, nothing persists |
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
| Storage with policies | 🟡 | Buckets and policies exist; no client writes to them |
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
| `profiles.is_online boolean` | Not stored | Brief §19 agrees: online state is not trustworthy as a column. It belongs on a Realtime presence channel, which is why it is ❌ rather than a wrong flag |
| `blocks` / `reports` | `user_blocks`, `user_reports` | Naming only; `user_reports` also carries a moderation status |
| `last_read_at` timestamp | `last_read_message_id` | A message id is monotonic and immune to clock skew between devices; a timestamp is not |
| `unique (message_id, user_id)` on reactions | Same intent, enforced as `message_reactions_one_per_user` (0006) | Matches your PK, keeps the surrogate id |
| WebRTC calls as MVP-adjacent | Not built | A call screen without a media stack is a fake. See `docs/calls.md` for what it actually needs |
| E2EE in the roadmap | Not built, not claimed | Brief §24 is right that it is a separate phase. Architecture is left E2EE-ready: ciphertext can replace `messages.text` without a schema change |

## 5. What is actually verified, and what is not

CI proves: the project analyzes clean, 163+ tests pass, and a debug APK builds.

CI cannot prove, and neither could this environment: that Realtime delivers,
that storage uploads work, that deep links open on a real device, that any screen
renders correctly against a live database, or anything about iOS. The database
side was fixed blind against error messages; `supabase/verify.sql` exists so a
live project can be checked in one paste.

## 6. Order I would build the gaps in

1. **Media** — image/file picker → `uploadFile` → attachment row. The schema, buckets and policies are already in place, so this is UI plus one service method.
2. **Receipts** — write `message_receipts` when a thread is read; makes ✓✓ mean something.
3. **Presence + typing** — one Realtime channel each; ephemeral, no schema change.
4. **Reply UI** — the column and plumbing already exist.
5. **FCM** — needs a Firebase project, which is a decision and an account, not just code.
6. **Calls** — signalling first (`calls`, `ice_candidates`), then `flutter_webrtc`, then TURN. The only item here that cannot be finished without two real devices.
7. **Stories, multi-device, monitoring, environments** — genuinely v2 work.
