import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/shared/models/profile.dart';

/// A conversation: either a direct 1:1 chat or a group chat.
class Conversation {
  final String id;
  final String type; // direct | group
  final String? name; // group name (null for direct)
  final String? avatarPath;
  final String? description; // group description
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    required this.id,
    required this.type,
    this.name,
    this.avatarPath,
    this.description,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isGroup => type == AppConstants.conversationTypeGroup;
  bool get isDirect => type == AppConstants.conversationTypeDirect;

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      type: json['type'] as String? ?? AppConstants.conversationTypeDirect,
      name: json['name'] as String?,
      avatarPath: json['avatar_path'] as String?,
      description: json['description'] as String?,
      createdBy: json['created_by'] as String?,
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
      'type': type,
      'name': name,
      'avatar_path': avatarPath,
      'description': description,
      'created_by': createdBy,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

/// Membership of a user in a conversation.
class ConversationMember {
  final String conversationId;
  final String userId;
  final String role; // member | admin | owner
  final DateTime joinedAt;
  final String? lastReadMessageId;
  final bool notificationsMuted;
  final DateTime? mutedUntil;

  ConversationMember({
    required this.conversationId,
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.lastReadMessageId,
    this.notificationsMuted = false,
    this.mutedUntil,
  });

  bool get isAdmin => role == AppConstants.memberRoleAdmin ||
      role == AppConstants.memberRoleOwner;
  bool get isOwner => role == AppConstants.memberRoleOwner;

  factory ConversationMember.fromJson(Map<String, dynamic> json) {
    return ConversationMember(
      conversationId: json['conversation_id'] as String,
      userId: json['user_id'] as String,
      role: json['role'] as String? ?? AppConstants.memberRoleMember,
      joinedAt: json['joined_at'] != null
          ? DateTime.tryParse(json['joined_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastReadMessageId: json['last_read_message_id'] as String?,
      notificationsMuted: json['notifications_muted'] as bool? ?? false,
      mutedUntil: json['muted_until'] != null
          ? DateTime.tryParse(json['muted_until'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'conversation_id': conversationId,
      'user_id': userId,
      'role': role,
      'joined_at': joinedAt.toIso8601String(),
      'last_read_message_id': lastReadMessageId,
      'notifications_muted': notificationsMuted,
      'muted_until': mutedUntil?.toIso8601String(),
    };
  }
}

/// A conversation enriched with last message and unread count for the chat list.
class ConversationListItem {
  final Conversation conversation;
  final Profile? otherParticipant; // for direct chats
  final String? lastMessageText;
  final DateTime? lastMessageAt;
  final String? lastMessageSenderId;
  final int unreadCount;
  final bool isMuted;

  ConversationListItem({
    required this.conversation,
    this.otherParticipant,
    this.lastMessageText,
    this.lastMessageAt,
    this.lastMessageSenderId,
    this.unreadCount = 0,
    this.isMuted = false,
  });

  String get title {
    if (conversation.isGroup) {
      return conversation.name ?? 'Group';
    }
    return otherParticipant?.displayNameOrUsername ?? 'Unknown';
  }

  String? get subtitle => lastMessageText;

  /// Copy with the fields the chat list changes locally.
  ///
  /// Only [unreadCount] is needed today: the badge is zeroed the moment a chat
  /// is opened, then confirmed against the server when the screen pops.
  ConversationListItem copyWith({int? unreadCount, bool? isMuted}) {
    return ConversationListItem(
      conversation: conversation,
      otherParticipant: otherParticipant,
      lastMessageText: lastMessageText,
      lastMessageAt: lastMessageAt,
      lastMessageSenderId: lastMessageSenderId,
      unreadCount: unreadCount ?? this.unreadCount,
      isMuted: isMuted ?? this.isMuted,
    );
  }

  factory ConversationListItem.fromJson(Map<String, dynamic> json) {
    return ConversationListItem(
      conversation: Conversation.fromJson(
          Map<String, dynamic>.from(json['conversation'] as Map)),
      otherParticipant: json['other_participant'] != null
          ? Profile.fromJson(
              Map<String, dynamic>.from(json['other_participant'] as Map))
          : null,
      lastMessageText: json['last_message_text'] as String?,
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.tryParse(json['last_message_at'] as String)
          : null,
      lastMessageSenderId: json['last_message_sender_id'] as String?,
      unreadCount: json['unread_count'] as int? ?? 0,
      isMuted: json['is_muted'] as bool? ?? false,
    );
  }
}
