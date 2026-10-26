# Notifications

**Status:** 🟡 preferences are real and persisted; **delivery is not wired.**
Nothing is pushed to a device, because push needs a Firebase project.
**Code:** `lib/shared/services/notification_service.dart`,
`lib/features/notifications/presentation/screens/notification_settings_screen.dart`
**Database:** `supabase/migrations/0001_core_schema.sql`
(`notification_preferences`, `user_devices`)
**Tests:** none directly — the JSON round trip is covered by
`test/unit/models_test.dart` for adjacent models

## What works today

| Piece | State |
| --- | --- |
| Notification settings screen | Global switches for messages, mentions and reactions |
| Persistence | Written to `notification_preferences` (one row per user, `conversation_id is null`) and reloaded on open, so the switches survive a restart |
| Per-chat mute | Schema supports it (`conversation_id` set, two partial unique indexes) — **no UI yet** |
| Device registry | `user_devices` table exists with `push_token`, `platform`, `last_active_at` — nothing writes to it |

The switches are honest about their scope: they record a preference that the
future sender must respect. Until a sender exists, they change nothing about what
the phone does.

## Why delivery is not here

| Piece | Blocked on |
| --- | --- |
| A Firebase project | Your Google account. `google-services.json` / `GoogleService-Info.plist` are per-project credentials and must not be committed |
| `firebase_messaging` | Adding it without those files fails the Android build, so it waits until the project exists |
| Token registration | An upsert into `user_devices.push_token` on login and on token refresh |
| Sending | A trusted server: a Supabase Edge Function, or a small service holding the FCM server key. **Never the app** |

## The order to build it in

1. Create the Firebase project; add Android (application id from
   `android/app/build.gradle` after scaffolding) and iOS.
2. Supply the config files from CI secrets, not from the repository.
3. Add `firebase_core` and `firebase_messaging`; initialise in `main()`.
4. On token refresh, upsert `user_devices` (`user_id`, `device_id`, `platform`,
   `push_token`).
5. Write an Edge Function that runs on `messages` insert: look up recipient
   tokens, drop the sender, apply `notification_preferences` (global and
   per-conversation), and post to FCM.
6. Deep-link from the payload into the conversation
   (`AppRoutes.directChat` with `conversationId`).

## Rules that must not be broken

* The FCM **server key never ships in the app**. A client that can send
  notifications can notify any user about anything.
* Preferences are evaluated **server-side**. A muted user must not be woken by a
  client that ignores the setting.
* Do not claim push works because the switches save. They are two different
  features, and the screen's own footnote says so.

## What a user sees today

Opening Notification settings shows three switches that save. No banner, sound
or badge appears for anything, in the foreground or background: the app has no
notification integration at all. This is the largest user-visible gap left in the
project.
