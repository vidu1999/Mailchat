# Notifications

**Events:** new messages and missed calls only. System/group-update events were removed in migration 0014. The database inbox and foreground realtime handling are implemented. Android background FCM code is now present, but delivery is only active after its private Firebase config, Edge Function, and Database Webhook are set up.

**Code:** `lib/shared/services/push_notification_service.dart`,
`supabase/functions/send-fcm/index.ts`, and
`lib/features/notifications/presentation/screens/notification_inbox_screen.dart`
**Database:** migrations `0013_notifications.sql` and `0014_remove_system_notifications.sql`

## Android setup

1. Add the Android Firebase app with package name `com.mailchat.mailchat` and place its `google-services.json` at `android/app/google-services.json`. This file is gitignored. The Android scaffold is generated locally; after adding the file, run `dart run tool/fix_android_build.dart` so the Google Services Gradle plugin is applied.
2. `main.dart` initializes Firebase when configured. After sign-in, the app asks for notification permission, registers the FCM token in the signed-in user's RLS-protected `user_devices` row, and updates it on token refresh. Sign-out removes this installation's token.
3. Deploy the trusted sender from the repository root:

   ```powershell
   supabase functions deploy send-fcm --project-ref YOUR_PROJECT_REF --no-verify-jwt
   ```

   The function requires `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON`, and `FCM_WEBHOOK_SECRET` Edge Function secrets. Supabase supplies its own `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the function. The service-account JSON must stay in Edge Function secrets, never in the app or Git.
4. Create a random webhook secret, and save it as the `FCM_WEBHOOK_SECRET` Edge Function secret. Use the same value as the webhook header described below. Never put it in the client `.env`.
5. In Supabase **Database → Webhooks**, create a webhook for `public.user_notifications`, **INSERT** only, method **POST**, URL:

   ```text
   https://YOUR_PROJECT_REF.supabase.co/functions/v1/send-fcm
   ```

   Add headers `Content-Type: application/json` and `x-mailchat-webhook-secret: YOUR_RANDOM_WEBHOOK_SECRET`. The function validates this header, reads Android device tokens server-side, obtains a short-lived Google OAuth token from the service-account key, and sends FCM HTTP v1 notification payloads. It removes tokens only when FCM explicitly reports them as unregistered.
6. If building from GitHub Actions, save the contents of `google-services.json` as a base64-encoded repository secret named `FIREBASE_ANDROID_JSON_BASE64`. Local builds use the ignored file directly.
7. Run `flutter pub get`, build/install the APK, open MailChat once while signed in (to register the token), allow Android notification permission, then put the receiving app in the background and send a **new** message from another account. Missed-call push is sent when the call row transitions to `missed`.

Use Firebase Console → Project settings → Service accounts to create the service-account JSON. In PowerShell, a random webhook secret can be generated with:

```powershell
$secret = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$secret
```

Paste that same value into the Edge Function secret and the webhook header. Do not send either secret in chat.

## Delivery behavior and limitations

* Android background notification payloads are displayed by Android/Google Play services; MailChat does not create a duplicate local alert. Tapping a message opens its conversation; tapping a missed-call alert opens call history.
* Android foreground behavior remains MailChat's realtime inbox/foreground alert. The request here removed system-update events, not message/call foreground behavior.
* This sends regular Android FCM notifications. Android/Samsung controls exact notification appearance and grouping; reproducing WhatsApp's exact stacked `MessagingStyle` requires extra native notification rendering and is not claimed here.
* Android force-stop prevents delivery until the app is opened again; Android 13+ permission must be granted. Samsung battery restrictions can delay delivery.
* The VAPID key is web-only and is not used by this Android sender. iOS requires APNs configuration; web background push needs its own service worker.
* FCM delivery itself is generally free, but Supabase Edge Function/database usage is subject to the project's plan quotas.

## Security and data

Message and missed-call rows are generated only for eligible recipients by database triggers that honor notification preferences and mutes. The Edge Function uses the service role only server-side to read token rows and delete expired tokens. No Firebase service-account key, FCM access token, or Supabase service-role key is included in the APK. Notification previews are capped at 240 characters; no email address is included.
