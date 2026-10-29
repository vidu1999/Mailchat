# Running MailChat

Practical setup for a developer machine, including the cases where the Supabase
CLI is not installed and no device is connected.

---

## 1. Configure Supabase credentials

Configuration is read from **`assets/config/env`**, so no CLI flags are needed:

```powershell
Copy-Item .env.example .env      # or: assets/config/env.example -> assets/config/env
# edit .env, then:
flutter run
```

`.env` in the project root is enough: `run.ps1`, `run.sh`, the build scripts and
`dart run tool/check_config.dart` all copy it to `assets/config/env`, which is the
file the app reads. Checking before a build:

```powershell
dart run tool/check_config.dart
```

```bash
cp assets/config/env.example assets/config/env
$EDITOR assets/config/env
flutter run
```

Fill in two values from **Supabase Dashboard → Project Settings → API**:

```ini
SUPABASE_URL=https://YOUR-PROJECT.supabase.co
SUPABASE_ANON_KEY=YOUR-ANON-KEY
```

Use the `anon` / public key. **Never** the `service_role` key — it bypasses
every RLS policy.

`assets/config/env` is gitignored; `env.example` is the committed template.
`./run.ps1` and `./run.sh` are thin wrappers that copy a root `.env` into
`assets/config/env` first, for anyone who keeps credentials there by habit.

### Why the file is not at the project root

Two Flutter facts force this:

1. `String.fromEnvironment` (what `--dart-define` populates) is resolved by the
   **compiler**. A root `.env` is never read by the running app — nothing in the
   Dart runtime looks for it.
2. Only declared assets are bundled. So the file has to live inside a declared
   asset directory and be read at runtime through `rootBundle`.

The name is `env`, not `.env`, because Flutter's bundler **skips dotfiles** —
`assets/config/.env` would be silently absent at runtime.

Consequences:

- Editing the file requires a **restart**, not a hot reload: the asset is baked
  into the bundle at build time.
- The anon key is inside the APK. That is intended — it is a publishable key and
  every table is behind RLS — which is precisely why RLS must stay enabled.

### "No assets/config/env" right after editing `.env`

The checker used to look only at the bundled asset, so a root `.env` that had not
been synced produced this. It now reads `.env` first, copies it into
`assets/config/env` and says so. If you still see the error, neither file exists:
create `.env` from `.env.example`.

### `git pull` refuses: local changes to `.env.example`

`.env.example` is a **template and tracked by git**; `.env` is your copy and is
gitignored. Editing the template is what causes this, and the fix never involves
committing it.

```powershell
# Keep whatever you typed — .env is gitignored, so this is the safe place for it.
Copy-Item .env.example .env

# Throw the template edit away so the pull can proceed.
git restore .env.example

git pull
notepad .env    # re-check it against the new template
```

If the values you typed included the service-role key or SMTP credentials, delete
those lines now: the build refuses them, because everything in `.env` is compiled
into the APK (`docs/security.md` § Key hygiene).

`git stash` also works (`git stash` → `git pull` → `git stash pop`), but it
restores your template edit on top of the new one, which is how the conflict
reappears. Copying to `.env` is the one-way route.

### Email links

AUTH_REDIRECT_URL must also appear under **Authentication → URL Configuration →
Redirect URLs** in Supabase, otherwise GoTrue silently drops it and sends the
user to the Site URL instead — which is how a confirmation email ends up on a
browser page reading "null is unreachable". Run
`dart run tool/enable_deep_links.dart` once to teach the Android project to
receive the link. Full walkthrough, including the SMTP requirement for reaching
addresses other than your own: **`docs/auth-links.md`**.

### Precedence

`--dart-define` beats the file, which beats the built-in defaults:

```
--dart-define=SUPABASE_URL=...   >   assets/config/env   >   placeholders
```

So CI and release builds keep passing values as defines (`docs/release.md`),
while a developer machine needs none. `--dart-define-from-file=.env` also works
if you prefer a root `.env` and are happy to type the flag; there is a VS Code
launch configuration for it in `.vscode/launch.json`.

### When it is wrong

If the values are missing or malformed the app shows a "Configuration required"
screen naming what is absent, instead of failing later on every request. The
startup log states which source was used (never the values):

```
[AppConfig] environment=development appName=MailChat supabaseHost=YOUR-PROJECT.supabase.co emailConfirmationRequired=true source=env file (assets/config/env) and --dart-define
```

## 2. Apply the database schema

The project needs nine migrations, applied **in order**:

