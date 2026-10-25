import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/message.dart';
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

  late final String _conversationId;
  late final String _title;
  late final String _currentUserId;

  List<Message> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _conversationId = (args['conversationId'] as String?) ?? '';
    _title = (args['title'] as String?) ?? 'Chat';
    _currentUserId =
        (args['currentUserId'] as String?) ??
        (SupabaseClient.instance.userId ?? '');
    _loadMessages();
  }

  @override
  void dispose() {
    _messageService.unsubscribe();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    if (_conversationId.isEmpty) {
      setState(() {
        _loading = false;
        _error = AppException('No conversation selected.');
      });
      return;
    }
    try {
      final messages =
          await _messageService.getMessages(conversationId: _conversationId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _loading = false;
      });
      _messageService.subscribeToConversation(_conversationId);
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
      await _messageService.toggleReaction(
        messageId: message.id,
        userId: _currentUserId,
        reaction: picked,
      );
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_reaction'});
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
            if (message.senderId == _currentUserId)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _messageService.deleteMessage(
                    messageId: message.id,
                    senderId: _currentUserId,
                  );
                  if (mounted) _loadMessages();
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
                  fillColor: colors.surfaceVariant,
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
