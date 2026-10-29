# Browser client

**Status:** 🧪 built. Published by `.github/workflows/web-client.yml` to the repository Pages site. Not exercised against a live Supabase project from this environment. It is not a Flutter web build.

The phone app cannot run in a browser. It is written on `dart:io` (`HttpClient`, `WebSocket`, `File`), and that library does not exist on the web. `flutter run -d chrome` still fails, and that is not the path.

`webapp/index.html` is a separate browser client for the **same** Supabase project. A person signed in here and a person signed in on the phone are in one system:

| | Phone app | This page |
| --- | --- | --- |
| Account | GoTrue email and password | The same GoTrue project |
| Chats | `messages`, `conversation_list` | The same tables |
| Groups, reactions, receipts, files | The phone screens | The same tables and the `attachments` bucket |
| Updates / status | Text/photo updates expire after 24 hours | Same `user_statuses`, `user_status_views` and private `status-media` bucket; migration 0012 must be applied |
| Calls | `calls` + `call_ice_candidates` + `flutter_webrtc` | The same rows, with the browser’s `RTCPeerConnection` |

A call placed here inserts the same `calls` row the phone already listens for, with `offer_sdp` set before the row exists. The phone’s answer is written to `answer_sdp`. ICE candidates go to `call_ice_candidates`. The page does not say Connected unless the peer connection reports connected.

## What you paste once

The page asks for `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Those are the same two lines as the phone’s env file. They stay in the browser’s local storage. The `service_role` key is rejected. A TURN username and password, if you paste them, stay in the browser too and are not written to the repository.

## What this is not

- Not the Flutter app, and not a claim that `flutter run -d chrome` works.
- Not end-to-end encryption.
- Not push notifications. The phone still needs the app installed to ring when the browser is closed. While this page is open, an incoming call is shown here. A ringing row older than 45 seconds is not shown, and is marked missed, so a leftover call cannot appear by itself.
- Not verified against a live project from the build environment. Hearing each other still requires two signed-in devices.

Group calls are not offered. The `calls` table is one caller and one callee, same as the phone.
