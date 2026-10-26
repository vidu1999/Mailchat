import 'dart:async';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/network/supabase_realtime.dart';
import 'package:mailchat/shared/models/peer_presence.dart';

/// Presence, typing indicators and the durable last-seen heartbeat.
///
/// Two different things live here, deliberately:
///
///   * **Ephemeral** — who is in *this conversation* right now, and who is
///     typing. Realtime broadcast/presence only; a "typing" row would be a write
///     per keystroke and an `is_online` boolean would be wrong the moment a phone
///     loses signal.
///   * **Durable** — `touchLastSeen()` writes a heartbeat row
///     (`user_presence`, migration 0008) and `presenceFor()` reads other people's
///     through `get_presence()`, which is what makes "last seen 10:41 AM" and the
///     chat list's online dots possible. Online means "heartbeat within 75 s",
///     not "a flag someone set".
///
/// See docs/architecture.md.
///
/// Channel shape, following Supabase's Realtime conventions:
///
/// ```text
/// topic: realtime:mailchat:presence:<conversationId>
/// join : config { broadcast: {self: false}, presence: {key: userId} }
/// out  : broadcast event "typing"  { user_id, typing }
/// in   : broadcast "typing", presence_state, presence_diff
/// ```
///
/// `self: false` keeps the sender's own events off their own channel, so the
/// person typing never sees "typing…" for themselves.
///
/// **Not verified against a live project.** The unit tests cover the parsing and
/// expiry logic; only a real two-device session can prove the Realtime server
/// accepts the join config.
class PresenceService {
  PresenceService({SupabaseRealtimeClient? realtime, SupabaseClient? client})
      : _realtime = realtime ?? SupabaseRealtimeClient.instance,
        _client = client ?? SupabaseClient.instance;

  final SupabaseRealtimeClient _realtime;
  final SupabaseClient _client;

  Channel? _channel;
  String? _userId;
  String? _conversationId;

  final StreamController<Set<String>> _onlineController =
      StreamController<Set<String>>.broadcast();
  final StreamController<Set<String>> _typingController =
      StreamController<Set<String>>.broadcast();

  /// User ids currently present in the conversation.
  Stream<Set<String>> get onlineUsers => _onlineController.stream;

  /// User ids currently typing. Expires on its own, so a dropped connection
  /// cannot leave someone "typing" forever.
  Stream<Set<String>> get typingUsers => _typingController.stream;

  final Set<String> _online = <String>{};
  final Set<String> _typing = <String>{};
  final Map<String, Timer> _expiry = <String, Timer>{};

  /// How long a typing event stays true without a repeat. The composer re-sends
  /// every few keystrokes; a shorter window flickers, a longer one lies.
  static const Duration typingTtl = Duration(seconds: 4);

  /// How often the app writes its own heartbeat while in the foreground.
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// How recent the last heartbeat must be for the user to count as online.
  ///
  /// Must match the `interval '75 seconds'` inside `public.get_presence()`
  /// (migration 0008), otherwise the dot and the "last seen" line disagree.
  static const Duration onlineWindow = Duration(seconds: 75);

  /// Writes this user's heartbeat. [share] also sets the privacy flag; null
  /// leaves it alone, which is what the periodic beat does.
  ///
  /// There is no client-side timestamp: the server stamps the row, so a wrong
  /// device clock cannot make someone look online or offline.
  Future<void> touchLastSeen({bool? share}) async {
    if (_client.userId == null) return;
    await _client.rpc(
      'touch_last_seen',
      params: {if (share != null) 'p_share': share},
    );
  }

  /// Presence for a set of other users, keyed by user id.
  ///
  /// The database decides what may be revealed: users with sharing off come
  /// back hidden, users you share no conversation with are not returned at all,
  /// and blocked pairs are filtered in both directions.
  Future<Map<String, PeerPresence>> presenceFor(Iterable<String> userIds) async {
    final ids = <String>{};
    for (final id in userIds) {
      if (id.isNotEmpty) ids.add(id);
    }
    if (ids.isEmpty || _client.userId == null) return const {};

    final raw = await _client.rpc(
      'get_presence',
      params: {'p_user_ids': ids.toList()},
    );
    final result = <String, PeerPresence>{};
    if (raw is! List) return result;
    for (final row in raw) {
      if (row is! Map) continue;
      final presence = PeerPresence.fromJson(Map<String, dynamic>.from(row));
      if (presence.userId.isEmpty) continue;
      result[presence.userId] = presence;
    }
    return result;
  }