| Order | File | Contents |
|---|---|---|
| 1 | `supabase/migrations/0001_core_schema.sql` | tables, indexes, constraints |
| 2 | `supabase/migrations/0002_functions_triggers.sql` | profile trigger, membership/block enforcement, get-or-create RPC |
| 3 | `supabase/migrations/0003_rls_policies.sql` | row level security on every table |
| 4 | `supabase/migrations/0004_views_storage_realtime.sql` | `conversation_list` view, storage buckets + policies, realtime publication |
| 5 | `supabase/migrations/0005_email_discovery.sql` | find a person by their email address (`search_users`), discoverability flags |
| 6 | `supabase/migrations/0006_one_reaction_per_user.sql` | collapses duplicates, adds `message_reactions_one_per_user` |
| 7 | `supabase/migrations/0007_call_signalling.sql` | `calls`, `call_ice_candidates`, transition + SDP-ownership triggers (the media itself is peer-to-peer, not in the database) |
| 8 | `supabase/migrations/0008_presence_last_seen.sql` | `user_presence` heartbeat, `touch_last_seen()`, `get_presence()` — online status and last seen |
| 9 | `supabase/migrations/0009_read_cursor.sql` | `mark_conversation_read()` — clears an unread badge against the newest message in the table, forward-only |

### Option C — the whole schema in one paste (recommended when in doubt)

`supabase/apply_all.sql` is all thirteen migration files concatenated, plus the health check
at the end. Paste it once; there is nothing to edit and no order to get right.

```
Dashboard -> SQL Editor -> New query -> paste supabase/apply_all.sql -> Run
```

Its last statement prints a table where every row must read `ok`. That is the
whole setup verified in one step. **Fourteen rows** is the current full set (it
grew with 0005 email search, 0007 calls, 0008 presence and 0009 read cursor); a
missing row means an older bundle.

Use this when you are unsure what state the database is in — after a failed run,
after a `git pull` that changed the migrations, or when the app reports a missing
column. It is safe on an empty database, a half-applied one, and a complete one.

If you cannot pull from git, open the file on GitHub
(`supabase/apply_all.sql` -> **Raw**) and copy it from the browser.

### Option A — Supabase CLI

```powershell
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
```

### Option B — Dashboard (no CLI installed)

1. Open **Supabase Dashboard → SQL Editor → New query**.
2. Paste the entire contents of `0001_core_schema.sql`, press **Run**.
3. Repeat for `0002`, `0003`, `0004`, `0005`, `0006`, `0007`, `0008`, `0009`, in
   that order.
4. Optionally run `supabase/seed.sql` for two demo accounts
   (`alice@example.com` / `bob@example.com`, password `MailChat123!`).
   Never run the seed against staging or production.

Each file is idempotent where practical (`create table if not exists`,
`drop policy if exists`), so re-running one file is safe. Applying them out of
order will fail: 0003 references functions created in 0002.

### Re-running is safe

Every file is written to be applied more than once. That matters because these
are pasted into a SQL editor by hand, and a half-applied set is otherwise hard to
recover from. `dart run tool/check_migrations.dart` enforces it in CI:
`create trigger` has no `if not exists`, so each trigger is dropped first, and
publication membership is checked before it is added. The same script checks that
`apply_all.sql` still matches the migrations, and rebuilds it after a change:

```powershell
dart run tool/check_migrations.dart --write-apply-all
```

The migrations remain the source of truth; `apply_all.sql` is generated and its
header says so.

The complete bundle may be re-run even when the database already has the later
`conversation_list` shape from migration 0011. Migration 0004 drops and rebuilds
that view to its base shape first; migration 0011 then restores the favourite and
pinned columns. The view has no dependent views, and dropping it does not delete
conversation/message data.

### Verify it worked

`supabase/verify.sql` is read-only and does all of the checks below in one table,
with each row reading `ok`. It is also the tail of `apply_all.sql`, so Option C
prints it automatically. The individual checks:

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

### Unread badges

The count on a chat row is `conversation_list.unread_count`: messages newer than
your `conversation_members.last_read_message_id`, not sent by you, not deleted.
Opening a chat calls `mark_conversation_read()` (0009), which points the cursor at
the newest message **in the table** and refuses to move it backwards, then returns
what is still unread. The app zeroes the badge immediately and adopts the server's
answer when you come back out.

If a badge will not clear, in this order:

* row 13 of the verification table must be `ok` (the function exists) and row 14
  (`conversation_list` is the current definition — a stale hand-applied view is the
  usual cause of wrong counts, and re-pasting `apply_all.sql` fixes it);
