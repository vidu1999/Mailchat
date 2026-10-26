import 'package:mailchat/core/constants/app_constants.dart';

/// A message within a conversation.
class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String type; // text | image | video | audio | voice | file | system
  final String? text;
  final String? replyToMessageId;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;

  /// Client-generated idempotency key used to prevent duplicate submissions.
  final String? clientId;

  /// Client-side delivery state (not persisted to the server).
  final String status;

  /// Reactions on this message. Populated when the query embeds
  /// `message_reactions(*)`; empty otherwise, and replaced wholesale when a
  /// reaction changes.
  final List<MessageReaction> reactions;

  Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    this.text,
    this.replyToMessageId,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.clientId,
    this.status = AppConstants.messageStatusSent,
    this.reactions = const [],
  });

  bool get isText => type == 'text';
  bool get isSystem => type == 'system';
  bool get isDeleted => deletedAt != null;
  bool get isEdited => editedAt != null;

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      type: json['type'] as String? ?? 'text',
      text: json['text'] as String?,
      replyToMessageId: json['reply_to_message_id'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      editedAt: json['edited_at'] != null
          ? DateTime.tryParse(json['edited_at'] as String)
          : null,
      deletedAt: json['deleted_at'] != null
          ? DateTime.tryParse(json['deleted_at'] as String)
          : null,
      clientId: json['client_id'] as String?,
      status: json['status'] as String? ?? AppConstants.messageStatusSent,
      reactions: _parseReactions(json),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'sender_id': senderId,
      'type': type,
      'text': text,
      'reply_to_message_id': replyToMessageId,
      'client_id': clientId,
      'created_at': createdAt.toIso8601String(),
      'edited_at': editedAt?.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
      'status': status,
    };
  }

  Message copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? type,
    String? text,
    String? replyToMessageId,
    DateTime? createdAt,
    DateTime? editedAt,
    DateTime? deletedAt,
    String? clientId,
    String? status,
    List<MessageReaction>? reactions,
  }) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      type: type ?? this.type,
      text: text ?? this.text,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      createdAt: createdAt ?? this.createdAt,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      clientId: clientId ?? this.clientId,
      status: status ?? this.status,
      reactions: reactions ?? this.reactions,
    );
  }

  /// Reads the embedded rows from `message_reactions(*)`.
  ///
  /// PostgREST returns this either as a list of rows or, for a to-one
  /// relationship, as a single object; both are accepted so an embedding change
  /// cannot silently drop every reaction from the UI.
  static List<MessageReaction> _parseReactions(Map<String, dynamic> json) {
    final raw = json['message_reactions'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((row) => MessageReaction.fromJson(Map<String, dynamic>.from(row)))
          .toList();
    }
    if (raw is Map) {
      return [MessageReaction.fromJson(Map<String, dynamic>.from(raw))];
    }
    return const [];
  }
}

/// A reaction on a message.
class MessageReaction {
  final String id;
  final String messageId;
  final String userId;
  final String reaction; // emoji
  final DateTime createdAt;

  MessageReaction({
    required this.id,
    required this.messageId,
    required this.userId,
    required this.reaction,
    required this.createdAt,
  });

  factory MessageReaction.fromJson(Map<String, dynamic> json) {
    return MessageReaction(
      id: json['id'] as String,
      messageId: json['message_id'] as String,
      userId: json['user_id'] as String,
      reaction: json['reaction'] as String,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message_id': messageId,
      'user_id': userId,
      'reaction': reaction,
      'created_at': createdAt.toIso8601String(),
    };
  }
}

/// Delivery / read receipt for a message.
class MessageReceipt {
  final String id;
  final String messageId;
  final String recipientId;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  MessageReceipt({
    required this.id,
    required this.messageId,
    required this.recipientId,
    this.deliveredAt,
    this.readAt,
  });

  bool get isRead => readAt != null;
  bool get isDelivered => deliveredAt != null;

  factory MessageReceipt.fromJson(Map<String, dynamic> json) {
    return MessageReceipt(
      id: json['id'] as String,
      messageId: json['message_id'] as String,
      recipientId: json['recipient_id'] as String,
      deliveredAt: json['delivered_at'] != null
          ? DateTime.tryParse(json['delivered_at'] as String)
          : null,
      readAt: json['read_at'] != null
          ? DateTime.tryParse(json['read_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message_id': messageId,
      'recipient_id': recipientId,
      'delivered_at': deliveredAt?.toIso8601String(),
      'read_at': readAt?.toIso8601String(),
    };
  }
}

/// Metadata of an attachment linked to a message.
class MessageAttachment {
  final String id;
  final String messageId;
  final String storagePath; // private bucket path
  final String fileName;
  final String mimeType;
  final int fileSize;
  final int? width;
  final int? height;
  final int? durationSeconds;
  final DateTime createdAt;

  MessageAttachment({
    required this.id,
    required this.messageId,
    required this.storagePath,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    this.width,
    this.height,
    this.durationSeconds,
    required this.createdAt,
  });

  bool get isImage => mimeType.startsWith('image/');
  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      id: json['id'] as String,
      messageId: json['message_id'] as String,
      storagePath: json['storage_path'] as String,
      fileName: json['file_name'] as String,
      mimeType: json['mime_type'] as String,
      fileSize: json['file_size'] as int,
      width: json['width'] as int?,
      height: json['height'] as int?,
      durationSeconds: json['duration_seconds'] as int?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message_id': messageId,
      'storage_path': storagePath,
      'file_name': fileName,
      'mime_type': mimeType,
      'file_size': fileSize,
      'width': width,
      'height': height,
      'duration_seconds': durationSeconds,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
