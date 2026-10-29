import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/shared/models/conversation.dart';
import 'package:mailchat/shared/models/peer_presence.dart';
import 'package:mailchat/features/calls/domain/call_model.dart';
import 'package:mailchat/features/calls/domain/call_service.dart';
import 'package:mailchat/features/calls/presentation/screens/incoming_call_screen.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/services/last_seen_heartbeat.dart';
import 'package:mailchat/shared/services/message_service.dart';
import 'package:mailchat/shared/services/presence_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';
import 'package:mailchat/shared/widgets/app_text.dart';
import 'package:mailchat/shared/widgets/offline_banner.dart';

/// Primary screen: list of conversations (direct + group) with unread badges.
///
/// The badges are not computed here. `conversation_list` counts messages newer
/// than the caller's `last_read_message_id`, so the only correct way to change
/// a badge is to change that cursor (inside the chat) and re-read the view.
/// This screen therefore reloads on two realtime signals — a new message, and a
/// read cursor moving — rather than adjusting its own copy of the number.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final ConversationService _conversationService = ConversationService();
  final MessageService _messageService = MessageService();
  final PresenceService _presenceService = PresenceService();
  final CallService _callService = CallService();
  late final LastSeenHeartbeat _heartbeat;

  /// Set while an incoming-call prompt is on screen, so a burst of realtime
  /// events for the same call cannot stack two prompts.
  String? _ringingCallId;
  StreamSubscription<Call>? _incomingCalls;

  List<ConversationListItem> _items = const [];
  final TextEditingController _chatSearchController = TextEditingController();
  String _chatFilter = 'All';
  String _chatKind = 'All chats';

  /// Online state per direct-chat peer, from `get_presence()`.
  Map<String, PeerPresence> _presence = const {};

  bool _loading = true;
  bool _refreshing = false;
  AppException? _error;

  /// Conversations whose badge the user has just cleared by opening them.
  ///
  /// Their badge is pinned to zero until the server confirms it, so a reload
  /// triggered by the read write itself (or by an incoming message) cannot
  /// flash the old count back while the chat screen is still on top. The pin is
  /// released when the chat screen pops, which is the first moment the user
  /// could see it again — and if the server still counts something then, the
  /// real number is shown rather than hidden.
  final Set<String> _clearedUnread = <String>{};

  StreamSubscription<String>? _inboxSubscription;
  Timer? _reloadDebounce;
  Timer? _presenceTimer;
  Timer? _incomingPoll;
  bool _pollingIncoming = false;

  @override
  void initState() {
    super.initState();
    // Writes this user's heartbeat so other people see "Online" and, once it
    // goes stale, "last seen".
    _heartbeat = LastSeenHeartbeat()..start();
    _load();
    _subscribeInbox();
    _listenForCalls();
    // Realtime can miss the insert. A poll is what makes a computer call
    // actually ring here. Old ringing rows are cleared inside the same call.
    _pollIncoming();
    _incomingPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _pollIncoming(),
    );
    // The heartbeat refreshes other people's status no faster than it writes
    // our own, so polling on the same cadence is enough to keep dots honest.
    _presenceTimer = Timer.periodic(
      PresenceService.heartbeatInterval,
      (_) => _refreshPresence(),
    );
  }

  @override
  void dispose() {
    _incomingCalls?.cancel();
    _chatSearchController.dispose();
    _incomingPoll?.cancel();
    _callService.dispose();
    _inboxSubscription?.cancel();
    _reloadDebounce?.cancel();
    _presenceTimer?.cancel();
    _messageService.disposeInbox();
    _heartbeat.dispose();
    super.dispose();
  }

  /// Rings for a call addressed to this user.
  ///
  /// The subscription lives here rather than in the chat screen because this is
  /// the screen that is on the stack whenever the app is in use — a call
  /// arriving while the user reads the chat list must still ring. Realtime
  /// filters by `callee_id`, so this never sees calls the user placed.
  void _listenForCalls() {
    final userId = SupabaseClient.instance.userId;
    if (userId == null) return;
    _callService.listenForCalls(userId);
    _incomingCalls = _callService.incomingCalls.listen((call) {
      if (!mounted) return;
      // Only a ringing call where this user is the callee is a prompt. Updates
      // (accepted, ended) arrive on the same stream and must be ignored here.
      if (call.state != CallState.ringing) return;
      if (call.calleeId != userId) return;
      // Realtime can replay the ringing row while its prompt/active call is
      // already on top. Do not expire the call underneath the accept flow.
      if (!incomingCallMayBeCleared(
        callId: call.id,
        activeCallId: _ringingCallId,
      )) return;
      if (!incomingCallIsFresh(call.createdAt, DateTime.now().toUtc())) {
        _callService.markMissed(call.id).catchError((Object e) {
          AppLogger.warning(
            'call_stale_clear_failed',
            details: {'error': e.toString()},
          );
          return call;
        });
        return;
      }
      _promptIncoming(call, userId);
    });
  }

  /// Asks the server for a fresh ringing call. This is what rings a computer
  /// call when the realtime insert was missed, and what retires a leftover
  /// ringing row so it cannot appear by itself.
  Future<void> _pollIncoming() async {
    // The chat list stays mounted under both the incoming prompt and the active
    // call. Polling there used to mark the ringing row missed after 45 seconds,
    // while the callee was still preparing media; set_call_status then replied
    // "call is not ringing" when the answer was submitted.
    if (_pollingIncoming || _ringingCallId != null) return;
    final userId = SupabaseClient.instance.userId;
    if (userId == null || !mounted) return;
    _pollingIncoming = true;
    try {
      final call = await _callService.takeFreshIncoming(
        userId,
        shouldClearStale: (callId) => incomingCallMayBeCleared(
          callId: callId,
          activeCallId: _ringingCallId,
        ),
      );
      if (!mounted || call == null) return;
      _promptIncoming(call, userId);
    } catch (e) {
      AppLogger.warning(
        'call_incoming_poll_failed',
        details: {'error': e.toString()},
      );
    } finally {
      _pollingIncoming = false;
    }
  }

  void _promptIncoming(Call call, String userId) {
    if (!mounted || _ringingCallId != null) return;
    if (call.state != CallState.ringing || call.calleeId != userId) return;
    if (!incomingCallIsFresh(call.createdAt, DateTime.now().toUtc())) return;
    _ringingCallId = call.id;
    _showIncomingCall(call, userId);
  }

  Future<void> _showIncomingCall(Call call, String userId) async {
    final callerName = _nameFor(call.callerId);
    AppLogger.info('incoming_call_shown', details: {'callId': call.id});
    var answerStarted = false;
    void releaseCallSlot() {
      if (!mounted || _ringingCallId != call.id) return;
      _ringingCallId = null;
      unawaited(_pollIncoming());
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          arguments: {
            'callId': call.id,
            'conversationId': call.conversationId,
            'callerId': call.callerId,
            'callerName': callerName,
            'selfId': userId,
            'isVideo': call.isVideo,
            // pushReplacement completes this prompt's route future as soon as
            // ActiveCallScreen replaces it. Keep the inbox slot reserved until
            // that active call actually closes, or a still-ringing row is
            // immediately presented again as a second accept/decline prompt.
            'onAnswerStarted': () => answerStarted = true,
            'onActiveCallClosed': releaseCallSlot,
          },
        ),
      ),
    );
    if (!mounted) return;
    if (!answerStarted && _ringingCallId == call.id) {
      _ringingCallId = null;
    }
    // The prompt was answered or declined; the preview may now be stale.
    await _load(quiet: true);
  }

  /// Best available display name for a user id, from what the list already
  /// holds. A call from someone new shows the handle-less fallback rather than
  /// blocking the ring on a network round trip.
  String _nameFor(String userId) {
    for (final item in _items) {
      final other = item.otherParticipant;
      if (other != null && other.id == userId) {
        return other.displayNameOrUsername;
      }
    }
    return 'Incoming call';
  }

  /// New messages and read-cursor changes both mean "the badges are stale".
  void _subscribeInbox() {
    final userId = SupabaseClient.instance.userId;
    if (userId == null) return;
    _messageService.subscribeToInbox(userId);
    _messageService.subscribeToReadCursors(userId);
    _inboxSubscription = _messageService.inboxEvents.listen((_) {
      // A group can produce a burst of rows; one reload per burst is enough.
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(
        const Duration(milliseconds: 400),
        () => _load(quiet: true),
      );
    });
  }

  /// [release] names a conversation whose badge pin should be dropped once this
  /// load has read the server's answer. Used when the chat screen pops.
  Future<void> _load({bool quiet = false, String? release}) async {
    if (quiet) {
      // A background refresh must not blank the list or race itself.
      if (_refreshing) return;
      _refreshing = true;
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final items = await _conversationService.listConversations();

      if (release != null) {
        // The server has now had its say about the conversation the user just
        // read. If it still counts unread messages, the write did not land or
        // the view is not the current definition — say so instead of showing a
        // badge the user already cleared without explanation.
        _clearedUnread.remove(release);
        for (final item in items) {
          if (item.conversation.id != release) continue;
          if (item.unreadCount > 0) {
            AppLogger.warning('unread_count_not_cleared', details: {
              'conversationId': release,
              'count': item.unreadCount,
              'hint': 'read cursor write failed, or conversation_list is stale '
                  '(re-paste supabase/apply_all.sql)',
            });
          }
        }
      }

      final displayed = <ConversationListItem>[
        for (final item in items)
          if (_clearedUnread.contains(item.conversation.id))
            item.copyWith(unreadCount: 0)
          else
            item,
      ];
      if (!mounted) return;
      setState(() {
        _items = displayed;
        _loading = false;
        _error = null;
      });
      await _refreshPresence();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_list'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A failed background refresh keeps the list that is already correct
        // on screen; only an explicit load may show the error page.
        if (!quiet) {
          _error = e is AppException ? e : AppException(e.toString());
        }
      });
    } finally {
      _refreshing = false;
    }
  }

  /// Refreshes the online dots for the direct chats in the list.
  Future<void> _refreshPresence() async {
    final ids = <String>[];
    for (final item in _items) {
      if (item.conversation.isGroup) continue;
      final other = item.otherParticipant;
      if (other != null && other.id.isNotEmpty) ids.add(other.id);
    }
    if (ids.isEmpty) {
      if (_presence.isNotEmpty && mounted) {
        setState(() => _presence = const {});
      }
      return;
    }

    try {
      final presence = await _presenceService.presenceFor(ids);
      if (!mounted) return;
      setState(() => _presence = presence);
    } catch (e, st) {
      // Presence is decoration: the list stays usable without it.
      AppLogger.error(e, st, {'where': 'chat_list_presence'});
    }
  }

  Future<void> _openConversation(ConversationListItem item) async {
    // Opening the thread reads it. Zero the badge first so the list does not
    // contradict the chat the user is standing in, then re-read the server
    // truth on the way back: if recording the read failed, the badge returns,
    // which is the honest outcome.
    _clearedUnread.add(item.conversation.id);
    setState(() {
      _items = [
        for (final i in _items)
          i.conversation.id == item.conversation.id
              ? i.copyWith(unreadCount: 0)
              : i,
      ];
    });

    await Navigator.of(context).pushNamed(
      // Groups get the same message screen as direct chats; the details screen
      // (members, leave) is reached from its app bar instead of replacing it.
      AppRoutes.directChat,
      arguments: {
        'conversationId': item.conversation.id,
        'title': item.title,
        'otherUserId': item.otherParticipant?.id,
        'isGroup': item.conversation.isGroup,
      },
    );

    if (!mounted) return;
    await _load(quiet: true, release: item.conversation.id);
  }

  /// The line under the name: the last message, or what state the chat is in.
  ///
  /// A message of your own is prefixed, which is how every messaging app
  /// distinguishes "you said this" from "they said this" in a one-line preview.
  String _previewText(ConversationListItem item) {
    final text = item.lastMessageText?.trim();
    if (text == null || text.isEmpty) {
      return item.otherParticipant == null && item.conversation.isGroup
          ? 'Group created'
          : 'No messages yet';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MailChat'),
        actions: [
          IconButton(
            tooltip: 'Search users',
            icon: const Icon(Icons.search),
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.searchUsers),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.applicationSettings),
          ),
        ],
      ),
      body: Column(
        children: [
          // An outage is otherwise invisible here: the list keeps its last
          // contents and nothing says why nothing new arrives.
          const OfflineBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New conversation',
        onPressed: () =>
            Navigator.of(context).pushNamed(AppRoutes.newConversation),
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  List<ConversationListItem> get _visibleItems {
    final query = _chatSearchController.text.trim().toLowerCase();
    final items = _items.where((item) {
      final isGroup = item.conversation.isGroup;
      if (_chatFilter == 'Unread' && item.unreadCount == 0) return false;
      if (_chatFilter == 'Favourites' && !item.isFavorite) return false;
      if (_chatKind == 'Groups' && !isGroup) return false;
      if (_chatKind == 'Direct' && isGroup) return false;
      if (query.isNotEmpty &&
          !'${item.title} ${_previewText(item)}'.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return (b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0));
      });
    return items;
  }

  Future<void> _setListPreference(
    ConversationListItem item, {
    bool? favorite,
    bool? pinned,
  }) async {
    final index = _items.indexWhere(
      (entry) => entry.conversation.id == item.conversation.id,
    );
    if (index < 0) return;
    final updated = item.copyWith(isFavorite: favorite, isPinned: pinned);
    setState(() => _items[index] = updated);
    try {
      await _conversationService.setListPreference(
        conversationId: item.conversation.id,
        isFavorite: favorite,
        isPinned: pinned,
      );
      await _load(quiet: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _items[index] = item);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update chat preferences: $error')),
      );
    }
  }

  Widget _buildBody() {
    if (_loading) return const AppLoading(message: 'Loading conversations...');
    if (_error != null) return AppError(exception: _error!, onRetry: _load);

    final items = _visibleItems;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _chatSearchController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search or start a new chat',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _chatSearchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _chatSearchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close),
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              children: [
                for (final filter in ['All', 'Unread', 'Favourites'])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(
                        filter == 'Unread'
                            ? 'Unread ${_items.fold<int>(
                                0,
                                (sum, item) => sum + item.unreadCount,
                              )}'
                            : filter,
                      ),
                      selected: _chatFilter == filter,
                      onSelected: (_) => setState(() => _chatFilter = filter),
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Filter chats',
                  initialValue: _chatKind,
                  onSelected: (value) => setState(() => _chatKind = value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'All chats', child: Text('All chats')),
                    PopupMenuItem(value: 'Direct', child: Text('Direct chats')),
                    PopupMenuItem(value: 'Groups', child: Text('Groups')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(
                      Icons.filter_list,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
              child: AppEmptyState(
                icon: _chatFilter == 'Favourites'
                    ? Icons.star_border_rounded
                    : Icons.forum_outlined,
                title: _items.isEmpty ? 'No conversations yet' : 'No matching chats',
                subtitle: _items.isEmpty
                    ? 'Start a chat by searching for a username or email.'
                    : 'Try another filter or search term.',
              ),
            )
          else
            for (final item in items) ...[
              _buildConversationTile(item),
              const Divider(height: 1, indent: 76),
            ],
        ],
      ),
    );
  }

  Widget _buildConversationTile(ConversationListItem item) {
    final isGroup = item.conversation.isGroup;
    final title = item.title;
    final senderIsMe = item.lastMessageSenderId == SupabaseClient.instance.userId;
    final subtitle = senderIsMe && item.lastMessageText != null
        ? '✓ ${_previewText(item)}'
        : _previewText(item);
    final otherId = item.otherParticipant?.id;
    final presence = otherId == null ? null : _presence[otherId];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: AppAvatar(
        profile: isGroup ? null : item.otherParticipant,
        radius: 25,
        online: presence?.isOnline ?? false,
        child: isGroup ? const Icon(Icons.groups_outlined, size: 24) : null,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: item.unreadCount > 0 ? FontWeight.w700 : FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: SizedBox(
        width: 94,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (item.lastMessageAt != null)
              AppText.caption(AppFormatters.chatTimestamp(item.lastMessageAt!)),
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (item.isPinned)
                  Icon(Icons.push_pin, size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                if (item.isMuted)
                  Icon(Icons.notifications_off_outlined, size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                if (item.unreadCount > 0) ...[
                  const SizedBox(width: 5),
                  _UnreadBadge(count: item.unreadCount, muted: item.isMuted),
                ] else if (item.isFavorite)
                  Icon(Icons.star_rounded, size: 16,
                      color: Theme.of(context).colorScheme.primary),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 180),
                  iconSize: 18,
                  tooltip: 'Chat options',
                  onSelected: (value) {
                    if (value == 'favorite') {
                      _setListPreference(item, favorite: !item.isFavorite);
                    } else {
                      _setListPreference(item, pinned: !item.isPinned);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'favorite',
                      child: Text(item.isFavorite
                          ? 'Remove from favourites'
                          : 'Add to favourites'),
                    ),
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(item.isPinned ? 'Unpin chat' : 'Pin chat'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      onTap: () => _openConversation(item),
    );
  }

}

class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool muted;

  const _UnreadBadge({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: muted ? colors.surfaceContainerHighest : colors.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: muted ? colors.onSurfaceVariant : colors.onPrimary,
        ),
      ),
    );
  }
}
