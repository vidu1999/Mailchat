# Testing

## What runs in CI

`.github/workflows/ci.yml` runs on every push and pull request:

1. `flutter pub get`
2. `dart format --set-exit-if-changed lib test` (non-blocking, reports drift)
3. `flutter analyze` (blocking — lints configured as errors)
4. `flutter test --coverage`
5. A separate job builds a debug APK and uploads it as an artifact

## Test layout

```
test/unit/     validators_test.dart   input rules (email, password, username)
               formatters_test.dart   timestamps and file sizes
               models_test.dart       JSON parsing for models and the
                                      conversation_list view row
test/widget/   message_bubble_test.dart  rendering, deleted placeholder,
                                         status icons, long-unbroken text,
                                         long-press callback
```

These tests are pure Dart/Flutter with no network or database access.

## Manual verification checklist

Nothing below has been executed yet. Work through it on a real device before
calling this app functional.

### Auth

- [ ] Register with a new email; confirm the verification email arrives via
      Supabase Auth (not simulated)
- [ ] Attempt login before confirming the email — expect a clear error
- [ ] Confirm the email, then log in
- [ ] Log out, restart the app, confirm you land on login (session cleared)
- [ ] Log in, restart the app, confirm the session restores
- [ ] Request a password reset and complete it via the emailed link
- [ ] Register with a duplicate username — expect a friendly error, not a
      raw `23505` unique-violation message

### Messaging

- [ ] Send a message; confirm it appears immediately (optimistic) and then
      persists with status `sent`
- [ ] Open the same conversation on a second device; confirm new messages
      arrive in real time
- [ ] Kill the network and send — confirm the message shows `failed`, not a
      silent lie
- [ ] React to a message; confirm the reaction persists after reload
- [ ] Edit your own message; confirm `edited_at` is set
- [ ] Delete your own message; confirm it renders as deleted, not blank
- [ ] Try editing another user's message via the API directly — expect denial

### Groups

- [ ] Create a group with members; confirm the creator is `owner`
- [ ] Promote a member to `admin`; confirm a non-owner cannot
- [ ] Remove a member; confirm they immediately lose access
- [ ] Leave a group; confirm it disappears from the chat list

### Blocking / reporting

- [ ] Block a user; confirm they can no longer send you messages
      (the `messages_block_check` trigger should reject the insert)
- [ ] Confirm the blocked user can no longer see you in search
- [ ] Unblock; confirm messaging works again
- [ ] File a report; confirm the row is written with `status = 'open'`

## Verifying RLS (run in the Supabase SQL editor)

These confirm the server — not the client — is enforcing access. Run them as
two different authenticated users.

```sql
-- 1. A user must not read another user's private conversation.
--    Sign in as Alice, then:
select * from public.conversations
where id = '<conversation_alice_is_not_in>';
-- expect: 0 rows (not an error, not data)

-- 2. A user must not insert a message as somebody else.
insert into public.messages (conversation_id, sender_id, type, text)
values ('<conv>', '<other_user_id>', 'text', 'spoofed');
-- expect: RLS violation

-- 3. A non-member must not insert at all.
insert into public.messages (conversation_id, sender_id, type, text)
values ('<conv_you_are_not_in>', auth.uid(), 'text', 'intruder');
-- expect: RLS violation or the member trigger error

-- 4. Hard delete must be denied to clients.
delete from public.messages where id = '<own_message_id>';
-- expect: 0 rows affected (no DELETE policy)

-- 5. Receipts are self-only.
insert into public.message_receipts (message_id, recipient_id)
values ('<msg>', '<other_user_id>');
-- expect: RLS violation

-- 6. Reports are readable only by the reporter.
select * from public.user_reports;
-- expect: only rows you filed

-- 7. Service-role key must never work from the client.
--    Search the built APK for the key:
--    unzip -p app-release.apk classes.dex | strings | grep 'service_role'
--    expect: no match
```

## Known functional gaps (verified by reading the code, not by running it)

- **Realtime delivery is implemented but unverified.** The channel join now
  sends a `postgres_changes` config scoped to `conversation_id` plus the access
  token, and the client normalises both known payload shapes. This has never
  run against a live Supabase project. Verify it first with two devices: send
  from one, confirm the other appends without a manual refresh. If nothing
  arrives, check that `messages` is in the `supabase_realtime` publication
  (migration 0004) and that the Realtime service is enabled in the dashboard.
- **Session tokens** are stored by `FileSessionStore` in the current working
  directory. This is not secure storage on Android/iOS and must be replaced
  before release.
- **Token refresh** is not implemented; an expired access token logs the user
  out rather than refreshing.

## Known test gaps

- No integration tests (would need a running Supabase instance + two clients).
- No tests for the Realtime subscription path.
- No golden-file tests for the design system.
- No performance or battery tests.
