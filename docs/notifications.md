# Notifications

**Current scope:** message and missed-call notifications only. System/group-update notifications were removed by migration 0014. The durable inbox and foreground realtime handling are implemented. **Background/OS push is still not implemented**: the Firebase SDK, token registration, and trusted FCM sender are absent.

**Code:** `lib/shared/services/notification_service.dart`,
`lib/features/notifications/presentation/screens/notification_inbox_screen.dart`,
`lib/features/notifications/presentation/screens/notification_settings_screen.dart`,
`webapp/app.js`
**Database:** migrations `0013_notifications.sql` and `0014_remove_system_notifications.sql`

## Current behavior

| Event | Behavior |
| --- | --- |
| New message | A database trigger writes an inbox event for conversation members other than the sender, subject to global/per-chat message settings and mutes. |
| Missed call | A transition to `missed` writes an event for both participants, subject to call settings and mutes. |
| System/group update | Disabled. System chat messages and membership changes do not create notification events. |
| Foreground | The connected app receives realtime events and can show its inbox/foreground alert. This is not an Android notification while MailChat is backgrounded or closed. |
| Tap-through | Inbox message events open the conversation; missed-call events open call history. |

## Why background/OS push does not work yet

`FCM_PROJECT_ID` identifies the Firebase project and `FCM_VAPID_KEY` is for browser push; neither sends notifications. This repository does not yet register FCM device tokens, include the Firebase messaging client SDK/native setup, or deploy a trusted server-side FCM sender. The `user_devices` table is not currently used for token registration.

A working Android background path needs Firebase Android app configuration, the Flutter messaging integration and notification handling, token registration, and a deployed server/Edge Function that reads eligible message/missed-call events and sends them through FCM. Store the Firebase service-account credential as a Supabase server secret, never in the app `.env`, APK, or Git. iOS additionally needs APNs setup; web background push needs its own service worker and browser permission.

## Database and security

The one-paste bundle `supabase/apply_all.sql` includes migrations 0013 and 0014 and the verification query. Migration 0014 removes existing system-event inbox rows, the membership-event trigger, and the system preference. Inbox rows remain RLS-protected by owner; clients may change only `read_at`. Message previews are capped at 240 characters and do not contain email addresses or device tokens.

The inbox is a normal server-side database record. Do not describe it as end-to-end encrypted or as OS/background push.
