# Email links: confirmation, recovery, and why they are not "global" yet

Clicking a MailChat confirmation email on a real device opened a browser tab
saying **"This site can't be reached — null is unreachable."** That page is
Chrome's, not the app's. This document explains the cause and the fix, in the
order that matters.

---

## What actually happened

Supabase builds the link in the email like this:

```
{{ .SiteURL }}/auth/v1/verify?token=<token>&type=signup&redirect_to={{ .RedirectTo }}
```

Two things were wrong at once:

1. **No usable `Site URL`.** Either it was empty or literally `null` (the string
   shows up in the error page), so the verify URL had no host. Chrome had
   nowhere to go — hence `null is unreachable`.
2. **No `redirect_to` target.** The app sent
   `email_redirect_to=mailchat://auth/callback`, but Supabase only honours a
   redirect that is on its allow-list. An unlisted value is silently dropped,
   and verification falls back to the Site URL.

Even with both fixed, the app had **no code to receive the link** — no intent
filter, no platform handler, no parser. So the link could not have worked by
accident.

---

## The fix, in order

### 1. Supabase dashboard → Authentication → URL Configuration

| Field | Value |
|---|---|
| Site URL | `https://YOUR-SITE` — a real `https://` address you control. Never `null`, never `localhost`, never a LAN IP. |
| Redirect URLs | `mailchat://auth/callback` **and** `https://YOUR-SITE/auth/callback` |

The Site URL is only where verification *lands* before redirecting; it does not
have to host the app, but it must be a valid https URL. `localhost` works on one
machine and nowhere else — which is exactly why a link that worked with the app
running locally failed on the phone.

### 2. `assets/config/env`

```ini
AUTH_REDIRECT_URL=mailchat://auth/callback
```

This is what the app sends as `email_redirect_to`, so it must match an entry in
Redirect URLs exactly — scheme, host and path.

### 3. Patch the Android project

```bash
dart run tool/enable_deep_links.dart
# or, once you own a domain:
dart run tool/enable_deep_links.dart --host=auth.example.com
```

Adds, idempotently:

- `INTERNET` permission to the main manifest (release builds otherwise have no
  networking — `flutter create` writes it only to the debug/profile manifests).
- An intent filter for `mailchat://auth/callback`, plus an https app-link filter
  when `--host` is given.
- Link forwarding in `MainActivity` over the `mailchat/links` channel.

Re-run it after any `flutter create`, then do a full `flutter run` — a manifest
change is native state, so a hot reload will not pick it up.

### 4. Configure SMTP before calling it global

This is the step that decides whether it works for **anyone** rather than for
you. Supabase's built-in email service:

- is heavily rate-limited (a handful of messages per hour), and
- reliably delivers only to addresses of your project's team members.

So "it arrived for me" is not evidence that a stranger's signup will arrive.
**Authentication → Emails → SMTP Settings** with your own provider (Resend,
SendGrid, Postmark, Amazon SES, …) is what makes registration work for arbitrary
addresses. Do the same under **Auth → Rate Limits** for production volumes.

---

## What the app does with the link now

`lib/core/deeplink/auth_deep_link.dart` parses the redirect;
`AuthService.handleAuthLink` turns it into a session.

| Incoming | Handling | Lands on |
|---|---|---|
| `#access_token=…&type=signup` | tokens stored as the session | chat list, "Email confirmed" |
| `#access_token=…&type=recovery` | session stored | **New password** screen |
| `?token_hash=…&type=…` | exchanged via `POST /auth/v1/verify` | as above |
| `?error_code=otp_expired&…` | GoTrue's own message shown | login, with the reason |
| a callback with no token | reported as invalid | login, with the reason |

Notes:

- Because the session is persisted, restarting the app after tapping the link
  opens it signed in rather than asking for the password again.
- Cold start and warm start are both handled: the launching intent and
  `onNewIntent` are both forwarded.
- Logs record only the link **length** (`deeplink_received`), never the link —
  it contains session tokens.

### `{{ .TokenHash }}` templates

If you edit the email templates to use `{{ .TokenHash }}` (recommended with a
verified https app link, and required for some flows), the link carries
`token_hash` instead of tokens and the app exchanges it with GoTrue. Keep the
`type` parameter correct — `signup`, `recovery`, `magiclink`, `invite`,
`email_change`.

---

## Testing it

```bash
# 1. Is the filter installed?
adb shell dumpsys package com.mailchat.mailchat | grep -A3 mailchat://

# 2. Fire a link without sending an email (tokens are fake: proves routing only)
adb shell am start -a android.intent.action.VIEW \
  -d "mailchat://auth/callback#access_token=fake&refresh_token=fake&type=signup"
```

The app should open, log `auth_link_handled`, and land on the chat list — then
fail on the next request because the token is fake. That is the expected result:
it proves the plumbing, not the token.

For a real token, sign up, then copy the `token` value out of the email's verify
URL and build:

```
mailchat://auth/callback#access_token=<access_token>&refresh_token=<refresh_token>&type=signup
```

The tokens are not in the emailed URL — only the one-time token is — so the
simplest real test is just to click the email on the device.

---

## Known limitations

- **iOS is not wired.** `tool/enable_deep_links.dart` only patches Android. iOS
  needs an `Info.plist` URL type plus `application(_:open:options:)` forwarding
  to the same channel.
- **No domain verification.** The https app link only opens the app without the
  browser chooser after `assetlinks.json` is published at
  `https://YOUR-SITE/.well-known/assetlinks.json`. Until then Android shows a
  disambiguation prompt, or opens the browser, which is why the custom scheme is
  kept working alongside it.
- **Session tokens in the fragment are short-lived** (`expires_in`, usually one
  hour). Token refresh is not implemented, so a link left in a browser tab
  overnight will land on a dead session — the app will then ask for a password.
