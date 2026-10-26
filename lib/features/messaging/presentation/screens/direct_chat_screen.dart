import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/models/reaction_summary.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/services/message_service.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';
import 'package:mailchat/shared/widgets/message_bubble.dart';

/// 1:1 and group chat screen.
///
/// Loads history with cursor pagination, sends text optimistically and
/// subscribes to realtime inserts. Reactions are available on long-press.
///
/// The current user id is injected via the auth session; until the session
/// provider is wired into this screen, `arguments['currentUserId']` is used.
class DirectChatScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const DirectChatScreen({super.key, this.arguments});

  @override
  State<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends State<DirectChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _messageService = MessageService();

  late String _conversationId;
  late final String _title;
  late final String _currentUserId;
  String? _otherUserId;

  List<Message> _messages = const [];
  StreamSubscription<Message>? _messageEvents;
  StreamSubscription<String>? _reactionEvents;
  bool _reactionsSubscribed = false;
  bool _loading = true;
  bool _sending = false;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _conversationId = (args['conversationId'] as String?) ?? '';
    _otherUserId = args['otherUserId'] as String?;
    _title = (args['title'] as String?) ?? 'Chat';
    _currentUserId =
        (args['currentUserId'] as String?) ??
        (SupabaseClient.instance.userId ?? '');
    _loadMessages();
  }

  /// Merges a realtime message into the list, replacing any optimistic copy
  /// that carries the same client id.
  void _onMessageEvent(Message message) {
    if (!mounted) return;
    setState(() {
      final withoutDuplicate = _messages.where((m) {
        if (m.id == message.id) return false;
        if (message.clientId != null && m.clientId == message.clientId) {
          return false;
        }
        return true;
      }).toList()
        ..add(message);
      withoutDuplicate.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _messages = withoutDuplicate;
    });
    _scrollToBottom();
    if (message.senderId != _currentUserId) _markRead();
  }

  /// Reactions changed somewhere: refresh that message if it is on screen.
  void _onReactionEvent(String messageId) {
    if (!mounted) return;
    if (!_messages.any((m) => m.id == messageId)) return;
    _refreshReactions(messageId);
  }

  @override
  void dispose() {
    _messageEvents?.cancel();
    _reactionEvents?.cancel();
    _messageService.unsubscribe();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    try {
      // Opened from user search: no conversation id yet, so resolve (or
      // create) the 1:1 conversation first.
      if (_conversationId.isEmpty) {
        if (_otherUserId == null || _otherUserId!.isEmpty) {
          throw AppException('No conversation selected.');
        }
        final conversation = await ConversationService()
            .getOrCreateDirectConversation(
          currentUserId: _currentUserId,
          otherUserId: _otherUserId!,
        );
        _conversationId = conversation.id;
      }
      final messages =
          await _messageService.getMessages(conversationId: _conversationId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _loading = false;
      });
      // Live updates: the service keeps its cache current; this listener
      // merges incoming messages into the rendered list.
      _messageEvents ??= _messageService.messageEvents.listen(_onMessageEvent);
      _reactionEvents ??=
          _messageService.reactionEvents.listen(_onReactionEvent);
      _messageService.subscribeToConversation(_conversationId);
      if (!_reactionsSubscribed) {
        _reactionsSubscribed = true;
        _messageService.subscribeToReactions();
      }
      // Opening the thread is reading it, which is what clears the unread
      // count on the chat list.
      _markRead();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_load'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AppException ? e : AppException(e.toString());
      });
    }
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _messageController.clear();
    try {
      final message = await _messageService.sendText(
        conversationId: _conversationId,
        senderId: _currentUserId,
        text: text,
      );
      if (!mounted) return;
      setState(() {
        _messages = [..._messages, message];
        _sending = false;
      });
      _scrollToBottom();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_send'});
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is AppException ? e.message : 'Message not sent'),
        ),
      );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openReactionPicker(Message message) async {
    const reactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
            spacing: 8,
            children: [
              for (final reaction in reactions)
                InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.of(context).pop(reaction),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(reaction, style: const TextStyle(fontSize: 26)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    try {
      final applied = await _messageService.toggleReaction(
        messageId: message.id,
        userId: _currentUserId,
        reaction: picked,
      );
      // Refetch this message's reactions rather than guessing: the server is
      // the one place that knows whether the tap replaced or removed one.
      await _refreshReactions(message.id);
      AppLogger.info('reaction_ui_applied',
          details: {'messageId': message.id, 'applied': applied});
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_reaction'});
      _showSnack('Could not update the reaction. ${_reason(e)}');
    }
  }

  String _reason(Object e) => e is AppException ? e.message : e.toString();

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Pulls one message's reactions and swaps them into the loaded list.
  Future<void> _refreshReactions(String messageId) async {
    try {
      final reactions = await _messageService.getReactions(messageId);
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .map((m) => m.id == messageId ? m.copyWith(reactions: reactions) : m)
            .toList();
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_refresh_reactions'});
    }
  }

  void _showMessageActions(Message message) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('React'),
              onTap: () {
                Navigator.of(context).pop();
                _openReactionPicker(message);
              },
            ),
            if (message.senderId == _currentUserId && !message.isDeleted)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete message'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _confirmDelete(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Message info'),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: 'Voice call',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _openCall(isVideo: false),
          ),
          IconButton(
            tooltip: 'Video call',
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _openCall(isVideo: true),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageList()),
          _buildComposer(),
        ],
      ),
    );
  }

  /// Opens the call UI. Media is not yet implemented (docs/calls.md), so this
  /// intentionally surfaces a notice instead of pretending a call connected.
  void _openCall({required bool isVideo}) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isVideo ? 'Video calling' : 'Voice calling'),
        content: const Text(
          'Calling is not available yet. It requires WebRTC media plus '
          'signalling and STUN/TURN servers, which are not configured for '
          'this build. See docs/calls.md.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Deleting is one tap away from a long-press, so it asks first — but only
  /// once, and it reports failure instead of failing silently.
  Future<void> _confirmDelete(Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this message?'),
        content: const Text(
          'It will be replaced with "This message was deleted" for everyone in '
          'the chat. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _messageService.deleteMessage(
        messageId: message.id,
        senderId: _currentUserId,
      );
      // Mark it locally as well: the UPDATE arrives over realtime too, but the
      // bubble must not keep showing the old text if that channel is slow.
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .map((m) =>
                m.id == message.id ? m.copyWith(deletedAt: DateTime.now()) : m)
            .toList();
      });
      AppLogger.info('message_delete_applied', details: {'messageId': message.id});
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_delete'});
      _showSnack('Could not delete the message. ${_reason(e)}');
    }
  }

  /// Records how far this user has read, which is what clears the unread badge
  /// on the chat list. Nothing called this before, so a conversation that had
  /// ever received a message stayed unread forever.
  Future<void> _markRead() async {
    if (_conversationId.isEmpty || _messages.isEmpty) return;
    final lastFromOther = _messages.lastWhere(
      (m) => m.senderId != _currentUserId,
      orElse: () => _messages.last,
    );
    try {
      await ConversationService().markRead(
        conversationId: _conversationId,
        messageId: lastFromOther.id,
      );
    } catch (e, st) {
      // Not fatal: the badge simply stays. Logged so it is not invisible.
      AppLogger.error(e, st, {'where': 'chat_mark_read'});
    }
  }

  Widget _buildMessageList() {
    if (_loading) return const AppLoading(message: 'Loading messages...');
    if (_error != null) {
      return AppError(exception: _error!, onRetry: _loadMessages);
    }
    if (_messages.isEmpty) {
      return const AppEmptyState(
        icon: Icons.chat_bubble_outline,
        title: 'No messages yet',
        subtitle: 'Say hello to start the conversation.',
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        return MessageBubble(
          message: message,
          isMe: message.senderId == _currentUserId,
          showStatus: message.senderId == _currentUserId,
          reactionChips:
              ReactionSummary.chips(message.reactions, _currentUserId),
          onLongPress: () => _showMessageActions(message),
        );
      },
    );
  }

  Widget _buildComposer() {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Attach',
              icon: const Icon(Icons.attach_file),
              onPressed: () => Navigator.of(context)
                  .pushNamed(AppRoutes.attachmentPreview),
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: colors.surfaceContainerHighest,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              tooltip: 'Send',
              icon: _sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_rounded),
              onPressed: _sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
