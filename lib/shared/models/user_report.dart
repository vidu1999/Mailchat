/// A user-generated abuse report.
class UserReport {
  final String id;
  final String reporterId;
  final String reportedUserId;
  final String? messageId;
  final String reason;
  final String? description;
  final String status; // open | reviewed | closed | dismissed
  final DateTime createdAt;

  UserReport({
    required this.id,
    required this.reporterId,
    required this.reportedUserId,
    this.messageId,
    required this.reason,
    this.description,
    required this.status,
    required this.createdAt,
  });

  factory UserReport.fromJson(Map<String, dynamic> json) {
    return UserReport(
      id: json['id'] as String,
      reporterId: json['reporter_id'] as String,
      reportedUserId: json['reported_user_id'] as String,
      messageId: json['message_id'] as String?,
      reason: json['reason'] as String,
      description: json['description'] as String?,
      status: json['status'] as String? ?? 'open',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'reporter_id': reporterId,
      'reported_user_id': reportedUserId,
      'message_id': messageId,
      'reason': reason,
      'description': description,
      'status': status,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

/// Notification preferences for a user / conversation.
class NotificationPreference {
  final String id;
  final String userId;
  final String? conversationId;
  final bool messagesEnabled;
  final bool mentionsEnabled;
  final bool reactionsEnabled;
  final bool muted;
  final DateTime? mutedUntil;
  final DateTime createdAt;
  final DateTime updatedAt;

  NotificationPreference({
    required this.id,
    required this.userId,
    this.conversationId,
    this.messagesEnabled = true,
    this.mentionsEnabled = true,
    this.reactionsEnabled = true,
    this.muted = false,
    this.mutedUntil,
    required this.createdAt,
    required this.updatedAt,
  });

  factory NotificationPreference.fromJson(Map<String, dynamic> json) {
    return NotificationPreference(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      conversationId: json['conversation_id'] as String?,
      messagesEnabled: json['messages_enabled'] as bool? ?? true,
      mentionsEnabled: json['mentions_enabled'] as bool? ?? true,
      reactionsEnabled: json['reactions_enabled'] as bool? ?? true,
      muted: json['muted'] as bool? ?? false,
      mutedUntil: json['muted_until'] != null
          ? DateTime.tryParse(json['muted_until'] as String)
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'conversation_id': conversationId,
      'messages_enabled': messagesEnabled,
      'mentions_enabled': mentionsEnabled,
      'reactions_enabled': reactionsEnabled,
      'muted': muted,
      'muted_until': mutedUntil?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}
