import 'dart:async';
import 'dart:math';

import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/network/supabase_realtime.dart';
import 'package:mailchat/shared/models/message.dart';

/// Message business logic: sending, pagination, edit/delete, receipts,
/// reactions and real-time subscription lifecycle.
class MessageService {
  MessageService({String? conversationId}) : _conversationId = conversationId;

  final SupabaseClient _supabase = SupabaseClient.instance;
  final SupabaseRealtimeClient _realtime = SupabaseRealtimeClient.instance;

  String? _conversationId;
  final Map<String, Message> _localMessages = {};

  /// Messages for the current conversation (cached).
  List<Message> get messages => _localMessages.values.toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// Sets the active conversation and resets the local cache.
  void setConversation(String? conversationId) {
    _conversationId = conversationId;
    _localMessages.clear();
    unsubscribe();
  }

  /// Sends a text message optimistically.
  ///
  /// Returns a [Message] with [Message.status] = `pending` immediately; the
  /// server-persisted message replaces it once the insert succeeds.
  Future<Message> sendText({
    required String conversationId,
    required String senderId,
    required String text,
    String? replyToMessageId,
  }) async {
    if (text.trim().isEmpty) {
      throw ValidationException('Message cannot be empty');
    }
    if (text.length > AppConstants.maxMessageLength) {
      throw ValidationException(
          'Message is too long (max ${AppConstants.maxMessageLength} characters)');
    }

    final clientId = 'client-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final pending = Message(
      id: clientId,
      conversationId: conversationId,
      senderId: senderId,
      type: 'text',
      text: text.trim(),
      replyToMessageId: replyToMessageId,
      createdAt: DateTime.now(),
      clientId: clientId,
      status: AppConstants.messageStatusPending,
    );

    // Optimistic update.
    _localMessages[clientId] = pending;
    _conversationId = conversationId;

