# Security model

## Identity

MailChat uses email as the only identifier. There is no phone number, SMS OTP
or SIM dependency anywhere in the schema, the auth flow or the UI.

Accounts live in Supabase Auth (`auth.users`). Profile data lives in
`public.profiles` and deliberately **does not contain the email address**, so a
profile read cannot leak it. Passwords are hashed and managed by Supabase Auth;
this application never stores, hashes or compares passwords itself.

## Keys

| Key | Where it is used | Safe in the app? |
|---|---|---|
| `SUPABASE_URL` | Client + CI | Yes |
| `SUPABASE_ANON_KEY` | Client + CI | Yes — it is a publishable key |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-side / Edge Functions only | **No — never ship it** |

The service-role key bypasses RLS. It must never appear in the Flutter build,
in `--dart-define` for a mobile build, or in any asset. `.gitignore` excludes
`.env`; CI reads secrets from GitHub Actions.

## Authorization (RLS)

Every table has row level security enabled. The default is deny: a table with
no matching policy returns zero rows.

Key invariants enforced in the database rather than the client:

- `profiles` — readable by authenticated users (needed for search); writable
  only by the owner (`id = auth.uid()`).
- `conversations` — visible only to members; creation only by the creator.
- `conversation_members` — roster visible to members; role changes require
  admin/owner.
- `messages` — read by members, inserted only as yourself, updated only by the
  author. Hard deletes are service-role only; clients soft-delete via
  `deleted_at`.
- `message_reactions` / `message_receipts` — a user may only write rows for
  themselves.
- `user_blocks` — a user sees and manages only their own blocks.
- `user_reports` — a user can file and read their own reports; triage is
  service-role only.
- `user_devices`, `notification_preferences` — owner only.

Triggers enforce invariants the client cannot be trusted with:

- the sender must be a member of the conversation;
- a blocked user cannot post into a conversation with the blocker;
- the group owner is always a member with role `owner`;
- `updated_at` is server-maintained.

Verify policies with the queries in `docs/testing.md`.

## Known gaps before production

These are real and should block a production launch:

1. **Session storage.** `FileSessionStore` writes a plaintext JSON file to
   `Directory.systemTemp` (the app's private cache directory on Android). The
   previous implementation used `Directory.current`, which is not writable on
   Android/iOS, so it silently persisted nothing and every launch returned the
   user to the login screen. The current version fixes persistence but is
   **not encrypted** and the OS may clear the cache. Replace with
   `flutter_secure_storage` (Keychain / Keystore) before shipping.
2. **Token refresh.** Access tokens are persisted but the refresh flow is not
   implemented; sessions expire and the user is silently logged out.
3. **Attachments.** Storage buckets are private and policies exist, but the
   upload path and signed-URL issuance are not implemented in the app.
4. **Push notifications.** No FCM credentials or server-side sender exist;
   no push is delivered.
5. **Rate limiting.** Auth endpoints are rate-limited by Supabase, but message
   and call-creation rate limiting is not implemented.
6. **Abuse reporting review.** `user_reports` rows are written but nothing
   triages them.

## Encryption posture

- In transit: TLS to Supabase, WSS for Realtime.
- At rest: Supabase-managed disk encryption.
- **Not end-to-end encrypted.** Message content is readable by the database.
  Do not claim otherwise in UI, store listings or documentation. The data model
  keeps message bodies in a single `text` column so an E2EE layer (per-
  conversation keys, ciphertext in that column) can be added later without a
  schema rewrite.

## Key hygiene

The mobile app is configured from `assets/config/env`, and **everything in that
file is compiled into the APK**. Anyone can unzip an APK and read its assets, so
the rule is simple: only client-safe values go there.

| Value | In the app bundle? | Where it belongs |
|---|---|---|
| `SUPABASE_URL` | yes — public | `assets/config/env` |
| `SUPABASE_ANON_KEY` / `sb_publishable_…` | yes — designed to be public; RLS is the boundary | `assets/config/env` |
| `SUPABASE_SERVICE_ROLE_KEY` | **never** — bypasses every RLS policy | server-side code only (Edge Functions secret), passed as `--dart-define` for tooling |
| `SMTP_PASS` / `SMTP_USER` / `SMTP_HOST` | **never** — the app never sends mail | Supabase dashboard → Authentication → Emails → SMTP |
| FCM server key | **never** | your push sender |

Two guards enforce this rather than relying on care:

- `tool/check_config.dart` **fails the build** when the service-role key or SMTP
  credentials appear in the bundled file, and when `SUPABASE_ANON_KEY` turns out
  to be a service-role key (verified from the JWT's `role` claim, not just the
  text).
- `AppConfig` reads the service-role key from `--dart-define` only. If it is in
  the bundled file it is ignored, and the startup log and configuration-error
  screen name it.

### If a privileged key has been exposed

Rotating is the only remedy — deleting the file or the message does not help,
because the key itself is the credential.

1. **Supabase dashboard → Project Settings → API → JWT Settings → generate a new
   secret.** This invalidates every issued token, including the `anon` key, so
   update `assets/config/env` and any deployment that uses it. (Projects on the
   new API keys rotate the `sb_secret_…` key instead.)
2. If SMTP credentials were exposed, rotate them with the provider.
3. Rebuild the APK: the old key is inside any APK that was built with it, and
   nothing in the app can revoke that copy.
4. Check the Supabase logs for requests you did not make.

Treat "the key was only in a chat/file that I deleted" as exposure. Assume it
was read.
