# Photos and files

**Status:** 🧪 built — picking, uploading, rendering and opening a file all work
in code; uploads have never been exercised against a live Storage bucket from
this build environment.
**Code:** `lib/shared/services/attachment_service.dart`,
`lib/features/messaging/presentation/screens/direct_chat_screen.dart`
(`_pickAttachment`), `lib/shared/widgets/message_bubble.dart`,
`lib/features/attachments/presentation/screens/media_viewer_screen.dart`,
`lib/features/attachments/presentation/screens/attachment_preview_screen.dart`
**Database:** `supabase/migrations/0004_views_storage_realtime.sql` (bucket and
policies), `0001_core_schema.sql` (`message_attachments`)
**Tests:** `test/unit/attachment_test.dart`

## What works

| Step | Implementation |
| --- | --- |
| Pick | `file_selector` → `openFile(acceptedTypeGroups: […])`, then `readAsBytes()` |
| Size gate | 10 MB in `AttachmentService.maxBytes`, checked before any upload |
| Upload | `storage/v1/object/attachments/<conversationId>/<millis>_<name>` |
| Message | A `messages` row with `type = 'image'` for `image/*`, otherwise `'file'`, and `text = null` |
| Metadata | A `message_attachments` row: path, name, MIME type, size |
| Render | Image types preview inline; everything else renders a file card with name and size |
| Open | Tapping fetches a 5-minute signed URL; images open in the viewer, other types are described |

## Order of operations, and why

```text
bytes → Storage object → messages row → message_attachments row
```

The bytes go up **first**. A failed upload therefore cannot leave a message
pointing at a file that does not exist — the worst case is an orphaned object,
which a cleanup job can sweep. Writing the rows first would produce a permanent
broken bubble in the thread, which nothing can repair.

## Storage rules

The `attachments` bucket is **private**. Two policies decide access:

| Policy | Rule |
| --- | --- |
| `attachments_read_member` | A member of the conversation whose id is the first path segment may read |
| `attachments_write_member` | The same, for insert |

So the path layout is the authorization: `attachments/<conversationId>/<file>`.
Renaming a folder in the app cannot widen access, because the policy recomputes
membership from the path.

Files are never served from a public URL. `createSignedUrl()` issues a
short-lived link, which is also why an image thumbnail costs a round trip the
first time it is shown.

## File names

`sanitiseFileName()` keeps the object key inert:

* strips directories (`/` and `\`) so a name cannot escape the folder;
* replaces anything outside `A-Z a-z 0-9 . _ -` with `_`;
* refuses to produce an empty or dot-only name — those become `attachment`;
* keeps the last 80 characters, so a long path cannot overflow the key.

The stored name is also what the file card displays, so the sanitising is
visible to the user rather than hidden.

## The picker decision

`file_selector` (first-party) is used instead of `file_picker` (third-party).
`file_picker` 6.x still declares the removed Android v1 plugin registration
(`registerWith(PluginRegistry.Registrar)`), which fails to compile on current
Flutter with `cannot find symbol: class Registrar`; 8.x needs a `compileSdk` the
scaffolded `android/` folder does not produce. `file_selector` is v2-only and
needs no Gradle edits. This is recorded in
[feature-matrix.md](feature-matrix.md) §4 so it is not re-litigated.

## Failure modes

| Symptom | Cause | What the app does |
| --- | --- | --- |
| "Files must be under 10 MB" | Size check | Refused before upload; nothing is sent |
| "That file is empty" | Zero-byte pick | Refused |
| Upload fails | Network or policy | Snack with the reason; no message row is created |
| Image does not render | Signed URL expired or object missing | The bubble falls back to the file card; the error is logged |
| Orphaned objects | Attachment row insert failed after a successful upload | Harmless; a bucket sweep can remove them |

## Known gaps

* No image compression or thumbnailing, so a 9 MB photo is downloaded at full
  size to show a bubble preview.
* No upload progress indicator — the composer shows a spinner for the whole
  operation.
* No OS "open with" hand-off for PDFs and documents; they are described, not
  launched.
* No avatar upload from the profile screen yet (the picker now exists, so this
  is a small follow-up).
* Voice messages are not recorded at all.
