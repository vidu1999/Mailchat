# Voice and video calls

**Status:** 🟡 **built, but unverified on a device, and dependent on a TURN
relay for mobile data.** Calling is real: `flutter_webrtc` opens a peer
connection, the microphone and camera are captured, SDP and ICE travel through
the database (0007), and the two screens drive the whole negotiation.

What is *not* proven: that a call connects between two real phones. That needs
two devices, and it needs a TURN server for anything outside the same network.
The app says so on screen when no relay is configured, and every failure ends as
"Could not connect" rather than a silent call.

**Code:** `lib/features/calls/domain/call_model.dart`,
`call_media.dart`, `call_service.dart`,
`lib/features/calls/presentation/screens/incoming_call_screen.dart` and
`active_call_screen.dart`
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

## How a call is negotiated

```text
caller                                    callee
  prepare camera/mic (before ringing)
  offer  →  calls.offer_sdp   ──────────▶  ring, from listenForCalls()
                                            prepare camera/mic
                                            answer → calls.answer_sdp
  applyAnswer(answer)       ◀────────────  accept (callee-only, trigger)
  ICE  →  call_ice_candidates  ◀────────▶  ICE
  RTCPeerConnectionState.connected         RTCPeerConnectionState.connected
```

Two ordering decisions carry the honesty of this feature:

* **Media is prepared before the row exists** (caller) or before the accept is
  written (callee). A refused microphone therefore produces "could not start the
  call" and never a ring the other person hears.
* **The screen never infers a connection.** It mirrors
  `RTCPeerConnectionState` through `stageFromPeerState()`, and only `connected`
  prints "Connected" — a test pins that every other stage's wording avoids the
  word.

`ActiveCallScreen` owns both roles. Splitting caller and callee across two
screens is how the SDP ordering gets inverted, so the sender of the offer and the
sender of the answer are one state machine with an `isCaller` flag.

## Configuration

| Key | Default | Purpose |
| --- | --- | --- |
| `STUN_URL` | `stun:stun.l.google.com:19302` | Discovers this device's public address |
| `TURN_URL` | none | Relay for carrier-grade NAT |
| `TURN_USERNAME` | none | Relay credentials |
| `TURN_CREDENTIAL` | none | Relay credentials |

All four are read in `AppConfig`, assembled by `AppConfig.buildIceServers()` and
unit tested. Without a TURN relay a call connects on the same Wi-Fi and on many
home routers, and fails on mobile data; the caller's screen says exactly that
rather than blaming the network in general.

The credential is a per-server secret, not a Supabase key, but it still belongs
in the gitignored env file (`assets/config/env`) or in `--dart-define`, never in
the repository.

## What the SDK must provide

| Requirement | Why | Where it bites |
| --- | --- | --- |
| Flutter **≥ 3.29** | `TextureRegistry.SurfaceProducer.Callback.onSurfaceCleanup()` — older engines declare an abstract `onSurfaceDestroyed()` the plugin does not implement | `:flutter_webrtc:compileDebugJavaWithJavac` fails |
| Flutter **≥ 3.35** (or an explicit `compileSdk = 36`) | The plugin compiles against Android SDK 36; 3.32 defaults to 35 | "requires Android SDK version 36 or higher" |

`pubspec.yaml` declares `flutter: ">=3.35.0"` for exactly this reason — the
plugin's own constraint (`>=1.22.0`) does not, so `pub get` would otherwise
succeed on an SDK that cannot build it. `tool/fix_android_build.dart` checks the
SDK, pins `compileSdk`, and re-applies the platform patches; CI runs the same
script, so a local build and a green run match.

## Android permissions

`android/` is not committed — CI runs `flutter create` — so the manifest cannot
carry the permissions. `tool/enable_call_permissions.dart` adds them after
scaffolding, exactly like `tool/enable_deep_links.dart` does for the intent
filter: `CAMERA`, `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`,
`ACCESS_NETWORK_STATE`, `BLUETOOTH_CONNECT`, and camera/microphone features
marked `required="false"` so a tablet without a camera can still install the app
and take voice calls. The runtime prompt is raised by `getUserMedia`.

## What still needs doing

| Item | Why it is not done here |
| --- | --- |
| **A TURN server** | Needs an account or a VPS. Until then, calls work on a local network and may fail on mobile data |
| **Two devices** | The only way to prove media; CI can compile WebRTC but cannot hear it |
| **Push for a call** | A call only rings while the app is open. Waking a backgrounded phone needs FCM — see [notifications.md](notifications.md) |
| **Ringtone, vibration, wake lock** | Without them a ringing phone may be silent and asleep |
| **Missed-call timeout** | A ring nobody answers stays `ringing` until one side acts. A `pg_cron` sweep (or a check on app start) would close it |
| **iOS** | `Info.plist` needs `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`; this repository builds Android only |

## What is verified, and what is not

| Verified | Not verified |
| --- | --- |
| The transition rules, SDP ownership, duration maths, ICE-server assembly and the media-stage wording, by unit tests | That a call connects between two real phones |
| That the app analyzes clean and a debug APK builds **with the WebRTC dependency and the permissions patched in** | Audio quality, echo, camera switching, bluetooth routing |
| That the migration is re-runnable and present in `apply_all.sql` | That Realtime delivers a `calls` insert to a sleeping-but-foregrounded app |
| `supabase/verify.sql` row 11: both tables exist with RLS | Anything about NAT traversal, which is exactly what TURN exists to fix |

The first device test to run is the one in the [testing](testing.md) checklist:
both phones on the same Wi-Fi, one call, accept, hear each other. If that works
and mobile data does not, the answer is a TURN server, not more code.
