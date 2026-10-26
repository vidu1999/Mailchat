# Making MailChat work on any device

An APK that runs on **your** phone and one that runs on **anyone's** phone are
different problems. This is the difference, split by who has to do what.

Read the "Not yet" section too. Several items there cannot be finished by
changing code.

---

## A. What only you can do (accounts, dashboard, secrets)

These are not code changes and cannot be done from this repository.

| # | Task | Where | Why it blocks other devices |
|---|---|---|---|
| A1 | **Apply the four migrations** (`0001`→`0004`) | Supabase → SQL Editor | Without them every screen fails with `relation does not exist`. This is the single most common "it crashes on my friend's phone" cause. |
| A2 | **Set Site URL** to a real `https://` **page** (`https://example.com` is fine) | Authentication → URL Configuration | `localhost` sends the link to the phone itself; the project host (`https://<ref>.supabase.co`) answers `{"error":"requested path is invalid"}`. |
| A3 | **Allow-list the redirect** `mailchat://auth/callback` | Authentication → URL Configuration → Redirect URLs | Without it GoTrue ignores the app's redirect and falls back to the Site URL. |
| A4 | **Configure custom SMTP** | Authentication → Emails → SMTP | The built-in sender is rate-limited and mainly delivers to team addresses. This is what makes confirmation emails reach strangers. |
| A5 | **Build with your credentials** | `tool/build_apk.ps1`, or repo secrets | The URL and anon key are compiled into the APK; an APK built without them shows a configuration screen. |
| A8 | **Keep server-side keys out of the app** | `.env` / `assets/config/env` | Anything in the bundled file ships inside the APK. The service-role key and SMTP password belong to the server and the dashboard; the build refuses them. |
| A6 | **Sign the release** (only for release builds) | keystore + `android/key.properties` | An unsigned release APK will not install at all. Debug APKs are already signed with the debug key. |
| A7 | *(optional)* Own a domain for https app links | DNS + `assetlinks.json` | Only needed if you want the link to open without the browser chooser. |

Your `SUPABASE_URL` can be derived from the key itself: the JWT payload's `ref`
claim is the `<ref>` in `https://<ref>.supabase.co`. `tool/check_config.dart`
prints the exact URL when it is blank.

Run this to see which of A5–A6 are done:

```powershell
dart run tool/check_config.dart            # A5
dart run tool/fix_android_build.dart       # checks the Flutter SDK, pins compileSdk,
                                           # applies deep links + camera/mic permissions
dart run tool/enable_deep_links.dart --signing   # A6, prints the exact signing snippet
```

---

## B. What this repository already does

So you know what not to re-do:

| Concern | Handling |
|---|---|
| Credentials without CLI flags | `assets/config/env`, read at runtime; `--dart-define` overrides it |
| Internet permission, deep links, camera/mic, `compileSdk` | All applied by `tool/fix_android_build.dart` (which calls the two smaller patchers) |
| Confirmation / recovery links | Intent filter, `MainActivity` forwarding, parser, paste fallback |
| Session persistence | Written to an app-private writable directory (not `Directory.current`, which is unwritable on Android) |
| Session lifetime | Access tokens are refreshed before they expire, and a stored refresh token is used at startup — otherwise every launch an hour after sign-in would ask for a password |
| Session restore across restarts | `AuthService.init()` verifies the token, refreshes if needed, clears it only when unrecoverable |
| Errors from a missing migration | Surfaced as the server's message rather than a bare "failed" |

---

## C. Building the APK

```powershell
git pull
.\tool\build_apk.ps1                 # debug: installs anywhere, any Android phone
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

For a build that can be *published* (Play Store, or updating an existing
install), you need A6 first, then:

```powershell
.\tool\build_apk.ps1 -Mode release
```

Debug and release APKs cannot replace each other: different signing keys, so
Android requires an uninstall between them.

---

## D. Testing on a device that is not yours

The honest sequence that catches the failures a "works on my phone" test misses:

1. **Fresh install, no prior data.** Uninstall first — a leftover session hides
   every sign-up bug.
2. **Register a brand-new address** you have never used on this project. This
   exercises A1 (migrations), A4 (SMTP) and the confirmation link in one go.
3. **Confirm the email on the phone**, not on a laptop. That is the only way to
   test A2/A3 and the intent filter.
4. **Kill and reopen the app.** You should land signed in, not on the login
   screen. This tests session persistence and refresh.
5. **Wait out an hour**, then send a message. This tests token refresh; without
   it the app would ask for a password.
6. **Enable airplane mode, act, re-enable.** Every screen should show a message,
   not a spinner that never ends.
7. **Open a chat, receive a message from the demo account.** This is the last
   unverified area: realtime delivery needs the publication from `0004`.

Steps 5 and 7 have no automated coverage. Treat them as unproven until you have
watched them pass.

---

## E. Not yet — and not fixable by configuration

Be aware of these before saying "it works everywhere":

| Gap | Consequence | Where |
|---|---|---|
| **iOS is not wired** | Deep links do not reach the app; `Info.plist` URL type + `openURL` forwarding are missing | `docs/auth-links.md` |
| **Session storage is a plaintext file** | Works on device, but a rooted device can read the tokens. Needs a keystore-backed store | `docs/security.md` |
| **Attachments are unverified** | Picker and upload path exist, but no upload has ever run against a live bucket | `docs/attachments.md` |
| **Push notifications absent** | No background alerts; the app must be open | `docs/running.md` §6 |
| **Realtime unverified** | Code exists; nothing has exercised it against a provisioned database | `docs/testing.md` |
| **Calls may not connect on mobile data** | Media works over WebRTC, but without a TURN relay carrier NAT often blocks it. A relay is configuration only: paste the provider's list into `TURN_URL` | `docs/calls.md` |
| **No rate limiting / abuse handling** | RLS protects data, but nothing throttles a hostile client | `docs/security.md` |

None of these stop the app from *installing and running* on another Android
phone. They stop it from being a finished product.

---

## F. The shortest honest answer

1. Apply the migrations (A1) — otherwise nothing works anywhere.
2. Fix Site URL and Redirect URLs (A2, A3).
3. Configure SMTP (A4).
4. Build with your credentials (A5) and install the debug APK.

That gives a working app on any Android phone. Publishing to Play additionally
needs A6 and the gaps in section E closed — token storage and iOS being the two
that matter most.