* the app logs `unread_count_not_cleared` with the conversation id when the badge
  survives a read, which distinguishes "the write failed" from "the view is stale";
* `mark_conversation_read` refuses callers who are not members, so a `42501` in the
  log means the conversation id does not match a membership row.

### Online status and last seen

`0008` adds a heartbeat. The app writes `touch_last_seen()` every 30 seconds while
it is in the foreground; `get_presence()` reports a peer as online when that
heartbeat is less than 75 seconds old, and otherwise reports the timestamp the
chat header shows as "last seen 10:41 AM".

Two things follow from that, and both are expected rather than bugs:

* closing the app does not send anything — the last heartbeat simply ages out, so
  someone shows as offline about a minute after they leave;
* if **Privacy → Show online status and last seen** is off, other people see
  nothing at all. The function returns nulls rather than "offline", because the
  app must not claim to know something it does not.

Check it by hand after a heartbeat:

```sql
select user_id, last_seen_at, now() - last_seen_at as age
from public.user_presence;
```

### Searching by email

User search accepts a username, a display name, or a **full email address**. The
last one needs migration `0005`, and it is why search is an RPC rather than a
select on `profiles`:

* emails stay in `auth.users`, which the app never reads directly. `profiles` is
  readable by every signed-in user, so an email column there would publish every
  address in the project;
* `public.search_users` reads `auth.users` as its owner, matches the address and
  returns profile fields only — the address is never an output;
* the match is **exact**, so a partial address finds nobody. That is deliberate:
  substring matching on addresses would let anyone enumerate accounts;
* both lookups are opt-out and enforced in the function, controlled by
  **Privacy → Discoverability**. Turning `Allow search by email` off removes the
  user from address lookups immediately.

So "I searched my email and found nobody" is usually one of three things: that
person turned email discovery off, their address is not confirmed yet, or `0005`
has not been applied (search then fails with *schema is out of date*).

### Auth settings

**Authentication → URL Configuration**: add `mailchat://auth/callback` to
Redirect URLs, or email confirmation links will bounce.

For local testing, consider turning **Authentication → Providers → Email →
Confirm email** off. Otherwise every test account needs a real inbox before it
can sign in. The app does not fake verification either way — it reflects what
the backend does.

## 2b. Build an installable APK

```powershell
.\tool\build_apk.ps1            # debug, split per ABI, signed with the debug key
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

The script validates `assets/config/env` with the app's own parser before
building, so it cannot hand you an APK that opens a configuration-error screen.
There is also a manual CI workflow that builds an APK against your project with
no local Android setup. Both are documented in **`docs/release.md`**.

### `flutter_webrtc` will not compile

Symptom, from `flutter run` or `flutter build apk`:

```text
Warning: The plugin flutter_webrtc requires Android SDK version 36 or higher.
SurfaceTextureRenderer.java:149: error: <anonymous ...$1> is not abstract and
does not override abstract method onSurfaceDestroyed() in Callback
FAILURE: Build failed with an exception.
* What went wrong:
Execution failed for task ':flutter_webrtc:compileDebugJavaWithJavac'.
```

Neither line is a bug in this repository. Two independent facts about the SDK:

| Fact | Needs |
| --- | --- |
| The plugin calls `TextureRegistry.SurfaceProducer.Callback.onSurfaceCleanup()`. Before Flutter 3.29 that interface declared an abstract `onSurfaceDestroyed()`, which the plugin does not implement | Flutter **≥ 3.29** |
| The plugin compiles against Android SDK 36; Flutter's default `compileSdk` was 34 until 3.32 and 35 until 3.35 | Flutter **≥ 3.35**, or an explicit `compileSdk = 36` |

`flutter_webrtc`'s own pubspec says `flutter: ">=1.22.0"`, which is why `pub get`
never warned you. This repository declares the real floor, so on an old SDK
`flutter pub get` now stops with a readable message instead.

The fix, in order:

```powershell
flutter upgrade                  # must be 3.35 or newer; `flutter --version`
flutter clean
dart run tool/fix_android_build.dart --reset --yes
flutter run
```

`--reset` deletes the generated `android/` folder and scaffolds it again, because
a folder generated by an older SDK keeps its old `compileSdk`. It is not
committed — but **back up `android/app/build.gradle` first if you have configured
release signing there**, since `--reset` discards it. Without `--reset`, the same
command still pins `compileSdk` and re-applies the deep-link and call-permission
patches to the existing folder:

```powershell
dart run tool/fix_android_build.dart
```

If it prints `✗ Your Flutter is too old for flutter_webrtc`, upgrade — no edit to
this repository will work around it. If you cannot upgrade yet, `git log` around
the call-media commit is the point where the app started needing WebRTC.

### The build stops with "Gradle version is lower than Flutter's minimum"

Symptom, minutes into `flutter run` after an SDK upgrade:

```text
* Where:
Build file '...\android\app\build.gradle' line: 5

