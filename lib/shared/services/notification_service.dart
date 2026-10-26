import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';

/// Notification preferences that belong to a user rather than a device.
///
/// The table has supported this since 0001: one row per user with a null
/// `conversation_id` is the global setting, and a row with one is a per-chat
/// mute. The settings screen previously wrote nothing — its switches were local
/// state, so the values were lost on the next launch and the copy implied
/// otherwise.
///
/// Sound and vibration are deliberately absent: they are device settings, and
/// they belong in local storage with the FCM work, not in Postgres.
class NotificationService {
  NotificationService();

  final SupabaseClient _supabase = SupabaseClient.instance;

  /// Returns the caller's global preferences, or null when they have never
  /// saved any (the table defaults apply).
  Future<NotificationPreferences?> getGlobal() async {
    final userId = _supabase.userId;
    if (userId == null) return null;
    final rows = await _supabase.select(
      'notification_preferences',
      select: 'messages_enabled, mentions_enabled, reactions_enabled, muted',
      filter: {'eq': 'user_id,$userId', 'is': 'conversation_id,null'},
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return NotificationPreferences.fromJson(rows.first);
  }

  /// Creates or updates the caller's global row.
  ///
  /// Insert-then-update rather than an upsert, because the uniqueness here is a
  /// *partial* index (`where conversation_id is null`), which ON CONFLICT
  /// cannot target without repeating the predicate.
  Future<void> saveGlobal(NotificationPreferences preferences) async {
    final userId = _supabase.userId;
    if (userId == null) {
      throw StateError('Not authenticated');
    }

    final existing = await _supabase.select(
      'notification_preferences',
      select: 'id',
      filter: {'eq': 'user_id,$userId', 'is': 'conversation_id,null'},
      limit: 1,
    );

    if (existing.isEmpty) {
      await _supabase.insert(
        'notification_preferences',
        data: {
          'user_id': userId,
          ...preferences.toJson(),
        },
        select: 'id',
      );
    } else {
      await _supabase.update(
        'notification_preferences',
        filter: {'eq': 'id,${existing.first['id']}'},
        data: preferences.toJson(),
      );
    }
    AppLogger.info('notification_preferences_saved', details: {
      'messages': preferences.messages,
      'mentions': preferences.mentions,
      'reactions': preferences.reactions,
    });
  }
}

/// The global notification switches.
class NotificationPreferences {
  const NotificationPreferences({
    this.messages = true,
    this.mentions = true,
    this.reactions = false,
    this.muted = false,
  });

  final bool messages;
  final bool mentions;
  final bool reactions;
  final bool muted;

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    return NotificationPreferences(
      messages: json['messages_enabled'] as bool? ?? true,
      mentions: json['mentions_enabled'] as bool? ?? true,
      reactions: json['reactions_enabled'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'messages_enabled': messages,
        'mentions_enabled': mentions,
        'reactions_enabled': reactions,
        'muted': muted,
      };

  NotificationPreferences copyWith({
    bool? messages,
    bool? mentions,
    bool? reactions,
    bool? muted,
  }) {
    return NotificationPreferences(
      messages: messages ?? this.messages,
      mentions: mentions ?? this.mentions,
      reactions: reactions ?? this.reactions,
      muted: muted ?? this.muted,
    );
  }
}
