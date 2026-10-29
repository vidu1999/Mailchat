import 'package:flutter/material.dart';

import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/services/notification_service.dart';

/// Account-backed notification inbox. Selecting an item marks it read and
/// navigates to the related conversation or call history (an in-app deep link).
class NotificationInboxScreen extends StatefulWidget {
  const NotificationInboxScreen({super.key});

  @override
  State<NotificationInboxScreen> createState() => _NotificationInboxScreenState();
}

class _NotificationInboxScreenState extends State<NotificationInboxScreen> {
  final NotificationService _service = NotificationService();
  List<MailNotification> _items = const [];
  bool _loading = true;
  bool _markingAll = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _service.subscribe();
    _service.newNotifications.listen((_) => _load());
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await _service.list();
      if (mounted) setState(() { _items = items; _loading = false; _loadError = null; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _loadError = error.toString(); });
    }
  }

  Future<void> _markAll() async {
    setState(() => _markingAll = true);
    try {
      await _service.markAllRead();
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update notifications.')),
        );
      }
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  Future<void> _open(MailNotification item) async {
    if (!item.read) {
      try { await _service.markRead(item.id); } catch (_) {}
    }
    if (!mounted) return;
    if (item.type == 'missed_call') {
      Navigator.of(context).pushNamed(AppRoutes.callHistory);
      return;
    }
    final conversationId = item.payload['conversationId'];
    if (conversationId is! String || conversationId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This notification has no conversation link.')),
      );
      return;
    }
    final isGroup = item.payload['conversationType'] == 'group';
    Navigator.of(context).pushNamed(AppRoutes.directChat, arguments: {
      'conversationId': conversationId,
      'isGroup': isGroup,
      'title': item.payload['conversationName'] is String &&
              (item.payload['conversationName'] as String).isNotEmpty
          ? item.payload['conversationName']
          : item.title,
      if (item.payload['actorId'] is String)
        'otherUserId': item.payload['actorId'],
    });
  }

  String _date(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour < 12 ? 'AM' : 'PM';
    return '${local.day}/${local.month}/${local.year} · $hour:$minute $period';
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          actions: [
            TextButton(
              onPressed: _markingAll || !_items.any((item) => !item.read)
                  ? null
                  : _markAll,
              child: const Text('Mark all read'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not load notifications.'),
                      const SizedBox(height: 8),
                      OutlinedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ))
                : _items.isEmpty
                ? const Center(child: Text('You’re all caught up.'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final icon = switch (item.type) {
                          'missed_call' => Icons.call_missed,
                          'system' => Icons.info_outline,
                          _ => Icons.chat_bubble_outline,
                        };
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: item.read
                                ? Theme.of(context).colorScheme.surfaceContainerHighest
                                : Theme.of(context).colorScheme.primaryContainer,
                            child: Icon(icon),
                          ),
                          title: Text(item.title,
                              style: TextStyle(fontWeight: item.read ? FontWeight.normal : FontWeight.w700)),
                          subtitle: Text('${item.body}\n${_date(item.createdAt)}'),
                          isThreeLine: true,
                          trailing: item.read ? null : const Icon(Icons.circle, size: 10),
                          onTap: () => _open(item),
                        );
                      },
                    ),
                  ),
      );
}
