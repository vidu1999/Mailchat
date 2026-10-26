import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show VoidCallback;

import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/network/transport_failure.dart';

/// Minimal Supabase Realtime (Phoenix protocol) client.
///
/// Supabase Realtime speaks the Phoenix channel protocol over WebSocket:
///   wss://<project>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0
///
/// This implementation covers what MailChat needs:
///   - connect / disconnect with automatic reconnect
///   - join / leave channels
///   - broadcast events (typing indicators, presence)
///   - listen to postgres_changes payloads
///   - heartbeats to keep the connection alive
///
/// It intentionally avoids a hard dependency on an external package so the
/// core compiles without pub.dev access. On a standard dev machine you may
/// replace this with the official `supabase_flutter` Realtime client.
class SupabaseRealtimeClient {
  SupabaseRealtimeClient._();
  static final SupabaseRealtimeClient instance = SupabaseRealtimeClient._();

  WebSocket? _socket;
  final Map<String, _Channel> _channels = {};
  final _connectTimeout = const Duration(seconds: 10);
  final _heartbeatInterval = const Duration(seconds: 30);

  int _messageRef = 0;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  /// Consecutive failed connection attempts, reset on success. Drives the
  /// backoff in [reconnectDelay] so an offline device does not log a failure
  /// every five seconds for as long as the app is open.
  int _reconnectAttempt = 0;
  StreamSubscription<dynamic>? _socketSubscription;
  bool _closing = false;

  /// Connection state stream. `true` when the socket is open.
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionState => _connectionStateController.stream;

  bool get isConnected => _socket != null && _socket!.readyState == WebSocket.open;

  /// Opens the WebSocket. Safe to call repeatedly; concurrent calls await the
  /// same connection attempt.
  Future<void> connect({VoidCallback? onConnected}) {
    if (isConnected) {
      onConnected?.call();
      return Future<void>.value();
    }
    return _connecting ??= _openSocket(onConnected);
  }

  Future<void>? _connecting;

  Future<void> _openSocket(VoidCallback? onConnected) async {
    AppLogger.info('realtime_connect');
    final uri =
        '${AppConfig.instance.supabaseUrl.replaceFirst('https://', 'wss://')}'
        '/realtime/v1/websocket'
        '?apikey=${AppConfig.instance.supabaseAnonKey}&vsn=1.0.0';

    try {
      final ws = await WebSocket.connect(uri).timeout(_connectTimeout);
      _socket = ws;
      _socketSubscription = ws.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      _connectionStateController.add(true);
      _startHeartbeat();
      _reconnectAttempt = 0;
      onConnected?.call();
      AppLogger.info('realtime_connected');
    } catch (e, st) {
      final kind = classifyTransportFailure(e);
      // A device with no network fails identically every time. Log the stack
      // for the first attempt, then only the classified cause: the advice for
      // "cannot look up the hostname" does not change between attempts.
      if (_reconnectAttempt == 0) {
        AppLogger.error(e, st, {
          'where': 'realtime_connect',
          'kind': kind.name,
        });
        AppLogger.warning('realtime_unreachable', details: {
          'kind': kind.name,
          'message': describeTransportFailure(
            host: AppConfig.instance.supabaseUrl,
            cause: e,
          ),
        });
      } else {
        AppLogger.warning('realtime_retry_waiting', details: {
          'kind': kind.name,
          'attempt': _reconnectAttempt,
        });
      }
      _socket = null;
      _connectionStateController.add(false);
      _scheduleReconnect();
    } finally {
      _connecting = null;
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
      final topic = decoded['topic'] as String?;
      final event = decoded['event'] as String?;
      final payload = decoded['payload'] as Map<String, dynamic>?;

      if (topic == null || event == null) return;

      if (event == 'phx_reply') {
        // Replies are handled by awaiting channels; logged for debugging.
        AppLogger.info('realtime_reply', details: {
          'topic': topic,
          'status': payload?['status'],
        });
        return;
      }

      if (event == 'phx_close') {
        _channels.remove(topic);
        return;
      }

      final channel = _channels[topic];
      if (channel != null) {
        channel._dispatch(event, payload ?? {});
      }
    } catch (e, st) {
      AppLogger.error(e, st, {'raw': raw.toString()});
    }
  }

  void _onError(Object error, StackTrace? stackTrace) {
    AppLogger.error(error, stackTrace, {'where': 'realtime_socket'});
    _connectionStateController.add(false);
  }

