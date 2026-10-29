import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';

import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/features/calls/domain/call_model.dart';
import 'package:mailchat/features/calls/presentation/screens/active_call_screen.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/models/peer_presence.dart';
import 'package:mailchat/shared/models/reaction_summary.dart';
import 'package:mailchat/shared/models/receipt_state.dart';
import 'package:mailchat/shared/services/attachment_service.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/services/message_service.dart';
import 'package:mailchat/shared/services/presence_service.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';
import 'package:mailchat/shared/widgets/message_bubble.dart';
import 'package:mailchat/shared/widgets/offline_banner.dart';

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
  bool _receiptsSubscribed = false;
  StreamSubscription<String>? _receiptEvents;
  Message? _replyTo;
  final _attachments = AttachmentService();
  final Map<String, Future<String>> _signedAttachmentUrls = {};
  final List<_PendingAttachment> _pendingAttachments = <_PendingAttachment>[];
  bool _sendingAttachment = false;

  final _presence = PresenceService();
  StreamSubscription<Set<String>>? _onlineEvents;
  /// Last known durable presence for the other participant (direct chats only).
  PeerPresence? _peerPresence;
  /// Guards against a burst of read writes: incoming messages can arrive faster
  /// than one round trip.
  bool _markingRead = false;
  bool _markReadAgain = false;
  Timer? _presenceRefreshTimer;
  Timer? _receiptPoll;
  bool _isGroup = false;
  StreamSubscription<Set<String>>? _typingEvents;
  Set<String> _onlineUserIds = const {};
  Set<String> _typingUserIds = const {};
  Timer? _typingStopTimer;
  bool _announcedTyping = false;

  /// Someone else in this thread is typing.
  bool get _peerTyping => _typingUserIds.isNotEmpty;

  /// Online state of the other participant, or null when unknown. Null renders
  /// nothing rather than a misleading grey dot.
  bool? get _peerOnline {
    final other = _otherUserId;
    if (other == null || _onlineUserIds.isEmpty) return null;
    return _onlineUserIds.contains(other);
  }

  /// The line under the title: typing, then live presence, then the durable
  /// "Online"/"last seen ..." from `get_presence()`.
  ///
  /// Null means "say nothing". A user who hid their status must not be shown as
  /// offline, so [PeerPresence.label] returns null for them and that null is
  /// kept rather than papered over.
  String? get _presenceLine {
    if (_peerTyping) return 'typing...';
    if (_peerOnline == true) return 'Online';
    final remote = _peerPresence;
    if (remote != null) return remote.label();
    if (_peerOnline == false) return 'Offline';
    return null;
  }
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
    _isGroup = (args['isGroup'] as bool?) ?? false;
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
      var next = message;
      for (final existing in _messages) {
        final same = existing.id == message.id ||
            (message.clientId != null &&
                message.clientId!.isNotEmpty &&
                existing.clientId == message.clientId);
        if (!same) continue;
        next = message.copyWith(
          attachments: message.attachments.isEmpty
              ? existing.attachments
              : message.attachments,
          status: ReceiptState.keepStatus(
            previous: existing.status,
            incoming: message.status,
          ),
        );
        break;
      }
      final withoutDuplicate = _messages.where((m) {
        if (m.id == next.id) return false;
        if (next.clientId != null && m.clientId == next.clientId) {
          return false;
        }
        return true;
      }).toList()
        ..add(next);
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

  /// A receipt changed on one of my messages: recompute that message's tick.
  Future<void> _onReceiptEvent(String messageId) async {
    if (!mounted) return;
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;
    try {
      final rows = await _messageService.getReceipts(messageId);
      if (!mounted) return;
      final status = ReceiptState.keepStatus(
        previous: _messages[index].status,
        incoming: ReceiptState.statusFrom(rows),
      );
      setState(() {
        _messages = _messages
            .map((m) => m.id == messageId ? m.copyWith(status: status) : m)
            .toList();
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_receipts', 'messageId': messageId});
    }
  }

  void _joinPresence() {
    if (_conversationId.isEmpty || _currentUserId.isEmpty) return;
    _presence.join(
      conversationId: _conversationId,
      userId: _currentUserId,
    );
    _onlineEvents ??= _presence.onlineUsers.listen((ids) {
      if (!mounted) return;
      setState(() => _onlineUserIds = ids);
    });
    _typingEvents ??= _presence.typingUsers.listen((ids) {
      if (!mounted) return;
      setState(() => _typingUserIds = ids);
    });
  }

  /// Debounced: one "typing" event on the first keystroke, then one "stopped"
  /// after a pause. Sending per keystroke would flood the channel.
  void _onComposerChanged(String value) {
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_announcedTyping) {
      _announcedTyping = true;
      _presence.setTyping(true);
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(const Duration(seconds: 2), _stopTyping);
  }

  void _stopTyping() {
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    if (!_announcedTyping) return;
    _announcedTyping = false;
    _presence.setTyping(false);
  }

  @override
  void dispose() {
    _messageEvents?.cancel();
    _reactionEvents?.cancel();
    _receiptEvents?.cancel();
    _onlineEvents?.cancel();
    _typingEvents?.cancel();
    _typingStopTimer?.cancel();
    _presenceRefreshTimer?.cancel();
    _receiptPoll?.cancel();
    _presence.dispose();
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
      if (!_receiptsSubscribed) {
        _receiptsSubscribed = true;
        _messageService.subscribeToReceipts();
        _receiptEvents ??=
            _messageService.receiptEvents.listen(_onReceiptEvent);
      }
      _startReceiptPoll();
      // Opening the thread is reading it, which is what clears the unread
      // count on the chat list. Awaited: the list re-reads the view as soon as
      // this screen pops, and a read still in flight would show up as a badge
      // that "did not clear".
      await _markRead();
      _joinPresence();
      _startPresenceRefresh();
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
    if (_sending || _sendingAttachment) return;
    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    if (_pendingAttachments.isNotEmpty) {
      final staged = List<_PendingAttachment>.of(_pendingAttachments);
      setState(() {
        _sending = true;
        _sendingAttachment = true;
      });
      try {
        final message = await _attachments.sendAttachments(
          conversationId: _conversationId,
          senderId: _currentUserId,
          attachments: staged
              .map(
                (file) => AttachmentUpload(
                  fileName: file.fileName,
                  mimeType: file.mimeType,
                  bytes: file.bytes,
                ),
              )
              .toList(),
          text: text,
          replyToMessageId: _replyTo?.id,
        );
        if (!mounted) return;
        setState(() {
          _messages = [
            ..._messages.where((existing) => existing.id != message.id),
            message,
          ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          _pendingAttachments.clear();
          _messageController.clear();
          _sending = false;
          _sendingAttachment = false;
          _replyTo = null;
        });
        _stopTyping();
        _scrollToBottom();
      } catch (e, st) {
        AppLogger.error(e, st, {'where': 'chat_send_attachment_album'});
        if (!mounted) return;
        setState(() {
          _sending = false;
          _sendingAttachment = false;
        });
        _showSnack('Could not send the selected files. ${_reason(e)}');
      }
      return;
    }

    setState(() => _sending = true);
    _messageController.clear();
    try {
      final message = await _messageService.sendText(
        conversationId: _conversationId,
        senderId: _currentUserId,
        text: text,
        replyToMessageId: _replyTo?.id,
      );
      if (!mounted) return;
      setState(() {
        _messages = [..._messages, message];
        _sending = false;
        _replyTo = null;
      });
      _stopTyping();
      _scrollToBottom();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_send'});
      if (!mounted) return;
      _messageController.text = text;
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
            if (!message.isDeleted)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() => _replyTo = message);
                },
              ),
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_title),
            // Typing wins over presence: it is the more specific state, and
            // showing "online" while they are mid-sentence says nothing useful.
            if (_presenceLine != null)
              Text(
                _presenceLine!,
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: _peerTyping ? FontStyle.italic : FontStyle.normal,
                ),
              ),
          ],
        ),
        actions: _isGroup
            // A group has no single presence or call target; its actions are
            // the member list and roles.
            ? [
                IconButton(
                  tooltip: 'Group info',
                  icon: const Icon(Icons.info_outline),
                  onPressed: _openGroupDetails,
                ),
              ]
            : [
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
          // A send that cannot leave the phone must not look like a message that
          // vanished: say the connection is gone, above the thread.
          const OfflineBanner(),
          Expanded(child: _buildMessageList()),
          _buildComposer(),
        ],
      ),
    );
  }

  /// Re-reads receipts for my own messages while this chat is open.
  ///
  /// A realtime receipt event can be missed, and a message update can arrive
  /// without the receipt rows. Without this poll the seen tick never appears.
  void _startReceiptPoll() {
    _receiptPoll ??= Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshOwnReceipts();
    });
    _refreshOwnReceipts();
  }

  Future<void> _refreshOwnReceipts() async {
    if (!mounted || _currentUserId.isEmpty) return;
    final mine = _messages
        .where((message) =>
            message.senderId == _currentUserId &&
            message.status != AppConstants.messageStatusRead &&
            message.status != AppConstants.messageStatusPending &&
            message.status != AppConstants.messageStatusFailed)
        .toList();
    if (mine.length > 12) {
      mine.removeRange(0, mine.length - 12);
    }
    for (final message in mine) {
      try {
        final rows = await _messageService.getReceipts(message.id);
        if (!mounted) return;
        final status = ReceiptState.keepStatus(
          previous: message.status,
          incoming: ReceiptState.statusFrom(rows),
        );
        if (status == message.status) continue;
        setState(() {
          _messages = _messages
              .map((item) =>
                  item.id == message.id ? item.copyWith(status: status) : item)
              .toList();
        });
      } catch (e) {
        AppLogger.warning(
          'chat_receipt_poll_failed',
          details: {'error': e.toString()},
        );
      }
    }
  }

  /// Starts the timer that keeps "last seen" honest while the thread is open.
  /// The presence channel only knows about people in this chat right now, so
  /// without this the line would never change from whatever it was on open.
  void _startPresenceRefresh() {
    if (_isGroup) return;
    final other = _otherUserId;
    if (other == null || other.isEmpty) return;
    _presenceRefreshTimer?.cancel();
    _presenceRefreshTimer = Timer.periodic(
      PresenceService.heartbeatInterval,
      (_) => _refreshPeerPresence(),
    );
    _refreshPeerPresence();
  }

  Future<void> _refreshPeerPresence() async {
    final other = _otherUserId;
    if (other == null || other.isEmpty) return;
    try {
      final presence = await _presence.presenceFor([other]);
      if (!mounted) return;
      setState(() => _peerPresence = presence[other]);
    } catch (e, st) {
      // Presence is decoration; the thread works without it.
      AppLogger.error(e, st, {'where': 'chat_peer_presence'});
    }
  }

  void _openGroupDetails() {
    Navigator.of(context).pushNamed(
      AppRoutes.groupDetails,
      arguments: {
        'conversationId': _conversationId,
        'title': _title,
        'currentUserId': _currentUserId,
      },
    );
  }

  /// Places a call.
  ///
  /// The screen prepares the camera and microphone *before* it creates the call
  /// row, so a refused permission produces "could not start" rather than a ring
  /// nobody can answer with sound.
  void _openCall({required bool isVideo}) {
    final other = _otherUserId;
    if (other == null || other.isEmpty) {
      _showSnack('This chat has no other participant to call.');
      return;
    }
    if (_conversationId.isEmpty) {
      _showSnack('Open the chat before calling.');
      return;
    }
    if (!callMediaConnected) {
      // Unreachable with the current build; kept so that flipping the flag off
      // cannot leave a button that dials into nothing.
      _showSnack('Calling is not available in this build.');
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ActiveCallScreen(
          arguments: {
            'conversationId': _conversationId,
            'peerId': other,
            'peerName': _title,
            'selfId': _currentUserId,
            'isVideo': isVideo,
            'isCaller': true,
          },
        ),
      ),
    );
  }

  /// Stages selected files in the composer. Nothing is uploaded until Send.
  Future<void> _pickAttachment() async {
    if (_sendingAttachment || _sending || _conversationId.isEmpty) return;
    setState(() => _sendingAttachment = true);
    try {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Photos'),
                subtitle: const Text('Select multiple images for one album'),
                onTap: () => Navigator.of(context).pop('image'),
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('File'),
                subtitle: const Text('Up to 10 MB per file'),
                onTap: () => Navigator.of(context).pop('file'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || choice == null) return;

      final List<XFile> files;
      if (choice == 'image') {
        files = await openFiles(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Images',
              extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'],
            ),
          ],
        );
      } else {
        final file = await openFile();
        files = file == null ? <XFile>[] : <XFile>[file];
      }
      if (files.isEmpty) return;
      if (_pendingAttachments.length + files.length > 10) {
        _showSnack('You can attach up to 10 files to one message.');
        return;
      }

      final staged = <_PendingAttachment>[];
      for (final file in files) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          _showSnack('${file.name} is empty and was not added.');
          continue;
        }
        if (bytes.length > AttachmentService.maxBytes) {
          _showSnack('${file.name} is over 10 MB and was not added.');
          continue;
        }
        staged.add(
          _PendingAttachment(
            fileName: file.name,
            mimeType: AttachmentService.mimeTypeFor(file.name),
            bytes: bytes,
          ),
        );
      }
      if (staged.isNotEmpty && mounted) {
        setState(() => _pendingAttachments.addAll(staged));
      }
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_stage_attachment'});
      if (mounted) _showSnack('Could not add the selected files.');
    } finally {
      if (mounted) setState(() => _sendingAttachment = false);
    }
  }

  void _removePendingAttachment(int index) {
    if (index < 0 || index >= _pendingAttachments.length) return;
    setState(() => _pendingAttachments.removeAt(index));
  }

  /// Resolves private storage URLs once per attachment for inline previews.
  Future<String> _attachmentUrl(MessageAttachment attachment) {
    return _signedAttachmentUrls.putIfAbsent(
      attachment.storagePath,
      () => _attachments.signedUrl(attachment),
    );
  }

  /// Opens one attachment. The bucket is private, so a signed URL is fetched
  /// here rather than stored on the message.
  Future<void> _openAttachment(MessageAttachment attachment) async {
    try {
      final url = await _attachments.signedUrl(attachment);
      if (!mounted) return;
      Navigator.of(context).pushNamed(
        AppRoutes.mediaViewer,
        arguments: {
          'fileName': attachment.fileName,
          'url': url,
          'mimeType': attachment.mimeType,
          'fileSize': attachment.fileSize,
        },
      );
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_open_attachment'});
      _showSnack('Could not open that file. ${_reason(e)}');
    }
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

  /// Records that this user has read the thread, which is what clears the
  /// unread badge on the chat list.
  ///
  /// The cursor is chosen by the database (`mark_conversation_read`, migration
  /// 0009), not by this screen: an unloaded page, a missed Realtime event or a
  /// second device used to leave the cursor behind the newest message, and the
  /// badge the user had just cleared came back. Nothing here needs the message
  /// list to be non-empty either.
  ///
  /// Calls are coalesced: a burst of incoming messages produces one write, and
  /// at most one follow-up.
  Future<void> _markRead() async {
    if (_conversationId.isEmpty) return;
    if (_markingRead) {
      _markReadAgain = true;
      return;
    }
    _markingRead = true;
    try {
      final remaining =
          await ConversationService().markConversationRead(_conversationId);
      if (remaining == null) {
        AppLogger.warning('chat_mark_read_unreadable_reply', details: {
          'conversationId': _conversationId,
        });
      } else if (remaining > 0) {
        // Not an error: something arrived while the write ran. The next
        // message event marks it too.
        AppLogger.info('chat_mark_read_still_unread', details: {
          'conversationId': _conversationId,
          'remaining': remaining,
        });
      }
      // The receipt rows are what turn the sender's tick from sent to read.
      // They are written by the reader, because RLS only lets a recipient
      // create their own.
      await _messageService.markReceivedAndRead(
        conversationId: _conversationId,
        userId: _currentUserId,
      );
    } catch (e, st) {
      // Not fatal: the badge simply stays. Logged so it is not invisible.
      AppLogger.error(e, st, {'where': 'chat_mark_read'});
    } finally {
      _markingRead = false;
    }
    if (_markReadAgain) {
      _markReadAgain = false;
      await _markRead();
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

    final timeline = <_ChatTimelineItem>[];
    DateTime? previousDay;
    for (final message in _messages) {
      final localDate = message.createdAt.toLocal();
      final sameDay = previousDay != null &&
          previousDay.year == localDate.year &&
          previousDay.month == localDate.month &&
          previousDay.day == localDate.day;
      if (!sameDay) {
        timeline.add(_ChatTimelineItem.day(
          AppFormatters.chatDayLabel(localDate),
        ));
      }
      timeline.add(_ChatTimelineItem.message(message));
      previousDay = localDate;
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      itemCount: timeline.length,
      itemBuilder: (context, index) {
        final entry = timeline[index];
        if (entry.dayLabel != null) {
          final colors = Theme.of(context).colorScheme;
          return Center(
            child: Container(
              key: ValueKey('chat-day-${entry.dayLabel}-$index'),
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                entry.dayLabel!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        final message = entry.message!;
        return MessageBubble(
          key: ValueKey(message.id),
          message: message,
          isMe: message.senderId == _currentUserId,
          showStatus: message.senderId == _currentUserId,
          reactionChips:
              ReactionSummary.chips(message.reactions, _currentUserId),
          replyPreview: _replyPreviewFor(message),
          attachments: message.attachments,
          attachmentUrl: _attachmentUrl,
          onAttachmentTap: _openAttachment,
          onLongPress: () => _showMessageActions(message),
        );
      },
    );
  }

  /// One-line summary of the parent message, or a placeholder when it is not
  /// in the loaded page. Either way the reply is visible: silently dropping the
  /// quote would make the bubble look like an ordinary message.
  String? _replyPreviewFor(Message message) {
    final parentId = message.replyToMessageId;
    if (parentId == null) return null;
    for (final candidate in _messages) {
      if (candidate.id != parentId) continue;
      if (candidate.isDeleted) return 'Message deleted';
      final text = candidate.text?.trim();
      if (text != null && text.isNotEmpty) return text;
      return 'Attachment';
    }
    return 'Earlier message';
  }

  Widget _replyStrip(ColorScheme colors) {
    final reply = _replyTo;
    if (reply == null) return const SizedBox.shrink();
    final text = reply.text?.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${reply.senderId == _currentUserId ? 'yourself' : 'them'}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
                Text(
                  (text == null || text.isEmpty) ? 'Attachment' : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _pendingAttachmentStrip() {
    if (_pendingAttachments.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 84,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        scrollDirection: Axis.horizontal,
        itemCount: _pendingAttachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final file = _pendingAttachments[index];
          return Stack(
            children: [
              Container(
                width: 68,
                height: 68,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: file.isImage
                    ? Image.memory(
                        file.bytes,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                        ),
                      )
                    : Tooltip(
                        message: file.fileName,
                        child: const Icon(Icons.insert_drive_file_outlined),
                      ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                  padding: EdgeInsets.zero,
                  tooltip: 'Remove ${file.fileName}',
                  onPressed: () => _removePendingAttachment(index),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildComposer() {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _replyStrip(colors),
            _pendingAttachmentStrip(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attach',
                    icon: _sendingAttachment
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.attach_file),
                    onPressed: (_sendingAttachment || _sending)
                        ? null
                        : _pickAttachment,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      readOnly: _sending,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Message',
                        filled: true,
                        fillColor: colors.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: _onComposerChanged,
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
                    onPressed: (_sending || _sendingAttachment) ? null : _send,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the chat timeline: a day heading or a message bubble.
class _ChatTimelineItem {
  const _ChatTimelineItem.day(this.dayLabel) : message = null;
  const _ChatTimelineItem.message(this.message) : dayLabel = null;

  final String? dayLabel;
  final Message? message;
}


class _PendingAttachment {
  const _PendingAttachment({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final Uint8List bytes;

  bool get isImage => mimeType.startsWith('image/');
}
