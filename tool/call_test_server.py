#!/usr/bin/env python3
"""Call test for a computer and a phone.

Serves one web page and a tiny room relay. Open the page on both devices, allow
the microphone, and talk. Audio goes directly between the two browsers. This
process only forwards the connection details (SDP and ICE). It does not record
audio, and it does not write the relay password to disk.

    python3 tool/call_test_server.py
    python3 tool/call_test_server.py --check

The phone must open an https:// address. A plain http:// link that is not
localhost cannot use the microphone, so a page served from a computer's LAN
address will fail on the phone. The hosted preview is https and works on both.
"""

from __future__ import annotations

import argparse
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PAGE = Path(__file__).resolve().parent / "call_test" / "index.html"
ROOM_TTL_SECONDS = 30 * 60
MAX_CANDIDATES = 80
MAX_BODY = 100_000

_lock = threading.Lock()
_rooms: dict[str, dict] = {}


def _now() -> float:
    return time.time()


def _purge() -> None:
    cutoff = _now() - ROOM_TTL_SECONDS
    dead = [code for code, room in _rooms.items() if room["touched"] < cutoff]
    for code in dead:
        del _rooms[code]


def _touch(room: dict) -> None:
    room["touched"] = _now()


def _public_ice(room: dict) -> dict:
    """What the joiner needs. The password is in memory for this test only."""
    return {
        "iceServers": room["iceServers"],
        "forceRelay": room["forceRelay"],
    }


def create_room(ice_servers: list, force_relay: bool) -> str:
    with _lock:
        _purge()
        if len(_rooms) > 200:
            raise RuntimeError("too many tests in progress")
        for _ in range(20):
            code = f"{secrets.randbelow(9000) + 1000}"
            if code not in _rooms:
                break
        else:
            raise RuntimeError("could not allocate a room code")
        _rooms[code] = {
            "created": _now(),
            "touched": _now(),
            "iceServers": ice_servers,
            "forceRelay": force_relay,
            "offer": None,
            "answer": None,
            "callerCandidates": [],
            "calleeCandidates": [],
            "caller": False,
            "callee": False,
            "callerBye": False,
            "calleeBye": False,
            "callerPath": {},
            "calleePath": {},
        }
        _rooms[code]["caller"] = True
        return code


def get_room(code: str) -> dict | None:
    if not code.isdigit() or len(code) != 4:
        return None
    with _lock:
        _purge()
        room = _rooms.get(code)
        if room is None:
            return None
        _touch(room)
        return room


def join_room(code: str) -> dict | None:
    room = get_room(code)
    if room is None:
        return None
    with _lock:
        if room["callee"]:
            return {"error": "taken"}
        room["callee"] = True
        _touch(room)
        return {"ok": True, **_public_ice(room), "offer": room["offer"]}


def _side_key(role: str, kind: str) -> str:
    if role not in ("caller", "callee"):
        raise ValueError("role")
    return f"{role}{kind}"


def post_sdp(code: str, role: str, sdp: str) -> bool:
    room = get_room(code)
    if room is None or not sdp:
        return False
    field = "offer" if role == "caller" else "answer"
    with _lock:
        room[field] = sdp
        _touch(room)
    return True


def post_candidates(code: str, role: str, items: list) -> bool:
    room = get_room(code)
    if room is None:
        return False
    key = "callerCandidates" if role == "caller" else "calleeCandidates"
    with _lock:
        bucket = room[key]
        for item in items:
            if not isinstance(item, dict):
                continue
            candidate = item.get("candidate")
            if not isinstance(candidate, str) or not candidate:
                continue
            if len(bucket) >= MAX_CANDIDATES:
                break
            bucket.append(
                {
                    "candidate": candidate[:2000],
                    "sdpMid": item.get("sdpMid") if isinstance(item.get("sdpMid"), str) else None,
                    "sdpMLineIndex": item.get("sdpMLineIndex")
                    if isinstance(item.get("sdpMLineIndex"), int)
                    else None,
                }
            )
        _touch(room)
    return True


def post_path(code: str, role: str, path: dict) -> bool:
    room = get_room(code)
    if room is None:
        return False
    key = "callerPath" if role == "caller" else "calleePath"
    clean = {}
    for name in ("host", "srflx", "relay", "gathering"):
        value = path.get(name)
        if isinstance(value, bool) or isinstance(value, int):
            clean[name] = value
    with _lock:
        room[key] = clean
        _touch(room)
    return True


def post_bye(code: str, role: str) -> bool:
    room = get_room(code)
    if room is None:
        return False
    key = "callerBye" if role == "caller" else "calleeBye"
    with _lock:
        room[key] = True
        _touch(room)
    return True