* What went wrong:
An exception occurred applying plugin request [id: 'dev.flutter.flutter-gradle-plugin']
> Failed to apply plugin 'dev.flutter.flutter-gradle-plugin'.
   > Error: Your project's Gradle version (8.3.0) is lower than Flutter's minimum
     supported version of 8.14.0. Please upgrade your Gradle version.
```

Cause: `flutter upgrade` replaces the SDK but **never rewrites an existing
`android/` folder**, so the Gradle wrapper keeps whatever version the previous
SDK wrote. Flutter 3.47 refuses anything below Gradle 8.14 and scaffolds 9.3.1;
a folder created by a much older Flutter still says 8.3. Nothing in `lib/` is
involved. CI never sees this because CI runs `flutter create` on every build, so
its folder is always current.

The fix is one command — regenerate the folder instead of editing it:

```powershell
dart run tool/fix_android_build.dart --reset --yes
flutter clean
flutter run
```

Do not raise the numbers by hand. Newer Android Gradle Plugin releases only read
the new DSL, so a wrapper bumped under an `app/build.gradle` written for AGP 8
fails with the *next* message in the same output ("Starting AGP 9+, only the new
DSL interface will be read"), and `--android-skip-build-dependency-validation`
only silences the first check while leaving the mismatch in place.

Running the same tool without `--reset` checks this for you, before Gradle gets
a chance to spend minutes on it:

```text
✗ android/ was generated by an older Flutter SDK.

    this project: Gradle 8.3, AGP 8.1.0
    this SDK:     Gradle 9.3.1, AGP 9.1.0
```

The comparison is against a throwaway project scaffolded by *your* SDK, so it
stays correct as Flutter's own versions move; there is no version table in this
repository to go stale. `--reset` is safe because `android/` is generated — back
up `android/app/build.gradle` first if you configured release signing there
(`docs/release.md`).

If the build then stops on Java, Flutter 3.47 requires **JDK 17 or newer**.
`flutter doctor -v` shows which JDK it picked; `flutter config
--jdk-dir="C:\Program Files\Android\Android Studio\jbr"` points it at the one
Android Studio bundles.

### The build fails with "Could not close incremental caches"

Windows only, and it arrives *after* the whole build has run — 30+ minutes in the
reported case:

```text
e: Daemon compilation failed
Caused by: java.lang.AssertionError: java.lang.Exception: Could not close
incremental caches in H:\Mailchat\build\flutter_webrtc\kotlin\compileDebugKotlin\...
        Suppressed: java.lang.IllegalArgumentException: this and base files have
        different roots: C:\Users\<you>\AppData\Local\Pub\Cache\hosted\pub.dev\
        flutter_webrtc-1.6.3\android\... and H:\Mailchat\android.
...
Execution failed for task ':flutter_webrtc:compileDebugKotlin'.
```

Read the two paths in the "different roots" line: the *package* is in the pub
cache on **C:**, the *project* is on **H:**. Kotlin's incremental compiler stores
every source file relative to the module, and Windows cannot relativise a path
across drives, so writing the cache throws. Up to Kotlin 2.2.x the compiler fell
back to a full recompile and the build still finished; from 2.3 the fallback
fails too ("Storage ... is already registered"). Flutter 3.47 scaffolds Kotlin
2.4.0, so it is fatal.

The fix is to turn off Kotlin's incremental compilation for this project.
`dart run tool/fix_android_build.dart` does it automatically when it detects the
two paths are on different drives:

```powershell
dart run tool/fix_android_build.dart
flutter run
```

What it writes, and why it is safe:

```ini
# android/gradle.properties
# mailchat:kotlin-incremental-off
# Kotlin stores incremental-cache paths relative to the module, which
# fails with "this and base files have different roots" when the pub
# cache is on another drive (C:) than this project. See docs/running.md.
kotlin.incremental=false
```

Only the Kotlin compiled for *plugins* is affected — this app's own code is Dart
— so the lost incremental speed costs seconds per build, not minutes. If you move
the project to `C:` (or point `PUB_CACHE` at `H:`), you can delete the line and
get incremental compilation back; the tool never adds it when both paths are on
the same drive.

The tool also deletes `build/` when it applies this setting, because the caches
written by the failed attempt are the ones that cannot be closed. If you set the
property by hand, run `flutter clean` first — otherwise the next build fails in
exactly the same place.

Moving the project instead of disabling the setting is a legitimate alternative:
`C:\Mailchat` with the pub cache on `C:` needs no change at all. Pointing
`PUB_CACHE` at a folder on `H:` works too, but re-downloads every package.

### "plugins that apply Kotlin Gradle Plugin"

```text
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP):
flutter_webrtc
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
```

A warning about the plugin's future, not an error now, and nothing in this
repository can fix it: `flutter_webrtc` bundles its own Kotlin build script
instead of using the Kotlin that Flutter now provides. It becomes fatal when
Flutter removes the old path — at which point `flutter_webrtc` needs a release
that supports built-in Kotlin, and `pubspec.yaml` needs a newer version. Until
then it can be ignored; it is not the cause of anything else in the build.

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
flutter run -d windows
```