  void _onDone() {
    AppLogger.info('realtime_socket_closed');
    _socket = null;
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _stopHeartbeat();
    _connectionStateController.add(false);
    if (!_closing) {
      _scheduleReconnect();
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (isConnected) {
        try {
          _socket!.add(jsonEncode({
            'topic': 'phoenix',
            'event': 'heartbeat',
            'payload': {},
            'ref': _nextRef(),
          }));
        } catch (e) {
          AppLogger.warning('realtime_heartbeat_failed', details: {'error': e.toString()});
        }
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final delay = reconnectDelay(_reconnectAttempt);
    _reconnectTimer = Timer(delay, () {
      if (!_closing && !isConnected) {
        AppLogger.info('realtime_reconnect', details: {
          'attempt': _reconnectAttempt,
          'after_seconds': delay.inSeconds,
        });
        connect();
      }
    });
  }

  int _nextRef() => ++_messageRef;

  /// Joins (or rejoins) a channel. [onMessage] receives `(event, payload)`.
  /// Joins a channel.
  ///
  /// [config] is the Realtime channel config. For Postgres change streams it
  /// must contain `postgres_changes`, e.g.
  /// ```dart
  /// join(topic, onMessage, config: {
  ///   'postgres_changes': [
  ///     {'event': '*', 'schema': 'public', 'table': 'messages',
  ///      'filter': 'conversation_id=eq.$id'},
  ///   ],
  /// });
  /// ```
  /// Without it Supabase accepts the join but streams nothing.
  Channel join(
    String topic,
    void Function(String event, Map<String, dynamic> payload) onMessage, {
    Map<String, dynamic>? config,
  }) {
    final channel = _Channel._(this, topic, onMessage, config: config);
    _channels[topic] = channel;
    if (isConnected) {
      channel._sendJoin();
    } else {
      // Join once the socket opens.
      unawaited(connect().then((_) => channel._sendJoin()));
    }
    return channel;
  }

  /// Leaves a channel and removes it from the local registry.
  void leave(String topic) {
    final channel = _channels.remove(topic);
    if (channel != null && isConnected) {
      try {
        _socket!.add(jsonEncode({
          'topic': topic,
          'event': 'phx_leave',
          'payload': {},
          'ref': _nextRef(),
        }));
      } catch (e) {
        AppLogger.warning('realtime_leave_failed', details: {'topic': topic, 'error': e.toString()});
      }
    }
  }

  /// Disconnects all channels and closes the socket.
  Future<void> disconnect() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    for (final topic in _channels.keys) {
      leave(topic);
    }
    _channels.clear();
    try {
      await _socket?.close();
    } catch (e) {
      AppLogger.warning('realtime_disconnect_error', details: {'error': e.toString()});
    }
    _socket = null;
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _connectionStateController.add(false);
    _closing = false;
  }
}

/// A channel handle returned by [SupabaseRealtimeClient.join].
abstract class Channel {
  /// Unsubscribe and leave this channel.
  Future<void> unsubscribe();

  /// Listen to broadcast events on this channel.
  Stream<Map<String, dynamic>> get broadcast;

  /// Sends a raw event on this channel.
  ///
  /// Used for broadcast payloads (typing indicators). Postgres changes are
  /// server-driven and never sent from here.
  void send(String event, [Map<String, dynamic>? payload]);
}

class _Channel implements Channel {
  final SupabaseRealtimeClient _client;
  final String _topic;
  final void Function(String event, Map<String, dynamic> payload) _onMessage;
  final Map<String, dynamic>? _config;
  final StreamController<Map<String, dynamic>> _broadcastController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _joined = false;

  _Channel._(this._client, this._topic, this._onMessage, {Map<String, dynamic>? config})
      : _config = config;

  @override
  Stream<Map<String, dynamic>> get broadcast => _broadcastController.stream;

  void _dispatch(String event, Map<String, dynamic> payload) {
    if (event == 'broadcast') {
      _broadcastController.add(payload);
      return;
    }

    // Postgres change payloads come in two shapes across Realtime versions:
    //   {event: 'INSERT', payload: {record: {...}, old_record: ...}}
    //   {event: 'postgres_changes', payload: {data: {type: 'INSERT',
    //                                                 record: {...}}}}
    // Normalise both to (eventType, {record, old_record, ...}).
    if (event == 'postgres_changes') {
      final data = payload['data'];
      final normalised = data is Map ? Map<String, dynamic>.from(data) : payload;
      final type = (normalised['type'] as String?) ??
          (normalised['eventType'] as String?) ??
          'UNKNOWN';
      _onMessage(type, normalised);
      return;
    }

    _onMessage(event, payload);
  }

  Future<void> _sendJoin() async {
    if (_joined) return;
    try {
      final payload = <String, dynamic>{
        if (_config != null) 'config': _config,
        // Required for Postgres changes: Realtime evaluates RLS against this
        // token, so without it no rows are delivered.
        if (SupabaseClient.instance.accessToken != null)
          'access_token': SupabaseClient.instance.accessToken,
      };
      _client._socket!.add(jsonEncode({
        'topic': _topic,
        'event': 'phx_join',
        'payload': payload,
        'ref': _client._nextRef(),
      }));
      _joined = true;
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'channel_join', 'topic': _topic});
      rethrow;
    }
  }

  @override
  void send(String event, [Map<String, dynamic>? payload]) {
    if (!_client.isConnected) {
      throw NetworkException('Realtime socket is not connected');
    }
    _client._socket!.add(jsonEncode({
      'topic': _topic,
      'event': event,
      'payload': payload ?? {},
      'ref': _client._nextRef(),
    }));
  }

  @override
  Future<void> unsubscribe() async {
    send('phx_leave');
    _client._channels.remove(_topic);
    await _broadcastController.close();
  }
}
