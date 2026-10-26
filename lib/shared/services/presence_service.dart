import 'dart:async';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_realtime.dart';

/// Presence and typing indicators for one conversation.
///
/// Both are **ephemeral**: they live on a Realtime channel and are never written
/// to a table. That matters for two reasons — a "typing" row would be written on
/// every keystroke, and a stored `is_online` boolean would go stale the moment a
/// phone loses signal. See docs/architecture.md.
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
  PresenceService({SupabaseRealtimeClient? realtime})
      : _realtime = realtime ?? SupabaseRealtimeClient.instance;

  final SupabaseRealtimeClient _realtime;

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