    try {
      final inserted = await _supabase.insert(
        'messages',
        // `id` is left to the database (uuid). `client_id` provides send
        // idempotency, and there is no `status` column — status is client-side.
        data: {
          'conversation_id': conversationId,
          'sender_id': senderId,
          'type': 'text',
          'text': text.trim(),
          'reply_to_message_id': replyToMessageId,
          'client_id': clientId,
        },
        select: '*',
      );
      if (inserted.isEmpty) {
        throw AppException('Message was not accepted by the server');
      }
      final saved = Message.fromJson(inserted.first)
          .copyWith(status: AppConstants.messageStatusSent);
      _localMessages[clientId] = saved;

      AppLogger.info('message_sent', details: {
        'messageId': saved.id,
        'conversationId': conversationId,
      });
      return saved;
    } catch (e, st) {
      _localMessages[clientId] = pending.copyWith(
          status: AppConstants.messageStatusFailed);
      AppLogger.error(e, st, {
        'where': 'send_text',
        'clientId': clientId,
        'conversationId': conversationId,
      });
      rethrow;
    }
  }

  /// Paginates older messages for [conversationId], newest first within the
  /// page, returning them oldest-first for display.
  Future<List<Message>> getMessages({
    required String conversationId,
    int limit = AppConstants.messagesPageSize,
    String? beforeMessageId, // cursor: fetch messages older than this
  }) {
    return _fetchMessages(
      conversationId,
      limit: limit,
      beforeMessageId: beforeMessageId,
    );
  }

  Future<List<Message>> _fetchMessages(
    String conversationId, {
    int limit = AppConstants.messagesPageSize,
    String? beforeMessageId,
  }) async {
    final params = <String, String>{
      'select': '*,message_attachments(*),message_reactions(*)',
      'order': 'created_at.desc',
      'limit': limit.toString(),
    };
    if (beforeMessageId != null) {
      final ref = await _supabase.select(
        'messages',
        select: 'created_at',
        filter: {'eq': 'id,$beforeMessageId'},
        limit: 1,
      );
      if (ref.isNotEmpty) {
        params['created_at'] = 'lt.${ref.first['created_at']}';
      }
    }

    // PostgREST filter: eq(conversation_id,X)
    final data = await _supabase.select(
      'messages',
      select: '*,message_attachments(*),message_reactions(*)',
      filter: {'eq': 'conversation_id,$conversationId'},
      order: 'created_at.desc',
      limit: limit,
    );
    // created_at cursor applied via rpc would be cleaner; here we filter in Dart
    // when a cursor is present to keep the implementation dependency-free.
    List<Map<String, dynamic>> rows = data.cast<Map<String, dynamic>>();
    if (beforeMessageId != null) {
      final ref = await _supabase.select(
        'messages',
        select: 'created_at',
        filter: {'eq': 'id,$beforeMessageId'},
        limit: 1,
      );
      if (ref.isNotEmpty) {
        final cutoff = DateTime.tryParse(ref.first['created_at'] as String);
        if (cutoff != null) {
          rows = rows.where((e) {
            final t = DateTime.tryParse(e['created_at'] as String);
            return t != null && t.isBefore(cutoff);
          }).toList();
        }
      }
    }

    rows.sort((a, b) => DateTime.tryParse(a['created_at'] as String)!
        .compareTo(DateTime.tryParse(b['created_at'] as String)!));

    return rows.map((e) => Message.fromJson(e)).toList();
  }

  /// Edits [messageId] — only the sender may edit, and only non-deleted messages.
  Future<void> editMessage({
    required String messageId,
    required String conversationId,
    required String senderId,
    required String newText,
  }) async {
    if (newText.trim().isEmpty) {
      throw ValidationException('Message cannot be empty');
    }
    await _assertSender(messageId, senderId);
    await _supabase.update(
      'messages',
      filter: {'eq': 'id,$messageId'},
      data: {
        'text': newText.trim(),
        'edited_at': DateTime.now().toIso8601String(),
      },
    );
    final cached = _localMessages[messageId];
    if (cached != null) {
      _localMessages[messageId] = cached.copyWith(
          text: newText.trim(), editedAt: DateTime.now());
    }
    AppLogger.info('message_edited', details: {'messageId': messageId});
  }

  /// Soft-deletes [messageId] — only the sender may delete their own messages.
  Future<void> deleteMessage({
    required String messageId,
    required String senderId,
  }) async {
    await _assertSender(messageId, senderId);
    await _supabase.update(
      'messages',
      filter: {'eq': 'id,$messageId'},
      data: {'deleted_at': DateTime.now().toIso8601String()},
    );
    final cached = _localMessages[messageId];
    if (cached != null) {
      _localMessages[messageId] = cached.copyWith(deletedAt: DateTime.now());
    }
    AppLogger.info('message_deleted', details: {'messageId': messageId});
  }

  /// Adds or removes a reaction on [messageId] by [userId].
  Future<void> toggleReaction({
    required String messageId,
    required String userId,
    required String reaction,
  }) async {
    final existing = await _supabase.select(
      'message_reactions',
      select: 'id',
      filter: {
        'eq': 'message_id,$messageId,user_id,$userId,reaction,$reaction',
      },
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await _supabase.delete(
        'message_reactions',
        filter: {'eq': 'id,${existing.first['id']}'},
      );
    } else {
      await _supabase.insert(
        'message_reactions',
        data: {
          'message_id': messageId,
          'user_id': userId,
          'reaction': reaction,
        },
      );
    }
    AppLogger.info('message_reaction_toggled', details: {
      'messageId': messageId,
      'userId': userId,
      'reaction': reaction,
    });
  }

  /// Marks [messageId] as delivered and/or read by [recipientId].
  /// Recipients can only write their own receipts (enforced by RLS).
  Future<void> markReceipt({
    required String messageId,
    required String recipientId,
    bool delivered = false,
    bool read = false,
  }) async {
    await _upsertReceipt(messageId, recipientId, delivered: delivered, read: read);
  }

  Future<void> _upsertReceipt(
    String messageId,
    String recipientId, {
    bool delivered = false,
    bool read = false,
  }) async {
    final now = DateTime.now().toIso8601String();
    final data = <String, dynamic>{
      'message_id': messageId,
      'recipient_id': recipientId,
      if (delivered) 'delivered_at': now,
      if (read) 'read_at': now,
    };
    // Update-then-insert: (message_id, recipient_id) is unique, so a blind
    // insert would raise a duplicate-key error on the second receipt event.
    final updated = await _supabase.update(
      'message_receipts',
      filter: {'eq': 'message_id,$messageId,recipient_id,$recipientId'},
      data: data,
    );
    if (updated.isEmpty) {
      await _supabase.insert(
        'message_receipts',
        data: {
          'message_id': messageId,
          'recipient_id': recipientId,
          ...data,
        },
        select: 'id',
      );
    }
    AppLogger.info('receipt_upserted', details: {
      'messageId': messageId,
      'recipientId': recipientId,
      'delivered': delivered,
      'read': read,
    });
  }

  Future<void> _assertSender(String messageId, String senderId) async {
    final rows = await _supabase.select(
      'messages',
      select: 'sender_id, deleted_at',
      filter: {'eq': 'id,$messageId'},
      limit: 1,
    );
    if (rows.isEmpty) throw NotFoundException('Message not found');
    if (rows.first['sender_id'] != senderId) {
      throw AuthorizationException('You can only edit or delete your own messages');
    }
    if (rows.first['deleted_at'] != null) {
      throw ValidationException('Message is already deleted');
    }
  }

  // ------------------------------------------------------------------
  // Real-time
  // ------------------------------------------------------------------

  /// Subscribes to real-time events for [conversationId].
  ///
  /// Sends a `postgres_changes` config scoped to this conversation, plus the
  /// access token so Realtime evaluates RLS. Events are normalised by the
  /// client to `(type, {record, ...})` where type is INSERT/UPDATE/DELETE.
  void subscribeToConversation(String conversationId) {
    _conversationId = conversationId;
    _ensureEventController();

    final topic = 'realtime:mailchat:messages:$conversationId';
    final channel = _realtime.join(
      topic,
      (type, payload) {
        final record = payload['record'];
        if (record is! Map) return;
        final row = Map<String, dynamic>.from(record);

        // Rows are already filtered server-side, but a misconfigured channel
        // must not leak another conversation's messages into this thread.
        if (row['conversation_id'] != conversationId) return;

        switch (type) {
          case 'INSERT':
          case 'UPDATE':
            final message = Message.fromJson(row);
            _localMessages[message.id] = message;
            if (!_messageEventController.isClosed) {
              _messageEventController.add(message);
            }
            break;
          case 'DELETE':
            final oldRecord = payload['old_record'];
            if (oldRecord is Map) {
              _localMessages.remove(oldRecord['id']);
            }
            break;
        }
      },
      config: {
        'postgres_changes': [
          {
            'event': '*',
            'schema': 'public',
            'table': 'messages',
            'filter': 'conversation_id=eq.$conversationId',
          },
        ],
      },
    );

    _channel = channel;
  }

  Channel? _channel;
  // Recreated on demand: closing it in unsubscribe() would otherwise make a
  // second subscribe on the same service instance throw.
  StreamController<Message> _messageEventController =
      StreamController<Message>.broadcast();

  void _ensureEventController() {
    if (_messageEventController.isClosed) {
      _messageEventController = StreamController<Message>.broadcast();
    }
  }
  Stream<Message> get messageEvents => _messageEventController.stream;

  void unsubscribe() {
    _channel?.unsubscribe();
    _channel = null;
    if (!_messageEventController.isClosed) {
      _messageEventController.close();
    }
  }
}
