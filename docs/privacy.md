# Privacy: blocking, reporting and settings

**Status:** 🧪 built — blocking and reporting are enforced in the database;
discoverability and presence sharing are persisted. Read receipts are still a
local switch, and the screen says so.
**Code:** `lib/features/privacy/presentation/screens/privacy_settings_screen.dart`,
`blocked_users_screen.dart`, `report_user_screen.dart`
**Database:** `supabase/migrations/0001_core_schema.sql` (`user_blocks`,
`user_reports`), `0002_functions_triggers.sql` (`enforce_block_between_users()`),
`0003_rls_policies.sql`, `0005_email_discovery.sql`, `0008_presence_last_seen.sql`
**Tests:** `test/unit/profile_search_test.dart` (search exclusions)

## What each setting does

| Setting | Stored in | Enforced where | Effect |
| --- | --- | --- | --- |
| Show online status and last seen | `user_presence.share_last_seen` | `get_presence()` | Others get `null`, not "offline" |
| Allow search by username | `profiles.discoverable_by_username` | `search_users()` | You stop appearing in handle and name searches |
| Allow search by email | `profiles.discoverable_by_email` | `search_users()` | You stop appearing in address lookups |
| Send read receipts | Nothing — device only | Nowhere | The toggle applies to this session; the screen notes this |

The two search toggles and the presence toggle are saved and take effect
immediately, because the decision is made inside the function that serves the
data. The read-receipts toggle is the exception: there is no column for it yet,
and pretending otherwise would be worse than admitting it. It is listed as a gap
below rather than quietly implemented in the client, where it could not be
respected by a modified client anyway.

## Blocking

A block is directional — A blocks B, and B is not told.

| Consequence | Where enforced |
| --- | --- |
| B cannot send messages into a conversation with A | `enforce_block_between_users()` → `42501` |
| A and B cannot call each other | `enforce_call_not_blocked()` (migration 0007) |
| Neither appears in the other's search results | `search_users()` |
| Neither sees the other's presence | `get_presence()` |
| A can unblock B from **Privacy → Blocked users** | `blocked_users_screen.dart`, RLS limited to `blocker_id = auth.uid()` |

Enforcement is in the database, not the composer, so a modified client cannot
talk its way past a block.

## Reporting

A report is a row in `user_reports`: `reporter_id`, `reported_user_id`,
optional `message_id`, `reason`, optional description (≤2000 chars), and a
status of `open` / `reviewed` / `closed` / `dismissed`. Reports are visible only
to their author through RLS; there is no moderation UI in the app.

Reporting does **not** block. They are separate actions on purpose: a user may
want a message reviewed without cutting the person off, and blocking silently
after a report would hide the outcome from the reporter.

## Rules the database enforces

| Rule | Where |
| --- | --- |
| You cannot report yourself | `user_reports_no_self` |
| Only the blocker sees their block rows | RLS `user_blocks_select_own` |
| Only the reporter sees their reports | RLS on `user_reports` |
| Presence cannot be read across a block | `get_presence()` |
| Search excludes blocked pairs both ways | `search_users()` |

## Failure modes

| Symptom | Cause | What the app does |
| --- | --- | --- |
| "Could not save" after flipping a toggle | The write failed | The switch snaps back — showing it off while the server still has it on would misstate who can find you |
| A blocked person can still message you | The block row was never created, or an old build | The insert error is shown; blocks are checked in the DB at send time |
| Report shows an error | Reason missing, or description over the limit | Validation message, nothing sent |

## Known gaps

* **Read receipts are not stored.** The switch is device-local.
* No moderation surface, so report status never changes from `open`.
* No "blocked me" indication (deliberate — telling a blocker's target would
  invite retaliation).
* Muting is stored (`conversation_members.notifications_muted`) but there is no
  UI to set it, and nothing is delivered to mute yet.
* No account deletion or data export.
