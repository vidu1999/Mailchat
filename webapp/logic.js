/* Pure helpers for the MailChat browser client. No DOM. Shared with the
   phone app's rules: username shape, receipt ticks, TURN URL parsing, and
   the auth-link fragment Supabase sends after email confirmation. */
(function (root) {
  'use strict';

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch];
    });
  }

  function jwtPayload(token) {
    var parts = String(token || '').split('.');
    if (parts.length < 2) return null;
    try {
      var pad = parts[1].replace(/-/g, '+').replace(/_/g, '/');
      while (pad.length % 4) pad += '=';
      var json = atob(pad);
      return JSON.parse(json);
    } catch (err) {
      return null;
    }
  }

  function jwtRole(token) {
    var payload = jwtPayload(token);
    return payload && payload.role ? String(payload.role) : '';
  }

  function usernameError(value) {
    var name = String(value || '').trim();
    if (!name) return 'Username is required';
    if (name.length < 3) return 'Username must be at least 3 characters';
    if (name.length > 30) return 'Username must be at most 30 characters';
    if (!/^[a-z0-9][a-z0-9_.]{2,29}$/.test(name)) {
      return 'Use lowercase letters, numbers, underscores or dots, and start with a letter or number';
    }
    return '';
  }

  function passwordError(value) {
    var password = String(value || '');
    if (!password) return 'Password is required';
    if (password.length < 8) return 'Password must be at least 8 characters';
    if (!/[A-Z]/.test(password)) return 'Password must contain an uppercase letter';
    if (!/[a-z]/.test(password)) return 'Password must contain a lowercase letter';
    if (!/[0-9]/.test(password)) return 'Password must contain a number';
    return '';
  }

  function parseTurnUrls(raw) {
    var out = [];
    String(raw || '').split(/[,;\n]/).forEach(function (chunk) {
      var url = chunk.trim().replace(/^[\s"'[\]]+|[\s"'[\]]+$/g, '');
      if (!url) return;
      var lower = url.toLowerCase();
      if (lower.startsWith('stun:')) return;
      if (lower.startsWith('https://')) url = 'turns:' + url.slice(8).replace(/^\/+/, '');
      else if (lower.startsWith('http://')) url = 'turn:' + url.slice(7).replace(/^\/+/, '');
      else if (lower.indexOf('turn:') !== 0 && lower.indexOf('turns:') !== 0) return;
      out.push(url);
    });
    return out;
  }

  // Published Open Relay pair. Same list as lib/core/config/public_relay.dart.
  // Two people on different networks need this when neither side pasted a relay.
  var PUBLIC_RELAY = [
    'turn:openrelay.metered.ca:80',
    'turn:openrelay.metered.ca:443',
    'turn:openrelay.metered.ca:443?transport=tcp'
  ];

  function buildIceServers(stunUrl, turnRaw, username, credential) {
    var servers = [{ urls: stunUrl || 'stun:stun.l.google.com:19302' }];
    var seen = {};
    seen[servers[0].urls] = true;
    var relays = parseTurnUrls(turnRaw);
    relays.forEach(function (url) {
      if (seen[url]) return;
      seen[url] = true;
      var entry = { urls: url };
      if (username) {
        entry.username = username;
        entry.credential = credential || '';
      }
      servers.push(entry);
    });
    PUBLIC_RELAY.forEach(function (url) {
      if (seen[url]) return;
      seen[url] = true;
      servers.push({
        urls: url,
        username: 'openrelayproject',
        credential: 'openrelayproject'
      });
    });
    // forceRelay means a relay is in the list. It is not a transport policy.
    return { iceServers: servers, forceRelay: servers.length > 1, relays: relays, publicRelay: true };
  }

  function parseAuthLink(href) {
    var url;
    try {
      url = new URL(href, 'https://mailchat.local');
    } catch (err) {
      return null;
    }
    var query = url.searchParams;
    var hash = new URLSearchParams(String(url.hash || '').replace(/^#/, ''));
    function pick(key) {
      return hash.get(key) || query.get(key) || '';
    }
    var access = pick('access_token');
    var refresh = pick('refresh_token');
    var tokenHash = pick('token_hash');
    var type = pick('type');
    var error = pick('error_description') || pick('error') || pick('error_code');
    if (!access && !tokenHash && error) {
      return { kind: 'error', error: error };
    }
    if (access) {
      return {
        kind: type === 'recovery' ? 'recovery' : 'session',
        access: access,
        refresh: refresh,
        type: type,
      };
    }
    if (tokenHash) {
      return { kind: 'token', tokenHash: tokenHash, type: type || 'signup' };
    }
    return null;
  }

  function receiptStatus(rows) {
    if (!rows || !rows.length) return 'sent';
    var delivered = false;
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      if (!row) continue;
      if (row.read_at) return 'read';
      if (row.delivered_at) delivered = true;
    }
    return delivered ? 'delivered' : 'sent';
  }

  function tick(status) {
    if (status === 'read') return '✓✓';
    if (status === 'delivered') return '✓✓';
    return '✓';
  }

  function rpcMissing(message) {
    var text = String(message || '');
    return text.indexOf('PGRST202') !== -1 ||
      text.indexOf('Could not find the function') !== -1 ||
      text.indexOf('schema cache') !== -1;
  }

  function friendlyError(data, fallback, status) {
    var msg = '';
    if (data && typeof data === 'object') {
      msg = data.message || data.msg || data.error_description || data.error || data.hint || '';
    } else if (typeof data === 'string') {
      msg = data;
    }
    msg = String(msg || fallback || '');
    var low = msg.toLowerCase();
    if (low.indexOf('invalid login') !== -1 || low.indexOf('invalid_credentials') !== -1) {
      return 'Email or password is wrong.';
    }
    if (low.indexOf('email not confirmed') !== -1) {
      return 'Confirm your email first. Open the newest MailChat email, then sign in.';
    }
    if (low.indexOf('user already registered') !== -1 || low.indexOf('already been registered') !== -1) {
      return 'That email is already registered. Sign in instead.';
    }
    if (low.indexOf('does not exist') !== -1 && (low.indexOf('relation') !== -1 || low.indexOf('function') !== -1)) {
      return 'The database is missing MailChat tables. In Supabase, open SQL Editor and paste the whole of supabase/apply_all.sql once.';
    }
    if (low.indexOf('redirect') !== -1 && low.indexOf('not allowed') !== -1) {
      return 'Supabase blocked the return address. Add this page’s address under Authentication → URL Configuration → Redirect URLs, then try again.';
    }
    if (status === 401) return 'Sign in again.';
    if (low.indexOf('calls') !== -1 && (low.indexOf('row-level') !== -1 || low.indexOf('42501') !== -1)) {
      return 'The server refused to save this call. In Supabase, open SQL Editor, paste supabase/migrations/0010_call_write.sql, run it, then call again.';
    }
    if (status === 403 || low.indexOf('42501') !== -1 || low.indexOf('permission denied') !== -1 || low.indexOf('row-level') !== -1) {
      return 'The server refused that. You may not be allowed to do it.';
    }
    if (!msg) return 'Something went wrong' + (status ? ' (' + status + ').' : '.');
    return msg.length > 280 ? msg.slice(0, 280) + '…' : msg;
  }

  function formatWhen(iso) {
    if (!iso) return '';
    var date = new Date(iso);
    if (isNaN(date.getTime())) return '';
    var now = new Date();
    var sameDay = date.toDateString() === now.toDateString();
    var time = date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    if (sameDay) return time;
    var yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    if (date.toDateString() === yesterday.toDateString()) return 'Yesterday ' + time;
    return date.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + time;
  }

  function dayLabel(iso) {
    var date = new Date(iso);
    if (isNaN(date.getTime())) return '';
    var now = new Date();
    if (date.toDateString() === now.toDateString()) return 'Today';
    var yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    if (date.toDateString() === yesterday.toDateString()) return 'Yesterday';
    return date.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
  }

  function sanitiseFileName(name) {
    var base = String(name || 'file').split(/[\\/]/).pop();
    base = base.replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^\.+/, '');
    if (!base) base = 'file';
    return base.slice(0, 80);
  }

  var RING_WINDOW_MS = 45000;
  var OUTGOING_CLEAR_MS = 180000;

  function ringIsFresh(createdAt, nowMs) {
    var created = Date.parse(createdAt || '');
    if (isNaN(created)) return false;
    var age = (nowMs == null ? Date.now() : nowMs) - created;
    if (age < 0) return age > -120000;
    return age <= RING_WINDOW_MS;
  }

  function ringShouldClear(createdAt, isCallee, nowMs) {
    if (ringIsFresh(createdAt, nowMs)) return false;
    var created = Date.parse(createdAt || '');
    if (isNaN(created)) return false;
    var age = (nowMs == null ? Date.now() : nowMs) - created;
    if (age < 0) return false;
    return isCallee ? age > RING_WINDOW_MS : age > OUTGOING_CLEAR_MS;
  }

  function sdpForPhone(sdp) {
    var text = String(sdp || '').replace(/\u0000/g, '').trim();
    if (text && text.indexOf('\n') < 0 && text.indexOf('\r') < 0 && text.indexOf('\\n') >= 0) {
      text = text.replace(/\\r\\n/g, '\n').replace(/\\n/g, '\n').replace(/\\r/g, '');
    }
    var start = text.indexOf('v=0');
    if (start < 0) return '';
    if (start > 0) text = text.slice(start);
    var lines = text.split(/\r\n|\n|\r/).filter(function (line) {
      var trimmed = line.replace(/\s+$/g, '');
      if (!trimmed) return false;
      if (trimmed.indexOf('a=extmap-allow-mixed') === 0) return false;
      if (trimmed === 'a=end-of-candidates') return false;
      return true;
    });
    if (!lines.length || lines[0].indexOf('v=0') !== 0) return '';
    return lines.join('\r\n') + '\r\n';
  }

  function pageAddress() {
    if (typeof location === 'undefined') return '';
    return location.origin + location.pathname;
  }

  root.MailChatLogic = {
    esc: esc,
    jwtRole: jwtRole,
    usernameError: usernameError,
    passwordError: passwordError,
    parseTurnUrls: parseTurnUrls,
    buildIceServers: buildIceServers,
    parseAuthLink: parseAuthLink,
    receiptStatus: receiptStatus,
    tick: tick,
    friendlyError: friendlyError,
    rpcMissing: rpcMissing,
    formatWhen: formatWhen,
    dayLabel: dayLabel,
    sanitiseFileName: sanitiseFileName,
    ringIsFresh: ringIsFresh,
    ringShouldClear: ringShouldClear,
    sdpForPhone: sdpForPhone,
    pageAddress: pageAddress,
  };
})(typeof globalThis !== 'undefined' ? globalThis : this);
