import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';

/// User search by username or email (email-based discovery, no phone contacts).
class SearchUsersScreen extends StatefulWidget {
  const SearchUsersScreen({super.key});

  @override
  State<SearchUsersScreen> createState() => _SearchUsersScreenState();
}

class _SearchUsersScreenState extends State<SearchUsersScreen> {
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

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = const [];
        _hasSearched = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await ProfileService().searchProfiles(trimmed);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        _hasSearched = true;
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'search_users'});
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
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search username or email',
            border: InputBorder.none,
          ),
          onChanged: _search,
          onSubmitted: _search,
        ),
      ),
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_searching) return const AppLoading(message: 'Searching...');
    if (_error != null) {
      return AppError(exception: _error!, onRetry: () => _search(_controller.text));
    }
    if (!_hasSearched) {
      return const AppEmptyState(
        icon: Icons.person_search_outlined,
        title: 'Find people',
        subtitle: 'Search by username or email address '
            '— no phone number needed.',
      );
    }
    if (_results.isEmpty) {
      return const AppEmptyState(
        icon: Icons.search_off,
        title: 'No results',
        subtitle: 'Try a different username or email.',
      );
    }

    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final profile = _results[index];
        return ListTile(
          leading: AppAvatar(profile: profile, radius: 22),
          title: Text(
            profile.displayNameOrUsername,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text('@${profile.username}'),
          trailing: const Icon(Icons.chat_bubble_outline, size: 20),
          onTap: () => Navigator.of(context).pushNamed(
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
