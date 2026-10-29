# Updates / status

**Status:** 🧪 implemented in Flutter and the browser; the database migration is
written but must be applied to the user's Supabase project before sharing works.
No live Supabase or device verification was available in this build.

## What it does

- Share a text update (up to 700 characters) or one photo (up to 10 MB), with an
  optional caption.
- Updates expire after 24 hours, using server timestamps.
- The Updates screen groups active updates by MailChat profile, shows unread
  rings and update counts, and opens an in-app viewer. The author can see view
  counts; viewers' identities are limited to the author and the viewer by RLS.
- Updates are visible only to authenticated users with an existing direct
  MailChat conversation with the author. A block in either direction hides the
  author's updates immediately. There are no phone numbers, SMS, device
  contacts, or OS status/story APIs.
- Photos live in the private `status-media` bucket. The object path is tied to
  the author's status row; new signed-link requests require the status to still
  be active and visible to that viewer. Each photo link lasts five minutes, so a
  link issued just before expiry may remain usable for up to five more minutes.

## Files

- `lib/features/status/domain/status_service.dart` — reads, publishes, marks
  views and signs status photos.
- `lib/features/status/presentation/screens/status_screen.dart` — Updates feed
  and story viewer.
- `lib/features/status/presentation/screens/status_composer_screen.dart` — text
  and photo composer; photo selection is staged until Share is tapped.
- `webapp/app.js` and `webapp/styles.css` — browser version on the same
  Supabase tables and bucket.
- `supabase/migrations/0012_user_statuses.sql` — schema, RLS, audience helper,
  private bucket, object policies and realtime publication.

## Setup

The one-paste schema and audit are maintained in `supabase/apply_all.sql` and
`supabase/verify.sql`. After applying the complete `apply_all.sql` in Supabase,
run `verify.sql` and look for `17. expiring user updates (0012) — ok`.

The database hides expired rows and signed-photo access expires with them, but
this repository does not configure a scheduled Storage cleanup job yet. Expired
photo objects remain private in the bucket until an administrator adds routine
cleanup; they are not accessible to other users through the app.