Requires Visual Studio with the **Desktop development with C++** workload. This
is the quickest way to see whether the UI renders, but it is not the target
platform. Credentials come from `assets/config/env` exactly as on Android.

### The Flutter app will not run in Chrome

The phone client is built on `dart:io` (`HttpClient`, `WebSocket`, `File`) for
the Supabase REST, Realtime and session layers. `dart:io` does not exist on the
web, so `flutter run -d chrome` fails to compile. Do not spend time on it.

The browser client is a separate page, `webapp/index.html`, for the same
Supabase project. See [web.md](web.md). It is not a Flutter web build.

## 4. Troubleshooting installs

### The app closes (or restarts) when a call starts

There is no exception in `flutter run` — the console simply stops and
`Lost connection to device.` appears, followed by a **new process id** and a
restart at the login screen. That is not a Dart error: the process was killed
below Dart, in native code (the camera, WebRTC itself, or the video texture).
A Dart exception would have been caught by the call screen and shown as
"Could not start the call".

**First, get the crash.** `flutter run` does not print it; Android does:

```powershell
adb logcat -b crash -d
```

Note what that buffer contains: **Java/Kotlin exceptions only**. If it lists
other apps (or old timestamps) and nothing for `com.mailchat.mailchat`, the
process was killed some other way — a native signal (camera, WebRTC, Vulkan) or
the system's low-memory killer — and you need the main buffer instead:

```powershell
adb logcat -c                                  # clear
# reproduce the call, wait for the app to come back
adb logcat -d > call-crash.txt
```

Then search it, in this order:

```powershell
findstr /I /C:"mailchat" /C:"Fatal signal" /C:"debuggerd" /C:"lowmemorykiller" /C:"Killing" /C:"SecurityException" call-crash.txt
```

| What appears | Cause |
| --- | --- |
| `Fatal signal 11 (SIGSEGV)` / `SIGABRT`, frames in `libflutter.so`, `libwebrtc*.so`, `libvulkan` | native crash in the renderer or WebRTC |
| `lowmemorykiller` / `ActivityManager: Killing … mailchat … (adj …)` / `am_kill` | the OS killed the app for memory — a debug build with WebRTC is heavy |
| `SecurityException` with a permission name | a runtime permission that was never requested |

`adb shell dumpsys dropbox --print data_app_native_crash` also keeps native crash
reports, and works when the log has rolled over.

**The breadcrumb the app leaves.** Because a native or OOM kill leaves nothing in
Dart, `call_media.dart` writes the step it is *about to* run into a small file,
and deletes it when the call ends properly. After a crash, the next launch logs:

```text
WARN previous_call_ended_without_cleanup {trace: step "getUserMedia_begin" (voice call) at 2026-10-27T…, hint: the app died during a call; the last step above was running}
```

That single line is the answer to "where did it die" — send it with the log.

**Rule out memory first, it is free.** A debug build carries the JIT engine on
top of WebRTC:

```powershell
flutter run --profile
```

If the call survives in profile mode and dies in debug, it is memory, not a bug
in the call code.

Two outcomes, two different causes:

| Crash buffer shows | Cause | Fix |
| --- | --- | --- |
| `FATAL EXCEPTION` … `SecurityException` … `BLUETOOTH_CONNECT` / `CAMERA` / `RECORD_AUDIO` | A missing runtime permission. `flutter_webrtc` requests camera and microphone itself but **not** `BLUETOOTH_CONNECT`, which Android 12+ requires before an audio call touches Bluetooth | Grant the permission: **Settings → Apps → MailChat → Permissions** → allow Microphone, Camera, and **Nearby devices** |
| `Fatal signal 11 (SIGSEGV)` / `SIGABRT`, with `libflutter.so`, `libwebrtc` or Vulkan frames | A native crash in rendering or WebRTC | Test with the software renderer, below |

