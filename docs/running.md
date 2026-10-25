# Running MailChat

Practical setup for a developer machine, including the cases where the Supabase
CLI is not installed and no device is connected.

---

## 1. Configure Supabase credentials

The app reads configuration from `--dart-define` values. There is no `.env`
loader, so passing them at build time is the supported path.

PowerShell:

```powershell
flutter run `
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY
```

Get both from **Supabase Dashboard → Project Settings → API**. Use the
`anon` / public key. **Never** use the `service_role` key in the app — it
bypasses every RLS policy.

If the values are missing, the app now shows a "Configuration required" screen
naming what is absent, instead of failing later on every request.

## 2. Apply the database schema

The project needs four migrations, applied **in order**:

| Order | File | Contents |
|---|---|---|
| 1 | `supabase/migrations/0001_core_schema.sql` | tables, indexes, constraints |
| 2 | `supabase/migrations/0002_functions_triggers.sql` | profile trigger, membership/block enforcement, get-or-create RPC |
| 3 | `supabase/migrations/0003_rls_policies.sql` | row level security on every table |
| 4 | `supabase/migrations/0004_views_storage_realtime.sql` | `conversation_list` view, storage buckets + policies, realtime publication |

### Option A — Supabase CLI

```powershell
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
```

### Option B — Dashboard (no CLI installed)

1. Open **Supabase Dashboard → SQL Editor → New query**.
2. Paste the entire contents of `0001_core_schema.sql`, press **Run**.
3. Repeat for `0002`, `0003`, `0004`, in that order.
4. Optionally run `supabase/seed.sql` for two demo accounts
   (`alice@example.com` / `bob@example.com`, password `MailChat123!`).
   Never run the seed against staging or production.

Each file is idempotent where practical (`create table if not exists`,
`drop policy if exists`), so re-running one file is safe. Applying them out of
order will fail: 0003 references functions created in 0002.

### Verify it worked

Run this in the SQL editor after the four files:

```sql
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;
```

Every row must show `rowsecurity = true`. If any is false, stop — the data is
unprotected and 0003 did not apply fully.

Check the realtime publication too:

```sql
select tablename
from pg_publication_tables
where pubname = 'supabase_realtime';
```

`messages`, `message_reactions`, `message_receipts` and
`conversation_members` should be listed. Without them, live updates never
arrive even though sending works.

### Auth settings

**Authentication → URL Configuration**: add `mailchat://auth/callback` to
Redirect URLs, or email confirmation links will bounce.

For local testing, consider turning **Authentication → Providers → Email →
Confirm email** off. Otherwise every test account needs a real inbox before it
can sign in. The app does not fake verification either way — it reflects what
the backend does.

## 3. Get a device

`flutter run` reported *"No supported devices connected"*. Pick one:

### Android emulator

```powershell
flutter emulators                  # list available emulators
flutter emulators --launch <id>    # start one
flutter devices                    # confirm it is detected
```

If `flutter emulators` is empty, create one in **Android Studio → Device
Manager → Create Device**. Also run `flutter doctor` to confirm the Android
toolchain is complete.

### Physical Android phone

1. Enable **Developer options** (tap *Build number* seven times).
2. Enable **USB debugging**.
3. Connect by USB and accept the debugging prompt on the phone.
4. `flutter devices` should list it, then `flutter run`.

### Windows desktop (fastest smoke test)

```powershell
flutter create --platforms=windows .
flutter run -d windows --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

Requires Visual Studio with the **Desktop development with C++** workload. This
is the quickest way to see whether the UI renders, but it is not the target
platform.

### Web will NOT work

The client is built on `dart:io` (`HttpClient`, `WebSocket`, `File`) for the
Supabase REST, Realtime and session layers. `dart:io` does not exist on the
web, so `flutter run -d chrome` fails to compile. Do not spend time on it
unless the networking layer is rewritten on `package:http` and
`package:web_socket_channel`.

## 4. Troubleshooting installs

### `INSTALL_FAILED_INSUFFICIENT_STORAGE`

Seen on a physical device with:

```
adb: failed to install app-debug.apk: Failure
[INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to override installation location]
```

The build succeeded; the **phone** ran out of space while installing. A debug
Flutter APK bundles the debug engine for every ABI and is large (often
100–200 MB), and Android needs roughly double that free to unpack and
optimise it.

Check the device first:

```powershell
adb shell df -h /data
```

As a rule of thumb, keep at least 1 GB free.

**Fix 1 — remove previous installs.** Repeated `flutter run` attempts leave
stale copies behind. Find the package id:

```powershell
adb shell pm list packages | findstr mailchat
```

Then uninstall it (the id is `com.mailchat.mailchat` when the project was
created with `--org com.mailchat --project-name mailchat`):

```powershell
adb uninstall com.mailchat.mailchat
```

**Fix 2 — free space on the phone.** Clear app caches from
**Settings → Apps → Storage**, move photos off the device, or empty
**Downloads**. This is the usual root cause; installing a large APK is what
surfaced it.

**Fix 3 — build a single-ABI APK.** Much smaller than the default fat APK:

```powershell
flutter build apk --debug --split-per-abi
```

The output folder then contains `app-armeabi-v7a-debug.apk`,
`app-arm64-v8a-debug.apk` and `app-x86_64-debug.apk`. Install only the one
matching the phone (arm64 for essentially every device since 2017):

```powershell
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

With the binary already installed, attach the debugger instead of reinstalling:

