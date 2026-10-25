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

## 4. Known limitations on a first run

- **Session persistence is fragile.** The session is stored as a plaintext JSON
  file in the app's temp directory. Android may clear it, and it is not
  encrypted. Production requires `flutter_secure_storage`.
- **Attachments do nothing.** The picker and upload path are stubs.
- **Calls are UI only.** No audio or video is transmitted.
- **No push notifications.** No FCM credentials are configured.
- **Realtime is unverified.** Implemented, never executed.

## 5. First-run checklist

Work through this in order; each step exercises a different layer.

1. App launches and shows the splash screen → theme and routing work.
2. Register an account → signup, `handle_new_user` trigger, profile insert, RLS.
3. Confirm the account (dashboard, or email if confirmations are on) → login.
4. Send a message → messages insert, membership trigger, block check.
5. Kill and relaunch → session restore (expect this to be flaky, see above).
6. Second client, same conversation → realtime delivery.
7. Block the other user, try sending → server-side block enforcement.
