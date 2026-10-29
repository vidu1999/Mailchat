/* MailChat in the browser.
   Same Supabase project as the Flutter phone app: same accounts, chats,
   groups, attachments, Updates and call rows. A call from this page rings the phone,
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
    callHistory: [],
    notifications: [],
    notificationUnread: 0,
    callHistoryLoading: false,
    callPicking: false,
    callVideo: false,
    statuses: [],
    statusLoading: false,
    statusPublishing: false,
    statusFile: null,
    statusFileUrl: '',
    viewingStatusId: null,
    pendingFiles: [],
    sendingFiles: false,
    chatFilter: 'All',
    chatKind: 'All chats',
    chatQuery: '',
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

  async function saveCallStatus(id, status, answer) {
    var body = { p_call_id: id, p_status: status };
    if (answer) body.p_answer_sdp = answer;
    try {
      await api('/rest/v1/rpc/set_call_status', { method: 'POST', body: body });
    } catch (err) {
      if (!L.rpcMissing(err && err.message)) throw err;
      var patch = { status: status };
      if (answer) patch.answer_sdp = answer;
      await api('/rest/v1/calls?id=eq.' + id, { method: 'PATCH', body: patch });
    }
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
    discardPendingFiles();
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
    join('realtime:mailchat:web:notifications:' + me(), {
      postgres_changes: [{
        event: 'INSERT', schema: 'public', table: 'user_notifications', filter: 'user_id=eq.' + me(),
      }],
    }, function () {
      loadNotifications().then(function () {
        if (state.pane === 'notifications') render();
        else toast('New MailChat notification');
      }).catch(function () {});
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

  async function loadCallHistory() {
    state.callHistoryLoading = true;
    render();
    try {
      var filter = encodeURIComponent('(caller_id.eq.' + me() + ',callee_id.eq.' + me() + ')');
      var data = await api('/rest/v1/calls?select=*&or=' + filter + '&order=created_at.desc&limit=100');
      state.callHistory = rowsOf(data);
      var ids = [];
      state.callHistory.forEach(function (row) {
        var peer = row.caller_id === me() ? row.callee_id : row.caller_id;
        if (peer && !names[peer]) ids.push(peer);
      });
      ids = Array.from(new Set(ids));
      if (ids.length) {
        var profileFilter = encodeURIComponent('(' + ids.join(',') + ')');
        var profiles = await api('/rest/v1/profiles?select=id,username,display_name,avatar_path&id=in.' + profileFilter);
        rowsOf(profiles).forEach(function (profile) { names[profile.id] = profile; });
      }
    } catch (err) { toast('Could not load calls: ' + err.message); }
    state.callHistoryLoading = false;
    render();
  }

  async function loadStatuses() {
    state.statusLoading = true;
    render();
    try {
      var now = encodeURIComponent(new Date().toISOString());
      var data = await api('/rest/v1/user_statuses?select=*&expires_at=gt.' + now + '&order=created_at.desc&limit=100');
      var rows = rowsOf(data);
      var ids = Array.from(new Set(rows.map(function (row) { return row.user_id; })));
      var profileMap = {};
      if (ids.length) {
        var profileFilter = encodeURIComponent('(' + ids.join(',') + ')');
        rowsOf(await api('/rest/v1/profiles?select=id,username,display_name,avatar_path&id=in.' + profileFilter)).forEach(function (profile) {
          profileMap[profile.id] = profile;
        });
      }
      var statusIds = rows.map(function (row) { return row.id; });
      var views = statusIds.length ? rowsOf(await api('/rest/v1/user_status_views?select=status_id,viewer_id&status_id=in.' + encodeURIComponent('(' + statusIds.join(',') + ')'))) : [];
      state.statuses = rows.map(function (row) {
        var rowViews = views.filter(function (view) { return view.status_id === row.id; });
        return Object.assign({}, row, {
          profile: profileMap[row.user_id] || {},
          viewedByMe: rowViews.some(function (view) { return view.viewer_id === me(); }),
          viewerCount: rowViews.length,
        });
      });
    } catch (err) {
      state.statuses = [];
      toast('Could not load updates: ' + err.message);
    }
    state.statusLoading = false;
    render();
  }

  function statusRowsFor(userId) {
    return state.statuses.filter(function (row) { return row.user_id === userId; });
  }

  function statusName(row) {
    var profile = row.profile || {};
    return profile.display_name || profile.username || 'MailChat member';
  }

  function statusAvatar(profile) {
    var path = profile && profile.avatar_path;
    if (!path) return '';
    if (/^https?:\/\//i.test(path)) return '<img src="' + L.esc(path) + '" alt="">';
    return '<img data-path="' + L.esc(path) + '" data-bucket="avatars" alt="">';
  }

  function statusAge(value) {
    var minutes = Math.max(0, Math.floor((Date.now() - Date.parse(value)) / 60000));
    return minutes < 1 ? 'just now' : minutes < 60 ? minutes + ' min ago' : Math.floor(minutes / 60) + ' hr ago';
  }

  function statusPane() {
    var own = statusRowsFor(me());
    var people = [];
    state.statuses.forEach(function (row) { if (row.user_id !== me() && !people.some(function (p) { return p.id === row.user_id; })) people.push({ id: row.user_id, row: row }); });
    var recent = state.statusLoading ? '<div class="empty"><h2>Loading updates…</h2></div>' :
      (!people.length ? '<div class="empty"><h2>No updates yet</h2><p>Updates from people you have a direct MailChat conversation with appear here.</p></div>' :
        people.map(function (person) {
          var items = statusRowsFor(person.id);
          var unseen = items.some(function (item) { return !item.viewedByMe; });
          var row = items[0];
          var profile = row.profile || {};
          var avatar = statusAvatar(profile);
          return '<button type="button" class="person status-person" data-act="status-view" data-id="' + L.esc(row.id) + '"><span class="avatar status-avatar ' + (unseen ? 'unseen' : '') + '">' + avatar + L.esc(String(statusName(row)).slice(0, 1).toUpperCase()) + '</span><span class="call-copy"><strong>' + L.esc(statusName(row)) + '</strong><span class="sub">' + items.length + ' update' + (items.length === 1 ? '' : 's') + ' · ' + L.esc(statusAge(row.created_at)) + '</span></span><span class="status-dots">' + items.length + '</span></button>';
        }).join(''));
    var staged = state.statusFile ? '<div class="status-photo-stage"><img src="' + L.esc(state.statusFileUrl) + '" alt="Photo preview"><button type="button" class="btn ghost" data-act="status-remove-photo">Remove photo</button></div>' : '';
    var ownTile = own.length ? '<button type="button" class="person status-person" data-act="status-view" data-id="' + L.esc(own[0].id) + '"><span class="avatar status-avatar">' + L.esc(String((state.profile && (state.profile.display_name || state.profile.username)) || 'M').slice(0, 1).toUpperCase()) + '</span><span class="call-copy"><strong>My status</strong><span class="sub">' + own.length + ' active update' + (own.length === 1 ? '' : 's') + ' · tap to view</span></span><span class="icon-btn status-add-mark">＋</span></button>' : '<div class="person status-person"><span class="avatar status-avatar">' + L.esc(String((state.profile && (state.profile.display_name || state.profile.username)) || 'M').slice(0, 1).toUpperCase()) + '</span><span class="call-copy"><strong>My status</strong><span class="sub">Share a photo or text update</span></span><label class="icon-btn status-file-label" title="Add photo">＋<input type="file" accept="image/*" data-act="status-file"></label></div>';
    return panelHead('Updates') + '<div class="panel status-panel"><h2>Status</h2>' + ownTile + '<div class="status-compose"><h3>Share an update</h3><textarea id="status-text" maxlength="700" placeholder="What’s new? Add text or choose a photo…"></textarea><div class="row status-compose-actions"><label class="btn ghost status-file-label">Photo<input type="file" accept="image/*" data-act="status-file"></label><input id="status-color" type="color" value="#6366f1" aria-label="Text background"><button class="btn" type="button" data-act="status-publish">Share update</button></div>' + staged + '<p class="tiny">Visible to your direct MailChat conversations · expires after 24 hours.</p></div><h2 class="status-recent-title">Recent updates</h2>' + recent + '</div>';
  }

  function statusViewerPane() {
    var row = state.statuses.filter(function (item) { return item.id === state.viewingStatusId; })[0];
    if (!row) return panelHead('Update') + '<div class="empty"><h2>This update is no longer available</h2></div>';
    var color = (Number(row.background_color || 4284704497) >>> 0).toString(16).slice(-6);
    var content = row.status_type === 'image'
      ? '<img class="status-view-image" data-path="' + L.esc(row.media_path) + '" data-bucket="status-media" data-expires-in="300" alt="Shared update">'
      : '<div class="status-view-text" style="background:#' + color + '">' + L.esc(row.text || '') + '</div>';
    return panelHead('Update') + '<div class="status-viewer"><div class="status-view-head"><span class="avatar status-avatar">' + L.esc(String(statusName(row)).slice(0, 1).toUpperCase()) + '</span><span><strong>' + L.esc(statusName(row)) + '</strong><small>' + L.esc(statusAge(row.created_at)) + '</small></span><button class="icon-btn" data-act="status-close">×</button></div>' + content + (row.text && row.status_type === 'image' ? '<p class="status-caption">' + L.esc(row.text) + '</p>' : '') + (row.user_id === me() ? '<p class="tiny">' + row.viewerCount + ' views</p>' : '') + '<div class="row"><button class="btn ghost" data-act="status-prev">Previous</button><button class="btn" data-act="status-next">Next</button></div></div>';
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

  async function openChat(id, deepLink) {
    if (state.sendingFiles) { toast('Wait for the files to finish sending.'); return; }
    if (state.thread && state.thread.id !== id) discardPendingFiles();
    var chat = state.chats.filter(function (item) { return item.id === id || item.conversation_id === id; })[0];
    deepLink = deepLink || {};
    state.pane = 'thread';
    state.reply = null;
    state.editing = null;
    state.openMessage = null;
    state.info = false;
    state.thread = {
      id: id,
      title: chat ? chatTitle(chat) : (deepLink.conversationName || deepLink.title || 'Chat'),
      type: chat && chat.conversation ? chat.conversation.type : (deepLink.conversationType || 'direct'),
      peerId: chat ? chatPeer(chat) : (deepLink.conversationType === 'direct' ? deepLink.actorId : null),
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
        await api(
          '/rest/v1/message_receipts?on_conflict=message_id,recipient_id',
          {
            method: 'POST',
            prefer: 'resolution=merge-duplicates,return=minimal',
            body: {
              message_id: msg.id,
              recipient_id: me(),
              delivered_at: now,
              read_at: now,
            },
          }
        );
      } catch (err) { /* a missed tick is not a failed send */ }
    }
  }

  async function sendText() {
    var box = $('draft');
    if (!box || !state.thread) return;
    var text = box.value.trim();
    if (!text && !state.pendingFiles.length) return;
    if (text.length > 4000) { toast('Message is too long.'); return; }
    if (state.editing && state.pendingFiles.length) {
      toast('Send or remove staged files before editing a message.');
      return;
    }
    var send = $('send');
    if (send) send.disabled = true;
    if (state.pendingFiles.length) {
      var threadId = state.thread.id;
      state.sendingFiles = true;
      if (send) { send.disabled = true; send.textContent = 'Sending…'; }
      if (box) box.readOnly = true;
      var fileInput = $('file');
      if (fileInput) fileInput.disabled = true;
      try {
        var files = state.pendingFiles.slice();
        var uploaded = [];
        for (var i = 0; i < files.length; i++) {
          var item = files[i];
          var safe = L.sanitiseFileName(item.file.name);
          var path = threadId + '/' + Date.now() + '_' + i + '_' + safe;
          await api('/storage/v1/object/attachments/' + path.split('/').map(encodeURIComponent).join('/'), {
            method: 'POST', body: await item.file.arrayBuffer(),
            headers: { 'Content-Type': item.mime, 'x-upsert': 'false' },
            prefer: 'return=minimal',
          });
          uploaded.push({ path: path, name: safe, mime: item.mime, size: item.file.size });
        }
        var allImages = uploaded.every(function (file) { return file.mime.indexOf('image/') === 0; });
        var body = {
          conversation_id: threadId,
          sender_id: me(),
          type: allImages ? 'image' : 'file',
          text: text || null,
          client_id: (crypto.randomUUID && crypto.randomUUID()) || String(Date.now()),
        };
        if (state.reply) body.reply_to_message_id = state.reply.id;
        var inserted = await api('/rest/v1/messages', { method: 'POST', body: body });
        var message = rowsOf(inserted)[0];
        if (!message) throw new Error('The message was not created.');
        for (var j = 0; j < uploaded.length; j++) {
          var file = uploaded[j];
          await api('/rest/v1/message_attachments', {
            method: 'POST',
            body: {
              message_id: message.id,
              storage_path: file.path,
              file_name: file.name,
              mime_type: file.mime,
              file_size: file.size,
            },
          });
        }
        box.value = '';
        state.reply = null;
        discardPendingFiles();
        sendTyping(false);
        render();
        await loadThread(threadId, true);
        loadChats(true);
      } catch (err) { toast(err.message); }
      state.sendingFiles = false;
      var currentSend = $('send');
      if (currentSend) { currentSend.disabled = false; currentSend.textContent = 'Send'; }
      var currentDraft = $('draft');
      if (currentDraft) currentDraft.readOnly = false;
      var currentFileInput = $('file');
      if (currentFileInput) currentFileInput.disabled = false;
      return;
    }
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

  function stageFiles(fileList) {
    var files = Array.prototype.slice.call(fileList || []);
    if (state.pendingFiles.length + files.length > 10) {
      toast('You can attach up to 10 files to one message.');
      files = files.slice(0, Math.max(0, 10 - state.pendingFiles.length));
    }
    files.forEach(function (file) {
      if (!file.size) { toast(file.name + ' is empty.'); return; }
      if (file.size > 10 * 1024 * 1024) { toast(file.name + ' is over 10 MB.'); return; }
      var ext = (file.name.split('.').pop() || '').toLowerCase();
      var known = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', heic: 'image/heic' };
      var mime = file.type || known[ext] || 'application/octet-stream';
      state.pendingFiles.push({ file: file, mime: mime, previewUrl: URL.createObjectURL(file) });
    });
    render();
    var draft = $('draft');
    if (draft) draft.focus();
  }

  function removePendingFile(index) {
    var item = state.pendingFiles[index];
    if (!item) return;
    URL.revokeObjectURL(item.previewUrl);
    state.pendingFiles.splice(index, 1);
    render();
  }


  async function signedUrl(path, bucket, expiresIn) {
    bucket = bucket || 'attachments';
    expiresIn = Number(expiresIn) || 3600;
    var data = await api(
      '/storage/v1/object/sign/' + encodeURIComponent(bucket) + '/' + path.split('/').map(encodeURIComponent).join('/'),
      { method: 'POST', body: { expiresIn: expiresIn } }
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
    if (!L.ringIsFresh(row.created_at)) {
      clearStaleRing(row.id);
      return;
    }
    var already = state.incoming && state.incoming.id === row.id;
    state.incoming = row;
    var box = $('incoming');
    if (!box) return;
    box.hidden = false;
    $('incoming-title').textContent = row.kind === 'video' ? 'Incoming video call' : 'Incoming voice call';
    var person = names[row.caller_id];
    $('incoming-detail').textContent = (person && (person.display_name || person.username)) || 'Someone in your chats';
    if (already) return;
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

  function clearStaleRing(id) {
    if (!id || dismissedCalls[id]) return;
    dismissedCalls[id] = true;
    saveCallStatus(id, 'missed').catch(function () { /* already cleared, or the other side ended it */ });
  }

  async function pollIncoming() {
    if (!session) return;
    try {
      var data = await api(
        '/rest/v1/calls?or=(caller_id.eq.' + me() + ',callee_id.eq.' + me() + ')' +
        '&status=eq.ringing&select=*&order=created_at.desc&limit=5'
      );
      var rows = rowsOf(data);
      var shown = false;
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        var incoming = row.callee_id === me();
        if (L.ringShouldClear(row.created_at, incoming)) {
          clearStaleRing(row.id);
          if (state.incoming && state.incoming.id === row.id) hideIncoming();
          continue;
        }
        if (!shown && incoming) {
          considerIncoming(row);
          shown = true;
        }
      }
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
      iceTransportPolicy: 'all',
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
    return 'Different networks use the built-in relay. Turn off any VPN and Data saver on both sides. Same Wi-Fi can also connect directly.';
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
        await call.pc.setRemoteDescription({ type: 'answer', sdp: L.sdpForPhone(row.answer_sdp) });
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
      var offerSdp = L.sdpForPhone(local);
      var inserted;
      try {
        inserted = await api('/rest/v1/rpc/place_call', {
          method: 'POST',
          body: {
            p_conversation_id: conversationId,
            p_callee_id: peerId,
            p_kind: video ? 'video' : 'voice',
            p_offer_sdp: offerSdp,
          },
        });
      } catch (err) {
        if (!L.rpcMissing(err && err.message)) throw err;
        inserted = await api('/rest/v1/calls', {
          method: 'POST',
          body: {
            conversation_id: conversationId,
            caller_id: me(),
            callee_id: peerId,
            kind: video ? 'video' : 'voice',
            status: 'ringing',
            offer_sdp: offerSdp,
          },
        });
      }
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
      await pc.setRemoteDescription({ type: 'offer', sdp: L.sdpForPhone(fresh.offer_sdp) });
      call.remoteSet = true;
      var answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await waitGather(pc);
      var local = pc.localDescription && pc.localDescription.sdp;
      await saveCallStatus(fresh.id, 'accepted', L.sdpForPhone(local));
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
      await saveCallStatus(incoming.id, 'declined');
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
      await saveCallStatus(id, status);
    } catch (err) {
      if (status !== 'failed') {
        try { await saveCallStatus(id, 'failed'); }
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
      '<button type="button" class="icon-btn" data-act="go" data-pane="notifications" title="Notifications">♧' +
      (state.notificationUnread ? '<span class="notification-count">' + L.esc(String(state.notificationUnread)) + '</span>' : '') + '</button>' +
      '<button type="button" class="icon-btn" data-act="go" data-pane="search" title="New chat">＋</button>' +
      '<button type="button" class="icon-btn" data-act="go" data-pane="settings" title="Settings">⚙</button></div>' +
      '<div class="search-wrap"><div class="sub">' + L.esc(profile.display_name || profile.username || session.user.email || '') + '</div>' +
      '<input id="chat-search" placeholder="Search or start a new chat" value="' + L.esc(state.chatQuery) + '" autocomplete="off">' +
      '<div class="chat-filters">' + ['All', 'Unread', 'Favourites'].map(function (name) {
        var label = name === 'Unread' ? 'Unread ' + state.chats.reduce(function (total, chat) {
          return total + (Number(chat.unread_count) || 0);
        }, 0) : name;
        return '<button type="button" class="filter-chip' + (state.chatFilter === name ? ' on' : '') +
          '" data-act="chat-filter" data-filter="' + name + '">' + L.esc(label) + '</button>';
      }).join('') +
      '<select id="chat-kind" aria-label="Chat type"><option' + (state.chatKind === 'All chats' ? ' selected' : '') + '>All chats</option>' +
      '<option' + (state.chatKind === 'Direct' ? ' selected' : '') + '>Direct</option>' +
      '<option' + (state.chatKind === 'Groups' ? ' selected' : '') + '>Groups</option></select></div></div>' +
      '<div class="list" id="chat-list">' + chatsHtml() + '</div>' +
      '<nav class="side-nav"><button type="button" data-act="go" data-pane="list">▣ <span>Chats</span></button>' +
      '<button type="button" data-act="go" data-pane="notifications">♧ <span>Notifications' +
      (state.notificationUnread ? ' (' + L.esc(String(state.notificationUnread)) + ')' : '') + '</span></button>' +
      '<button type="button" data-act="go" data-pane="status">◉ <span>Updates</span></button>' +
      '<button type="button" data-act="go" data-pane="calls">☎ <span>Calls</span></button></nav>';
  }

  function filteredChats() {
    var query = String(state.chatQuery || '').trim().toLowerCase();
    return state.chats.filter(function (chat) {
      var unread = Number(chat.unread_count) || 0;
      var group = chat.conversation && chat.conversation.type === 'group';
      if (state.chatFilter === 'Unread' && unread <= 0) return false;
      if (state.chatFilter === 'Favourites' && !chat.is_favorite) return false;
      if (state.chatKind === 'Direct' && group) return false;
      if (state.chatKind === 'Groups' && !group) return false;
      if (query && (chatTitle(chat) + ' ' + previewText(chat)).toLowerCase().indexOf(query) < 0) return false;
      return true;
    }).sort(function (a, b) {
      if (!!a.is_pinned !== !!b.is_pinned) return a.is_pinned ? -1 : 1;
      return Date.parse(b.last_message_at || 0) - Date.parse(a.last_message_at || 0);
    });
  }

  function chatsHtml() {
    var chats = filteredChats();
    if (!chats.length) {
      var empty = state.chatFilter === 'Favourites' ? 'No favourite chats yet' :
        (state.chats.length ? 'No matching chats' : 'No chats yet');
      return '<div class="empty"><h2>' + L.esc(empty) + '</h2><p>' +
        (state.chats.length ? 'Try another filter or search term.' : 'Tap ＋ and search by username or the other person’s exact email.') + '</p></div>';
    }
    return chats.map(function (chat) {
      var id = chat.id || chat.conversation_id;
      var peer = chatPeer(chat);
      var online = peer && state.presence[peer] && state.presence[peer].online === true;
      var unread = Number(chat.unread_count) || 0;
      var initial = chatTitle(chat).slice(0, 1).toUpperCase();
      var stamp = chat.last_message_at ? L.dayLabel(chat.last_message_at) : '';
      if (stamp === 'Today') stamp = L.messageTime(chat.last_message_at);
      var preview = chat.last_message_sender_id === me() ? '✓ ' + previewText(chat) : previewText(chat);
      return '<button type="button" class="chat' + (state.thread && state.thread.id === id ? ' on' : '') +
        '" data-act="open" data-id="' + L.esc(id) + '"><span class="avatar">' + L.esc(initial) +
        (online ? '<i class="dot"></i>' : '') + '</span><span class="chat-copy"><span class="chat-topline"><span class="chat-name">' +
        L.esc(chatTitle(chat)) + '</span><span class="chat-stamp">' + L.esc(stamp) + '</span></span><span class="chat-bottomline"><span class="chat-preview">' +
        L.esc(preview) + '</span><span class="chat-indicators">' + (chat.is_pinned ? '📌' : '') + (chat.is_muted ? '🔕' : '') +
        (unread ? '<span class="badge">' + (unread > 99 ? '99+' : unread) + '</span>' : '') + '</span></span></span>' +
        '<span class="chat-actions"><span role="button" tabindex="0" title="' + (chat.is_favorite ? 'Remove favourite' : 'Add favourite') +
        '" data-act="chat-pref" data-id="' + L.esc(id) + '" data-pref="favorite">' + (chat.is_favorite ? '★' : '☆') + '</span>' +
        '<span role="button" tabindex="0" title="' + (chat.is_pinned ? 'Unpin chat' : 'Pin chat') +
        '" data-act="chat-pref" data-id="' + L.esc(id) + '" data-pref="pin">' + (chat.is_pinned ? '📌' : '⋯') + '</span></span></button>';
    }).join('');
  }

  function mainHtml() {
    if (state.pane === 'notifications') return notificationsPane();
    if (state.pane === 'calls') return callHistoryPane();
    if (state.pane === 'status') return statusPane();
    if (state.pane === 'status-viewer') return statusViewerPane();
    if (state.pane === 'search') return searchPane();
    if (state.pane === 'group') return groupPane();
    if (state.pane === 'settings') return settingsPane();
    if (state.pane === 'blocked') return blockedPane();
    if (state.pane === 'report') return reportPane();
    if (state.thread) return threadHtml();
    return '<div class="empty"><h2>Choose a chat</h2><p>Messages and calls here are the same ones on the phone.</p></div>';
  }


  async function loadNotifications() {
    if (!me()) return;
    var rows = await api('/rest/v1/user_notifications?select=*&user_id=eq.' +
      encodeURIComponent(me()) + '&order=created_at.desc&limit=100');
    state.notifications = rows || [];
    state.notificationUnread = state.notifications.filter(function (row) { return !row.read_at; }).length;
  }

  function notificationsPane() {
    var rows = state.notifications || [];
    var content = rows.length ? rows.map(function (row) {
      var stamp = '';
      try { stamp = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(row.created_at)); } catch (err) { stamp = row.created_at || ''; }
      return '<button type="button" class="person notification-row' + (row.read_at ? '' : ' notification-unread') +
        '" data-act="open-notification" data-id="' + L.esc(row.id) + '"><span class="avatar">' +
        (row.notification_type === 'missed_call' ? '☎' : row.notification_type === 'system' ? 'ⓘ' : '●') +
        '</span><span class="call-copy"><strong>' + L.esc(row.title || 'MailChat') + '</strong><span class="sub">' +
        L.esc(row.body || '') + ' · ' + L.esc(stamp) + '</span></span>' + (row.read_at ? '' : '<b>●</b>') + '</button>';
    }).join('') : '<div class="empty"><h2>You’re all caught up</h2><p>New messages, missed calls and conversation updates will appear here.</p></div>';
    return panelHead('Notifications') + '<div class="panel"><div class="row"><button type="button" class="btn ghost" data-act="notifications-read-all">Mark all read</button></div>' + content + '</div>';
  }

  function callHistoryPane() {
    var rows = state.callHistory || [];
    var content = state.callHistoryLoading ? '<div class="empty"><h2>Loading calls…</h2></div>' :
      (!rows.length ? '<div class="empty"><h2>No calls yet</h2><p>MailChat voice and video calls will appear here.</p></div>' :
        rows.map(function (row) {
          var outgoing = row.caller_id === me();
          var peerId = outgoing ? row.callee_id : row.caller_id;
          var person = names[peerId] || {};
          var name = person.display_name || person.username || 'MailChat member';
          var avatar = typeof person.avatar_path === 'string' && person.avatar_path
            ? (/^https?:\/\//i.test(person.avatar_path)
              ? '<img src="' + L.esc(person.avatar_path) + '" alt="">'
              : '<img data-path="' + L.esc(person.avatar_path) + '" data-bucket="avatars" alt="">')
            : '';
          var missed = row.status === 'missed' || row.status === 'declined' || row.status === 'failed';
          var kind = row.kind === 'video' ? 'Video' : 'Voice';
          var direction = row.status === 'missed' ? (outgoing ? 'No answer' : 'Missed') :
            row.status === 'declined' ? (outgoing ? 'Declined' : 'You declined') :
            row.status === 'failed' ? 'Could not connect' : (outgoing ? 'Outgoing' : 'Incoming');
          var stamp = '';
          try { stamp = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(row.created_at)); } catch (err) { stamp = row.created_at || ''; }
          return '<div class="person call-row"><span class="avatar">' + avatar + L.esc(String(name).slice(0, 1).toUpperCase()) + '</span>' +
            '<span class="call-copy"><strong class="' + (missed ? 'call-missed' : '') + '">' + L.esc(name) + '</strong><span class="sub">' + L.esc(direction + ' · ' + kind + ' call · ' + stamp) + '</span></span>' +
            '<button type="button" class="icon-btn" title="Call back" data-act="call-back" data-id="' + L.esc(row.conversation_id) + '" data-video="' + (row.kind === 'video') + '">' + (row.kind === 'video' ? '▣' : '☎') + '</button></div>';
        }).join(''));
    return panelHead('Calls') + '<div class="panel"><div class="row"><button type="button" class="btn" data-act="call-new" data-video="false">☎ Voice call</button><button type="button" class="btn ghost" data-act="call-new" data-video="true">▣ Video call</button></div>' + content + '</div>';
  }

  function searchPane() {
    var title = state.callPicking ? (state.callVideo ? 'Start a video call' : 'Start a voice call') : 'New chat';
    return panelHead(title) +
      '<div class="panel"><form data-act="search" class="row"><input id="q" placeholder="Username or exact email" autocomplete="off"><button class="btn" type="submit">Search</button></form>' +
      '<div id="results">' + resultsHtml() + '</div>' +
      (state.callPicking ? '' : '<button type="button" class="btn ghost full" data-act="go" data-pane="group">New group</button>') + '</div>';
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
      pendingFilesHtml() +
      '<form class="composer" data-act="send"><label class="file-btn btn ghost">＋<input type="file" id="file" data-act="file" multiple' + (state.sendingFiles ? ' disabled' : '') + '></label>' +
      '<textarea id="draft" rows="1" placeholder="Message"' + (state.sendingFiles ? ' readonly' : '') + '></textarea>' +
      '<button class="btn" id="send" type="submit"' + (state.sendingFiles ? ' disabled' : '') + '>' +
      (state.sendingFiles ? 'Sending…' : 'Send') + '</button></form></div>';
  }

  function pendingFilesHtml() {
    if (!state.pendingFiles.length) return '';
    return '<div class="pending-files">' + state.pendingFiles.map(function (item, index) {
      var preview = item.mime.indexOf('image/') === 0
        ? '<img src="' + L.esc(item.previewUrl) + '" alt="' + L.esc(item.file.name) + '">'
        : '<span class="pending-file-icon">📎</span><span class="pending-file-name">' + L.esc(item.file.name) + '</span>';
      return '<div class="pending-file">' + preview +
        '<button type="button" data-act="remove-pending-file" data-index="' + index + '" title="Remove">×</button></div>';
    }).join('') + '<span class="pending-hint">Send to share these files</span></div>';
  }

  function discardPendingFiles() {
    state.pendingFiles.forEach(function (item) { URL.revokeObjectURL(item.previewUrl); });
    state.pendingFiles = [];
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
      : (msg.text ? '<p>' + L.esc(msg.text) + '</p>' : '');
    var quote = '';
    if (msg.reply_to_message_id) {
      var parent = (state.thread.messages || []).filter(function (item) { return item.id === msg.reply_to_message_id; })[0];
      quote = '<div class="quote">' + L.esc(snippet(parent)) + '</div>';
    }
    var attachments = msg.deleted_at ? [] : (msg.message_attachments || []);
    var imageFiles = attachments.filter(function (file) {
      return (file.mime_type || '').indexOf('image/') === 0;
    });
    var otherFiles = attachments.filter(function (file) {
      return (file.mime_type || '').indexOf('image/') !== 0;
    });
    var files = (imageFiles.length
      ? '<div class="media-album">' + imageFiles.map(function (file) {
        return '<img class="preview" alt="' + L.esc(file.file_name) + '" data-act="open-file" data-path="' + L.esc(file.storage_path) + '">';
      }).join('') + '</div>' : '') + otherFiles.map(function (file) {
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
      '<div class="meta"><span>' + L.esc(L.messageTime(msg.created_at)) + (msg.edited_at ? ' · edited' : '') + '</span>' +
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
    document.querySelectorAll('.filter-chip').forEach(function (chip) {
      var name = chip.dataset.filter;
      var count = state.chats.reduce(function (total, chat) {
        return total + (Number(chat.unread_count) || 0);
      }, 0);
      chip.textContent = name === 'Unread' ? 'Unread ' + count : name;
      chip.classList.toggle('on', name === state.chatFilter);
    });
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
        var url = await signedUrl(node.dataset.path, node.dataset.bucket || 'attachments', node.dataset.expiresIn);
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
      if (state.sendingFiles) {
        toast('Wait for the files to finish sending.');
        return;
      }
      state.pane = el.dataset.pane;
      state.error = '';
      if (state.pane === 'calls') { await loadCallHistory(); return; }
      if (state.pane === 'notifications') { await loadNotifications(); render(); return; }
      if (state.pane === 'status') { await loadStatuses(); return; }
      if (state.pane === 'blocked') {
        try { await loadBlocked(); } catch (err) { toast(err.message); }
      }
      if (state.pane === 'settings') {
        try { await loadProfile(); } catch (err) { toast(err.message); }
      }
      render();
      return;
    }
    if (act === 'open-notification') {
      var notice = state.notifications.find(function (row) { return row.id === el.dataset.id; });
      if (!notice) return;
      try {
        if (!notice.read_at) await api('/rest/v1/user_notifications?id=eq.' + encodeURIComponent(notice.id), {
          method: 'PATCH', body: { read_at: new Date().toISOString() },
        });
        if (notice.notification_type === 'missed_call') {
          state.pane = 'calls';
          await loadCallHistory();
        } else {
          var targetConversation = notice.payload && notice.payload.conversationId;
          if (!targetConversation) { toast('This notification has no conversation link.'); return; }
          state.pane = 'thread';
          var deepLink = Object.assign({}, notice.payload || {}, { title: notice.title });
          await openChat(targetConversation, deepLink);
        }
        await loadNotifications();
        render();
      } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'notifications-read-all') {
      try {
        await api('/rest/v1/user_notifications?user_id=eq.' + encodeURIComponent(me()) + '&read_at=is.null', {
          method: 'PATCH', body: { read_at: new Date().toISOString() },
        });
        await loadNotifications(); render();
      } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'chat-filter') {
      state.chatFilter = el.dataset.filter;
      paintChats();
      var chips = document.querySelectorAll('.filter-chip');
      chips.forEach(function (chip) { chip.classList.toggle('on', chip.dataset.filter === state.chatFilter); });
      return;
    }
    if (act === 'chat-pref') {
      ev.preventDefault();
      ev.stopPropagation();
      var target = state.chats.filter(function (chat) { return (chat.id || chat.conversation_id) === el.dataset.id; })[0];
      if (!target) return;
      var field = el.dataset.pref === 'favorite' ? 'is_favorite' : 'is_pinned';
      try {
        await api('/rest/v1/conversation_members?conversation_id=eq.' + encodeURIComponent(el.dataset.id) +
          '&user_id=eq.' + encodeURIComponent(me()), {
            method: 'PATCH', body: (function () { var data = {}; data[field] = !target[field]; return data; })(),
          });
        await loadChats(true);
      } catch (err) { toast('Could not update chat preference: ' + err.message); }
      return;
    }
    if (act === 'remove-pending-file') {
      ev.preventDefault();
      ev.stopPropagation();
      removePendingFile(Number(el.dataset.index));
      return;
    }
    if (act === 'status-publish') { await publishStatus(); return; }
    if (act === 'status-remove-photo') { state.statusFile = null; if (state.statusFileUrl) URL.revokeObjectURL(state.statusFileUrl); state.statusFileUrl = ''; render(); return; }
    if (act === 'status-view') {
      state.viewingStatusId = el.dataset.id;
      state.pane = 'status-viewer';
      var viewed = state.statuses.filter(function (row) { return row.id === state.viewingStatusId; })[0];
      if (viewed && viewed.user_id !== me() && !viewed.viewedByMe) {
        api('/rest/v1/user_status_views', { method: 'POST', body: { status_id: viewed.id, viewer_id: me() } }).then(function () { viewed.viewedByMe = true; }).catch(function () {});
      }
      render();
      return;
    }
    if (act === 'status-close') { state.pane = 'status'; state.viewingStatusId = null; render(); return; }
    if (act === 'status-next' || act === 'status-prev') {
      var group = statusRowsFor((state.statuses.filter(function (row) { return row.id === state.viewingStatusId; })[0] || {}).user_id);
      var at = group.findIndex(function (row) { return row.id === state.viewingStatusId; });
      var nextIndex = at + (act === 'status-next' ? 1 : -1);
      if (nextIndex < 0) nextIndex = group.length - 1;
      if (nextIndex >= group.length) nextIndex = 0;
      state.viewingStatusId = group[nextIndex] && group[nextIndex].id;
      render();
      var current = state.statuses.filter(function (row) { return row.id === state.viewingStatusId; })[0];
      if (current && current.user_id !== me() && !current.viewedByMe) api('/rest/v1/user_status_views', { method: 'POST', body: { status_id: current.id, viewer_id: me() } }).then(function () { current.viewedByMe = true; }).catch(function () {});
      return;
    }
    if (act === 'open') { openChat(el.dataset.id); return; }
    if (act === 'call-new') { state.pane = 'search'; state.callPicking = true; state.callVideo = el.dataset.video === 'true'; state.search = []; render(); return; }
    if (act === 'call-back') {
      var chatId = el.dataset.id;
      var video = el.dataset.video === 'true';
      try { await openChat(chatId); if (!state.thread || state.thread.id !== chatId) return; await startCall(video); } catch (err) { toast(err.message); }
      return;
    }
    if (act === 'direct') {
      try {
        await openDirect(el.dataset.id);
        if (state.callPicking) { var videoCall = state.callVideo; state.callPicking = false; await startCall(videoCall); }
      } catch (err) { toast(err.message); }
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

  async function publishStatus() {
    if (state.statusPublishing) return;
    state.statusPublishing = true;
    var publishButton = document.querySelector('[data-act="status-publish"]');
    if (publishButton) { publishButton.disabled = true; publishButton.textContent = 'Sharing…'; }
    var userText = ($('status-text') && $('status-text').value || '').trim();
    try {
      if (state.statusFile) {
        if (state.statusFile.size > 10 * 1024 * 1024) throw new Error('Choose a photo under 10 MB.');
        if (!/^image\/(jpeg|png|webp|gif|heic)$/i.test(state.statusFile.type)) throw new Error('Choose a JPG, PNG, WEBP, GIF or HEIC photo.');
        var id = crypto.randomUUID();
        var extension = (state.statusFile.name.split('.').pop() || 'jpg').toLowerCase();
        var path = me() + '/' + id + '/photo.' + extension;
        var bytes = new Uint8Array(await state.statusFile.arrayBuffer());
        await api('/storage/v1/object/status-media/' + path.split('/').map(encodeURIComponent).join('/'), {
          method: 'POST', body: bytes,
          headers: { 'Content-Type': state.statusFile.type, 'x-upsert': 'false' },
        });
        var colorValue = $('status-color') ? parseInt($('status-color').value.slice(1), 16) : 0x6366f1;
        await api('/rest/v1/user_statuses', { method: 'POST', body: {
          id: id, user_id: me(), status_type: 'image', text: userText || null,
          media_path: path, background_color: 0xff000000 + colorValue,
        } });
      } else {
        if (!userText) throw new Error('Write something or choose a photo first.');
        if (userText.length > 700) throw new Error('Status is limited to 700 characters.');
        var color = $('status-color') ? parseInt($('status-color').value.slice(1), 16) : 0x6366f1;
        await api('/rest/v1/user_statuses', { method: 'POST', body: {
          user_id: me(), status_type: 'text', text: userText,
          background_color: 0xff000000 + color,
        } });
      }
      state.statusFile = null;
      if (state.statusFileUrl) URL.revokeObjectURL(state.statusFileUrl);
      state.statusFileUrl = '';
      toast('Update shared. It expires in 24 hours.');
      state.statusPublishing = false;
      await loadStatuses();
    } catch (err) {
      state.statusPublishing = false;
      if (publishButton) { publishButton.disabled = false; publishButton.textContent = 'Share update'; }
      toast('Could not share update: ' + err.message);
    }
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
    if (el.dataset.act === 'status-file' && el.files && el.files[0]) {
      if (state.statusFileUrl) URL.revokeObjectURL(state.statusFileUrl);
      state.statusFile = el.files[0];
      state.statusFileUrl = URL.createObjectURL(state.statusFile);
      state.pane = 'status';
      render();
      return;
    }
    if (el.dataset.act === 'file' && el.files && el.files.length) {
      stageFiles(el.files);
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
    if (el.id === 'chat-kind') {
      state.chatKind = el.value;
      paintChats();
    }
  }

  function onKeydown(ev) {
    if (ev.key === 'Enter' && !ev.shiftKey && ev.target.id === 'draft') {
      ev.preventDefault();
      sendText();
    }
  }

  function onInput(ev) {
    if (ev.target.id === 'chat-search') {
      state.chatQuery = ev.target.value;
      paintChats();
      return;
    }
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
    try { await loadNotifications(); } catch (err) { toast(err.message); }
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