```powershell
flutter run --use-application-binary=build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

**Fix 4 — clean the build directory.** Stale intermediates occasionally inflate
the APK:

```powershell
flutter clean
flutter pub get
```

### `ADB exited with exit code 1` for other reasons

- **Device offline / unauthorised** — reconnect USB and accept the *Allow USB
  debugging?* prompt; check with `adb devices` showing `device`, not
  `unauthorized`.
- **Version downgrade** — an installed copy has a higher `versionCode`. Run
  `adb uninstall <package>` and install again.

## 5. Troubleshooting network calls

### `NetworkException: Could not reach <host>`

Symptoms in `flutter run`:

```
I/flutter: ERROR AppException(code: network_error, message: Network request failed)
  #0 SupabaseClient._postUri (supabase_client.dart)
  #1 SupabaseClient.signUp
  #2 AuthService.register
```

The request never left the device. Work through these in order — the cause is
almost always one of the first two.

**1. The project URL is wrong or the project does not exist.**

Check what the app actually resolved. The startup log prints the host (never
the key):

```
[AppConfig] environment=development appName=MailChat supabaseHost=xxxx.supabase.co ...
```

Compare it to **Supabase Dashboard → Project Settings → API → Project URL**.
Common mistakes:

| Mistake | Symptom |
|---|---|
| Placeholder like `https://your-project-ref.supabase.co` | DNS failure |
| Copied the dashboard URL (`supabase.com/dashboard/project/xxx`) | DNS failure |
| Project was paused (free tier pauses after inactivity) | Connection refused / DNS failure |
| Trailing slash or missing `https://` | Now normalised automatically |
| A deleted or mistyped project ref | DNS failure |

Confirm the host resolves from your machine:

```powershell
nslookup YOUR-PROJECT.supabase.co
```

If that fails, the URL is wrong — nothing in the app can fix it.

**2. The phone has no working connection.**

The device is not automatically on your PC's network path. Check:

```powershell
adb shell ping -c 3 8.8.8.8
adb shell ping -c 3 YOUR-PROJECT.supabase.co
```

If the IP pings but the hostname does not, it is a DNS problem on the device:
disable private DNS, reconnect Wi-Fi, or test on mobile data.

**3. INTERNET permission is missing (release builds only).**

`flutter create` puts `<uses-permission android:name="android.permission.INTERNET"/>`
in `android/app/src/debug/AndroidManifest.xml` and
`android/app/src/profile/AndroidManifest.xml` — **not** in the main manifest.
A debug build therefore works, and a release build silently loses all
networking.

Before shipping, add it to `android/app/src/main/AndroidManifest.xml`, just
above `<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

Verify on a device:

```powershell
adb shell dumpsys package com.mailchat.mailchat | findstr INTERNET
```

**4. The project exists but returns an error instead of connecting.**

If you reach the host and get `SupabaseException: Request failed (401)`, that is
`SUPABASE_ANON_KEY` being wrong — a different problem. Check that the key is the
`anon` / `public` key from Project Settings → API.

### `Request timed out`

`HttpClient.connectionTimeout` is 30 seconds. A timeout with a valid URL usually
means a captive portal, a VPN, or a firewall. Test in a browser on the device
with `https://YOUR-PROJECT.supabase.co/auth/v1/health`.

### Registration outcomes

Registration has two successful results, and which one you get depends purely
on a project setting:

| Project setting | Result | What you see |
|---|---|---|
| **Confirm email ON** (Supabase default) | `confirmationRequired` | "Check your inbox" screen. The account exists but cannot sign in until the link is followed. |
| **Confirm email OFF** | `signedIn` | Straight to the chat list. |

If registration appears to do nothing, check **Authentication → Providers →
Email → Confirm email**. With it on, no session can be returned by design, and
there is no way for the app to skip the confirmation step.

### "This email is already registered"

The account exists from an earlier attempt. GoTrue never says so directly — it
returns a placeholder user with an empty `identities` array — which the client
now detects and reports with a "sign in instead" shortcut.

Confirm it locally (SQL editor; development databases only):

```sql
select id, email, email_confirmed_at, created_at
from auth.users
order by created_at desc;
```

Then pick one:

```sql
-- Mark the account confirmed so you can sign in without an email round-trip.
update auth.users
set email_confirmed_at = now()
where email = 'you@example.com';
```

Or delete it and retry the whole flow:

```sql
delete from auth.users where email = 'you@example.com';
```

Profiles and conversation rows cascade from `auth.users`, so the delete is
clean. Do not run either statement against a database with real accounts.

The profile row is created server-side by the `handle_new_user` trigger from the
`username` and `display_name` sent at signup, so it exists even for an
unconfirmed account. That is why the client never inserts the profile itself:
before confirmation there is no session, and RLS would reject the insert.

## 6. Known limitations on a first run

- **Session persistence is fragile.** The session is stored as a plaintext JSON
  file in the app's temp directory. Android may clear it, and it is not
  encrypted. Production requires `flutter_secure_storage`.
- **Attachments do nothing.** The picker and upload path are stubs.
- **Calls are UI only.** No audio or video is transmitted.
- **No push notifications.** No FCM credentials are configured.
- **Realtime is unverified.** Implemented, never executed.

## 7. First-run checklist

Work through this in order; each step exercises a different layer.

1. App launches and shows the splash screen → theme and routing work.
2. Register an account → signup, `handle_new_user` trigger, profile insert, RLS.
3. Confirm the account (dashboard, or email if confirmations are on) → login.
4. Send a message → messages insert, membership trigger, block check.
5. Kill and relaunch → session restore (expect this to be flaky, see above).
6. Second client, same conversation → realtime delivery.
7. Block the other user, try sending → server-side block enforcement.