def sync_room(code: str, role: str, after: int) -> dict | None:
    room = get_room(code)
    if room is None:
        return None
    other = "calleeCandidates" if role == "caller" else "callerCandidates"
    other_bye = "calleeBye" if role == "caller" else "callerBye"
    other_path = "calleePath" if role == "caller" else "callerPath"
    with _lock:
        cands = room[other]
        start = after if 0 <= after <= len(cands) else 0
        return {
            "offer": room["offer"],
            "answer": room["answer"],
            "candidates": cands[start:],
            "candidateCount": len(cands),
            "peerJoined": room["callee"] if role == "caller" else room["caller"],
            "peerBye": room[other_bye],
            "peerPath": room[other_path],
            **_public_ice(room),
        }


def normalise_ice(body: dict) -> tuple[list, bool]:
    """Builds the iceServers list the browsers will share.

    A blank relay is allowed: the test then only works when the two devices can
    reach each other directly. A half-filled relay is refused, because a missing
    password looks exactly like a network failure.
    """
    urls_raw = body.get("urls") or ""
    username = (body.get("username") or "").strip()
    credential = (body.get("credential") or "").strip()
    force = bool(body.get("forceRelay"))
    urls = []
    seen = set()
    if isinstance(urls_raw, str):
        chunks = urls_raw.replace(";", ",").replace("\n", ",").split(",")
    elif isinstance(urls_raw, list):
        chunks = urls_raw
    else:
        chunks = []
    for chunk in chunks:
        url = _normalise_url(str(chunk))
        if url and url not in seen:
            seen.add(url)
            urls.append(url)
    if urls and (not username or not credential):
        raise ValueError("Relay username and password are both required.")
    if (username or credential) and not urls:
        raise ValueError(
            "Relay address is missing. Paste the line that starts with turns:."
        )
    if force and not urls:
        raise ValueError("Turn off \"Use only the relay\", or paste a relay address.")
    servers = [{"urls": "stun:stun.l.google.com:19302"}]
    for url in urls:
        servers.append(
            {"urls": url, "username": username, "credential": credential}
        )
    return servers, force and bool(urls)


def _normalise_url(raw: str) -> str | None:
    value = raw.strip().strip("\"'")
    if not value:
        return None
    lower = value.lower()
    if lower.startswith("stun:"):
        return None
    if lower.startswith("turns:"):
        rest = value[6:]
        scheme = "turns"
    elif lower.startswith("turn:"):
        rest = value[5:]
        scheme = "turn"
    elif lower.startswith("https:"):
        rest = value[6:]
        scheme = "turns"
    elif lower.startswith("http:"):
        rest = value[5:]
        scheme = "turn"
    else:
        return None
    host = rest.lstrip("/")
    if not host:
        return None
    return f"{scheme}:{host}"


class Handler(BaseHTTPRequestHandler):
    server_version = "MailChatCallTest/1.0"

    def log_message(self, fmt: str, *args) -> None:
        # Default logging prints the request target. Room traffic is enough;
        # never print a body, because the body can hold the relay password.
        return

    def _send(self, status: int, payload: dict | None = None, body: bytes | None = None, content_type: str = "application/json") -> None:
        data = body if body is not None else json.dumps(payload or {}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        # The preview may embed this page. Do not send a frame-blocking header.
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        if length < 0 or length > MAX_BODY:
            raise ValueError("body too large")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        parsed = json.loads(raw.decode("utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError("expected an object")
        return parsed

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ("/", "/index.html"):
            if not PAGE.is_file():
                self._send(500, {"error": "call test page is missing"})
                return
            data = PAGE.read_bytes()
            self._send(200, body=data, content_type="text/html; charset=utf-8")
            return
        if path == "/favicon.ico":
            self._send(204, body=b"", content_type="image/x-icon")
            return
        if path == "/api/health":
            self._send(200, {"ok": True})
            return
        if path.startswith("/api/rooms/") and path.endswith("/sync"):
            parts = path.strip("/").split("/")
            # api / rooms / CODE / sync
            if len(parts) != 4:
                self._send(404, {"error": "not found"})
                return
            code = parts[2]
            query = parse_qs(parsed.query)
            role = (query.get("role") or ["caller"])[0]
            try:
                after = int((query.get("after") or ["0"])[0])
            except ValueError:
                after = 0
            if role not in ("caller", "callee"):
                self._send(400, {"error": "role must be caller or callee"})
                return
            state = sync_room(code, role, after)
            if state is None:
                self._send(404, {"error": "That test code has expired. Start again."})
                return
            self._send(200, state)
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        try:
            body = self._read_json()
        except (ValueError, json.JSONDecodeError):
            self._send(400, {"error": "Could not read that request."})
            return
        if path == "/api/rooms":
            try:
                servers, force = normalise_ice(body)
            except ValueError as exc:
                self._send(400, {"error": str(exc)})
                return
            try:
                code = create_room(servers, force)
            except RuntimeError as exc:
                self._send(503, {"error": str(exc)})
                return
            room = get_room(code)
            self._send(200, {"code": code, "role": "caller", **_public_ice(room)})
            return
        parts = path.strip("/").split("/")
        # api / rooms / CODE / action
        if len(parts) != 4 or parts[0] != "api" or parts[1] != "rooms":
            self._send(404, {"error": "not found"})
            return
        code, action = parts[2], parts[3]
        if action == "join":
            joined = join_room(code)
            if joined is None:
                self._send(404, {"error": "That test code has expired. Start again."})
                return
            if joined.get("error") == "taken":
                self._send(409, {"error": "Someone already joined that code. Start a new test."})
                return
            self._send(200, {"role": "callee", **joined})
            return
        role = body.get("role")
        if role not in ("caller", "callee"):
            self._send(400, {"error": "role must be caller or callee"})
            return
        if action == "sdp":
            sdp = body.get("sdp")
            kind = body.get("kind")
            expected = "caller" if kind == "offer" else "callee" if kind == "answer" else None
            if expected != role or not isinstance(sdp, str):
                self._send(400, {"error": "bad sdp"})
                return
            if not post_sdp(code, role, sdp):
                self._send(404, {"error": "That test code has expired. Start again."})
                return
            self._send(200, {"ok": True})
            return
        if action == "candidates":
            items = body.get("items")
            if not isinstance(items, list):
                self._send(400, {"error": "bad candidates"})
                return
            if not post_candidates(code, role, items):
                self._send(404, {"error": "That test code has expired. Start again."})
                return
            self._send(200, {"ok": True})
            return
        if action == "path":
            if not post_path(code, role, body):
                self._send(404, {"error": "That test code has expired. Start again."})
                return
            self._send(200, {"ok": True})
            return
        if action == "bye":
            if not post_bye(code, role):
                self._send(404, {"error": "That test code has expired. Start again."})
                return
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "not found"})


def serve(host: str, port: int) -> None:
    if not PAGE.is_file():
        raise SystemExit(f"missing page: {PAGE}")
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"Call test on http://{host}:{port}", flush=True)
    print("Open that page on the computer and on the phone.", flush=True)
    httpd.serve_forever()


