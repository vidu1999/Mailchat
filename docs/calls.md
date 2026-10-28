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
| `TURN_URL` | none | One relay address, or the whole list a provider gives you |
| `TURN_USERNAME` | none | Used by every address in `TURN_URL` |
| `TURN_CREDENTIAL` | none | Used by every address in `TURN_URL` |

All four are read in `AppConfig` and assembled by `AppConfig.buildIceServers()`,
with the URL list parsed by `lib/core/config/turn_urls.dart`. Both are unit
tested. `TURN_URL` accepts any of:

- one address — `turn:turn.example.com:3478`;
- a list separated by commas, semicolons or newlines;
- a whole pasted `iceServers` JSON snippet, quotes and braces included;
- `http://` / `https://` entries, rewritten to `turn:` / `turns:` because
  `RTCPeerConnection` accepts only the TURN schemes — an untouched `https://`
  entry is an ICE server the native stack discards without saying so.

`stun:` entries in a pasted list are dropped (`STUN_URL` already provides one)
and duplicate addresses are removed, in order. Each relay address becomes its own
entry in the ICE server list, all carrying the same username/credential, so one
blocked UDP port cannot take the working TCP/TLS addresses down with it.

Without a relay a call connects on the same Wi-Fi and on many home routers, and
fails on mobile data; the caller's screen says exactly that rather than blaming
the network in general. A configured relay is still offered
(`iceServers` in `lib/features/calls/domain/call_media.dart`), but the policy
stays `all`. Forcing `relay` left a computer with no pasted relay and a phone
with no other path, so the call rang and never connected. A wrong password
fails the relay path; same Wi-Fi can still connect.

The credential is a per-server secret, not a Supabase key, but it still belongs
in the gitignored env file (`assets/config/env`) or in `--dart-define`, never in
the repository.

## Setting up a hosted TURN relay

