# Accounts: register, verify, sign in, reset

**Status:** 🧪 built — every flow exists and is wired to Supabase Auth; none has
been exercised against a live project from this build environment.
**Code:** `lib/shared/services/auth_service.dart`, `lib/core/services/session_store.dart`,
`lib/features/auth/presentation/screens/` (`registration_screen.dart`,
`email_verification_screen.dart`, `login_screen.dart`, `forgot_password_screen.dart`,
`reset_password_screen.dart`, `paste_link_screen.dart`, `splash_screen.dart`)
**Database:** `supabase/migrations/0001_core_schema.sql` (`profiles`),
`supabase/migrations/0002_functions_triggers.sql` (`handle_new_user`)
**Tests:** `test/unit/auth_registration_test.dart`, `test/unit/auth_deep_link_test.dart`,
`test/unit/validators_test.dart`
**Deep links:** [auth-links.md](auth-links.md) — read that one when a confirmation
link bounces instead of opening the app.

## Identity

Email and password only. There is no phone number, SMS one-time code or SIM
dependency anywhere in the schema, the auth flow or the UI. Passwords are hashed
and held by Supabase Auth (GoTrue); this app never stores, hashes or compares a
password itself.

## Flows

| Flow | Screens | Server call |
| --- | --- | --- |
| Register | `registration_screen.dart` | `POST /auth/v1/signup` with `username` and `display_name` metadata |
| Verify | `email_verification_screen.dart` → `paste_link_screen.dart` | Confirmation link opens the app; the token is exchanged |
| Sign in | `login_screen.dart` | `POST /auth/v1/token?grant_type=password` |
| Restore session | `splash_screen.dart` | Stored refresh token → new access token, or back to login |
| Forgot password | `forgot_password_screen.dart` | `POST /auth/v1/recover` |
| Reset password | `reset_password_screen.dart` | Recovery link → `PUT /auth/v1/user` |
| Sign out | Settings | Clears the stored session |

## Registration is not "success" when confirmation is required

`register()` returns a `RegistrationResult` with one of two outcomes:

* `signedIn` — the project has email confirmation **disabled**, GoTrue returned a
  session, and the caller goes straight into the app;
* `confirmationRequired` — the default configuration. GoTrue returns the user
  with `session: null`, and the screen says "check your inbox" instead of
  pretending the account is ready.

A third case matters: GoTrue answers a **duplicate** address with a placeholder
user carrying no identities rather than an error, so accounts cannot be
enumerated. That is detected and surfaced as `EmailAlreadyRegisteredException`,
which the UI turns into "sign in instead, or check your inbox".

The profile row is created by the `handle_new_user` trigger from the metadata sent
at signup — not by the client, which has no session yet and would be refused by
RLS.

## Sessions

`SessionStore` keeps the refresh token between launches; `SupabaseClient`
refreshes the access token shortly before expiry and retries with the new one.
On launch, `splash_screen.dart` tries to restore before routing, so a returning
user never sees the login form flash.

`init()` also reads the current user and keeps `SupabaseClient.userId` populated,
which every RLS-scoped query depends on.

## Password reset

Two paths, both real:

1. The emailed recovery link, which returns to the app and lands on
   `reset_password_screen.dart`;
2. **Paste link** — for the common case on Android where a link opens in a
   browser instead of the app. The user pastes the URL and the same token
   exchange runs.

Only `/verify` consumes a token, and it consumes it even if the final redirect
fails. That is why a link that "did not work" often cannot simply be reopened;
the flow asks for a new one instead.

## Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Email not confirmed" at login | Confirmation link not opened | Resend from the verification screen |
| Confirmation link shows `requested path is invalid` | Site URL points at the Supabase project host instead of the app | See [auth-links.md](auth-links.md) |
| Link opens the browser, not the app | Intent filter missing | `dart run tool/enable_deep_links.dart`; the app offers Paste link as a workaround |
| Duplicate username on register | Unique index on `lower(username)` | 23505 is translated into a readable message, not shown raw |
| Signed out on every launch | Session store not persisting (fresh install, or cleared data) | Expected on a clean install |

## Known gaps

* No "log out all devices", no session list — `user_devices` is not used for
  sessions.
* No two-factor authentication.
* No account deletion or data export.
* Email *change* is not implemented.
