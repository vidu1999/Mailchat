# MailChat documentation

Every feature has one document, in the same shape, saying what works, how it
works, what the database enforces, and what is missing. Nothing here claims a
feature that cannot be pointed at in the repository.

Start with [running.md](running.md) if you only want to install the app.
Start with [feature-matrix.md](feature-matrix.md) if you want the audit — spec
versus what actually exists.

## Documents

### Setup and operations

| Document | Covers | Status of what it describes |
| --- | --- | --- |
| [running.md](running.md) | Installing, configuration, applying the schema, building an APK, troubleshooting | — |
| [any-device.md](any-device.md) | Running on a phone, emulator or desktop without editing files | — |
| [release.md](release.md) | Signed builds and Play Store steps | Not signed yet |
| [testing.md](testing.md) | What CI runs, every test file, and the manual checklist | CI green; manual list mostly unticked |

### Feature guides

| Document | Covers | Status |
| --- | --- | --- |
| [auth.md](auth.md) | Register, verify, sign in, restore, reset, sign out | 🧪 built, needs a live project |
| [auth-links.md](auth-links.md) | The confirmation and reset links: redirect URLs, deep links, why they bounce | 🧪 built |
| [messaging.md](messaging.md) | Sending, delivery ticks, edit/delete, replies, pagination, realtime | 🧪 built |
| [unread.md](unread.md) | Unread counts, the read cursor, why a badge would not clear | 🧪 built |
| [attachments.md](attachments.md) | Photos and files: picker, storage, limits, viewer | 🧪 built |
| [groups.md](groups.md) | Group creation, roles, the group thread, leaving | 🧪 built |
| [search.md](search.md) | Finding people by username, display name or exact email | 🧪 built |
| [presence.md](presence.md) | Online status, last seen, typing, and the privacy switch | 🧪 built |
| [privacy.md](privacy.md) | Blocking, reporting, discoverability, what is saved and what is not | 🧪 built |
| [notifications.md](notifications.md) | Durable message/call/system inbox, foreground realtime, tap-through, and FCM gap | 🧪 code built; migration 0013 needs applying |
| [calls.md](calls.md) | Voice and video calls: signalling, WebRTC media, TURN, what is unverified | 🟡 built, unverified on a device |
| [status.md](status.md) | Updates/stories: photo and text sharing, 24-hour expiry, audience and setup | 🧪 code built; migration needs applying |
| [web.md](web.md) | The browser client: same accounts, chats, Updates and calls as the phone | 🧪 built, not a Flutter web build |

### Design

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | Components, schema relationships, request paths, trust boundary |
| [security.md](security.md) | Identity, keys, RLS invariants, what is deliberately not stored |
| [feature-matrix.md](feature-matrix.md) | Every spec item, ✅ / 🟡 / ❌, with the path that backs the verdict |

## How these documents are kept honest

* Each feature document starts with a **Status** line and names its code,
  database migration and tests. If a path is wrong, the document is wrong — the
  checker below treats every `` `lib/...` `` path in these files as a claim.
* `dart run tool/check_docs.dart` verifies that every document here is linked
  from this index, that every relative link resolves, and that every path
  mentioned in backticks exists. It runs in CI, so a document cannot rot
  silently when a file is renamed.
* A feature marked 🧪 is implemented but has never been exercised against a live
  Supabase project from this build environment. That distinction is deliberate:
  the database half has been written blind against error messages, so
  "compiles and is tested in isolation" is not the same as "works".

## Conventions

| Mark | Meaning |
| --- | --- |
| ✅ | Built, and covered by CI (analysis, tests, build) |
| 🧪 | Built, but not verified against a live project |
| 🟡 | Partly built — the parts that exist are named |
| ❌ | Not built |
| 🚫 | Deliberately not built, with a reason |