**Test the renderer** (30 seconds, no rebuild of anything but the app):

```powershell
flutter run --no-enable-impeller
```

If the call now works, Impeller's Vulkan backend is the cause on this GPU. To
make that permanent, add this inside `<application>` in
`android/app/src/main/AndroidManifest.xml`:

```xml
<meta-data
    android:name="io.flutter.embedding.android.EnableImpeller"
    android:value="false" />
```

and run `flutter clean && flutter run`. (`dart run tool/fix_android_build.dart
--reset --yes` would discard the edit, because `android/` is generated.)

**Which step died.** `call_media.dart` logs each step *before* it runs, so the
last line in the log before the process ends localises the crash:

```text
INFO call_media_step {step: renderers_begin, video: false}
INFO call_media_step {step: renderers_skipped, video: false}
INFO call_media_step {step: getUserMedia_begin, video: false}   <- died here
```

| Last step | Meaning |
| --- | --- |
| `renderers_begin` | The video texture (**only** for a video call; voice calls skip it) |
| `getUserMedia_begin` | Camera/microphone permission or the camera driver |
| `peer_connection_begin` | WebRTC initialisation, including the audio device |
| `tracks_added` | Attaching the local tracks |

Send that last line with the crash buffer — it plus the crash type identifies
the cause without another round trip.

### The app forgets the login after a restart

Sessions are stored as a plaintext JSON file in the app's **cache** directory
(`docs/security.md` explains why that is temporary). The startup log now says
which case it is:

```text
INFO session_store_read {found: false, path: /data/user/0/com.mailchat.mailchat/cache/mailchat_session.json}
```

* `found: false` — the file is gone. Android may clear the cache directory;
  which is why this storage is not production-grade.
* `found: true` and still sent to `/login` — the refresh token was rejected, and
  `auth_restore_attempting_refresh` appears above it.

The fix for both is the same and is on the outstanding list: replace
`FileSessionStore` with a keystore-backed store (`flutter_secure_storage`).

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

The message now names the layer that failed, because "Could not reach" covers
four different problems with four different fixes:

| Message | Meaning | Where to look |
|---|---|---|
| `This device could not look up "<host>"` | No DNS answer — **no request was attempted** | The phone's connection, step 2 |
| `The connection to "<host>" was refused` | Name resolved, nothing listening | Paused project, or a firewall, step 1 |
| `"<host>" did not answer in time` | Slow or blocked | Network, often a proxy |
| `The secure connection to "<host>" failed` | TLS | Wrong device clock, captive portal |

Work through these in order — for a *lookup* failure it is almost always the
second, and for everything else the first.

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

Or let the checker do both halves of that question (it also verifies that the
key and the URL belong to the same project, which otherwise shows up as a
failing login):

```powershell
dart run tool/check_config.dart --check-network
```

```text
ok xxxx.supabase.co -> 104.18.x.x (21 ms)
  This machine can reach the project. If the phone reports
  "Failed host lookup", the problem is on the phone...
```

A pass there is proof the project is alive and the ref is right — which moves
the whole investigation to step 2. A failure there means the project was
paused, renamed or deleted (free-tier projects pause after a week of inactivity
and must be restored from the dashboard).

**2. The phone has no working connection.**

The device is not automatically on your PC's network path. Check:

```powershell
adb shell ping -c 3 8.8.8.8
adb shell ping -c 3 YOUR-PROJECT.supabase.co
```

If the IP pings but the hostname does not, it is a DNS problem on the device:
disable private DNS, reconnect Wi-Fi, or test on mobile data.

This is the state that produces, in the app log:

```text
SocketException: Failed host lookup: 'xxxx.supabase.co'
(OS Error: No address associated with hostname, errno = 7)
```

`errno = 7` is `EAI_NONAME`: the lookup itself failed. The app is working
correctly — nothing was sent — and `adb` is the quickest proof, because it runs
the same lookup the app does:

```powershell
adb shell ping -c 3 xxxx.supabase.co     # "unknown host" = the phone's DNS
```

On the phone, in order: turn Wi-Fi off and use mobile data (or the reverse),
turn off any VPN, and check **Settings → Network → Private DNS** is *Automatic*
(a strict private DNS such as an ad-blocking resolver can refuse this host).

The reconnect loop in the log is expected while this is broken, but it now backs
off (5 s, 10, 20, 40, then 60 s) and logs the classified cause instead of a stack
trace every five seconds.

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