def self_check() -> None:
    """Proves the room relay without a browser. Audio is not involved."""
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    import urllib.error
    import urllib.request

    def call(method: str, path: str, payload: dict | None = None) -> tuple[int, dict]:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json"} if data else {},
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = resp.read()
                return resp.status, json.loads(raw.decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return exc.code, json.loads(raw.decode("utf-8") or "{}")

    try:
        status, health = call("GET", "/api/health")
        assert status == 200 and health["ok"], health
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5) as resp:
            html = resp.read().decode("utf-8")
        assert resp.status == 200 and "Call test" in html, "page missing"

        status, bad = call("POST", "/api/rooms", {"username": "u"})
        assert status == 400 and "turns" in bad["error"], bad

        status, created = call(
            "POST",
            "/api/rooms",
            {
                "urls": "turns:relay.example.test:443?transport=tcp, stun:stun.example.test:80",
                "username": "user",
                "credential": "secret",
                "forceRelay": True,
            },
        )
        assert status == 200, created
        code = created["code"]
        assert created["forceRelay"] is True
        assert all(s.get("username") != "user" or "secret" == s.get("credential") for s in created["iceServers"])
        assert not any(str(s.get("urls", "")).startswith("stun:stun.example") for s in created["iceServers"])

        status, offer = call(
            "POST",
            f"/api/rooms/{code}/sdp",
            {"role": "caller", "kind": "offer", "sdp": "v=0\r\noffer"},
        )
        assert status == 200, offer
        status, joined = call("POST", f"/api/rooms/{code}/join", {})
        assert status == 200 and joined["offer"] == "v=0\r\noffer", joined
        status, taken = call("POST", f"/api/rooms/{code}/join", {})
        assert status == 409, taken

        status, cand = call(
            "POST",
            f"/api/rooms/{code}/candidates",
            {
                "role": "callee",
                "items": [{"candidate": "candidate:1 1 udp 1 1.2.3.4 9 typ relay", "sdpMid": "0", "sdpMLineIndex": 0}],
            },
        )
        assert status == 200, cand
        status, sync = call("GET", f"/api/rooms/{code}/sync?role=caller&after=0")
        assert status == 200, sync
        assert sync["peerJoined"] is True
        assert sync["candidates"][0]["candidate"].endswith("typ relay")
        status, again = call("GET", f"/api/rooms/{code}/sync?role=caller&after=1")
        assert again["candidates"] == [], again

        status, missing = call("GET", "/api/rooms/0000/sync?role=caller&after=0")
        assert status == 404, missing
        print("call test relay ok")
    finally:
        httpd.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser(description="MailChat call test (computer and phone)")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--check", action="store_true", help="run the relay self-check and exit")
    args = parser.parse_args()
    if args.check:
        self_check()
        return
    serve(args.host, args.port)


if __name__ == "__main__":
    main()
