# Testing

**Status:** CI runs analysis, the full test suite and an APK build on every push.
The **manual checklist at the end has not been executed**: nothing in this
repository has been exercised against a live Supabase project from the build
environment, so "the tests pass" is not the same as "the app works".

## What runs in CI

`.github/workflows/ci.yml` runs on every push and pull request:

| Step | Blocking? | What it proves |
| --- | --- | --- |
| `flutter pub get` | Yes | Dependencies resolve |
| `dart format --set-exit-if-changed lib test` | No | Reports formatting drift |
| `flutter analyze` | Yes | Lints configured as errors; analyzer findings are published as a check run |
| `dart run tool/check_config.dart` | Yes | Refuses a build with no configuration, and refuses placeholder keys |
| `dart run tool/check_migrations.dart` | Yes | Every migration is re-runnable; `apply_all.sql` has not drifted |
| `dart run tool/check_docs.dart` | Yes | Every document is linked and every path it names exists |
| `flutter test --coverage` | Yes | Unit and widget tests |
| `flutter build apk --debug --split-per-abi` | Yes | An installable APK exists; Gradle's "What went wrong" is re-emitted as an annotation |

Job logs are not readable from every environment, so the build step converts the
failure reason into `::error::` annotations. That change is what made the last two
build failures diagnosable at all.

## Test layout

```text
test/unit/
  validators_test.dart          email, password, username rules
  formatters_test.dart          timestamps, file sizes, last-seen wording
  models_test.dart              JSON parsing; conversation_list rows; copyWith
  attachment_test.dart          file-name sanitising, MIME guessing, size gate
  auth_deep_link_test.dart      parsing confirmation and recovery links
  auth_registration_test.dart   RegistrationResult outcomes
  call_signalling_test.dart     call states, permissions, duration, media flag
  env_file_test.dart            .env parsing and --dart-define precedence
  app_config_test.dart          configuration resolution
  anon_key_test.dart            the anon key is accepted and service_role rejected
  last_seen_test.dart           heartbeat window, hidden means silent
  presence_test.dart            presence payload shapes, typing TTL
  profile_search_test.dart      search query rules and empty-result wording
  postgrest_error_test.dart     PostgREST and auth errors become readable text
  reaction_summary_test.dart    reaction chip aggregation
  receipt_state_test.dart       sent / delivered / read from receipt rows
  rpc_payload_test.dart         scalar, rows and integer RPC replies

test/widget/
  message_bubble_test.dart      rendering, deleted placeholder, ticks, long words
  paste_link_screen_test.dart   the paste-a-link recovery path
```

Everything here is pure Dart/Flutter: no network, no database, no device. That is
the limit of what CI can prove, and it is why the feature documents distinguish
🧪 from ✅.

## The manual checklist

Work through this on a real device before calling the app functional. Every line
needs two accounts (`supabase/seed.sql` creates `alice@example.com` and
`bob@example.com`, password `MailChat123!`).

### Auth

- [ ] Register with a new email; the verification mail arrives from Supabase Auth
      (never simulated)
- [ ] Log in before confirming — expect a clear "email not confirmed" error
- [ ] Confirm via the link; it opens the app, not a browser error page
- [ ] Log in; restart the app; the session restores
- [ ] Log out; restart; you land on login
- [ ] Request a password reset and complete it from the emailed link
- [ ] Register a duplicate username — a friendly error, not a raw `23505`

### Messaging

- [ ] Send a message: immediate bubble, then `sent`
- [ ] Second device receives it live
- [ ] Airplane mode + send: bubble shows `failed`, not a lie
- [ ] React, edit, delete — each persists after a reload
- [ ] Reply to an older message: the quote renders, or "Earlier message" if off-page
- [ ] Receipts: the sender's tick goes delivered → read when the reader opens the thread

### Unread badges

- [ ] Message arrives while the list is on screen: preview and badge update without a pull
- [ ] Open the chat: badge clears, and stays cleared after going back
- [ ] Read on device B: the badge clears on device A
- [ ] `supabase/verify.sql` row 14 reads `ok` (a stale `conversation_list` view
      is the one cause the app cannot fix)

### Groups

- [ ] Create a group; the creator is `owner`
- [ ] The new group opens as a **message thread**, not a details page
- [ ] Post in the group from another account; it arrives live and the badge clears on open
- [ ] Promote a member to `admin`; a non-owner cannot
- [ ] Leave the group; it disappears from the list

### Attachments

- [ ] Send a photo: bubble preview renders
- [ ] Send a PDF: file card with name and size
- [ ] Tap each: the viewer opens via a signed URL
- [ ] Try a file over 10 MB: refused before upload
- [ ] A file with spaces and unicode in the name still uploads

### Presence

- [ ] Open the same chat on both devices: neither shows "typing" for itself
- [ ] Type: the other side sees "typing..." then it expires
- [ ] Background the app: after ~75 s the peer shows "last seen …"
- [ ] Turn off **Show online status and last seen**: the other side shows no line at all
- [ ] Direct chat list shows a dot for an online peer, and no dot for a hidden one

### Privacy

- [ ] Block a user: their next message is refused
- [ ] The blocked user does not appear in search
- [ ] Unblock: messaging works again
- [ ] Submit a report; the row lands in `user_reports` with status `open`

### Notifications

- [ ] The three switches survive an app restart (they are stored)
- [ ] Nothing is pushed, in foreground or background — expected, see
      [notifications.md](notifications.md)

### Calls

The first four need **two devices on the same Wi-Fi**, both signed in as
different accounts with a direct conversation open in the chat list.

- [ ] `supabase/verify.sql` row 11 is `ok` (tables exist with RLS)
- [ ] Call from A: B's phone shows the incoming-call screen within a second or two
- [ ] B accepts: both screens reach "Connected" and each can hear the other
- [ ] Video call: A's camera preview appears mirrored; B's video fills the screen
- [ ] Mute on one side silences it; camera-off shows a placeholder, not a black box
- [ ] Hang up on either side: both screens close and the row ends `ended`
- [ ] Decline: the caller sees "Declined" and the row ends `declined`
- [ ] Ring, then leave B's prompt untouched and swipe it away: the row ends `missed`
- [ ] Over mobile data with **no** TURN configured: expect "Could not connect".
      That is the documented behaviour, not a bug — add a relay to `TURN_URL`