  /// Whether this user shares their status, read from their own row. Defaults
  /// to true for an account that has never sent a heartbeat.
  Future<bool> sharesLastSeen() async {
    final userId = _client.userId;
    if (userId == null) return true;
    final rows = await _client.select(
      'user_presence',
      select: 'share_last_seen',
      filter: {'eq': 'user_id,$userId'},
      limit: 1,
    );
    if (rows.isEmpty) return true;
    return rows.first['share_last_seen'] as bool? ?? true;
  }

  bool get isJoined => _channel != null;

  void join({required String conversationId, required String userId}) {
    if (_channel != null &&
        _conversationId == conversationId &&
        _userId == userId) {
      return;
    }
    leave();
    _conversationId = conversationId;
    _userId = userId;
    _channel = _realtime.join(
      'realtime:mailchat:presence:$conversationId',
      _onEvent,
      config: {
        'broadcast': {'self': false},
        'presence': {'key': userId},
      },
    );
    AppLogger.info('presence_join', details: {'conversationId': conversationId});
  }

  /// Announces whether this user is typing. Called on a debounce by the
  /// composer, never per keystroke.
  void setTyping(bool typing) {
    final channel = _channel;
    final userId = _userId;
    final conversationId = _conversationId;
    if (channel == null || userId == null || conversationId == null) return;
    try {
      channel.send('broadcast', {
        'type': 'broadcast',
        'event': 'typing',
        'payload': {
          'user_id': userId,
          'conversation_id': conversationId,
          'typing': typing,
        },
      });
    } catch (e, st) {
      // A dropped socket is not worth interrupting the user over: the indicator
      // simply stops. Logged so it is not invisible.
      AppLogger.error(e, st, {'where': 'presence_typing_send'});
    }
  }

  void _onEvent(String event, Map<String, dynamic> payload) {
    switch (event) {
      case 'broadcast':
        final inner = payload['payload'];
        if (payload['event'] == 'typing' && inner is Map) {
          _handleTyping(Map<String, dynamic>.from(inner));
        }
        break;
      case 'presence_state':
        _online
          ..clear()
          ..addAll(parsePresenceState(payload));
        _emitOnline();
        break;
      case 'presence_diff':
        _applyPresenceDiff(payload);
        break;
    }
  }

  void _handleTyping(Map<String, dynamic> payload) {
    final userId = payload['user_id'];
    if (userId is! String || userId.isEmpty || userId == _userId) return;
    final typing = payload['typing'] != false;

    _expiry.remove(userId)?.cancel();
    if (!typing) {
      if (_typing.remove(userId)) _emitTyping();
      return;
    }
    _typing.add(userId);
    _emitTyping();
    _expiry[userId] = Timer(typingTtl, () {
      if (_typing.remove(userId)) _emitTyping();
    });
  }

  /// `presence_state` is `{ "<key>": { metas: [...] }, ... }`.
  static Set<String> parsePresenceState(Map<String, dynamic> payload) {
    final ids = <String>{};
    for (final entry in payload.entries) {
      final metas = entry.value is Map ? (entry.value as Map)['metas'] : null;
      if (metas is List && metas.isNotEmpty) {
        for (final meta in metas) {
          if (meta is Map && meta['phx_ref'] != null) {
            ids.add(entry.key);
            break;
          }
        }
      } else if (metas == null) {
        // Some server versions send the key alone; the key is the user id.
        ids.add(entry.key);
      }
    }
    return ids;
  }

  void _applyPresenceDiff(Map<String, dynamic> payload) {
    final joins = payload['joins'];
    if (joins is Map) _online.addAll(parsePresenceState(Map<String, dynamic>.from(joins)));
    final leaves = payload['leaves'];
    if (leaves is Map) {
      _online.removeAll(parsePresenceState(Map<String, dynamic>.from(leaves)));
    }
    _emitOnline();
  }

  void _emitOnline() {
    if (!_onlineController.isClosed) {
      _onlineController.add(Set<String>.unmodifiable(_online));
    }
  }

  void _emitTyping() {
    if (!_typingController.isClosed) {
      _typingController.add(Set<String>.unmodifiable(_typing));
    }
  }

  void leave() {
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    _expiry.clear();
    _typing.clear();
    _online.clear();
    _channel?.unsubscribe();
    _channel = null;
    _conversationId = null;
    _userId = null;
  }

  void dispose() {
    leave();
    _onlineController.close();
    _typingController.close();
  }
}
