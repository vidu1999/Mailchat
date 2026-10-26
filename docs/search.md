# Finding people

**Status:** 🧪 built — username, display name and **exact email** lookup, with
opt-out discoverability and block filtering, all enforced in the database.
**Code:** `lib/shared/services/profile_service.dart` (`searchProfiles`),
`lib/shared/models/profile_search.dart`,
`lib/features/contacts/presentation/screens/new_conversation_screen.dart`,
`lib/features/contacts/presentation/screens/search_users_screen.dart`
**Database:** `supabase/migrations/0005_email_discovery.sql`
**Tests:** `test/unit/profile_search_test.dart`

## What works

| You type | What matches |
| --- | --- |
| `jane.doe` | Username substring, case-insensitive |
| `Jane` | Display-name substring, case-insensitive |
| `jane@example.com` | **Exact** address, case-insensitive — and only if that account confirmed it |

Results show the handle, and say `matched by email` when that is how the row was
found. The address itself is never displayed, because the server never returns it.

## Why this is a database function, not a query

Two constraints make a plain `select` on `profiles` impossible:

1. **Emails live in `auth.users`.** `profiles` is readable by every signed-in
   user, so an `email` column there would publish every address in the project to
   every account. `search_users` is `security definer`: it reads `auth.users`,
   matches the address, and returns profile fields only.
2. **Discoverability and blocking must be server decisions.** Both flags, the
   block list and the "email must be confirmed" rule are applied inside the
   function, so a modified client cannot widen the search.

## Anti-enumeration rules

| Rule | Why |
| --- | --- |
| Email matching is `=`, never `ilike '%…%'` | Substring matching would let anyone walk a domain and confirm which addresses exist |
| Unconfirmed addresses are not discoverable | Otherwise a stranger could pre-register a colleague's address and be found in their place |
| Blocked pairs are excluded in both directions | A blocked user must not be able to locate the blocker |
| You are excluded from your own results | Obvious, but it is an explicit clause |
| `p_limit` is clamped to 1..50 | The endpoint cannot be asked for the whole table |
| The email is never an output | The function returns a `matched_by` label instead |

## How a chat gets created from a result

```text
search result
  → POST /rpc/get_or_create_direct_conversation    advisory lock per member pair
  → conversation id (a bare JSON string — see RpcPayload)
  → GET /rest/v1/messages?conversation_id=eq.…
```

The advisory lock is what stops two devices from creating two direct
conversations for the same pair at the same moment. Creating the conversation
needs to insert the *other* user's membership row, which RLS does not permit a
plain client to do — hence the function.

## Failure modes

| Symptom | Cause | What to check |
| --- | --- | --- |
| "No MailChat account uses that email address" | Wrong address, unconfirmed account, or discovery turned off | Their Privacy → Discoverability |
| Search fails with a schema error | Migration 0005 not applied | `supabase/verify.sql` row 09 |
| Your own account does not appear | Deliberate | — |
| A blocked user still shows | Old build, or the block was removed | Privacy → Blocked users |

## Known gaps

* No contact import, no address-book sync — deliberately, since the app has no
  phone-number identity to sync against.
* No "recently contacted" list above the search box.
* No pagination of results beyond the clamped limit.
