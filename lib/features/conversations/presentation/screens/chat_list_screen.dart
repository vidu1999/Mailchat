import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/shared/models/conversation.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';
import 'package:mailchat/shared/widgets/app_text.dart';

/// Primary screen: list of conversations (direct + group) with unread badges.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<ConversationListItem> _items = const [];
  bool _loading = true;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await ConversationService().listConversations();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'chat_list'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AppException ? e : AppException(e.toString());
      });
    }
  }

  void _openConversation(ConversationListItem item) {
    final isGroup = item.conversation.type == 'group';
    Navigator.of(context).pushNamed(
      isGroup ? AppRoutes.groupDetails : AppRoutes.directChat,
      arguments: {
        'conversationId': item.conversation.id,
        'title': isGroup
            ? (item.conversation.name ?? 'Group')
            : (item.otherParticipant?.displayNameOrUsername ?? 'Chat'),
        'otherUserId': item.otherParticipant?.id,
      },
    );
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
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New conversation',
        onPressed: () =>
            Navigator.of(context).pushNamed(AppRoutes.newConversation),
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const AppLoading(message: 'Loading conversations...');
    if (_error != null) return AppError(exception: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return const AppEmptyState(
        icon: Icons.forum_outlined,
        title: 'No conversations yet',
        subtitle: 'Start a chat by searching for a username or email.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
        itemBuilder: (context, index) {
          final item = _items[index];
          final isGroup = item.conversation.type == 'group';
          final title = isGroup
              ? (item.conversation.name ?? 'Group')
              : (item.otherParticipant?.displayNameOrUsername ?? 'Unknown');
          final subtitle = item.lastMessageText ?? 'No messages yet';

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: AppAvatar(
              profile: isGroup ? null : item.otherParticipant,
              radius: 24,
              child: isGroup
                  ? const Icon(Icons.groups_outlined, size: 24)
                  : null,
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
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
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (item.lastMessageAt != null)
                  AppText.caption(
                      AppFormatters.chatTimestamp(item.lastMessageAt!)),
                const SizedBox(height: 6),
                if (item.unreadCount > 0)
                  _UnreadBadge(
                    count: item.unreadCount,
                    muted: item.isMuted,
                  )
                else if (item.isMuted)
                  Icon(Icons.notifications_off_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
              ],
            ),
            onTap: () => _openConversation(item),
          );
        },
      ),
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
        color: muted ? colors.surfaceVariant : colors.primary,
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
