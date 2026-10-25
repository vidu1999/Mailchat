import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/widgets/app_button.dart';

/// Group details: member list, roles and leave-group action.
///
/// Role changes are enforced server-side (owner-only); the UI only offers the
/// actions the backend permits and surfaces failures verbatim.
class GroupDetailsScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const GroupDetailsScreen({super.key, this.arguments});

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen> {
  List<Map<String, dynamic>> _members = const [];
  bool _loading = true;
  AppException? _error;

  late final String _conversationId;
  late final String _title;
  late final String _currentUserId;

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _conversationId = (args['conversationId'] as String?) ?? '';
    _title = (args['title'] as String?) ?? 'Group';
    _currentUserId =
        (args['currentUserId'] as String?) ??
        (SupabaseClient.instance.userId ?? '');
    _load();
  }

  Future<void> _load() async {
    if (_conversationId.isEmpty) {
      setState(() {
        _loading = false;
        _error = AppException('No group selected.');
      });
      return;
    }
    try {
      final members =
          await ConversationService().getMembers(_conversationId);
      if (!mounted) return;
      setState(() {
        _members = members;
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'group_details'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AppException ? e : AppException(e.toString());
      });
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text('You will stop receiving messages from this group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ConversationService()
          .leaveGroup(conversationId: _conversationId, userId: _currentUserId);
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil(AppRoutes.chatList, (route) => false);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'group_leave'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                e is AppException ? e.message : 'Could not leave the group.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!.message, textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  children: [
                    ListTile(
                      leading: CircleAvatar(
                        radius: 24,
                        backgroundColor: colors.primaryContainer,
                        child: Icon(Icons.groups_outlined,
                            color: colors.onPrimaryContainer),
                      ),
                      title: Text(_title),
                      subtitle: Text('${_members.length} members'),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Members',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (final member in _members)
                      ListTile(
                        leading: CircleAvatar(
                          radius: 20,
                          backgroundColor: colors.surfaceVariant,
                          child: Text(
                            (member['username'] as String? ?? '?')
                                .substring(0, 1)
                                .toUpperCase(),
                          ),
                        ),
                        title: Text(
                          (member['display_name'] as String?) ??
                              (member['username'] as String?) ??
                              'Member',
                        ),
                        subtitle: Text('@${member['username'] ?? 'unknown'}'),
                        trailing: (member['role'] as String? ?? 'member') ==
                                'member'
                            ? null
                            : Chip(
                                label: Text(
                                  member['role'] as String,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                      ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          AppButton(
                            text: 'Add members',
                            variant: AppButtonVariant.outlined,
                            onPressed: () => Navigator.of(context)
                                .pushNamed(AppRoutes.newConversation),
                          ),
                          const SizedBox(height: 12),
                          AppButton(
                            text: 'Leave group',
                            onPressed: _leaveGroup,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
