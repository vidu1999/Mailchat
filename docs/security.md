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
- `user_devices`, `notification_preferences`, `user_notifications` — owner only. Notification clients may change only `read_at`; event content and recipient are server-generated.

Triggers enforce invariants the client cannot be trusted with:

- the sender must be a member of the conversation;
- a blocked user cannot post into a conversation with the blocker;
- the group owner is always a member with role `owner`;
- `updated_at` is server-maintained.

Verify policies with the queries in `docs/testing.md`.

## Known gaps before production

These are real and should block a production launch:

1. **Session storage is not encrypted.** `FileSessionStore` writes a plaintext
   JSON file (`mailchat_session.json`) into the app's private cache directory.
   It survives a restart, but it is readable by anything that can read app data
   on a rooted device, and the OS may clear the cache. Replace with
   `flutter_secure_storage` (Keychain / Keystore) before shipping. Token refresh
   itself *is* implemented: `refreshSession()` runs before any request whose
   access token is stale, and a rejected refresh clears the session instead of
   looping.
2. **Attachments are private but unencrypted.** Buckets are private, paths are
   authorisation, and every read goes through a short-lived signed URL. The bytes
   themselves are plaintext at rest, and a signed URL that leaks is valid for its
   lifetime.
3. **Presence is coarse.** A heartbeat older than 75 seconds is "offline", so a
   user whose phone slept looks away even if they are reading. That is honest,
   but it is not the same as an accurate session state.
4. **Updated Android notification actions need re-verification.** The initial
   background FCM flow was reported working by the operator. Grouped previews,
   inline reply, mark-read/mute actions, and incoming-call actions change delivery
   to locally rendered data messages; redeploy the updated Edge Function, add
   the calls webhook, rebuild the APK, and test those new paths. See
   [notifications.md](notifications.md).
5. **Rate limiting.** Auth endpoints are rate-limited by Supabase, but message,
   attachment and call-creation rate limiting is not implemented — nothing stops
   a member from flooding a conversation or ringing in a loop.
6. **Abuse reporting review.** `user_reports` rows are written but nothing
   triages them, and there is no moderation role.
7. **Calls carry live media over WebRTC,** which is DTLS-SRTP encrypted between
   the two devices — but the *signalling* is stored in plaintext in `calls`
   (`offer_sdp`, `answer_sdp`) and `call_ice_candidates`, readable by both
   participants. Those rows disclose IP addresses and network candidates to the
   other side, which is inherent to WebRTC: a call cannot be routed without
   them. They do not contain media. With no TURN relay the two devices connect
   directly, so each learns the other's address; a relay hides that.
8. **Call media is unverified.** No call has been placed between two devices
   from this build.

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

## Email discovery and account enumeration

MailChat lets you find someone by typing their email address, because an app
whose identity is an email address is unusable if the only way to reach someone
is a handle they have to tell you out of band. That is a deliberate trade-off
against account enumeration, and it is contained in three ways:

| Control | Where |
| --- | --- |
| Addresses are **never returned**. `search_users` matches on the address and returns profile fields only. | `0005_email_discovery.sql` |
| Matching is **exact**, never a substring, so a search cannot walk the address space from fragments. | same |
| Lookup is **opt-out** per user, enforced server-side rather than in the UI. | `profiles.discoverable_by_email`, same |

Unverified addresses are not discoverable: otherwise anyone could pre-register a
colleague's address and be found in their place.

`search_users` is `SECURITY DEFINER` with `set search_path = public, pg_temp`,
executable by `authenticated` only (`revoke`d from `public` and `anon`). It
filters out the caller and any user involved in a block in either direction, so
a blocked user cannot use search to find the person who blocked them.

The residual risk is that someone who already knows an address can confirm it
belongs to a MailChat account. That is inherent in address-book discovery, and
is why the opt-out exists and why the search screen says so when an address
finds nobody.

