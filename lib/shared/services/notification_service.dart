import 'dart:async';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/network/supabase_realtime.dart';

/// Durable inbox + realtime events. This is foreground/in-app delivery; an OS
/// push requires a trusted FCM sender and credentials configured on the server.
class NotificationService {
  NotificationService();

  final SupabaseClient _supabase = SupabaseClient.instance;
  final SupabaseRealtimeClient _realtime = SupabaseRealtimeClient.instance;
  final StreamController<MailNotification> _events =
      StreamController<MailNotification>.broadcast();
  Channel? _channel;

  Stream<MailNotification> get newNotifications => _events.stream;

  Future<NotificationPreferences?> getGlobal() async {
    final userId = _supabase.userId;
    if (userId == null) return null;
    final rows = await _supabase.select(
      'notification_preferences',
      select: 'messages_enabled, mentions_enabled, reactions_enabled, calls_enabled, muted',
      filter: {'eq': 'user_id,$userId', 'is': 'conversation_id,null'},
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return NotificationPreferences.fromJson(rows.first);
  }

  Future<void> saveGlobal(NotificationPreferences preferences) async {
    final userId = _supabase.userId;
    if (userId == null) throw StateError('Not authenticated');
    final existing = await _supabase.select(
      'notification_preferences',
      select: 'id',
      filter: {'eq': 'user_id,$userId', 'is': 'conversation_id,null'},
      limit: 1,
    );
    if (existing.isEmpty) {
      await _supabase.insert('notification_preferences', data: {
        'user_id': userId,
        ...preferences.toJson(),
      }, select: 'id');
    } else {
      await _supabase.update('notification_preferences',
          filter: {'eq': 'id,${existing.first['id']}'},
          data: preferences.toJson());
    }
    AppLogger.info('notification_preferences_saved', details: {
      'messages': preferences.messages,
      'calls': preferences.calls,
    });
  }

  Future<List<MailNotification>> list({int limit = 100}) async {
    final userId = _supabase.userId;
    if (userId == null) return const [];
    final rows = await _supabase.select(
      'user_notifications',
      select: '*',
      filter: {'eq': 'user_id,$userId'},
      order: 'created_at.desc',
      limit: limit,
    );
    return rows.map(MailNotification.fromJson).toList();
  }

  Future<int> unreadCount() async {
    final userId = _supabase.userId;
    if (userId == null) return 0;
    final rows = await _supabase.select(
      'user_notifications',
      select: 'id',
      filter: {'eq': 'user_id,$userId', 'is': 'read_at,null'},
      limit: 500,
    );
    return rows.length;
  }

  Future<void> markRead(String id) async => _supabase.update(
        'user_notifications',
        filter: {'eq': 'id,$id'},
        data: {'read_at': DateTime.now().toUtc().toIso8601String()},
      );

  Future<void> markConversationRead(String conversationId) async {
    final userId = _supabase.userId;
    if (userId == null || conversationId.isEmpty) return;
    await _supabase.update(
      'user_notifications',
      filter: {
        'eq': 'user_id,$userId,conversation_id,$conversationId',
        'is': 'read_at,null',
      },
      data: {'read_at': DateTime.now().toUtc().toIso8601String()},
    );
  }

  /// Mutes this conversation for eight hours; the database preference expires
  /// naturally, so there is no need to find a hidden unmute control.
  Future<void> muteConversation(String conversationId) async {
    final userId = _supabase.userId;
    if (userId == null || conversationId.isEmpty) return;
    final mutedUntil = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String();
    final existing = await _supabase.select(
      'notification_preferences',
      select: 'id',
      filter: {'eq': 'user_id,$userId,conversation_id,$conversationId'},
      limit: 1,
    );
    if (existing.isEmpty) {
      await _supabase.insert('notification_preferences', data: {
        'user_id': userId,
        'conversation_id': conversationId,
        'muted': false,
        'muted_until': mutedUntil,
      });
    } else {
      await _supabase.update(
        'notification_preferences',
        filter: {'eq': 'id,${existing.first['id']}'},
        data: {'muted': false, 'muted_until': mutedUntil},
      );
    }
  }

  Future<void> markAllRead() async {
    final userId = _supabase.userId;
    if (userId == null) return;
    await _supabase.update(
      'user_notifications',
      filter: {'eq': 'user_id,$userId', 'is': 'read_at,null'},
      data: {'read_at': DateTime.now().toUtc().toIso8601String()},
    );
  }

  void subscribe() {
    final userId = _supabase.userId;
    if (userId == null || _channel != null) return;
    if (_events.isClosed) return;
    _channel = _realtime.join(
      'realtime:mailchat:notifications:$userId',
      (event, payload) {
        if (event != 'INSERT') return;
        final raw = payload['record'];
        if (raw is! Map || _events.isClosed) return;
        try {
          _events.add(MailNotification.fromJson(Map<String, dynamic>.from(raw)));
        } catch (e, st) {
          AppLogger.error(e, st, {'where': 'notification_realtime'});
        }
      },
      config: {
        'postgres_changes': [
          {
            'event': 'INSERT',
            'schema': 'public',
            'table': 'user_notifications',
            'filter': 'user_id=eq.$userId',
          },
        ],
      },
    );
  }

  void dispose() {
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.unsubscribe().catchError((Object _) {}));
    }
    unawaited(_events.close());
  }
}

class MailNotification {
  const MailNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.read,
    required this.payload,
  });

  final String id;
  final String type;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool read;
  final Map<String, dynamic> payload;

  factory MailNotification.fromJson(Map<String, dynamic> row) =>
      MailNotification(
        id: row['id'] as String,
        type: row['notification_type'] as String? ?? 'message',
        title: row['title'] as String? ?? 'MailChat',
        body: row['body'] as String? ?? '',
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        read: row['read_at'] != null,
        payload: row['payload'] is Map
            ? Map<String, dynamic>.from(row['payload'] as Map)
            : const {},
      );
}

class NotificationPreferences {
  const NotificationPreferences({
    this.messages = true,
    this.mentions = true,
    this.reactions = false,
    this.calls = true,
    this.muted = false,
  });

  final bool messages;
  final bool mentions;
  final bool reactions;
  final bool calls;
  final bool muted;

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      NotificationPreferences(
        messages: json['messages_enabled'] as bool? ?? true,
        mentions: json['mentions_enabled'] as bool? ?? true,
        reactions: json['reactions_enabled'] as bool? ?? false,
        calls: json['calls_enabled'] as bool? ?? true,
        muted: json['muted'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'messages_enabled': messages,
        'mentions_enabled': mentions,
        'reactions_enabled': reactions,
        'calls_enabled': calls,
        'muted': muted,
      };

  NotificationPreferences copyWith({
    bool? messages,
    bool? mentions,
    bool? reactions,
    bool? calls,
    bool? muted,
  }) =>
      NotificationPreferences(
        messages: messages ?? this.messages,
        mentions: mentions ?? this.mentions,
        reactions: reactions ?? this.reactions,
        calls: calls ?? this.calls,
        muted: muted ?? this.muted,
      );
}
