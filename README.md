# MailChat

Email-based real-time messaging. Users register and chat with an email address
and a username — **no phone number, no SMS OTP, no SIM card**.

Flutter (Dart) client, Supabase backend (Auth, PostgreSQL, Realtime, Storage).

---

## Project status

This is a **work in progress**, not a shippable app. Read this before relying
on anything below.

| Area | State |
|---|---|
| Design system, routing, theme | Implemented |
| Auth screens + `AuthService` (Supabase Auth) | Implemented, never compiled |
| Chat list, direct chat, message send/receive | Implemented, never compiled |
| Groups (create, members, roles, leave) | Implemented, never compiled |
| Reactions, receipts, edit/delete | Implemented, never compiled |
| Blocking, reporting, privacy + notification settings | Partially implemented |
| Profile / search / settings screens | Implemented |
| Database schema, RLS policies, triggers, seed | Written |
| Debug APK build | **Compiles** — `flutter build apk --debug` succeeds |
| Unit + widget tests | Written, **never executed** |
| GitHub Actions CI (analyze, test, build APK) | Written |
| Attachments (upload/preview) | **Stubbed** — needs a file picker + Storage wiring |
| Push notifications (FCM) | **Not implemented** — no credentials, no sender |
| Voice / video calls | **UI only** — see `docs/calls.md` |
| End-to-end encryption | **Not implemented** — and not claimed |

**The app compiles; it has never been run.** `flutter build apk --debug`
produces a working APK as of the commit that added realtime subscriptions. That
proves the code type-checks — it does **not** prove any feature works. No
database has been provisioned, no test has been executed, and no screen has
been rendered on a device.

Do not describe this as a working app until `flutter analyze`, `flutter test`
and the manual checklist in `docs/testing.md` all pass.

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