### `Failed host lookup` with `errno = 7`, and `UDP send … failed with error 1`

Two log lines that usually appear together, and that both mean *the phone is
withholding the network from this app* rather than *the server is down*:

```text
I/flutter: ERROR SocketException: Failed host lookup: 'xxxx.supabase.co' (errno = 7)
E/stun_port.cc: UDP send of 20 bytes to host stun.l.google.com:19302 failed with error 1
```

`errno = 7` is `EAI_NONAME`: the name never resolved, so no request left the
phone. `error 1` on a UDP send is `EPERM`: the kernel refused the packet. Google's
STUN server is fine — something on the device is blocking this app's traffic.

The app already names the cause in its own message ("this is a name-resolution
problem, not a bad key"), shows it as a strip at the top of the chat list
(`OfflineBanner`), and retries with backoff instead of hammering. Check, in this
order:

| Check | Where |
| --- | --- |
| Airplane mode off, mobile data or Wi-Fi actually on | notification shade |
| **Data saver** off, or MailChat allowed | Settings → Connections → Data usage → Data saver |
| **Background data** allowed for MailChat | Settings → Apps → MailChat → Mobile data → allow background data |
| **Private DNS** set to Automatic | Settings → Connections → More connection settings → Private DNS |
| No VPN / ad-blocking app intercepting traffic | Settings → Connections → VPN |
| The host resolves from the phone at all | `adb shell ping -c 1 YOUR-PROJECT.supabase.co` |

That last one splits the two halves cleanly: if `ping` fails too, the phone's
network is down; if `ping` works and the app still cannot resolve, it is a
per-app restriction (data saver, background data, VPN).

Mid-call this also explains a call that rings, records audio and never connects:
see [calls.md](calls.md) § "The call rings, the microphone works, but it never
connects".

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

### Signup response shapes

`POST /auth/v1/signup` does not have one response shape. The client normalises
three, plus the flat password-grant shape (`SupabaseClient.normalizeAuthPayload`):

| Shape | When | Meaning |
|---|---|---|
| `{user: {...}, session: null}` | confirmations required | confirmation email sent |
| `{id, aud, role, email, identities, ...}` — the user object **at the top level**, no wrapper | confirmations required | the same thing, different envelope |
| `{user: {...}, session: {...}}` | confirmations disabled | signed in |
| `{access_token, refresh_token, expires_at, user}` — flat, no `session` | `POST /auth/v1/token` (password sign-in) and older GoTrue signups | signed in |

The second row is the one that bites: a client that only reads `data['user']`
reports "returned no user" for a perfectly good signup. If that message appears,
check the logged `signup_no_user {keys: [...]}` line — a key list containing
`id`, `aud`, `role` and `identities` means the response was the user object.

The `auth_registration_awaiting_confirmation` log line includes
`confirmationSentAt`. If it is `null` while no session was returned, GoTrue did
not dispatch an email — usually a project with no SMTP configured (the built-in
service is rate-limited and only delivers to team addresses).

### What do I put in Site URL?

Any real `https://` **web page**. It is only the fallback destination, not the
app's URL (an app has none), so `https://example.com` is enough — provided
`mailchat://auth/callback` is in Redirect URLs, which is the setting that
actually matters.

Two values break the link:

| Value | What happens |
|---|---|
| `http://localhost:3000` | On a phone, localhost is the phone → "site can't be reached" |
| `https://<ref>.supabase.co` | The API host serves no `/` route → `{"error":"requested path is invalid"}` |

Use a page you control (GitHub Pages, your own domain) if you want the fallback
to be useful. `docs/auth-links.md` has the details.

### `trigger "..." for relation "..." already exists` (42710)

**Fastest way out: run `supabase/apply_all.sql` instead** (Option C in §2). One
paste, no editing, and it cannot hit this error. The rest of this entry explains
the cause and the manual fixes.

The migration was applied before and the statement is not re-runnable — the SQL
editor runs the whole file as one transaction, so it aborts and nothing in that
attempt is applied.

`0001` was fixed for this (its four `set_updated_at` triggers are now dropped
before being created, matching what `0002` already did). Pull the current files
and run all four in order. If you cannot pull, the one-line workaround is:

```sql
drop trigger if exists profiles_set_updated_at on public.profiles;
-- repeat for conversations, user_devices, notification_preferences
```

Then run the file again. `dart run tool/check_migrations.dart` reports any file
that would fail this way, without touching the database.

The same error appears in another form:

```
ERROR: 42710: relation "messages" is already member of publication "supabase_realtime"
```

That is the same root cause in `0004`. It was fixed in the same commit, so seeing
it means the file being run is older than the repository. Confirm with Ctrl+F:

| search for | present | absent |
| --- | --- | --- |
| `pg_publication_tables` | current `0004` | stale — pull before running |
| `drop trigger if exists` | current `0001` | stale — pull before running |

If you cannot pull, delete the four `alter publication ... add table` lines and
run the rest of the file: the tables are already published, so those lines have
nothing left to do and nothing else in `0004` depends on them.

### `column conversation_list.updated_at does not exist` (or any "does not exist")

The app is ahead of the database: PostgREST answered a query for a column or table
that is not there yet (SQLSTATE `42703` / `42P01`). It is not a bug in the screen.

```sql
-- Which migrations have effectively run? Compare against the files.
select table_name from information_schema.tables
where table_schema = 'public' order by table_name;
```

Re-run the migration that creates the missing object, in the SQL editor — for
this error, `0004_views_storage_realtime.sql`. Migrations are written to be
re-runnable, so applying it twice is harmless.

From this version on, the app turns these codes into an instruction that names
the migration, instead of showing the raw JSON body.

### Sign-in says "Invalid email or password" but Supabase logs show 200

The request succeeded and the client failed to read the response — a different
problem from a wrong password, and the message used to claim otherwise.

`POST /auth/v1/token?grant_type=password` returns a **flat** payload: the tokens
are siblings of `user`, with no `session` object. A client that reads only
`data['session']` sees no session, concludes the sign-in failed, and blames the
credentials. Sign-in now goes through `SupabaseClient.normalizeAuthPayload`,
which handles both that shape and `{user, session}`.

If it recurs after an update, the log carries `signin_no_session` with the
response's key names — that is the line to report, because it means GoTrue
changed shape again. A genuinely rejected sign-in logs `signin_rejected` with
GoTrue's `error_code` (`invalid_credentials`, `email_not_confirmed`, ...) and
shows the matching sentence rather than a JSON body.

### The confirmation link opens "null is unreachable" / "localhost unreachable"

Chrome's page, not the app's — the verify URL had no host the phone could reach.
Two variants of the same cause:

- `null is unreachable` → **Site URL** is unset or literally `null`.
- `localhost unreachable` (link looks like `http://localhost:3000/#access_token=…`)
  → **Site URL** is Supabase's local default. On a phone, `localhost` is the
  phone itself.

Either way the app's `AUTH_REDIRECT_URL` was also missing from **Authentication
→ URL Configuration → Redirect URLs**, so GoTrue ignored it and fell back to the
Site URL. Fix the dashboard fields, then `dart run tool/enable_deep_links.dart`.

The account itself is usually already confirmed — the token in the failed URL is
valid. To finish without changing anything: sign in with the password, or paste
that URL into the app via *"Have a confirmation link?"* on the login screen. See
`docs/auth-links.md`.

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
- **Attachments are unverified.** The picker, upload and signed-URL viewer all
  exist; no upload has been exercised against a live bucket.
- **Calls include a public global relay.** Media is real (`flutter_webrtc`).
  Same Wi-Fi can connect directly. A different network, including mobile data,
  uses the built-in Open Relay list. A private relay is optional: paste the
  provider's whole address list (one line, comma-separated, including the
  `turns:…:443?transport=tcp` entry) into `TURN_URL` and add `TURN_USERNAME` /
  `TURN_CREDENTIAL`. `dart run tool/check_config.dart` confirms a paste and
  refuses a list that has no TCP/TLS address. See `docs/calls.md`.
  Before blaming the app, the same network can be tested from a computer and a
  phone with `tool/call_test_server.py` — see `docs/calls.md`.
- **No push notifications.** No FCM credentials are configured; the preference
  switches save but nothing is delivered — see `docs/notifications.md`.
- **Realtime is unverified.** Implemented, never executed.
- **Presence needs migration 0008.** Without it the chat header shows nothing
  and the chat list has no dots.

## 7. First-run checklist

Work through this in order; each step exercises a different layer.

1. App launches and shows the splash screen → theme and routing work.
2. Register an account → signup, `handle_new_user` trigger, profile insert, RLS.
3. Confirm the account (dashboard, or email if confirmations are on) → login.
4. Send a message → messages insert, membership trigger, block check.
5. Kill and relaunch → session restore (plaintext file store; see above).
6. Second client, same conversation → realtime delivery.
7. Block the other user, try sending → server-side block enforcement.
