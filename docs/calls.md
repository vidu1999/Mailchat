# Voice and video calls

**Status:** 🟡 **signalling built, media not.** A call can ring, be accepted,
declined, ended or failed, and the two sides can exchange SDP and ICE through the
database. **No audio or video is captured or transmitted, so nobody can hear
anybody.**

The chat screen's call buttons therefore still open an explanatory dialog rather
than the call UI. A ringing screen with silence behind it would be a lie. The
single switch is `callMediaConnected` in
`lib/features/calls/domain/call_model.dart`, and a test asserts it is `false`.

**Code:** `lib/features/calls/domain/call_model.dart`,
`lib/features/calls/domain/call_service.dart`,
`lib/features/calls/presentation/screens/incoming_call_screen.dart` and
`active_call_screen.dart` (not routed while media is absent)
**Database:** `supabase/migrations/0007_call_signalling.sql`
**Tests:** `test/unit/call_signalling_test.dart` (15 tests)

## What exists

| Piece | Where | Notes |
| --- | --- | --- |
| `calls` table | 0007 | One row per call: participants, kind, status, SDP offer/answer, timestamps |
| `call_ice_candidates` | 0007 | Append-only candidate stream, ordered by insertion |
| Transition rules | `enforce_call_transitions()` | Callee-only accept/decline, end only from accepted, terminal states stay terminal, participants fixed at insert |
| SDP ownership | same trigger | The caller writes the offer, the callee writes the answer; nobody rewrites the other's |
| Blocking | `enforce_call_not_blocked()` | A blocked pair cannot ring; uses `has_block_relation_by(a, b)` because the older helper reads `auth.uid()` |
| RLS | 0007 | Participants only; the caller alone may insert, inside their own conversation |
| Realtime | 0007 | Both tables added to the publication, guarded like 0004 |
| `Call` model | `call_model.dart` | `canAccept`, `canDecline`, `canEnd`, `canSetOffer`, `canSetAnswer`, and a `duration` that refuses to invent a length for a call that never connected |
| `CallService` | `call_service.dart` | `placeCall`, `fetch`, `accept`, `decline`, `end`, `markMissed`, `reportFailure`, `sendIceCandidate`, `iceCandidates`, `listenForCalls` |

## The state machine

```text
              placeCall()
                  │
                  ▼
             ┌─────────┐  callee declines  ┌──────────┐
             │ ringing │ ─────────────────▶│ declined │
             └─────────┘                   └──────────┘
               │     │
     callee    │     │  nobody answers
     accepts   │     └──────────────────▶  ┌────────┐
               ▼                           │ missed │
          ┌──────────┐                     └────────┘
          │ accepted │
          └──────────┘
               │  either side ends
               ▼
          ┌───────┐
          │ ended │
          └───────┘

  any state ──(error reported by a participant)──▶ failed
```

Wrong actor → `42501`. Wrong transition → `22023`. Terminal rows are frozen, so
a call log cannot be rewritten after the fact.

## Why signalling lives in the database

A broadcast tells whoever is connected at that moment. A call that arrives while
the app is backgrounded, or whose packet is dropped, would leave no trace at all —
no missed-call entry, no way to know it rang. A row gives "missed" a definition
and makes the flow auditable after the fact.

The server decides; the client mirrors. `Call.canAccept` exists so the UI greys
out the wrong button. It is not the boundary: the trigger raises `42501`
regardless of what the client believes. The 15 unit tests pin the client's mirror
of those rules so the two cannot drift silently.

## What the media layer needs

Three things, in this order:

1. **`flutter_webrtc`** — one `RTCPeerConnection` per call: add the local track,
   put the offer in `calls.offer_sdp`, answer into `calls.answer_sdp`, push every
   `onIceCandidate` through `sendIceCandidate`, and apply the other side's rows
   with `addCandidate`. It also needs camera and microphone permissions in
   `AndroidManifest.xml` and `Info.plist`; this repository does not commit
   `android/`, so the permissions belong in the scaffolding step (there is
   already a `tool/enable_deep_links.dart` that does exactly this kind of
   post-scaffold patch — a sibling script is the natural home).
2. **A TURN server.** STUN alone works on the same network and fails on mobile
   carriers, which is most of the time. Either run coturn or use a hosted
   provider. The ICE servers are configuration, so they come from the same
   `.env` as the Supabase keys and must not be committed if they carry a
   credential.
3. **Two devices.** Media cannot be verified any other way. This is the one part
   of the project CI cannot check.

Then, in one commit: flip `callMediaConnected`, route
`incoming_call_screen.dart` and `active_call_screen.dart` to
`CallService.listenForCalls`, replace the dialog in the chat screen, and add a
timeout that marks an unanswered ringing call `missed` (a `pg_cron` job, or a
sweep on app start — the row is already there, so either works).

## Why the buttons are still a dialog

Three independent reasons, all of them honest:

* **No media,** as above.
* **No push** — a call only rings if the app is open and connected. A real phone
  call needs FCM; see [notifications.md](notifications.md).
* **No ringtone, vibration or wake lock,** so even a delivered call would not wake
  a sleeping phone.

The first is code. The other two need infrastructure outside this repository.

## What is verified

| Verified | Not verified |
| --- | --- |
| The transition rules, SDP ownership, duration maths and the media flag, by unit tests | That Realtime delivers a `calls` insert to the callee |
| That the migration is re-runnable and present in `apply_all.sql` | That RLS lets the callee read a call but not a stranger |
| That the app compiles and an APK builds with the call code in it | Anything about audio, video, echo, or connection quality |

`supabase/verify.sql` row 11 checks the two tables exist with RLS enabled.
