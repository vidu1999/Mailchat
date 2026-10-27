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

This is a **work in progress**, not a shippable app: one large feature (call
media) and one integration (push delivery) are missing, and the parts that exist
have not been exercised against a live database from the build environment.

| Area | State |
|---|---|
| Design system, routing, theme | Implemented |
| Auth (register, verify, sign in, restore, reset, sign out) | Implemented; registration reaches GoTrue against the live project, the rest awaits the manual checklist |
| Chat list, direct chat, send/receive | Implemented; never exercised against a live database |
| Unread badges | Implemented; cleared by a database function (0009), not by the phone |
| Groups (create, roles, thread, leave) | Implemented; groups now open a real message thread |
| Reactions, receipts, edit/delete, replies | Implemented; never exercised |
| Attachments (photos and files) | Implemented: `file_selector` → private bucket → `message_attachments` |
| Online status, last seen, typing | Implemented: live presence channel + a 30 s heartbeat (0008) |
| Blocking, reporting, discoverability | Implemented in the database; read-receipt toggle is device-local |
| Search by username, display name, exact email | Implemented (`search_users`, 0005) |
| Notification preferences | Implemented and persisted; **nothing is pushed** |
| Voice / video calls | Built on `flutter_webrtc`: real peer connection, offer/answer/ICE via the database, ring/accept/decline/hang-up. Unverified on a device, and mobile data needs a TURN relay — see `docs/calls.md` |
| Browser client | `webapp/index.html` — same Supabase accounts, chats and calls as the phone. Not a Flutter web build. See `docs/web.md` |
| Push notifications (FCM) | **Not implemented** — needs a Firebase project |
| End-to-end encryption | **Not implemented** — and not claimed |
| Database schema, RLS, triggers, seed | Written; applied by hand in one paste (`supabase/apply_all.sql`) |
| `flutter analyze` | **Clean** in CI |
| Unit + widget tests | **260+ cases, passing in CI** |
| GitHub Actions CI (analyze, tests, APK) | **Green** |
| Debug APK | **Builds in CI and installs on a physical Android device** |

**Where the evidence stops.** The app builds, installs, launches and completes a
real signup request against Supabase Auth; analysis, the test suite and the APK
build pass in CI. That is the whole of the verified surface. Nothing has been
exercised against a database with the migrations applied — realtime delivery,
sending a message, uploads, presence and calls are untested on a device. Do not
describe this as a working messaging app until the manual checklist in
`docs/testing.md` passes.

## Requirements

- **Flutter 3.35+ (stable)**, Dart 3.5+
  Call media pulls `flutter_webrtc`, whose Java needs an embedding hook that only
  exists from 3.29 and a default `compileSdk` of 36, reached in 3.35. On an older
  SDK the Android build fails inside the plugin, not in this repository — see
  `docs/running.md` § "flutter_webrtc will not compile".
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

Tests live in `test/unit` (rules, parsing, state machines) and `test/widget`
(rendering). The per-file list and the manual device checklist are in
`docs/testing.md`; the database checks are `supabase/verify.sql`.

## Documentation

Every feature has a document in the same shape — what works, how it works, what
the database enforces, what is missing. Start at **`docs/README.md`** for the
index, or go straight to:

| Document | Covers |
|---|---|
| `docs/running.md` | Install, configure, apply the schema, build an APK, troubleshoot |
| `docs/auth.md`, `docs/auth-links.md` | Accounts, and why confirmation links bounce |
| `docs/messaging.md`, `docs/unread.md` | Sending, ticks, edits, replies; unread counts and the read cursor |
| `docs/attachments.md` | Photos and files |
| `docs/groups.md`, `docs/search.md` | Groups; finding people by handle or exact email |
| `docs/presence.md` | Online status, last seen, typing, and the privacy switch |
| `docs/privacy.md` | Blocking, reporting, discoverability |
| `docs/notifications.md` | Preferences (real) and push (not delivered) |
| `docs/calls.md` | Voice and video: signalling built, media not |
| `docs/architecture.md`, `docs/security.md` | Components, schema, trust boundary |
| `docs/feature-matrix.md` | Every spec item, with the path that backs the verdict |

`dart run tool/check_docs.dart` fails CI if a document links to something that
does not exist, so these files cannot quietly rot.

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
    attachments/   preview + media viewer
    calls/         signalling, call model, call screens (no media yet)
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
