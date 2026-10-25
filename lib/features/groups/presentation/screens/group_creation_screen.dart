import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Creates a group conversation: name, optional description and members.
class GroupCreationScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const GroupCreationScreen({super.key, this.arguments});

  @override
  State<GroupCreationScreen> createState() => _GroupCreationScreenState();
}

class _GroupCreationScreenState extends State<GroupCreationScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _searchController = TextEditingController();
  final Set<String> _selectedIds = {};
  List<Profile> _results = const [];
  final Map<String, Profile> _selected = {};
  bool _creating = false;
  String? _errorMessage;

  String get _ownerId =>
      (widget.arguments?['currentUserId'] as String?) ??
      (SupabaseClient.instance.userId ?? '');

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    try {
      final results = await ProfileService().searchProfiles(query.trim());
      if (!mounted) return;
      setState(() => _results = results);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'group_search_members'});
    }
  }

  void _toggle(Profile profile) {
    setState(() {
      if (_selectedIds.contains(profile.id)) {
        _selectedIds.remove(profile.id);
        _selected.remove(profile.id);
      } else {
        _selectedIds.add(profile.id);
        _selected[profile.id] = profile;
      }
    });
  }

  Future<void> _create() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Group name is required.');
      return;
    }
    setState(() {
      _creating = true;
      _errorMessage = null;
    });
    try {
      final conversation = await ConversationService().createGroup(
        ownerId: _ownerId,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        memberIds: _selectedIds.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(
        AppRoutes.groupDetails,
        arguments: {
          'conversationId': conversation.id,
          'title': conversation.name ?? 'Group',
          'currentUserId': _ownerId,
        },
      );
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'group_create'});
      if (!mounted) return;
      setState(() {
        _creating = false;
        _errorMessage =
            e is AppException ? e.message : 'Could not create the group.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppInput(
            controller: _nameController,
            label: 'Group name',
            hint: 'e.g. Weekend plans',
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          AppInput(
            controller: _descriptionController,
            label: 'Description (optional)',
            hint: 'What is this group about?',
            maxLines: 2,
          ),
          const SizedBox(height: 24),
          Text('Add members',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface)),
          const SizedBox(height: 10),
          AppInput(
            controller: _searchController,
            label: 'Search users',
            hint: 'Username or email',
            onChanged: _search,
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final profile in _selected.values)
                  Chip(
                    avatar: AppAvatar(profile: profile, radius: 12),
                    label: Text(profile.displayNameOrUsername),
                    onDeleted: () => _toggle(profile),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          for (final profile in _results)
            CheckboxListTile(
              value: _selectedIds.contains(profile.id),
              onChanged: (_) => _toggle(profile),
              secondary: AppAvatar(profile: profile, radius: 20),
              title: Text(profile.displayNameOrUsername),
              subtitle: Text('@${profile.username}'),
              controlAffinity: ListTileControlAffinity.trailing,
            ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(_errorMessage!,
                style: TextStyle(color: colors.error, fontSize: 13)),
          ],
          const SizedBox(height: 24),
          AppButton(
            text: 'Create group',
            isLoading: _creating,
            onPressed: _create,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
