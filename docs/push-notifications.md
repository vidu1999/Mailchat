# Push notifications

Status: **not wired.** Preferences are stored; delivery is not.

What exists:

- `notification_preferences` (0001) with per-user and per-chat rows, and
  `NotificationService` reading and writing the global row, so the switches in
  Notification settings survive a restart.
- `user_devices` (0001): device name, platform, `fcm_token`, last active.

What is missing, and why it cannot be done in this repository alone:

| Piece | Blocked on |
| --- | --- |
| A Firebase project | Your Google account. `google-services.json` and `GoogleService-Info.plist` are per-project credentials and must not be committed |
| `firebase_messaging` dependency | Adding it to a build without those files fails at Android build time, so it waits until the project exists |
| Token registration | `user_devices.fcm_token` per device, written on login and on token refresh |
| Sending | Needs a trusted server. The options are a Supabase Edge Function or a small service holding the FCM server key — never the app |

## Order to do it in

1. Create the Firebase project; add Android (application id
   `com.example.mailchat` unless you have changed it) and iOS.
2. Drop the config files in `android/app/` and `ios/Runner/`, and add them to
   `.gitignore` — or better, supply them in CI from secrets.
3. Add `firebase_core` and `firebase_messaging`; initialise in `main()`.
4. On token refresh, upsert a row in `user_devices`.
5. Write an Edge Function that, on `messages` insert, looks up the recipients'
   tokens, drops the sender, and posts to FCM. Respect
   `notification_preferences` there, not in the app.
6. Deep-link from the notification payload to the conversation.

## What you should not do

Do not put the FCM server key in the app, and do not send from the client: a
client that can send notifications can notify any user about anything. That
boundary is the same one described in `docs/security.md`.
