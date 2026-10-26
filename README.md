# MailChat

[![CI](https://github.com/vidu1999/Mailchat/actions/workflows/ci.yml/badge.svg?branch=arena%2F3c0fee10-mailchat)](https://github.com/vidu1999/Mailchat/actions/workflows/ci.yml)

Email-based real-time messaging. Users register and chat with an email address
and a username — **no phone number, no SMS OTP, no SIM card**.

Flutter (Dart) client, Supabase backend (Auth, PostgreSQL, Realtime, Storage).

---

## Quick start

```bash
cp assets/config/env.example assets/config/env   # PowerShell: Copy-Item
# put your project URL + anon key in assets/config/env
flutter run
```

No `--dart-define` flags. Configuration is read at runtime from the bundled
`assets/config/env` asset; `--dart-define` still overrides it.

To build an installable APK instead of running from source:

```powershell
.\tool\build_apk.ps1      # or: ./tool/build_apk.sh
```

See `docs/release.md`. The file is
gitignored — never commit real credentials, and never use the `service_role`
key in the app. Details: `docs/running.md` §1.

---

## Running it anywhere

`docs/any-device.md` lists what makes the difference between "runs on my phone"
and "runs on anyone's": the dashboard steps only you can do, what the code
already handles, and the gaps that are still real.

---

## Project status

This is a **work in progress**, not a shippable app. Read this before relying
on anything below.

| Area | State |
|---|---|
| Design system, routing, theme | Implemented |
| Auth screens + `AuthService` (Supabase Auth) | Implemented; **registration verified against a live project**, sign-in not yet exercised end to end |
| Chat list, direct chat, message send/receive | Implemented; compiles, never exercised against a live database |
| Groups (create, members, roles, leave) | Implemented; never exercised |
| Reactions, receipts, edit/delete | Implemented; never exercised |
| Blocking, reporting, privacy + notification settings | Partially implemented |
| Profile / search / settings screens | Implemented; never exercised |
| Database schema, RLS policies, triggers, seed | Written; migrations must be applied by hand (see `docs/running.md` §2) |
| `flutter analyze` | **Clean** — locally and in CI |
| Registration against a live Supabase project | Reaches GoTrue; confirms/existing-account/signed-in paths handled |
| Unit + widget tests | **54 cases, passing in CI** (the last local run, 38 cases, predates the SDK-config and registration suites) |
| GitHub Actions CI (analyze, test, build APK) | **Green** |
| Debug APK build | **Builds in CI and locally; installs and launches on a physical Android device** |
| Attachments (upload/preview) | **Stubbed** — needs a file picker + Storage wiring |
| Push notifications (FCM) | **Not implemented** — no credentials, no sender |
| Email link handling (confirm / reset) | Implemented on Android; needs a Site URL + Redirect URLs in Supabase — see `docs/auth-links.md` |
| Voice / video calls | **UI only** — see `docs/calls.md` |
| End-to-end encryption | **Not implemented** — and not claimed |

**Where the evidence stops.** The app builds, installs, launches and completes a
real signup request against Supabase Auth; analysis and the test suite pass in
CI. That is the whole of the verified surface. Nothing has been exercised
against a database with the migrations applied — realtime delivery, sending a
message, groups, uploads and settings are all untested on a device. Do not
describe this as a working app until the manual checklist in `docs/testing.md`
passes.

## Requirements

- Flutter 3.22+ (stable), Dart 3.3+
  (the theme uses `surfaceContainerHighest`; older SDKs do not have it)
- A Supabase project
- Android Studio / Xcode for device builds

## Setup

1. **Install Flutter** — https://docs.flutter.dev/get-started/install

2. **Clone and enter the repo**
   ```bash
   git clone https://github.com/vidu1999/Mailchat.git
   cd Mailchat
   ```

3. **Generate the platform folders** (not committed to keep the repo lean)
   ```bash
   flutter create --platforms=android,ios --org com.mailchat --project-name mailchat .
   ```
   Commit the resulting `android/` and `ios/` folders before your first release.

4. **Fetch dependencies**
   ```bash
   flutter pub get
   ```

5. **Configure Supabase**
   - Create a project at https://supabase.com
   - Copy `.env.example` to `.env` and fill in `SUPABASE_URL` and
     `SUPABASE_ANON_KEY` (Settings → API)
   - Run the migrations in order:
     ```bash
     supabase db push          # or paste supabase/migrations/*.sql in the dashboard
     ```
   - Optional demo data: run `supabase/seed.sql` (local/dev only — it creates
     real accounts with a known password)

6. **Configure Auth redirect URLs** in Supabase → Authentication → URL
   Configuration. Add `mailchat://auth/callback` for local development.

7. **Run**
   ```bash
   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
   ```

## Building an APK

```bash
flutter create --platforms=android --org com.mailchat --project-name mailchat .
flutter pub get
flutter build apk --debug
# build/app/outputs/flutter-apk/app-debug.apk
```

The default debug APK bundles the Flutter engine for every ABI and is large
(100–200 MB), which can fail to install on a phone with little free space. For
a phone, build a single-ABI APK instead:

```powershell
flutter build apk --debug --split-per-abi
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

See `docs/running.md` for install troubleshooting.

A debug APK is signed with the debug keystore and is **not** suitable for
distribution. For a release build you need a signing keystore
(`android/key.properties`, which is git-ignored) and
`flutter build apk --release --split-per-abi`.

CI also builds a debug APK on every push: see the `mailchat-debug-apk` artifact
on the Actions run.

## Testing

```bash
flutter analyze
flutter test
```

Tests live in `test/unit` (validators, formatters, model parsing) and
`test/widget` (message bubble rendering). Security checks to run against your
database are in `docs/testing.md`.

## Documentation

- `docs/running.md` — setup, applying migrations without the Supabase CLI,
  device options, first-run checklist
- `docs/security.md` — threat model, key handling, RLS, known gaps
- `docs/calls.md` — why calling is UI-only and what it needs
- `docs/testing.md` — test strategy + SQL policy verification

## Repository layout

```
lib/
  core/            config, theme, routing, network (REST + Realtime), errors, logging
  features/
    auth/          splash, login, registration, email verification, password reset
    conversations/ chat list
    messaging/     direct/group chat thread
    contacts/      user search, new conversation
    groups/        create group, group details
    profile/       view/edit profile
    privacy/       privacy settings, blocked users, report user
    notifications/ notification preferences
    attachments/   preview + media viewer (stubbed)
    calls/         call UI + domain types (no media)
  shared/          models, services, reusable widgets
supabase/
  migrations/      schema, functions/triggers, RLS, views + storage
  seed.sql
test/
  unit/  widget/
docs/
.github/workflows/ci.yml
```

## Contributing

Run `flutter analyze` and `flutter test` before opening a PR. Do not add the
service-role key to the app. Do not claim a feature works until it has been run.

## License

Not yet specified.