Any hosted provider works, because the app only needs a list of addresses and one
credential pair. With [Metered](https://dashboard.metered.ca/v2/turn/dashboard)
as the example:

1. Log in at [dashboard.metered.ca](https://dashboard.metered.ca/) and open
   **TURN Server & SFU → Credentials**. If it asks for a plan, pick **Free**
   (no card). Then **Create Credential**. The label and region are optional;
   the region decides which relay host serves you.
2. On the new credential, **Get credential → Show ICE Servers Array**. It shows
   four or five entries and one username/password. A brand-new credential can
   take up to two minutes to propagate — a call placed immediately may gather no
   relay candidate even though the values are right.
3. Put the addresses into `TURN_URL`, **on one line, comma-separated**, with the
   credential pair under it:

```ini
TURN_URL=turn:global.relay.metered.ca:80,turn:global.relay.metered.ca:80?transport=tcp,turn:global.relay.metered.ca:443,turns:global.relay.metered.ca:443?transport=tcp
TURN_USERNAME=the-credential-username
TURN_CREDENTIAL=the-credential-password
```

   Pasting the dashboard's JSON array instead is also accepted, but it must stay
   on one line: the env file is line-based.

4. `dart run tool/check_config.dart` — a correct paste reports `relay: 4
   addresses`. It fails when `TURN_URL` holds no usable address, when the
   username or credential is missing (a hosted relay rejects anonymous
   allocations and the call would then quietly fall back to STUN), and when
   the list has no TCP or TLS address. A UDP-only relay is refused at build
   time: on mobile data it fails exactly like no relay, with the screen
   saying a relay is configured.
5. Rebuild and install that APK on **both** phones. Configuration is bundled
   into the build, so a hot restart will not pick up an edit, and a phone still
   running the previous APK will not exchange the relay address.
6. Call between the two phones on different networks — one on mobile data. The
   "no relay configured" warning is gone, and `call_media_ready` reports
   `turn: true` and `policy: relay`.

Rotating the credential later is a dashboard action plus an env edit: nothing in
the database, the migrations or the RLS policies knows about TURN.

The relay credential is not a Supabase key and carries no data access of its own,
but it is billed per gigabyte, so it stays in the gitignored `.env` /
`assets/config/env` like any other secret.

## What the SDK must provide

| Requirement | Why | Where it bites |
| --- | --- | --- |
| Flutter **≥ 3.29** | `TextureRegistry.SurfaceProducer.Callback.onSurfaceCleanup()` — older engines declare an abstract `onSurfaceDestroyed()` the plugin does not implement | `:flutter_webrtc:compileDebugJavaWithJavac` fails |
| Flutter **≥ 3.35** (or an explicit `compileSdk = 36`) | The plugin compiles against Android SDK 36; 3.32 defaults to 35 | "requires Android SDK version 36 or higher" |
| A generated `android/` **matching the installed SDK** | `flutter upgrade` never rewrites an existing `android/`, so its Gradle wrapper stays behind. Flutter 3.47 requires Gradle ≥ 8.14 and scaffolds 9.3.1/AGP 9.1.0 | "Your project's Gradle version (8.3.0) is lower than Flutter's minimum supported version of 8.14.0" |
| **JDK 17+** | Flutter 3.47's Gradle plugin refuses older JVMs | Java version error before any of the above |

`pubspec.yaml` declares `flutter: ">=3.35.0"` for exactly this reason — the
plugin's own constraint (`>=1.22.0`) does not, so `pub get` would otherwise
succeed on an SDK that cannot build it. `tool/fix_android_build.dart` checks the
SDK, compares `android/` against a throwaway scaffold of the installed SDK,
pins `compileSdk`, and re-applies the platform patches; CI runs the same script,
so a local build and a green run match. A stale `android/` is answered with
`--reset --yes` rather than a hand-edited version number — see
[running.md](running.md) § "The build stops with Gradle version". 

## Android permissions

`android/` is not committed — CI runs `flutter create` — so the manifest cannot
carry the permissions. `tool/enable_call_permissions.dart` adds them after
scaffolding, exactly like `tool/enable_deep_links.dart` does for the intent
filter: `CAMERA`, `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`,
`ACCESS_NETWORK_STATE`, `BLUETOOTH_CONNECT`, and camera/microphone features
marked `required="false"` so a tablet without a camera can still install the app
and take voice calls. The runtime prompt is raised by `getUserMedia`.

## When a call kills the app

Media runs in native code (camera, WebRTC, video textures), so a failure there
ends the process instead of raising a Dart exception: the console stops with
`Lost connection to device.` and there is nothing to read in it.

`CallMedia.initialise()` therefore logs each step **before** running it:

```text
INFO call_media_step {step: renderers_begin, video: true}
INFO call_media_step {step: renderers_ready, video: true}
INFO call_media_step {step: getUserMedia_begin, video: true}
INFO call_media_step {step: getUserMedia_ready, video: true}
INFO call_media_step {step: peer_connection_begin, video: true}
INFO call_media_step {step: tracks_added, video: true}
INFO call_media_ready {video: true, iceServers: 5, turn: true}
```

The last line before the process ends names the failing step, and
[running.md](running.md) § "The app closes (or restarts) when a call starts" maps
each step and crash type to a cause. Two behaviours are worth knowing:

* **A voice call never creates a video texture.** Only a video call initialises
  the renderers, and only then is `srcObject` assigned — a voice call that
  touched the renderer path would be taking a native trip it does not need.
* **A refused microphone or camera is a Dart exception**, caught by the call
  screen and shown as "could not start the call", never a silent ring.

### After a crash: the breadcrumb file

A native or out-of-memory kill produces no Dart error and no `logcat -b crash`
entry. So `call_media.dart` writes the step it is about to run to
`mailchat_call_trace.json` in the app cache **before** running it, and deletes
the file from `dispose()` when the call ends normally. The next launch reads it
once and logs:

```text
WARN previous_call_ended_without_cleanup {trace: step "peer_connection_begin" (voice call) at …}
```

A leftover trace therefore means exactly one thing: the previous process never
reached `dispose()`. `test/unit/call_trace_test.dart` pins the two properties
that make it meaningful — valid JSON survives, and a clean end leaves no file —
so a leftover file can keep being trusted as evidence.

## The call rings, the microphone works, but it never connects

This is the commonest "calls are broken" report, and it is almost never the call
code. A device log from one such attempt, in order:

```text
E/stun_port.cc: UDP send of 20 bytes to host stun.l.google.com:19302 failed with error 1
I/flutter: ERROR SocketException: Failed host lookup: 'xxxx.supabase.co' (errno = 7)
I/audio_device_buffer.cc: [REC : 10000msec, 48kHz] callbacks: 984, samples: 472320, level: 0
I/flutter: INFO realtime_reconnect {attempt: 2, after_seconds: 10}
```

Read it as three separate facts:

| Line | Meaning |
| --- | --- |
| `[REC : …] callbacks: 984` | the microphone **is** capturing. `getUserMedia` succeeded and the native audio device is running: the app is not stuck before the call. |
| `failed host lookup … errno = 7` | **DNS is dead** for this app. No request left the phone. |
| `UDP send … failed with error 1` | `EPERM` — the kernel refused the packet. This is not a STUN outage; `stun.l.google.com` is fine. |

DNS dead *and* UDP refused together means the app has no usable network at all,
while its native audio thread keeps running: the call has sound going nowhere and
no candidates to pair with. On Android that combination usually means the
system is withholding network from the app — **Data saver**, a per-app
"restrict background data" setting, a VPN, or a private-DNS setting that does not
resolve. The fix is in the phone, not in the code:

```text
Settings → Apps → MailChat → Mobile data → allow background data
Settings → Connections → Data usage → Data saver → off (or allow MailChat)
Settings → Connections → More connection settings → Private DNS → Automatic
```

**Then the relay question.** One line now answers it at the start of every call:

```text
INFO call_ice_config {stun: stun.l.google.com:19302, relay_count: 0, relay_hosts: [], relay_fallback: false, policy: all}
WARN call_no_relay {detail: no TURN relay configured: media can only flow when the two phones reach each other directly…}
```

`relay_count: 0` is the whole story of a call that works on the office Wi-Fi and
dies on mobile data: without a relay, media has to travel directly between the
two phones, and most mobile networks cannot do that. `relay_fallback: false`
with a non-zero count is the second half of the story — a UDP-only relay stops
working on a network that blocks UDP, which is why a hosted provider's
`turns:…:443?transport=tcp` entry matters more than its `turn:…:80` one. How to
set one up is below, in [Setting up a hosted TURN relay](#setting-up-a-hosted-turn-relay).

After **15 seconds** still connecting, the call screen names the gap instead of
showing "Connecting..." forever. The sentences live in `callConnectAdvice`
(`lib/features/calls/domain/ice_path.dart`) and are pinned by
`test/unit/ice_path_test.dart`:

* no relay configured;
* the other phone has not accepted (or this phone cannot reach the server);
* this phone's relay has no TCP address;
* the relay refused this phone, and only after gathering finished with no
  relay address and no direct address (wrong username/password, or a
  credential that is less than two minutes old). A rejected call
  description is a different sentence — it is not a wrong password;
* this phone reached the relay and nothing arrived from the other phone;
* this phone reached the relay and the other phone did not;
* both reached the relay and audio is still blocked (Data saver or a VPN).

The old single sentence — "the relay has not taken over, the network is
blocking the call" — is gone. It sent people into phone settings when the
missing piece was a dropped answer or a relay that never allocated an address.

The same facts are logged once, as `call_connect_slow` with `waited_seconds`,
`has_relay`, `has_tcp_fallback`, `answer_applied` and the candidate counts
(`relay`, `remote_relay`, no IP addresses), so a bug report carries the answer
rather than the symptom.

A configured relay is offered, and the policy stays `all` so a computer on
the same network can connect even when that browser has no relay of its own.
Candidates gathered before the call id exists are
buffered, candidates that arrive before the answer are held until
`setRemoteDescription`, and the offer/answer wait up to 8 seconds so the SDP
itself contains the relay address. The call row and `call_ice_candidates` are
also polled every 2 seconds: a missed realtime event used to drop the answer
and the call never connected.

## Testing from a computer and a phone

The Flutter app cannot run in a browser (`dart:io`). The browser half of the
same system is `webapp/index.html`, described in [web.md](web.md). Sign in
there with the same Supabase project as the phone. A direct call on that page
writes the same `calls` row the phone rings for.

`tool/call_test/index.html` is only a network probe. It does not use MailChat
accounts. Do not use a sandbox preview host for either page: that name is not
in Cloudflare DNS, so the browser reports that the host was not found.

## What still needs doing

| Item | Why it is not done here |
| --- | --- |
| **A TURN server** | Configuration, not code: paste the provider's list into `TURN_URL` (§ *Setting up a hosted TURN relay*). Without one, calls work on a local network and may fail on mobile data |
| **Two devices** | The only way to prove media; CI can compile WebRTC but cannot hear it |
| **Push for a call** | A call only rings while the app is open. Waking a backgrounded phone needs FCM — see [notifications.md](notifications.md) |
| **Ringtone, vibration, wake lock** | Without them a ringing phone may be silent and asleep |
| **Missed-call timeout** | A ring nobody answers stays `ringing` until one side acts. A `pg_cron` sweep (or a check on app start) would close it |
| **iOS** | `Info.plist` needs `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`; this repository builds Android only |

## What is verified, and what is not

| Verified | Not verified |
| --- | --- |
| The transition rules, SDP ownership, duration maths, ICE-server assembly, relay-URL parsing and the media-stage wording, by unit tests | That a call connects between two real phones |
| That the app analyzes clean and a debug APK builds **with the WebRTC dependency and the permissions patched in** | Audio quality, echo, camera switching, bluetooth routing |
| That the migration is re-runnable and present in `apply_all.sql` | That Realtime delivers a `calls` insert to a sleeping-but-foregrounded app |
| `supabase/verify.sql` row 11: both tables exist with RLS | Anything about NAT traversal, which is exactly what TURN exists to fix |

The first device test to run is the one in the [testing](testing.md) checklist:
both phones on the same Wi-Fi, one call, accept, hear each other. If that works
and mobile data does not, the answer is a TURN server, not more code.
