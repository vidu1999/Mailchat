import 'package:flutter/material.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/theme/app_theme.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/shared/widgets/app_avatar.dart';
import 'package:mailchat/shared/widgets/app_error.dart';
import 'package:mailchat/shared/widgets/app_loading.dart';

/// User profile screen. Shows the current user's profile and actions
/// (edit profile, privacy settings, sign out).
class ProfileScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const ProfileScreen({super.key, this.arguments});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Profile? _profile;
  bool _loading = true;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final userId = (widget.arguments?['userId'] as String?) ??
        SupabaseClient.instance.userId ??
    try {
      if (userId == null || userId.isEmpty) {
        throw AuthorizationException('Not signed in');
      }
      final profile = await ProfileService().getProfile(userId);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.error(e, st);
      if (!mounted) return;
      setState(() {
        _error = e is AppException ? e : AppException(e.toString());
        _loading = false;
      });
    }
  }

  void _openEditProfile() {
    Navigator.of(context).pushNamed(AppRoutes.editProfile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile'), centerTitle: true),
      body: _loading
          ? const AppLoading(message: 'Loading profile...')
          : _error != null
              ? AppError(exception: _error!, onRetry: _loadProfile)
              : _profile == null
                  ? const AppEmptyState(
                      icon: Icons.person_off,
                      title: 'Profile not found',
                      subtitle: 'Unable to load your profile.',
                    )
                  : _buildBody(_profile!),
    );
  }

  Widget _buildBody(Profile profile) {
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          AppAvatar(
            profile: profile,
            radius: 56,
            borderWidth: 2,
            borderColor: colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            profile.displayNameOrUsername,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '@${profile.username}',
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          if (profile.bio != null && profile.bio!.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              profile.bio!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 28),
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.blueAccent),
            title: const Text('Edit Profile'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openEditProfile,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.lock, color: Colors.blueAccent),
            title: const Text('Privacy Settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.privacySettings),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.block, color: Colors.blueAccent),
            title: const Text('Blocked Users'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.blockedUsers),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: const Text('Sign Out',
                style: TextStyle(color: Colors.redAccent)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // Sign out handled by auth provider; navigate to login.
              Navigator.of(context).pushNamedAndRemoveUntil(
                  AppRoutes.login, (route) => false);
            },
          ),
        ],
      ),
    );
  }
}

