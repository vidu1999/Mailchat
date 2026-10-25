import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';

/// Lists users the current user has blocked, with unblock action.
///
/// Reads `user_blocks` directly; RLS restricts rows to the blocker.
class BlockedUsersScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const BlockedUsersScreen({super.key, this.arguments});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  List<Map<String, dynamic>> _blocks = const [];
  bool _loading = true;
  AppException? _error;

  String get _currentUserId =>
      (widget.arguments?['currentUserId'] as String?) ??
      (SupabaseClient.instance.userId ?? '');

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
      final rows = await SupabaseClient.instance.select(
        'user_blocks',
        select: 'id,blocked_user_id,created_at',
        filter: {'eq': 'blocker_id,$_currentUserId'},
        order: 'created_at.desc',
      );
      if (!mounted) return;
      setState(() {
        _blocks = rows;
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'blocked_users'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is AppException ? e : AppException(e.toString());
      });
    }
  }

  Future<void> _unblock(Map<String, dynamic> block) async {
    try {
      await SupabaseClient.instance.delete(
        'user_blocks',
        filter: {'eq': 'id,${block['id']}'},
      );
      if (!mounted) return;
      setState(() {
        _blocks = _blocks.where((b) => b['id'] != block['id']).toList();
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'unblock'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not unblock this user.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked users')),
      body: _loading
          ? const AppLoading(message: 'Loading blocked users...')
          : _error != null
              ? AppError(exception: _error!, onRetry: _load)
              : _blocks.isEmpty
                  ? const AppEmptyState(
                      icon: Icons.block,
                      title: 'No blocked users',
                      subtitle:
                          'People you block cannot message you or find your '
                          'profile.',
                    )
                  : ListView.separated(
                      itemCount: _blocks.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 16),
                      itemBuilder: (context, index) {
                        final block = _blocks[index];
                        return ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person_off_outlined),
                          ),
                          title: Text(
                            'User ${block['blocked_user_id']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () => _unblock(block),
                            child: const Text('Unblock'),
                          ),
                        );
                      },
                    ),
    );
  }
}
