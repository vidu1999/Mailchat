# Voice & video calling — status and remaining work

**Status: signalling implemented, media not. A call can ring, be accepted,
declined or ended, and the two sides can exchange SDP and ICE. No audio or video
is captured or transmitted, so nobody can hear anybody.**

The chat screen's call buttons still open an explanatory dialog rather than the
call UI. That is deliberate: a ringing screen with no audio would be a lie. Flip
that dialog only together with `callMediaConnected` in
`lib/features/calls/domain/call_model.dart`.

## What exists now (migration 0007 + `lib/features/calls/domain/`)

| Piece | Where | Notes |
| --- | --- | --- |
| `calls` table | `0007_call_signalling.sql` | One row per call: participants, kind, status, SDP offer/answer, timestamps |
| `call_ice_candidates` | same | Append-only candidate stream, ordered by insertion |
| Transition rules | `enforce_call_transitions()` | Callee-only accept/decline, ended-only-from-accepted, terminal states stay terminal, participants fixed at insert |
| SDP ownership | same | Caller writes the offer, callee writes the answer, nobody rewrites the other's |
| Blocking | `enforce_call_not_blocked()` | A blocked user cannot ring; uses `has_block_relation_by(a, b)` because the existing helper reads `auth.uid()` |
| RLS | same file | Participants only, for select/update; caller-only insert inside their own conversation |
| Realtime | same file | Both tables added to the publication, guarded like `0004` |
| `Call` model + permissions | `call_model.dart` | `canAccept`, `canDecline`, `canEnd`, `canSetOffer`, `canSetAnswer`, `duration` that refuses to invent a length for a call that never connected |
| `CallService` | `call_service.dart` | `placeCall`, `fetch`, `accept`, `decline`, `end`, `markMissed`, `reportFailure`, `sendIceCandidate`, `iceCandidates`, `listenForCalls` |
| Tests | `test/unit/call_signalling_test.dart` | 15 tests pinning the rules the trigger enforces |

Two design choices worth knowing:

* **Signalling lives in the database, not only in Realtime broadcast.** A
  broadcast reaches whoever is connected at that moment. A call that arrives
  while the app is backgrounded, or whose packet is dropped, would leave no
  trace. A row gives "missed call" a definition and makes the flow auditable.
* **The server decides, the client mirrors.** `Call.canAccept` exists so the UI
  greys out the wrong button; it is not the boundary. The trigger raises
  `42501` regardless of what the client believes.

## What is missing — the media layer

Three pieces, in this order:

1. **`flutter_webrtc`** — create an `RTCPeerConnection` per call, add the local
   track, feed `offerSdp`/`answerSdp` through `CallService`, and push every
   `onIceCandidate` into `sendIceCandidate`, applying the other side's rows to
   `addCandidate`. This is the only part that needs a new dependency, and it
   needs camera/microphone permissions in `AndroidManifest.xml` and
   `Info.plist`.
2. **A TURN server.** STUN alone works on the same network and fails on mobile
   carriers, which is most of the time. Either run coturn or use a hosted
   provider; the ICE servers are supplied to `RTCPeerConnection` as config, so
   they can come from the same `.env` as the Supabase keys (and must not be
   committed if they carry a shared secret).
3. **Two devices.** Media cannot be verified any other way. This is the one part
   of the project that CI cannot check for me.

Then: flip `callMediaConnected`, wire `incoming_call_screen.dart` and
`active_call_screen.dart` to `CallService.listenForCalls`, replace the dialog in
`direct_chat_screen.dart`, and add a timeout that marks an unanswered ringing
call as `missed` (a `pg_cron` job or a check on app start — the row is already
there, so either works).

## Why the UI is still a dialog

Outstanding, in order of how much they matter:

* No media, as above.
* No push, so a call only rings if the app is open — see
  docs/push-notifications.md. A real phone call needs FCM.
* No ringtone or vibration, and no wake lock, so a call would not wake a
  sleeping phone.

All three are the same kind of problem: they need infrastructure outside this
repository. The signalling is the part that could be built here, and it is done
and tested.
