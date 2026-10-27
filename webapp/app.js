/* MailChat in the browser.
   Same Supabase project as the Flutter phone app: same accounts, chats,
   groups, attachments and call rows. A call from this page rings the phone,
   and a call from the phone rings this page. */
(function () {
  'use strict';
  if (typeof document === 'undefined') return;

  var L = MailChatLogic;
  var CONFIG_KEY = 'mailchat.web.config';
  var SESSION_KEY = 'mailchat.web.session';
  var PENDING_KEY = 'mailchat.web.pending';
  var TURN_PASS_KEY = 'mailchat.web.turnpass';

  var cfg = null;
  var session = null;
  var socket = null;
  var socketOpen = false;
  var ref = 0;
  var channels = {};
  var refreshFlight = null;
  var names = {};
  var seenIce = {};
  var dismissedCalls = {};
  var call = null;
  var callTimer = null;
  var inboxTimer = null;
  var presenceTimer = null;
  var typingTimer = null;
  var slowTimer = null;

  var state = {
    pane: 'list',
    authMode: 'login',
    chats: [],
    thread: null,
    profile: null,
    presence: {},
    reply: null,
    editing: null,
    openMessage: null,
    search: [],
    groupName: '',
    groupPick: {},
    blocked: [],
    shareLastSeen: true,
    error: '',
    notice: '',
    busy: false,
    recovery: false,
    booting: true,
  };

  function $(id) { return document.getElementById(id); }
  function me() { return session && session.user && session.user.id; }

  function loadConfig() {
    try { return JSON.parse(localStorage.getItem(CONFIG_KEY) || 'null'); }
    catch (err) { return null; }
  }
  function saveConfig(next) {
    cfg = next;
    localStorage.setItem(CONFIG_KEY, JSON.stringify(next));
  }
  function loadSession() {
    try { return JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null'); }
    catch (err) { return null; }
  }
  function saveSession(next) {
    session = next;
    if (next) sessionStorage.setItem(SESSION_KEY, JSON.stringify(next));
    else sessionStorage.removeItem(SESSION_KEY);
  }
  function loadTurnPass() {
    return sessionStorage.getItem(TURN_PASS_KEY) || '';
  }
  function saveTurnPass(value) {
    if (value) sessionStorage.setItem(TURN_PASS_KEY, value);
    else sessionStorage.removeItem(TURN_PASS_KEY);
  }

  function toast(text) {
    var box = $('toasts');
    if (!box) return;
    var el = document.createElement('div');
    el.className = 'toast';
    el.textContent = text;
    box.appendChild(el);
    setTimeout(function () { el.remove(); }, 4200);
  }

  function normaliseUrl(raw) {
    var url = String(raw || '').trim();
    while (url.endsWith('/')) url = url.slice(0, -1);
    if (url && url.indexOf('://') === -1) url = 'https://' + url;
    return url;
  }

  function configError(url, key) {
    if (!url || url.indexOf('your-project') !== -1) return 'Paste the project URL from the phone’s env file.';
    var parsed;
    try { parsed = new URL(url); } catch (err) { parsed = null; }
    if (!parsed || (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') || parsed.hostname.indexOf('.') === -1) {
      return 'That project URL does not look right. It should look like https://YOUR-PROJECT.supabase.co';
    }
    if (!key || key.indexOf('placeholder') !== -1 || key.split('.').length < 3) {
      return 'Paste the anon public key. In Supabase that is Project Settings → API → anon / public.';
    }
    if (L.jwtRole(key) === 'service_role') {
      return 'That is the service_role key. It must never be used here. Paste the anon public key.';
    }
    return '';
  }

  async function api(path, opts) {
    opts = opts || {};
    if (opts.auth !== false) await ensureFresh();
    var headers = {
      apikey: cfg.anonKey,
      Accept: 'application/json',
    };
    if (opts.auth !== false && session && session.access) {
      headers.Authorization = 'Bearer ' + session.access;
    }
    if (opts.prefer) headers.Prefer = opts.prefer;
    else if (opts.method && opts.method !== 'GET') headers.Prefer = 'return=representation';
    var body = opts.body;
    if (body != null && !(body instanceof ArrayBuffer) && !(body instanceof Uint8Array)) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(body);
    }
    if (opts.headers) {
      Object.keys(opts.headers).forEach(function (key) { headers[key] = opts.headers[key]; });
    }
    var res;
    try {
      res = await fetch(cfg.url + path, { method: opts.method || 'GET', headers: headers, body: body });
    } catch (err) {
      throw new Error('This browser cannot reach Supabase. Check the project URL and the connection.');
    }
    var text = await res.text();
    var data = null;
    if (text) {
      try { data = JSON.parse(text); } catch (err) { data = text; }
    }
    if (res.status === 401 && opts.auth !== false && !opts.retried && session && session.refresh) {
      if (await refreshSession()) return api(path, Object.assign({}, opts, { retried: true }));
      await signOutLocal();
      throw new Error('Your session ended. Sign in again.');
    }
    if (!res.ok) throw new Error(L.friendlyError(data, text, res.status));
    return data;
  }

  function rowsOf(data) {
    if (Array.isArray(data)) return data;
    if (data && typeof data === 'object') return [data];
    return [];
  }

  async function ensureFresh() {
    if (!session || !session.expiresAt) return;
    if (Date.now() < session.expiresAt - 60000) return;
    await refreshSession();
  }

  async function refreshSession() {
    if (!session || !session.refresh) return false;
    if (refreshFlight) return refreshFlight;
    refreshFlight = (async function () {
      try {
        var data = await api('/auth/v1/token?grant_type=refresh_token', {
          method: 'POST',
          auth: false,
          body: { refresh_token: session.refresh },
        });
        applyTokenResponse(data);
        return true;
      } catch (err) {
        return false;
      } finally {
        refreshFlight = null;
      }
    })();
    return refreshFlight;
  }

  function applyTokenResponse(data) {
    var access = data.access_token;
    var refresh = data.refresh_token || (session && session.refresh);
    var user = data.user || (session && session.user);
    if (!access) throw new Error('Supabase did not return a session.');
    saveSession({
      access: access,
      refresh: refresh,
      expiresAt: Date.now() + (Number(data.expires_in) || 3600) * 1000,
      user: user,
    });
  }

  async function signOutLocal() {
    saveSession(null);
    closeSocket();
    state.thread = null;
    state.chats = [];
    state.pane = 'list';
    hideCall();
    render();
  }

  async function signOut() {
    try {
      if (session) {
        await api('/auth/v1/logout?scope=local', {
          method: 'POST',
          body: session.refresh ? { refresh_token: session.refresh } : {},
        });
      }
    } catch (err) { /* local sign-out still happens */ }
    await signOutLocal();
  }

  function closeSocket() {
    socketOpen = false;
    if (socket) {
      socket.onclose = null;
      try { socket.close(); } catch (err) { /* already closed */ }
      socket = null;
    }
    channels = {};
  }

  function nextRef() { ref += 1; return String(ref); }

  function sendFrame(topic, event, payload) {
    if (!socket || socket.readyState !== 1) return;
    socket.send(JSON.stringify({ topic: topic, event: event, payload: payload || {}, ref: nextRef() }));
  }

  function connectSocket() {
    if (!cfg || !session) return;
    if (socket && (socket.readyState === 0 || socket.readyState === 1)) return;
    var wsUrl = cfg.url.replace(/^http/, 'ws') + '/realtime/v1/websocket?apikey=' +
      encodeURIComponent(cfg.anonKey) + '&vsn=1.0.0';
    var ws;
    try { ws = new WebSocket(wsUrl); }
    catch (err) { return; }
    socket = ws;
    ws.onopen = function () {
      socketOpen = true;
      setNet(true);
      sendFrame('phoenix', 'heartbeat', {});
      Object.keys(channels).forEach(function (topic) { joinTopic(topic); });
    };
    ws.onmessage = function (ev) {
      var frame;
      try { frame = JSON.parse(ev.data); } catch (err) { return; }
      var topic = frame.topic;
      var event = frame.event;
      var payload = frame.payload || {};
      if (!topic || !event || event === 'phx_reply' || event === 'heartbeat') return;
      var channel = channels[topic];
      if (channel && channel.handler) channel.handler(event, payload);
    };
    ws.onclose = function () {
      socketOpen = false;
      setNet(false);
      socket = null;
      if (session) setTimeout(connectSocket, 2000);
    };
    ws.onerror = function () { setNet(false); };
  }

  function setNet(ok) {
    var el = $('net');
    if (el) el.textContent = ok ? 'Live' : 'Reconnecting';
  }

  function join(topic, config, handler) {
    channels[topic] = { config: config, handler: handler };
    if (socketOpen) joinTopic(topic);
    else connectSocket();
  }

  function joinTopic(topic) {
    var channel = channels[topic];
    if (!channel) return;
    sendFrame(topic, 'phx_join', {
      config: channel.config || {},
      access_token: session && session.access,
    });
  }

  function leave(topic) {
    if (channels[topic]) {
      sendFrame(topic, 'phx_leave', {});
      delete channels[topic];
    }
  }

  function startHeartbeat() {
    setInterval(function () {
      if (socketOpen) sendFrame('phoenix', 'heartbeat', {});
    }, 25000);
  }

  function subscribeInbox() {
    join('realtime:mailchat:web:inbox:' + me(), {
      postgres_changes: [
        { event: '*', schema: 'public', table: 'messages' },
        { event: '*', schema: 'public', table: 'conversation_members', filter: 'user_id=eq.' + me() },
      ],
    }, function () {
      clearTimeout(inboxTimer);
      inboxTimer = setTimeout(function () {
        loadChats(true);
        if (state.thread) loadThread(state.thread.id, true);
      }, 350);
    });
    join('realtime:mailchat:calls:' + me(), {
      postgres_changes: [{
        event: '*', schema: 'public', table: 'calls', filter: 'callee_id=eq.' + me(),
      }],
    }, function (event, payload) {
      var record = recordOf(event, payload);
      if (record) considerIncoming(record);
    });
  }

  function recordOf(event, payload) {
    var data = payload.data && typeof payload.data === 'object' ? payload.data : payload;
    if (event === 'postgres_changes') {
      return data.record || data.new || null;
    }
    return payload.record || null;
  }

  function watchCallRow(callId) {
    leave('realtime:mailchat:call:' + callId);
    leave('realtime:mailchat:ice:' + callId);
    join('realtime:mailchat:call:' + callId, {
      postgres_changes: [{ event: '*', schema: 'public', table: 'calls', filter: 'id=eq.' + callId }],
    }, function (event, payload) {
      var record = recordOf(event, payload);
      if (record) onCallRow(record);
    });
    join('realtime:mailchat:ice:' + callId, {
      postgres_changes: [{
        event: 'INSERT', schema: 'public', table: 'call_ice_candidates', filter: 'call_id=eq.' + callId,
      }],
    }, function (event, payload) {
      var record = recordOf(event, payload);
      if (record) addRemoteIce(record);
    });
  }

  function joinPresence(conversationId) {
    Object.keys(channels).forEach(function (topic) {
      if (topic.indexOf('realtime:mailchat:presence:') === 0) leave(topic);
    });
    join('realtime:mailchat:presence:' + conversationId, {
      broadcast: { self: false },
      presence: { key: me() },
    }, function (event, payload) {
      var inner = payload.payload;
      var typingEvent = payload.event === 'typing' || event === 'typing';
      if (!typingEvent || !inner) return;
      if (inner.user_id === me()) return;
      if (!state.thread || state.thread.id !== conversationId) return;
      state.thread.typing = !!inner.typing;
      var sub = $('thread-sub');
      if (sub) sub.textContent = state.thread.typing ? 'typing...' : threadSub();
      if (inner.typing) {
        clearTimeout(state.thread.typingTimer);
        state.thread.typingTimer = setTimeout(function () {
          if (state.thread) state.thread.typing = false;
          if (sub) sub.textContent = threadSub();
        }, 4000);
      }
    });
  }

  function sendTyping(on) {
    if (!state.thread) return;
    sendFrame('realtime:mailchat:presence:' + state.thread.id, 'broadcast', {
      type: 'broadcast',
      event: 'typing',
      payload: { user_id: me(), conversation_id: state.thread.id, typing: on },
    });
  }

  async function loadProfile() {
    var data = await api('/rest/v1/profiles?id=eq.' + me() + '&select=*');
    state.profile = rowsOf(data)[0] || null;
    if (state.profile) names[me()] = state.profile;
    try {
      var presence = await api('/rest/v1/user_presence?user_id=eq.' + me() + '&select=share_last_seen');
      var row = rowsOf(presence)[0];
      if (row && typeof row.share_last_seen === 'boolean') state.shareLastSeen = row.share_last_seen;
    } catch (err) { /* presence table may be absent */ }
  }

  async function loadChats(quiet) {
    try {
      var data = await api(
        '/rest/v1/conversation_list?select=*&user_id=eq.' + me() +
        '&order=last_message_at.desc.nullslast,updated_at.desc'
      );
      state.chats = rowsOf(data);
      state.chats.forEach(rememberParticipant);
      paintChats();
      refreshPresence();
    } catch (err) {
      if (!quiet) {
        state.error = err.message;
        render();
      }
    }
  }

  function rememberParticipant(chat) {
    var other = chat.other_participant;
    if (other && other.id) names[other.id] = other;
  }

  function chatTitle(chat) {
    if (!chat) return 'Chat';
    if (chat.conversation && chat.conversation.type === 'group') {
      return (chat.conversation && chat.conversation.name) || 'Group';
    }
    var other = chat.other_participant || {};
    return other.display_name || other.username || 'Chat';
  }

  function chatPeer(chat) {
    return chat && chat.other_participant && chat.other_participant.id;
  }

  async function refreshPresence() {
    var ids = [];
    state.chats.forEach(function (chat) {
      var id = chatPeer(chat);
      if (id) ids.push(id);
    });
    if (!ids.length) return;
    try {
      var data = await api('/rest/v1/rpc/get_presence', {
        method: 'POST',
        body: { p_user_ids: ids },
      });
      var map = {};
      rowsOf(data).forEach(function (row) { if (row.user_id) map[row.user_id] = row; });
      state.presence = map;
      paintChats();
      var sub = $('thread-sub');
      if (sub && state.thread && !state.thread.typing) sub.textContent = threadSub();
    } catch (err) { /* dots are optional */ }
  }

  async function touchPresence(share) {
    var body = {};
    if (typeof share === 'boolean') body.p_share = share;
    try { await api('/rest/v1/rpc/touch_last_seen', { method: 'POST', body: body }); }
    catch (err) { /* heartbeat is best-effort */ }
  }

  async function openChat(id) {
    var chat = state.chats.filter(function (item) { return item.id === id || item.conversation_id === id; })[0];
    state.pane = 'thread';
    state.reply = null;
    state.editing = null;
    state.openMessage = null;
    state.info = false;
    state.thread = {
      id: id,
      title: chat ? chatTitle(chat) : 'Chat',
      type: chat && chat.conversation ? chat.conversation.type : 'direct',
      peerId: chat ? chatPeer(chat) : null,
      messages: [],
      typing: false,
    };
    render();
    await loadThread(id, false);
    joinPresence(id);
    markRead(id);
  }

  async function loadThread(id, quiet) {
    if (!state.thread || state.thread.id !== id) return;
    try {
      var data = await api(
        '/rest/v1/messages?conversation_id=eq.' + id +
        '&select=*,message_attachments(*),message_reactions(*),message_receipts(*)' +
        '&order=created_at.asc&limit=80'
      );
      state.thread.messages = rowsOf(data);
      var unknown = {};
      state.thread.messages.forEach(function (msg) {
        if (msg.sender_id && !names[msg.sender_id]) unknown[msg.sender_id] = true;
      });
      var ids = Object.keys(unknown);
      if (ids.length) {
        var people = await api('/rest/v1/profiles?id=in.(' + ids.join(',') + ')&select=id,username,display_name');
        rowsOf(people).forEach(function (person) { names[person.id] = person; });
      }
      paintMessages();
      if (!quiet) markRead(id);
    } catch (err) {
      if (!quiet) toast(err.message);
    }
  }

  async function markRead(id) {
    try {
      await api('/rest/v1/rpc/mark_conversation_read', {
        method: 'POST',
        body: { p_conversation_id: id },
      });
    } catch (err) { /* badge clears on the next successful write */ }
    if (!state.thread) return;
    var pending = state.thread.messages.filter(function (msg) {
      return msg.sender_id !== me() && !msg.deleted_at;
    }).slice(-30);
    for (var i = 0; i < pending.length; i++) {
      var msg = pending[i];
      var receipts = msg.message_receipts || [];
      var mine = receipts.filter(function (row) { return row.recipient_id === me() && row.read_at; })[0];
      if (mine) continue;
      var now = new Date().toISOString();
      try {
        var updated = await api(
          '/rest/v1/message_receipts?message_id=eq.' + msg.id + '&recipient_id=eq.' + me(),
          { method: 'PATCH', body: { delivered_at: now, read_at: now } }
        );
        if (!rowsOf(updated).length) {
          await api('/rest/v1/message_receipts', {
            method: 'POST',
            body: { message_id: msg.id, recipient_id: me(), delivered_at: now, read_at: now },
          });
        }
      } catch (err) { /* a missed tick is not a failed send */ }
    }
  }

  async function sendText() {
    var box = $('draft');
    if (!box || !state.thread) return;
    var text = box.value.trim();
    if (!text) return;
    if (text.length > 4000) { toast('Message is too long.'); return; }
    var send = $('send');
    if (send) send.disabled = true;
    var body = {
      conversation_id: state.thread.id,
      sender_id: me(),
      type: 'text',
      text: text,
      client_id: (crypto.randomUUID && crypto.randomUUID()) || String(Date.now()),
    };
    if (state.reply) body.reply_to_message_id = state.reply.id;
    if (state.editing) {
      try {
        await api('/rest/v1/messages?id=eq.' + state.editing.id, {
          method: 'PATCH',
          body: { text: text, edited_at: new Date().toISOString() },
        });
        state.editing = null;
        box.value = '';
        await loadThread(state.thread.id, true);
      } catch (err) { toast(err.message); }
      if (send) send.disabled = false;
      return;
    }
    try {
      await api('/rest/v1/messages', { method: 'POST', body: body });
      box.value = '';
      state.reply = null;
      var strip = $('reply-strip');
      if (strip) strip.remove();
      sendTyping(false);
      await loadThread(state.thread.id, true);
      loadChats(true);
    } catch (err) { toast(err.message); }
    if (send) send.disabled = false;
  }

  async function sendFile(file) {
    if (!file || !state.thread) return;
    if (file.size > 10 * 1024 * 1024) { toast('Files must be under 10 MB.'); return; }
    if (!file.size) { toast('That file is empty.'); return; }
    toast('Sending file…');
    var safe = L.sanitiseFileName(file.name);
    var path = state.thread.id + '/' + Date.now() + '_' + safe;
    var mime = file.type || 'application/octet-stream';
    var bytes = await file.arrayBuffer();
    try {
      await api('/storage/v1/object/attachments/' + path.split('/').map(encodeURIComponent).join('/'), {
        method: 'POST',
        body: bytes,
        headers: { 'Content-Type': mime, 'x-upsert': 'false' },
        prefer: 'return=minimal',
      });
      var inserted = await api('/rest/v1/messages', {
        method: 'POST',
        body: {
          conversation_id: state.thread.id,
          sender_id: me(),
          type: mime.indexOf('image/') === 0 ? 'image' : 'file',
          client_id: (crypto.randomUUID && crypto.randomUUID()) || String(Date.now()),
        },
      });
      var message = rowsOf(inserted)[0];
      if (!message) throw new Error('The message was not created.');
      await api('/rest/v1/message_attachments', {
        method: 'POST',
        body: {
          message_id: message.id,
          storage_path: path,
          file_name: safe,
          mime_type: mime,
          file_size: file.size,
        },
      });
      await loadThread(state.thread.id, true);
      loadChats(true);
    } catch (err) { toast(err.message); }
  }

  async function signedUrl(path) {
    var data = await api(
      '/storage/v1/object/sign/attachments/' + path.split('/').map(encodeURIComponent).join('/'),
      { method: 'POST', body: { expiresIn: 3600 } }
    );
    var signed = data && (data.signedURL || data.signedUrl);
    if (!signed) throw new Error('Could not open that file.');
    if (String(signed).indexOf('http') === 0) return signed;
    if (String(signed).indexOf('/storage/') === 0) return cfg.url + signed;
    return cfg.url + '/storage/v1' + signed;
  }

  async function toggleReaction(messageId, emoji) {
    var mine = await api(
      '/rest/v1/message_reactions?message_id=eq.' + messageId + '&user_id=eq.' + me() + '&select=reaction'
    );
    var rows = rowsOf(mine);
    var already = rows.some(function (row) { return row.reaction === emoji; });
    if (rows.length) {
      await api('/rest/v1/message_reactions?message_id=eq.' + messageId + '&user_id=eq.' + me(), { method: 'DELETE' });
    }
    if (!already) {
      await api('/rest/v1/message_reactions', {
        method: 'POST',
        body: { message_id: messageId, user_id: me(), reaction: emoji },
      });
    }
    if (state.thread) await loadThread(state.thread.id, true);
  }

  async function deleteMessage(id) {
    await api('/rest/v1/messages?id=eq.' + id, {
      method: 'PATCH',
      body: { deleted_at: new Date().toISOString() },
    });
    if (state.thread) await loadThread(state.thread.id, true);
  }

  async function searchUsers(query) {
    var q = String(query || '').trim();
    if (q.length < 2) { state.search = []; return; }
    var data = await api('/rest/v1/rpc/search_users', {
      method: 'POST',
      body: { p_query: q, p_limit: 20 },
    });
    state.search = rowsOf(data);
  }

  async function openDirect(userId) {
    var data = await api('/rest/v1/rpc/get_or_create_direct_conversation', {
      method: 'POST',
      body: { other_user_id: userId },
    });
    var id = typeof data === 'string' ? data : (data && (data.id || data.get_or_create_direct_conversation));
    if (!id) throw new Error('Could not open that chat.');
    names[userId] = state.search.filter(function (person) { return person.id === userId; })[0] || names[userId];
    await loadChats(true);
    var chat = state.chats.filter(function (item) { return item.id === id; })[0];
    if (!chat) {
      state.chats.unshift({
        id: id,
        conversation_id: id,
        conversation: { id: id, type: 'direct' },
        other_participant: names[userId] || { id: userId, display_name: 'Chat' },
      });
    }
    await openChat(id);
  }

  async function createGroup() {
    var name = ($('group-name') && $('group-name').value || state.groupName || '').trim();
    if (!name) { toast('Group name is required.'); return; }
    if (name.length > 100) { toast('Group name is too long.'); return; }
    var inserted = await api('/rest/v1/conversations', {
      method: 'POST',
      body: { type: 'group', name: name, created_by: me() },
    });
    var conv = rowsOf(inserted)[0];
    if (!conv) throw new Error('The group was not created.');
    var ids = Object.keys(state.groupPick);
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] === me()) continue;
      try {
        await api('/rest/v1/conversation_members', {
          method: 'POST',
          body: { conversation_id: conv.id, user_id: ids[i], role: 'member' },
        });
      } catch (err) { toast(err.message); }
    }
    state.groupPick = {};
    await loadChats(true);
    state.chats.unshift({
      id: conv.id,
      conversation: conv,
      conversation_id: conv.id,
    });
    await openChat(conv.id);
  }

  async function leaveGroup() {
    if (!state.thread) return;
    await api(
      '/rest/v1/conversation_members?conversation_id=eq.' + state.thread.id + '&user_id=eq.' + me(),
      { method: 'DELETE' }
    );
    state.thread = null;
    state.pane = 'list';
    await loadChats(true);
    render();
  }

  async function blockUser(userId) {
    await api('/rest/v1/user_blocks', {
      method: 'POST',
      body: { blocker_id: me(), blocked_user_id: userId },
    });
    toast('Blocked. They cannot message you.');
  }

  async function loadBlocked() {
    var data = await api('/rest/v1/user_blocks?blocker_id=eq.' + me() + '&select=id,blocked_user_id');
    var blocks = rowsOf(data);
    var ids = blocks.map(function (row) { return row.blocked_user_id; }).filter(Boolean);
    if (ids.length) {
      var people = await api('/rest/v1/profiles?id=in.(' + ids.join(',') + ')&select=id,username,display_name');
      rowsOf(people).forEach(function (person) { names[person.id] = person; });
    }
    state.blocked = blocks;
  }

  async function reportUser(userId, reason, description) {
    await api('/rest/v1/user_reports', {
      method: 'POST',
      body: {
        reporter_id: me(),
        reported_user_id: userId,
        reason: reason,
        description: description || null,
        status: 'open',
      },
    });
    toast('Report sent.');
  }

  function iceConfig() {
    return L.buildIceServers(
      'stun:stun.l.google.com:19302',
      cfg.turnUrl,
      (cfg.turnUser || '').trim(),
      cfg.turnPass || loadTurnPass() || ''
    );
  }

  function hideIncoming() {
    var box = $('incoming');
    if (box) box.hidden = true;
  }

  function showIncoming(row) {
    if (!row || dismissedCalls[row.id] || (call && call.id === row.id)) return;
    if (row.callee_id !== me() || row.status !== 'ringing') return;
    state.incoming = row;
    var box = $('incoming');
    if (!box) return;
    box.hidden = false;
    $('incoming-title').textContent = row.kind === 'video' ? 'Incoming video call' : 'Incoming voice call';
    var person = names[row.caller_id];
    $('incoming-detail').textContent = (person && (person.display_name || person.username)) || 'Someone in your chats';
    try {
      var ctx = new (window.AudioContext || window.webkitAudioContext)();
      var osc = ctx.createOscillator();
      var gain = ctx.createGain();
      osc.frequency.value = 880;
      gain.gain.value = 0.04;
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start();
      setTimeout(function () { osc.stop(); ctx.close(); }, 180);
    } catch (err) { /* sound is optional */ }
  }

  function considerIncoming(row) {
    if (!row || row.status !== 'ringing') {
      if (state.incoming && row && state.incoming.id === row.id && row.status !== 'ringing') hideIncoming();
      return;
    }
    showIncoming(row);
  }

  async function pollIncoming() {
    if (!session) return;
    try {
      var data = await api(
        '/rest/v1/calls?callee_id=eq.' + me() + '&status=eq.ringing&select=*&order=created_at.desc&limit=1'
      );
      var row = rowsOf(data)[0];
      if (row) considerIncoming(row);
    } catch (err) { /* the next poll retries */ }
  }

  function setCallText(status, hint) {
    var statusEl = $('call-status');
    var hintEl = $('call-hint');
    if (statusEl && status) statusEl.textContent = status;
    if (hintEl && hint != null) hintEl.textContent = hint;
  }

  function showCallLayer(title, kind) {
    var layer = $('call-layer');
    layer.hidden = false;
    $('call-name').textContent = title || 'Call';
    $('call-kind').textContent = kind === 'video' ? 'Video call' : 'Voice call';
    $('call-cam').hidden = kind !== 'video';
    setCallText('Starting microphone...', 'Allow the microphone when the browser asks. Nothing is recorded.');
  }

  function hideCall() {
    clearInterval(callTimer);
    clearTimeout(slowTimer);
    callTimer = null;
    if (call && call.pc) {
      try { call.pc.close(); } catch (err) { /* already closed */ }
    }
    if (call && call.stream) call.stream.getTracks().forEach(function (track) { track.stop(); });
    if (call && call.id) {
      leave('realtime:mailchat:call:' + call.id);
      leave('realtime:mailchat:ice:' + call.id);
    }
    call = null;
    var layer = $('call-layer');
    if (layer) layer.hidden = true;
    var remote = $('remote-video');
    var local = $('local-video');
    if (remote) { remote.hidden = true; remote.srcObject = null; }
    if (local) { local.hidden = true; local.srcObject = null; }
    var audio = $('remote-audio');
    if (audio) audio.srcObject = null;
  }

  async function openMedia(video) {
    var stream = await navigator.mediaDevices.getUserMedia({
      audio: true,
      video: video ? { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 } } : false,
    });
    return stream;
  }

  function makePeer(stream, video) {
    var ice = iceConfig();
    var pc = new RTCPeerConnection({
      iceServers: ice.iceServers,
      iceTransportPolicy: ice.forceRelay ? 'relay' : 'all',
    });
    stream.getTracks().forEach(function (track) { pc.addTrack(track, stream); });
    var local = $('local-video');
    if (video && local) {
      local.hidden = false;
      local.srcObject = stream;
    }
    pc.ontrack = function (ev) {
      var remoteStream = ev.streams && ev.streams[0];
      if (!remoteStream) return;
      var audio = $('remote-audio');
      if (audio) {
        audio.srcObject = remoteStream;
        audio.play().catch(function () {});
      }
      if (remoteStream.getVideoTracks().length) {
        var remote = $('remote-video');
        remote.hidden = false;
        remote.srcObject = remoteStream;
      }
    };
    pc.oniceconnectionstatechange = onPeerState;
    pc.onconnectionstatechange = onPeerState;
    return pc;
  }

  function onPeerState() {
    if (!call || !call.pc) return;
    var ice = call.pc.iceConnectionState;
    var conn = call.pc.connectionState;
    var up = conn === 'connected' || ice === 'connected' || ice === 'completed';
    if (up) {
      call.connected = true;
      setCallText('Connected', '');
      return;
    }
    if (call.connected) return;
    if (conn === 'failed' || ice === 'failed') {
      setCallText('Could not connect', callHint());
    }
  }

  function callHint() {
    var ice = iceConfig();
    if (!ice.forceRelay) {
      return 'This browser has no relay. On mobile data the call stays here until Settings has the same TURN lines as the phone.';
    }
    return 'Still connecting. Turn off any VPN and Data saver, on this browser and on the phone.';
  }

  function queueLocalIce(candidate) {
    if (!call || !candidate || !candidate.candidate) return;
    if (!call.id) {
      call.pendingLocal.push(candidate);
      return;
    }
    sendLocalIce(candidate);
  }

  async function sendLocalIce(candidate) {
    if (!call || !call.id || !candidate.candidate) return;
    try {
      await api('/rest/v1/call_ice_candidates', {
        method: 'POST',
        prefer: 'return=minimal',
        body: {
          call_id: call.id,
          sender_id: me(),
          candidate: candidate.candidate,
          sdp_mid: candidate.sdpMid,
          sdp_mline_index: candidate.sdpMLineIndex,
        },
      });
    } catch (err) { /* a lost candidate is retried by ICE itself */ }
  }

  async function flushLocalIce() {
    if (!call) return;
    var queued = call.pendingLocal.splice(0);
    for (var i = 0; i < queued.length; i++) await sendLocalIce(queued[i]);
  }

  async function addRemoteIce(row) {
    if (!call || !call.pc || !row || row.sender_id === me()) return;
    if (seenIce[row.candidate]) return;
    seenIce[row.candidate] = true;
    var item = {
      candidate: row.candidate,
      sdpMid: row.sdp_mid || '0',
      sdpMLineIndex: row.sdp_mline_index == null ? 0 : row.sdp_mline_index,
    };
    if (!call.remoteSet) {
      call.pendingRemote.push(item);
      return;
    }
    try { await call.pc.addIceCandidate(item); } catch (err) { /* ignore malformed */ }
  }

  async function flushRemoteIce() {
    if (!call) return;
    var queued = call.pendingRemote.splice(0);
    for (var i = 0; i < queued.length; i++) {
      try { await call.pc.addIceCandidate(queued[i]); } catch (err) { /* ignore */ }
    }
  }

  function waitGather(pc) {
    return new Promise(function (resolve) {
      if (pc.iceGatheringState === 'complete') { resolve(); return; }
      var timer = setTimeout(resolve, 6000);
      pc.addEventListener('icegatheringstatechange', function () {
        if (pc.iceGatheringState === 'complete') {
          clearTimeout(timer);
          resolve();
        }
      });
    });
  }

  function armSlowHint() {
    clearTimeout(slowTimer);
    slowTimer = setTimeout(function () {
      if (call && !call.connected) setCallText('Connecting...', callHint());
    }, 15000);
  }

  function beginPolling() {
    clearInterval(callTimer);
    callTimer = setInterval(syncCall, 2000);
    syncCall();
    armSlowHint();
  }

  async function syncCall() {
    if (!call || !call.id) return;
    try {
      var data = await api('/rest/v1/calls?id=eq.' + call.id + '&select=*');
      var row = rowsOf(data)[0];
      if (row) onCallRow(row);
      var ice = await api(
        '/rest/v1/call_ice_candidates?call_id=eq.' + call.id + '&sender_id=neq.' + me() +
        '&select=candidate,sdp_mid,sdp_mline_index,sender_id&order=created_at.asc'
      );
      var list = rowsOf(ice);
      for (var i = 0; i < list.length; i++) await addRemoteIce(list[i]);
    } catch (err) { /* keep the call up; the next poll retries */ }
  }

  async function onCallRow(row) {
    if (!call || row.id !== call.id) return;
    if (row.status === 'declined' || row.status === 'ended' || row.status === 'missed' || row.status === 'failed') {
      var label = row.status === 'declined' ? 'Declined' : row.status === 'missed' ? 'Missed' : row.status === 'failed' ? 'Could not connect' : 'Call ended';
      hideCall();
      toast(label);
      return;
    }
    if (call.role === 'caller' && row.answer_sdp && !call.answerApplied) {
      call.answerApplied = true;
      call.remoteSet = true;
      try {
        await call.pc.setRemoteDescription({ type: 'answer', sdp: row.answer_sdp });
        await flushRemoteIce();
        if (!call.connected) setCallText('Connecting...', 'The other side answered.');
      } catch (err) {
        setCallText('Could not connect', err.message);
      }
    }
  }

  async function startCall(video) {
    if (!state.thread || !state.thread.peerId) {
      toast('Calls are between two people. Open a direct chat.');
      return;
    }
    if (call) return;
    var conversationId = state.thread.id;
    var peerId = state.thread.peerId;
    var title = state.thread.title;
    hideIncoming();
    showCallLayer(title, video ? 'video' : 'voice');
    try {
      var stream = await openMedia(video);
      var pc = makePeer(stream, video);
      call = {
        id: null,
        role: 'caller',
        pc: pc,
        stream: stream,
        video: video,
        pendingLocal: [],
        pendingRemote: [],
        remoteSet: false,
        answerApplied: false,
        connected: false,
        title: title,
      };
      pc.onicecandidate = function (ev) { if (ev.candidate) queueLocalIce(ev.candidate); };
      var offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitGather(pc);
      var local = pc.localDescription && pc.localDescription.sdp;
      var inserted = await api('/rest/v1/calls', {
        method: 'POST',
        body: {
          conversation_id: conversationId,
          caller_id: me(),
          callee_id: peerId,
          kind: video ? 'video' : 'voice',
          status: 'ringing',
          offer_sdp: local,
        },
      });
      var row = rowsOf(inserted)[0];
      if (!row) throw new Error('The call was not created.');
      call.id = row.id;
      seenIce = {};
      await flushLocalIce();
      watchCallRow(row.id);
      beginPolling();
      setCallText('Ringing...', 'Waiting for the other person to accept.');
    } catch (err) {
      hideCall();
      toast(err.message || 'Could not start the call.');
    }
  }

  async function acceptCall() {
    var incoming = state.incoming;
    if (!incoming) return;
    hideIncoming();
    dismissedCalls[incoming.id] = true;
    var person = names[incoming.caller_id];
    var title = (person && (person.display_name || person.username)) || 'Call';
    showCallLayer(title, incoming.kind);
    try {
      var fresh = rowsOf(await api('/rest/v1/calls?id=eq.' + incoming.id + '&select=*'))[0] || incoming;
      if (!fresh.offer_sdp) throw new Error('The caller did not send an offer, so this call cannot connect.');
      var stream = await openMedia(fresh.kind === 'video');
      var pc = makePeer(stream, fresh.kind === 'video');
      call = {
        id: fresh.id,
        role: 'callee',
        pc: pc,
        stream: stream,
        video: fresh.kind === 'video',
        pendingLocal: [],
        pendingRemote: [],
        remoteSet: false,
        answerApplied: true,
        connected: false,
        title: title,
      };
      pc.onicecandidate = function (ev) { if (ev.candidate) queueLocalIce(ev.candidate); };
      await pc.setRemoteDescription({ type: 'offer', sdp: fresh.offer_sdp });
      call.remoteSet = true;
      var answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await waitGather(pc);
      var local = pc.localDescription && pc.localDescription.sdp;
      await api('/rest/v1/calls?id=eq.' + fresh.id, {
        method: 'PATCH',
        body: { status: 'accepted', answer_sdp: local },
      });
      seenIce = {};
      await flushLocalIce();
      await flushRemoteIce();
      watchCallRow(fresh.id);
      beginPolling();
      setCallText('Connecting...', '');
    } catch (err) {
      hideCall();
      toast(err.message || 'Could not answer.');
    }
  }

  async function declineCall() {
    var incoming = state.incoming;
    hideIncoming();
    if (!incoming) return;
    dismissedCalls[incoming.id] = true;
    state.incoming = null;
    try {
      await api('/rest/v1/calls?id=eq.' + incoming.id, { method: 'PATCH', body: { status: 'declined' } });
    } catch (err) { toast(err.message); }
  }

  async function hangup() {
    if (!call) { hideCall(); return; }
    var id = call.id;
    var role = call.role;
    var connected = call.connected;
    hideCall();
    if (!id) return;
    var status = 'failed';
    if (connected) status = 'ended';
    else if (role === 'callee') status = 'declined';
    else status = 'missed';
    try {
      await api('/rest/v1/calls?id=eq.' + id, { method: 'PATCH', body: { status: status } });
    } catch (err) {
      if (status !== 'failed') {
        try { await api('/rest/v1/calls?id=eq.' + id, { method: 'PATCH', body: { status: 'failed' } }); }
        catch (again) { /* the row stays as the server left it */ }
      }
    }
  }

  function threadSub() {
    if (!state.thread) return '';
    if (state.thread.typing) return 'typing...';
    var peer = state.thread.peerId && state.presence[state.thread.peerId];
    if (peer && peer.online === true) return 'Online';
    if (peer && peer.last_seen_at) return 'Last seen ' + L.formatWhen(peer.last_seen_at);
    if (state.thread.type === 'group') return 'Group';
    return 'MailChat';
  }

  function previewText(chat) {
    if (chat.last_message_text) return chat.last_message_text;
    if (chat.last_message_at) return 'Photo or file';
    return 'No messages yet';
  }

  function render() {
    var app = $('app');
    if (!app) return;
    if (!cfg) { app.innerHTML = setupHtml(); return; }
    if (!session) { app.innerHTML = authHtml(); return; }
    app.innerHTML = shellHtml();
    var box = $('messages');
    if (box) box.scrollTop = box.scrollHeight;
    hydrateImages();
  }

  function setupHtml() {
    return '<div class="gate"><form class="card" data-act="save-config">' +
      '<div class="brand"><div class="mark">M</div><div><p class="eyebrow">MailChat</p><h1>Phone and browser, one account</h1></div></div>' +
      '<p class="lede">This is the MailChat app in the browser. It uses the same email account, chats and calls as the phone app. Paste the two lines from the phone’s env file. Do not paste the service_role key.</p>' +
      (state.error ? '<div class="error">' + L.esc(state.error) + '</div>' : '') +
      '<label for="cfg-url">SUPABASE_URL</label><input id="cfg-url" name="url" autocomplete="off" placeholder="https://YOUR-PROJECT.supabase.co" required>' +
      '<label for="cfg-key">SUPABASE_ANON_KEY</label><input id="cfg-key" name="key" autocomplete="off" placeholder="anon public key" required>' +
      '<details><summary>Relay for calls on mobile data (optional)</summary>' +
      '<label for="cfg-turn">TURN addresses, same as the phone</label><textarea id="cfg-turn" name="turn" placeholder="turns:…"></textarea>' +
      '<label for="cfg-turn-user">TURN username</label><input id="cfg-turn-user" name="turnUser" autocomplete="off">' +
      '<label for="cfg-turn-pass">TURN password</label><input id="cfg-turn-pass" name="turnPass" type="password" autocomplete="off">' +
      '<p class="tiny">The password stays in this browser. It is not sent to MailChat’s authors.</p></details>' +
      '<button class="btn full" type="submit">Continue</button></form></div>';
  }

  function authHtml() {
    var mode = state.authMode;
    var form = mode === 'register' ? registerFields() : mode === 'reset' ? resetFields() : loginFields();
    return '<div class="gate"><div class="card">' +
      '<div class="brand"><div class="mark">M</div><div><p class="eyebrow">MailChat</p><h1>' +
      (state.recovery ? 'Choose a new password' : 'Sign in') + '</h1></div></div>' +
      (state.recovery
        ? '<form data-act="new-password"><p class="lede">This link is for resetting the password. It works for the phone app too.</p>' +
          (state.error ? '<div class="error">' + L.esc(state.error) + '</div>' : '') +
          '<label for="new-pass">New password</label><input id="new-pass" type="password" required>' +
          '<button class="btn full" type="submit">Save password</button></form>'
        : '<div class="tabs">' +
          tab('login', 'Sign in') + tab('register', 'Create account') + tab('reset', 'Reset') +
          '</div><p class="lede">Use the same email as the phone app. Chats and calls are shared.</p>' +
          (state.notice ? '<div class="ok">' + L.esc(state.notice) + '</div>' : '') +
          (state.error ? '<div class="error">' + L.esc(state.error) + '</div>' : '') +
          form) +
      '<p class="tiny">Project ' + L.esc(cfg.url.replace(/^https?:\/\//, '')) +
      ' · <button type="button" class="btn ghost" data-act="forget-project">Use a different project</button></p>' +
      '</div></div>';
  }

  function tab(id, label) {
    return '<button type="button" class="' + (state.authMode === id ? 'on' : '') + '" data-act="auth-tab" data-mode="' + id + '">' + label + '</button>';
  }

  function loginFields() {
    return '<form data-act="login"><label for="email">Email</label><input id="email" type="email" autocomplete="username" required>' +
      '<label for="password">Password</label><input id="password" type="password" autocomplete="current-password" required>' +
      '<button class="btn full" type="submit">Sign in</button></form>';
  }

  function registerFields() {
    return '<form data-act="register"><label for="email">Email</label><input id="email" type="email" autocomplete="username" required>' +
      '<label for="display">Display name</label><input id="display" required>' +
      '<label for="username">Username</label><input id="username" autocapitalize="none" required>' +
      '<label for="password">Password</label><input id="password" type="password" autocomplete="new-password" required>' +
      '<p class="tiny">At least 8 characters, with a capital letter, a small letter and a number. Username is lowercase.</p>' +
      '<button class="btn full" type="submit">Create account</button></form>';
  }

  function resetFields() {
    return '<form data-act="reset"><p class="lede">We email a link. Open it in this same browser.</p>' +
      '<label for="email">Email</label><input id="email" type="email" required>' +
      '<button class="btn full" type="submit">Send reset email</button></form>';
  }

  function shellHtml() {
    return '<div class="shell is-' + L.esc(state.pane) + '"><aside class="side">' + sideHtml() +
      '</aside><section class="main">' + mainHtml() + '</section></div>';
  }

  function sideHtml() {
    var profile = state.profile || {};
    return '<div class="top"><div class="mark">M</div><div style="flex:1"><h1>MailChat</h1>' +
      '<div class="sub" id="net">' + (socketOpen ? 'Live' : 'Connecting') + '</div></div>' +
      '<button type="button" class="icon-btn" data-act="go" data-pane="search" title="New chat">＋</button>' +
      '<button type="button" class="icon-btn" data-act="go" data-pane="settings" title="Settings">⚙</button></div>' +
      '<div class="search-wrap"><div class="sub">' + L.esc(profile.display_name || profile.username || session.user.email || '') + '</div></div>' +
      '<div class="list" id="chat-list">' + chatsHtml() + '</div>';
  }

  function chatsHtml() {
    if (!state.chats.length) {
      return '<div class="empty"><h2>No chats yet</h2><p>Tap ＋ and search by username or the other person’s exact email.</p></div>';
    }
    return state.chats.map(function (chat) {
      var id = chat.id || chat.conversation_id;
      var peer = chatPeer(chat);
      var online = peer && state.presence[peer] && state.presence[peer].online === true;
      var unread = Number(chat.unread_count) || 0;
      var initial = chatTitle(chat).slice(0, 1).toUpperCase();
      return '<button type="button" class="chat' + (state.thread && state.thread.id === id ? ' on' : '') +
        '" data-act="open" data-id="' + L.esc(id) + '"><span class="avatar">' + L.esc(initial) +
        (online ? '<i class="dot"></i>' : '') + '</span><span><div class="chat-name">' + L.esc(chatTitle(chat)) +
        '</div><div class="chat-preview">' + L.esc(previewText(chat)) + '</div></span>' +
        (unread ? '<span class="badge">' + unread + '</span>' : '<span></span>') + '</button>';
    }).join('');
  }

  function mainHtml() {
    if (state.pane === 'search') return searchPane();
    if (state.pane === 'group') return groupPane();
    if (state.pane === 'settings') return settingsPane();
    if (state.pane === 'blocked') return blockedPane();
    if (state.pane === 'report') return reportPane();
    if (state.thread) return threadHtml();
    return '<div class="empty"><h2>Choose a chat</h2><p>Messages and calls here are the same ones on the phone.</p></div>';
  }

  function searchPane() {
    return panelHead('New chat') +
      '<div class="panel"><form data-act="search" class="row"><input id="q" placeholder="Username or exact email" autocomplete="off"><button class="btn" type="submit">Search</button></form>' +
      '<div id="results">' + resultsHtml() + '</div>' +
      '<button type="button" class="btn ghost full" data-act="go" data-pane="group">New group</button></div>';
  }

  function resultsHtml() {
    if (!state.search.length) return '<p class="tiny">Search uses the same rules as the phone. Email must be the full address.</p>';
    return state.search.map(function (person) {
      return '<button type="button" class="person" data-act="direct" data-id="' + L.esc(person.id) + '"><strong>' +
        L.esc(person.display_name || person.username) + '</strong><div class="sub">@' + L.esc(person.username) +
        (person.matched_by === 'email' ? ' · matched email' : '') + '</div></button>';
    }).join('');
  }

  function groupPane() {
    var picked = Object.keys(state.groupPick).map(function (id) {
      var person = names[id] || {};
      return L.esc(person.display_name || person.username || id);
    }).join(', ');
    return panelHead('New group') + '<div class="panel"><label for="group-name">Name</label><input id="group-name" maxlength="100">' +
      '<form data-act="search" class="row"><input id="q" placeholder="Add people" autocomplete="off"><button class="btn" type="submit">Find</button></form>' +
      '<div id="results">' + state.search.map(function (person) {
        var on = !!state.groupPick[person.id];
        return '<button type="button" class="person" data-act="pick" data-id="' + L.esc(person.id) + '">' +
          (on ? '✓ ' : '') + L.esc(person.display_name || person.username) + '</button>';
      }).join('') + '</div>' +
      (picked ? '<p class="note">' + picked + '</p>' : '') +
      '<button type="button" class="btn full" data-act="create-group">Create group</button></div>';
  }

  function settingsPane() {
    var profile = state.profile || {};
    return panelHead('Settings') + '<div class="panel">' +
      '<form data-act="save-profile"><label for="display">Display name</label><input id="display" value="' + L.esc(profile.display_name || '') + '">' +
      '<label for="bio">Bio</label><textarea id="bio">' + L.esc(profile.bio || '') + '</textarea>' +
      '<button class="btn full" type="submit">Save profile</button></form>' +
      '<div class="toggle"><span>Find me by email</span><input class="switch" type="checkbox" data-act="privacy" data-key="discoverable_by_email"' +
      (profile.discoverable_by_email !== false ? ' checked' : '') + '></div>' +
      '<div class="toggle"><span>Find me by username</span><input class="switch" type="checkbox" data-act="privacy" data-key="discoverable_by_username"' +
      (profile.discoverable_by_username !== false ? ' checked' : '') + '></div>' +
      '<div class="toggle"><span>Share last seen</span><input class="switch" type="checkbox" data-act="share-seen"' +
      (state.shareLastSeen ? ' checked' : '') + '></div>' +
      '<button type="button" class="btn ghost full" data-act="go" data-pane="blocked">Blocked people</button>' +
      '<h3 style="margin-top:22px">Relay for calls</h3><p class="tiny">Paste the same TURN lines the phone uses, or a call on mobile data stays on Connecting. The password stays in this browser.</p>' +
      '<form data-act="save-turn"><label for="turn">TURN addresses</label><textarea id="turn">' + L.esc(cfg.turnUrl || '') + '</textarea>' +
      '<label for="turn-user">Username</label><input id="turn-user" value="' + L.esc(cfg.turnUser || '') + '" autocomplete="off">' +
      '<label for="turn-pass">Password</label><input id="turn-pass" type="password" value="' + L.esc(loadTurnPass()) + '" autocomplete="off">' +
      '<button class="btn full" type="submit">Save relay</button></form>' +
      '<h3 style="margin-top:22px">Email links</h3><p class="tiny">If a confirmation or reset email bounces, add this address in Supabase → Authentication → URL Configuration → Redirect URLs.</p>' +
      '<input id="redirect-url" readonly value="' + L.esc(L.pageAddress()) + '">' +
      '<button type="button" class="btn ghost full" data-act="copy-redirect">Copy address</button>' +
      '<button type="button" class="btn danger full" data-act="sign-out">Sign out</button></div>';
  }

  function blockedPane() {
    var list = state.blocked.map(function (row) {
      var person = names[row.blocked_user_id] || {};
      return '<div class="person"><strong>' + L.esc(person.display_name || person.username || 'Person') +
        '</strong><button type="button" class="btn ghost" data-act="unblock" data-id="' + L.esc(row.id) + '">Unblock</button></div>';
    }).join('') || '<p class="tiny">Nobody is blocked.</p>';
    return panelHead('Blocked') + '<div class="panel">' + list + '</div>';
  }

  function reportPane() {
    return panelHead('Report') + '<form class="panel" data-act="report"><label for="reason">Reason</label><select id="reason">' +
      ['Spam', 'Harassment or abuse', 'Impersonation', 'Inappropriate content', 'Other'].map(function (reason) {
        return '<option>' + reason + '</option>';
      }).join('') + '</select><label for="details">What happened</label><textarea id="details"></textarea>' +
      '<button class="btn danger full" type="submit">Send report</button></form>';
  }

  function panelHead(title) {
    return '<div class="thread-head"><button type="button" class="icon-btn" data-act="go" data-pane="list">←</button><div class="who"><h2>' +
      L.esc(title) + '</h2></div></div>';
  }

  function infoBar() {
    if (!state.thread) return '';
    var peer = state.thread.peerId;
    var buttons = peer
      ? '<button type="button" class="btn ghost" data-act="block">Block</button>' +
        '<button type="button" class="btn ghost" data-act="report-open">Report</button>'
      : '<button type="button" class="btn ghost" data-act="leave">Leave group</button>';
    return '<div class="reply-strip' + (state.info ? '' : ' hidden') + '" id="info-bar">' + buttons + '</div>';
  }

  function threadHtml() {
    var thread = state.thread;
    var direct = thread.type !== 'group' && thread.peerId;
    return '<div class="thread"><div class="thread-head"><button type="button" class="icon-btn" data-act="go" data-pane="list">←</button>' +
      '<div class="who"><h2>' + L.esc(thread.title) + '</h2><div class="sub" id="thread-sub">' + L.esc(threadSub()) + '</div></div>' +
      (direct ? '<button type="button" class="icon-btn" data-act="call" data-video="0" title="Voice call">☎</button>' +
        '<button type="button" class="icon-btn" data-act="call" data-video="1" title="Video call">▶</button>' : '') +
      '<button type="button" class="icon-btn" data-act="info" title="Info">⋯</button></div>' +
      infoBar() +
      '<div class="messages" id="messages">' + messagesHtml() + '</div>' +
      (state.reply ? '<div class="reply-strip" id="reply-strip">Replying · ' + L.esc(snippet(state.reply)) +
        '<button type="button" class="icon-btn" data-act="clear-reply">×</button></div>' : '') +
      '<form class="composer" data-act="send"><label class="file-btn btn ghost">File<input type="file" id="file" data-act="file"></label>' +
      '<textarea id="draft" rows="1" placeholder="Message"></textarea>' +
      '<button class="btn" id="send" type="submit">Send</button></form></div>';
  }

  function snippet(msg) {
    if (!msg || msg.deleted_at) return 'Earlier message';
    return (msg.text || 'Photo or file').slice(0, 80);
  }

  function messagesHtml() {
    var html = '';
    var lastDay = '';
    (state.thread.messages || []).forEach(function (msg) {
      var day = L.dayLabel(msg.created_at);
      if (day && day !== lastDay) {
        lastDay = day;
        html += '<div class="day">' + L.esc(day) + '</div>';
      }
      html += bubbleHtml(msg);
    });
    return html || '<div class="empty"><h2>No messages yet</h2><p>Say hello. The phone sees this chat too.</p></div>';
  }

  function bubbleHtml(msg) {
    var mine = msg.sender_id === me();
    var person = names[msg.sender_id] || {};
    var text = msg.deleted_at
      ? '<p class="deleted">This message was deleted</p>'
      : '<p>' + L.esc(msg.text || '') + '</p>';
    var quote = '';
    if (msg.reply_to_message_id) {
      var parent = (state.thread.messages || []).filter(function (item) { return item.id === msg.reply_to_message_id; })[0];
      quote = '<div class="quote">' + L.esc(snippet(parent)) + '</div>';
    }
    var files = (msg.message_attachments || []).map(function (file) {
      if ((file.mime_type || '').indexOf('image/') === 0) {
        return '<img class="preview" alt="' + L.esc(file.file_name) + '" data-path="' + L.esc(file.storage_path) + '">';
      }
      return '<a class="attach" href="#" data-path="' + L.esc(file.storage_path) + '" data-act="open-file">' + L.esc(file.file_name) + '</a>';
    }).join('');
    var reactions = groupReactions(msg.message_reactions || []).map(function (item) {
      return '<button type="button" class="chip' + (item.mine ? ' on' : '') + '" data-act="react" data-id="' +
        L.esc(msg.id) + '" data-emoji="' + L.esc(item.emoji) + '">' + L.esc(item.emoji) + ' ' + item.count + '</button>';
    }).join('');
    var tools = '';
    if (state.openMessage === msg.id && !msg.deleted_at) {
      tools = '<div class="tools">' +
        ['👍', '❤️', '😂', '😮', '😢', '🙏'].map(function (emoji) {
          return '<button type="button" data-act="react" data-id="' + L.esc(msg.id) + '" data-emoji="' + emoji + '">' + emoji + '</button>';
        }).join('') +
        '<button type="button" data-act="reply" data-id="' + L.esc(msg.id) + '">Reply</button>' +
        (mine ? '<button type="button" data-act="edit" data-id="' + L.esc(msg.id) + '">Edit</button>' +
          '<button type="button" data-act="delete" data-id="' + L.esc(msg.id) + '">Delete</button>' : '') +
        '</div>';
    }
    var status = mine ? L.receiptStatus(msg.message_receipts) : '';
    return '<article class="bubble' + (mine ? ' mine' : '') + '" data-act="menu" data-id="' + L.esc(msg.id) + '">' +
      (!mine && state.thread.type === 'group' ? '<div class="who-name">' + L.esc(person.display_name || person.username || 'Member') + '</div>' : '') +
      quote + text + files +
      (reactions ? '<div class="reactions">' + reactions + '</div>' : '') +
      tools +
      '<div class="meta"><span>' + L.esc(L.formatWhen(msg.created_at)) + (msg.edited_at ? ' · edited' : '') + '</span>' +
      (mine ? '<span class="tick ' + status + '">' + L.tick(status) + '</span>' : '') +
      '</div></article>';
  }

  function groupReactions(rows) {
    var map = {};
    rows.forEach(function (row) {
      if (!map[row.reaction]) map[row.reaction] = { emoji: row.reaction, count: 0, mine: false };
      map[row.reaction].count += 1;
      if (row.user_id === me()) map[row.reaction].mine = true;
    });
    return Object.keys(map).map(function (key) { return map[key]; });
  }

  function paintChats() {
    var box = $('chat-list');
    if (!box) return;
    box.innerHTML = chatsHtml();
  }

  function paintMessages() {
    var box = $('messages');
    if (!box) { render(); return; }
    var near = box.scrollHeight - box.scrollTop - box.clientHeight < 140;
    box.innerHTML = messagesHtml();
    if (near) box.scrollTop = box.scrollHeight;
    hydrateImages();
  }

  async function hydrateImages() {
    var nodes = document.querySelectorAll('[data-path]');
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.dataset.loaded) continue;
      node.dataset.loaded = '1';
      try {
        var url = await signedUrl(node.dataset.path);
        if (node.tagName === 'IMG') node.src = url;
        else node.href = url;
      } catch (err) { node.dataset.loaded = ''; }
    }
  }

  async function onClick(ev) {
    var el = ev.target.closest('[data-act]');
    if (!el) return;
    var act = el.dataset.act;
    if (act === 'open-file') {
      ev.preventDefault();
      signedUrl(el.dataset.path).then(function (url) {
        window.open(url, '_blank', 'noopener');
      }).catch(function (err) { toast(err.message); });
      return;
    }
    if (act === 'auth-tab') {
      state.authMode = el.dataset.mode;
      state.error = '';
      state.notice = '';
      render();
      return;
    }
    if (act === 'forget-project') {
      localStorage.removeItem(CONFIG_KEY);
      cfg = null;
      await signOutLocal();
      return;
    }
    if (act === 'go') {
      state.pane = el.dataset.pane;
      state.error = '';
      if (state.pane === 'blocked') {
        try { await loadBlocked(); } catch (err) { toast(err.message); }
      }
      if (state.pane === 'settings') {
        try { await loadProfile(); } catch (err) { toast(err.message); }
      }
      render();
      return;
    }
    if (act === 'open') { openChat(el.dataset.id); return; }
    if (act === 'direct') {
      try { await openDirect(el.dataset.id); } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'pick') {
      var id = el.dataset.id;
      if (state.groupPick[id]) delete state.groupPick[id];
      else state.groupPick[id] = true;
      var person = state.search.filter(function (item) { return item.id === id; })[0];
      if (person) names[id] = person;
      var box = $('results');
      if (box) box.innerHTML = groupPaneResults();
      return;
    }
    if (act === 'create-group') {
      try { await createGroup(); } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'menu') {
      state.openMessage = state.openMessage === el.dataset.id ? null : el.dataset.id;
      paintMessages();
      return;
    }
    if (act === 'react') {
      try { await toggleReaction(el.dataset.id, el.dataset.emoji); } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'reply') {
      state.reply = (state.thread.messages || []).filter(function (msg) { return msg.id === el.dataset.id; })[0];
      state.openMessage = null;
      render();
      return;
    }
    if (act === 'clear-reply') { state.reply = null; render(); return; }
    if (act === 'edit') {
      var msg = (state.thread.messages || []).filter(function (item) { return item.id === el.dataset.id; })[0];
      state.editing = msg;
      render();
      var draft = $('draft');
      if (draft && msg) draft.value = msg.text || '';
      return;
    }
    if (act === 'delete') {
      if (!confirm('Delete this message?')) return;
      try { await deleteMessage(el.dataset.id); } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'call') { startCall(el.dataset.video === '1'); return; }
    if (act === 'call-accept') { acceptCall(); return; }
    if (act === 'call-decline') { declineCall(); return; }
    if (act === 'call-hangup') { hangup(); return; }
    if (act === 'call-mute') {
      if (!call || !call.stream) return;
      var audio = call.stream.getAudioTracks()[0];
      if (!audio) return;
      audio.enabled = !audio.enabled;
      el.textContent = audio.enabled ? 'Mute' : 'Unmute';
      return;
    }
    if (act === 'call-cam') {
      if (!call || !call.stream) return;
      var video = call.stream.getVideoTracks()[0];
      if (!video) return;
      video.enabled = !video.enabled;
      el.textContent = video.enabled ? 'Camera' : 'Camera off';
      return;
    }
    if (act === 'info') { infoMenu(); return; }
    if (act === 'block' && state.thread && state.thread.peerId) {
      blockUser(state.thread.peerId).catch(function (err) { toast(err.message); });
      return;
    }
    if (act === 'report-open' && state.thread && state.thread.peerId) {
      state.reportUserId = state.thread.peerId;
      state.pane = 'report';
      render();
      return;
    }
    if (act === 'leave') {
      leaveGroup().catch(function (err) { toast(err.message); });
      return;
    }
    if (act === 'copy-redirect') {
      var input = $('redirect-url');
      if (input) {
        input.select();
        navigator.clipboard.writeText(input.value).then(function () { toast('Address copied.'); }, function () { toast(input.value); });
      }
      return;
    }
    if (act === 'sign-out') { signOut(); return; }
    if (act === 'unblock') {
      try {
        await api('/rest/v1/user_blocks?id=eq.' + el.dataset.id, { method: 'DELETE' });
        await loadBlocked();
        render();
      } catch (err) { toast(err.message); }
    }
  }

  function groupPaneResults() {
    return state.search.map(function (person) {
      var on = !!state.groupPick[person.id];
      return '<button type="button" class="person" data-act="pick" data-id="' + L.esc(person.id) + '">' +
        (on ? '✓ ' : '') + L.esc(person.display_name || person.username) + '</button>';
    }).join('');
  }

  function infoMenu() {
    if (!state.thread) return;
    state.info = !state.info;
    var bar = $('info-bar');
    if (bar) {
      bar.classList.toggle('hidden', !state.info);
      return;
    }
    render();
  }

  async function onSubmit(ev) {
    var form = ev.target.closest('form[data-act]');
    if (!form) return;
    ev.preventDefault();
    var act = form.dataset.act;
    state.error = '';
    try {
      if (act === 'save-config') { await saveConfigForm(); return; }
      if (act === 'login') return doLogin();
      if (act === 'register') return doRegister();
      if (act === 'reset') return doReset();
      if (act === 'new-password') return doNewPassword();
      if (act === 'search') return doSearch();
      if (act === 'send') return sendText();
      if (act === 'save-profile') return saveProfile();
      if (act === 'save-turn') return saveTurn();
      if (act === 'report') return sendReport();
    } catch (err) {
      state.error = err.message;
      toast(err.message);
      if (!session || !cfg) render();
    }
  }

  async function saveConfigForm() {
    var url = normaliseUrl($('cfg-url').value);
    var key = $('cfg-key').value.trim();
    var problem = configError(url, key);
    if (problem) { state.error = problem; render(); return; }
    saveTurnPass(($('cfg-turn-pass') && $('cfg-turn-pass').value) || '');
    saveConfig({
      url: url,
      anonKey: key,
      turnUrl: ($('cfg-turn') && $('cfg-turn').value) || '',
      turnUser: ($('cfg-turn-user') && $('cfg-turn-user').value) || '',
    });
    state.error = '';
    render();
    await finishPending();
  }

  async function doLogin() {
    var data = await api('/auth/v1/token?grant_type=password', {
      method: 'POST',
      auth: false,
      body: { email: $('email').value.trim().toLowerCase(), password: $('password').value },
    });
    applyTokenResponse(data);
    await enterApp();
  }

  async function doRegister() {
    var username = $('username').value.trim().toLowerCase();
    var userErr = L.usernameError(username);
    var passErr = L.passwordError($('password').value);
    if (userErr || passErr) { state.error = userErr || passErr; render(); return; }
    var data = await api('/auth/v1/signup?redirect_to=' + encodeURIComponent(L.pageAddress()), {
      method: 'POST',
      auth: false,
      body: {
        email: $('email').value.trim().toLowerCase(),
        password: $('password').value,
        data: { username: username, display_name: $('display').value.trim() },
        options: {
          email_redirect_to: L.pageAddress(),
          data: { username: username, display_name: $('display').value.trim() },
        },
      },
    });
    var user = data.user || data;
    var identities = user && user.identities;
    if (user && Array.isArray(identities) && identities.length === 0) {
      state.error = 'That email is already registered. Sign in instead.';
      state.authMode = 'login';
      render();
      return;
    }
    if (data.access_token || (data.session && data.session.access_token)) {
      applyTokenResponse(data.session || data);
      await enterApp();
      return;
    }
    state.notice = 'Check your email and open the link in this browser. If the link is refused, add this page’s address to Supabase Redirect URLs: ' + L.pageAddress();
    state.authMode = 'login';
    render();
  }

  async function doReset() {
    await api('/auth/v1/recover?redirect_to=' + encodeURIComponent(L.pageAddress()), {
      method: 'POST',
      auth: false,
      body: { email: $('email').value.trim().toLowerCase() },
    });
    state.notice = 'Reset email sent. Open it in this browser.';
    state.authMode = 'login';
    render();
  }

  async function doNewPassword() {
    var err = L.passwordError($('new-pass').value);
    if (err) { state.error = err; render(); return; }
    await api('/auth/v1/user', { method: 'PUT', body: { password: $('new-pass').value } });
    state.recovery = false;
    toast('Password saved. The phone can use it too.');
    await enterApp();
  }

  async function doSearch() {
    var q = $('q') && $('q').value;
    try {
      await searchUsers(q);
      var box = $('results');
      if (box) box.innerHTML = state.pane === 'group' ? groupPaneResults() : resultsHtml();
    } catch (err) { toast(err.message); }
  }

  async function saveProfile() {
    await api('/rest/v1/profiles?id=eq.' + me(), {
      method: 'PATCH',
      body: { display_name: $('display').value.trim(), bio: $('bio').value.trim() || null },
    });
    await loadProfile();
    toast('Profile saved.');
    render();
  }

  function saveTurn() {
    cfg.turnUrl = $('turn').value;
    cfg.turnUser = $('turn-user').value;
    saveTurnPass($('turn-pass').value);
    saveConfig(cfg);
    toast('Relay saved in this browser tab.');
  }

  async function sendReport() {
    await reportUser(state.reportUserId, $('reason').value, $('details').value.trim());
    state.pane = 'thread';
    render();
  }

  async function onChange(ev) {
    var el = ev.target;
    if (el.dataset.act === 'file' && el.files && el.files[0]) {
      await sendFile(el.files[0]);
      el.value = '';
      return;
    }
    if (el.dataset.act === 'privacy') {
      var body = {};
      body[el.dataset.key] = el.checked;
      try {
        await api('/rest/v1/profiles?id=eq.' + me(), { method: 'PATCH', body: body });
        if (state.profile) state.profile[el.dataset.key] = el.checked;
      } catch (err) { toast(err.message); el.checked = !el.checked; }
    }
    if (el.dataset.act === 'share-seen') {
      state.shareLastSeen = el.checked;
      try { await touchPresence(el.checked); }
      catch (err) { toast(err.message); el.checked = !el.checked; }
    }
  }

  function onKeydown(ev) {
    if (ev.key === 'Enter' && !ev.shiftKey && ev.target.id === 'draft') {
      ev.preventDefault();
      sendText();
    }
  }

  function onInput(ev) {
    if (ev.target.id !== 'draft') return;
    sendTyping(true);
    clearTimeout(typingTimer);
    typingTimer = setTimeout(function () { sendTyping(false); }, 2000);
  }

  async function enterApp() {
    state.recovery = false;
    state.error = '';
    state.notice = '';
    connectSocket();
    subscribeInbox();
    try { await loadProfile(); } catch (err) { toast(err.message); }
    await loadChats(true);
    touchPresence();
    clearInterval(presenceTimer);
    presenceTimer = setInterval(function () {
      touchPresence();
      refreshPresence();
      pollIncoming();
      loadChats(true);
    }, 30000);
    clearInterval(state.incomingTimer);
    state.incomingTimer = setInterval(pollIncoming, 4000);
    state.pane = 'list';
    render();
    pollIncoming();
  }

  async function finishPending() {
    var raw = sessionStorage.getItem(PENDING_KEY);
    if (!raw || !cfg) return;
    sessionStorage.removeItem(PENDING_KEY);
    var pending;
    try { pending = JSON.parse(raw); } catch (err) { return; }
    await consumeLink(pending);
  }

  async function consumeLink(link) {
    if (!link) return;
    if (link.kind === 'error') {
      state.error = link.error || 'That email link is no longer valid.';
      render();
      return;
    }
    try {
      if (link.kind === 'token') {
        var verified = await api('/auth/v1/verify', {
          method: 'POST',
          auth: false,
          body: { token_hash: link.tokenHash, type: link.type || 'signup' },
        });
        applyTokenResponse(verified.session || verified);
      } else if (link.access) {
        saveSession({ access: link.access, refresh: link.refresh, expiresAt: Date.now() + 3600 * 1000, user: null });
        var user = await api('/auth/v1/user');
        session.user = user;
        saveSession(session);
      }
      if (link.kind === 'recovery' || link.type === 'recovery') state.recovery = true;
      if (state.recovery) { render(); return; }
      await enterApp();
    } catch (err) {
      state.error = err.message;
      render();
    }
  }

  function cleanAddress() {
    if (location.hash || /token_hash|access_token|error/.test(location.search)) {
      history.replaceState(null, '', location.pathname);
    }
  }

  async function boot() {
    cfg = loadConfig();
    session = loadSession();
    var link = L.parseAuthLink(location.href);
    cleanAddress();
    document.body.addEventListener('click', onClick);
    document.body.addEventListener('submit', onSubmit);
    document.body.addEventListener('change', onChange);
    document.body.addEventListener('keydown', onKeydown);
    document.body.addEventListener('input', onInput);
    startHeartbeat();
    if (link) {
      if (!cfg) {
        sessionStorage.setItem(PENDING_KEY, JSON.stringify(link));
        state.notice = '';
        render();
        return;
      }
      await consumeLink(link);
      return;
    }
    render();
    if (cfg && session && session.access) {
      try {
        if (session.expiresAt && Date.now() > session.expiresAt - 60000) {
          if (!await refreshSession()) throw new Error('expired');
        }
        var user = await api('/auth/v1/user');
        session.user = user;
        saveSession(session);
        await enterApp();
      } catch (err) {
        await signOutLocal();
      }
    }
  }

  boot();
})();
