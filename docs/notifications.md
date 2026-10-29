# Notifications

**Events:** new messages and missed calls only. System/group-update events were removed in migration 0014. Android now displays background FCM as locally rendered, actionable notifications. End-to-end delivery of the new action flow still needs a rebuild and Android-device check after deployment.

**Code:** `lib/shared/services/android_notification_controller.dart`,
`lib/shared/services/push_notification_service.dart`, and
`supabase/functions/send-fcm/index.ts`.
**Database:** migrations `0013_notifications.sql` and `0014_remove_system_notifications.sql`.

## Android setup

1. Add the Android Firebase app with package name `com.mailchat.mailchat` and place its `google-services.json` at `android/app/google-services.json`. This file is gitignored. The Android scaffold is generated locally; the build helper applies Google's Gradle plugin when the file exists, enables core library desugaring, adds the notification-action receiver, and installs the MailChat launcher and notification icons from `assets/`.
2. `main.dart` initializes Firebase when configured. After sign-in, the app asks for notification permission, registers the FCM token in the signed-in user's RLS-protected `user_devices` row, and updates it on token refresh. Sign-out removes this installation's token.
3. **Install the updated Android client before changing the sender.** From the repository root, run `flutter pub get`, build and install a new APK, open MailChat while signed in, and allow notification permission. This ordering avoids a delivery gap: the old sender still sends OS-rendered notification payloads until the new client is installed.
4. Deploy the updated trusted sender from the repository root:

   ```powershell
   supabase functions deploy send-fcm --project-ref YOUR_PROJECT_REF --no-verify-jwt
   ```

   Required Edge Function secrets are `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON`, and `FCM_WEBHOOK_SECRET`. Supabase supplies its own `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to the function. Service-account JSON stays in Edge Function secrets, never in the app or Git.
5. In Supabase **Database → Webhooks**, create a webhook for `public.user_notifications`, **INSERT** only, method **POST**, URL:

   ```text
   https://YOUR_PROJECT_REF.supabase.co/functions/v1/send-fcm
   ```

   Add headers `Content-Type: application/json` and `x-mailchat-webhook-secret` with the exact value of the `FCM_WEBHOOK_SECRET` secret.
6. Create a second webhook with the same URL and headers, this time for `public.calls`, **INSERT** only. It sends a ringing call to the callee's registered Android devices. It honors call preferences and active conversation mutes.
7. If building from GitHub Actions, save the contents of `google-services.json` as a base64-encoded repository secret named `FIREBASE_ANDROID_JSON_BASE64`. Local builds use the ignored file directly.
8. In the updated client, background message pushes are data-only and are rendered by `flutter_local_notifications`. After redeploying the sender, background the receiving app and send it a **new** message from another account. Keep both the `user_notifications` and `calls` Database Webhooks enabled.

Use Firebase Console → Project settings → Service accounts to create the service-account JSON. In PowerShell, generate a random webhook secret with:

```powershell
$secret = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$secret
```

Save that value as `FCM_WEBHOOK_SECRET` and use the same value in both webhook headers. Do not send either secret in chat.

## Android notification actions

* Messages from the same conversation update one notification, with up to three recent unread message previews in Android's Inbox style.
* **Reply** opens Android's inline reply field. Submitting sends the text through MailChat using the signed-in account and advances the conversation's read cursor; it does not post a message under another account.
* **Mark as read** clears that conversation's notification inbox rows and unread message cursor.
* **Mute for 8 hours** suppresses future message and call notifications for that conversation; it expires automatically.
* Incoming call notifications have **Answer** and **Decline** actions. Answer opens MailChat and starts the real microphone/camera and WebRTC negotiation; the call is not treated as connected until the peer connection actually connects. Decline marks the ringing call declined. Tapping the body opens the incoming-call prompt without auto-answering.
* Missed-call alerts open call history and do not show message actions.

## Delivery behavior and limitations

* Foreground behavior remains MailChat's realtime inbox/foreground alerts. This request removed system-update events, not message or missed-call alerts.
* This uses Android local notification styling and action buttons. Android/Samsung may display/group them differently depending on OS version, device settings and notification permission.
* Android force-stop prevents delivery until the app is opened again; Android 13+ notification permission must be granted. Samsung battery restrictions can delay delivery.
* The VAPID key is web-only and is not used by this Android sender. iOS requires APNs configuration; web background push needs its own service worker.
* FCM delivery itself is generally free, but Supabase Edge Function/database usage is subject to project plan quotas.

## Security and data

Message and missed-call inbox rows are generated only for eligible recipients by database triggers that honor notification preferences and mutes. The Edge Function uses the service role only server-side to read token rows, notification previews and preferences, and remove expired tokens. Notification action callbacks use the signed-in client session and existing RLS-protected APIs. No Firebase service-account key, FCM access token, or Supabase service-role key is included in the APK. Notification previews are capped at 240 characters; no email address is included.
