import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/models/profile_search.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_input.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';

/// New conversation chooser: start a 1:1 chat by username, or create a group.
class NewConversationScreen extends StatefulWidget {
  const NewConversationScreen({super.key});

  @override
  State<NewConversationScreen> createState() => _NewConversationScreenState();
}

class _NewConversationScreenState extends State<NewConversationScreen> {
  final _controller = TextEditingController();
  List<Profile> _results = const [];
  bool _searching = false;
  bool _hasSearched = false;
  AppException? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final typed = SearchQuery(_controller.text).normalised();
    if (!typed.isSearchable) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await ProfileService().searchProfiles(typed.text);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        _hasSearched = true;
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'new_conversation_search'});
      if (!mounted) return;
      setState(() {
        _searching = false;
        _hasSearched = true;
        _error = e is AppException ? e : AppException(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New conversation')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: [
                AppInput(
                  controller: _controller,
                  label: 'Search by username or email',
                  hint: 'jane.doe or jane@example.com',
                  textInputAction: TextInputAction.search,
                  onEditingComplete: _search,
                ),
                const SizedBox(height: 12),
                AppButton(
                  text: 'Search',
                  isLoading: _searching,
                  onPressed: _search,
                ),
                const SizedBox(height: 8),
                AppButton(
                  text: 'Create a group',
                  variant: AppButtonVariant.outlined,
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.groupCreation),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_searching) return const AppLoading();
    if (_error != null) return AppError(exception: _error!, onRetry: _search);
    if (!_hasSearched) {
      return const AppEmptyState(
        icon: Icons.group_add_outlined,
        title: 'Start a conversation',
        subtitle: 'Search for someone by username, display name, or full '
            'email address.',
      );
    }
    if (_results.isEmpty) {
      // Not const: the wording depends on whether an address or a handle was
      // searched for.
      return AppEmptyState(
        icon: Icons.search_off,
        title: 'No users found',
        subtitle: SearchQuery(_controller.text).normalised().emptyResultMessage,
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final profile = _results[index];
        return ListTile(
          leading: AppAvatar(profile: profile, radius: 22),
          title: Text(profile.displayNameOrUsername),
          subtitle: Text(
            profile.matchedBy == 'email'
                ? '@${profile.username} · matched by email'
                : '@${profile.username}',
          ),
          onTap: () => Navigator.of(context).pushReplacementNamed(
            AppRoutes.directChat,
            arguments: {
              'otherUserId': profile.id,
              'title': profile.displayNameOrUsername,
            },
          ),
        );
      },
    );
  }
}
