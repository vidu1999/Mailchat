# Voice & video calling — current status

**Status: UI only. No calls can be placed, received or carried in this build.**

This document exists so the call feature is not mistaken for something that
works, and so the remaining work is unambiguous.

## What is implemented

| Piece | File | Status |
|---|---|---|
| Incoming call screen (accept / decline) | `lib/features/calls/presentation/screens/incoming_call_screen.dart` | UI only |
| Active call screen (timer, mute, camera, speaker, end call) | `lib/features/calls/presentation/screens/active_call_screen.dart` | UI only, timer is local |
| Call state + signalling message types | `lib/features/calls/domain/call_model.dart` | Types defined |
| `CallService.placeCall` / `endCall` | `lib/features/calls/domain/call_service.dart` | Throws `UnsupportedError` |

The chat screen's call buttons open an explanatory dialog rather than the call
screens, so a user can never believe a call connected.

## What is missing (the actual feature)

1. **Media transport.** WebRTC is not included. `flutter_webrtc` (or an
   equivalent maintained package) must be added; this repository currently has
   no third-party dependencies at all.
2. **Signalling.** Call offers, answers, ICE candidates and hang-up events need
   a transport. Options:
   - Supabase Realtime broadcast channels (lowest infrastructure cost), or
   - a `calls` + `call_signals` table with RLS and Realtime enabled, or
   - an Edge Function that owns call state.
3. **STUN/TURN.** NAT traversal needs at least a STUN server; reliable calling
   behind symmetric NAT requires a TURN server with credentials. TURN
   credentials must be issued per-session from a server function — never
   embedded in the app.
4. **Permissions.** `RECORD_AUDIO` and `CAMERA` on Android,
   `NSMicrophoneUsageDescription` and `NSCameraUsageDescription` on iOS, plus
   runtime permission prompts and denial handling.
5. **Call records.** A `calls` table (caller, callee, conversation, type,
   state, started_at, ended_at, duration_seconds) for history and missed-call
   badges, with RLS scoping rows to participants.
6. **Foreground/background behaviour.** Android foreground service for ongoing
   calls; CallKit (iOS) / ConnectionService (Android) integration so calls ring
   while the app is backgrounded.
7. **Abuse controls.** Blocking must prevent calls between blocked users, and
   rate-limiting repeated call attempts is required.
8. **Tests.** Signalling state-machine unit tests plus at least one two-client
   integration test on real devices.

## Security notes

- Do not attempt end-to-end encryption claims. WebRTC media is encrypted in
  transit (DTLS-SRTP) between peers, but the signalling server sees call
  metadata. The app must not describe this as E2EE without a reviewed design.
- Never ship TURN credentials in the binary. Issue short-lived credentials.
- Emit audit events for call start/end through `AppLogger` (no media content,
  no participant names in production logs).

## Estimated work

This is a milestone of its own — roughly a 2–4 week effort including the
signalling layer, both platform integrations, TURN provisioning and device
testing. It should not ship as a partial "it opens a screen" feature.
