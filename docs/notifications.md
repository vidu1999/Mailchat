# Notifications

**Status:** database-backed notification inbox, in-app navigation, and foreground realtime alerts are implemented. **Background/OS push is not implemented.** A trusted Firebase Cloud Messaging sender and project credentials are still required.

**Code:** `lib/shared/services/notification_service.dart`,
`lib/features/notifications/presentation/screens/notification_inbox_screen.dart`,
`lib/features/notifications/presentation/screens/notification_settings_screen.dart`,
`webapp/app.js`
**Database:** `supabase/migrations/0013_notifications.sql` (and earlier core notification preferences)

## What works

| Piece | State |
| --- | --- |
| New-message event | A database trigger writes a per-recipient inbox row after a message insert; sender is excluded. Global/per-chat message enable and mute preferences are applied on the server. |
| Missed-call event | When a call row transitions to `missed`, both participants get a call-specific inbox event, subject to call preferences and mute. |
| System event | `messages.type = 'system'` and group membership joins/leaves create system-update inbox events for eligible conversation members, subject to system preferences. |
| Durable inbox | RLS limits reads/updates/deletes to the owner. The client can update only `read_at`; notification content and ownership are not client-writable. |
| Realtime / foreground | Supabase Realtime refreshes the mobile and browser inbox while the app is connected. Mobile shows a foreground alert and an unread badge; browser shows a live inbox update. |
| Tap-through | Message/system events open the corresponding conversation. Missed-call events open call history. These are in-app deep links and work after app sign-in. |
| Preferences | Account switches persist for messages, missed calls and system events. Existing mentions/reactions preferences are retained. |
| Per-chat mute | Existing `notification_preferences` rows and conversation-member mute fields are respected by the database trigger; dedicated mute-management UI is not yet present. |

## What does not work

There is no FCM token registration, Firebase SDK setup, background sender, Android/iOS OS notification, or notification delivery while the app is closed/disconnected. Foreground realtime is not a substitute for OS push. The `user_devices` table exists but is not used for token registration. Notification events are created in the database and become visible after migration `0013_notifications.sql` has been applied.

To enable OS push later, create the Firebase project and native config files outside Git, register device tokens, and add a trusted Supabase Edge Function or server that checks RLS-equivalent recipient eligibility and preferences before sending FCM. Never put an FCM server credential or Supabase service-role key in the client.

## Applying the database changes

The one-paste bundle `supabase/apply_all.sql` includes the migration and verifier. Apply it in Supabase SQL Editor only when ready to update the project; the inbox cannot work against a database that has not applied migration 0013. `supabase/verify.sql` checks that the notification table is in the Realtime publication.

## Security and event semantics

* Inbox rows are private to `user_id`; Realtime relies on the same RLS policy.
* Message previews are limited to 240 characters. No email address or device token is copied into an event.
* The database trigger applies existing global/per-conversation mutes and event preferences before inserting.
* Messages authored by the recipient do not notify that recipient.
* A missed call must first be transitioned to `missed` by the call lifecycle; a merely ringing call does not produce a missed-call inbox event.
* Do not describe this as end-to-end encrypted delivery or OS push. The inbox is a normal server-side database record protected by RLS.
