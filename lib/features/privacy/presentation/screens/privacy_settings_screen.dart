import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/auth_service.dart';
import 'package:mailchat/shared/services/profile_service.dart';

/// Privacy settings: who can message, discoverability, read receipts and
/// presence visibility.
///
/// Discoverability is stored on the profile (`discoverable_by_email`,
/// `discoverable_by_username`, migration 0005) and enforced server-side inside
/// `public.search_users`, so turning a toggle off removes the user from that
/// kind of search rather than merely hiding a row in the UI.
///
/// Read receipts and presence are still local: there is no column for them yet,
/// and the note at the bottom of the screen says so rather than implying they
/// are saved.
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool _readReceipts = true;
  bool _showOnlineStatus = true;
  bool _allowSearchByUsername = true;
  bool _allowSearchByEmail = true;
  bool _savingDiscoverability = false;
  bool _loadedDiscoverability = false;

  String? get _userId => AuthService().currentUser?.id;

  @override
  void initState() {
    super.initState();
    _loadDiscoverability();
  }

  /// Shows the stored values rather than the defaults; silently keeps the
  /// defaults if the profile cannot be read, because the controls still work.
  Future<void> _loadDiscoverability() async {
    final userId = _userId;
    Profile? profile;
    if (userId != null) {
      try {
        profile = await ProfileService().getDiscoverability(userId);
      } catch (e, st) {
        AppLogger.error(e, st, {'where': 'privacy_load_discoverability'});
      }
    }
    if (!mounted) return;
    setState(() {
      // Enable the switches even when the read failed: a settings screen whose
      // controls are permanently greyed out is worse than one that saves into
      // an error the user can see.
      if (profile != null) {
        _allowSearchByEmail = profile!.discoverableByEmail;
        _allowSearchByUsername = profile.discoverableByUsername;
      }
      _loadedDiscoverability = true;
    });
  }

  Future<void> _setDiscoverability({bool? byEmail, bool? byUsername}) async {
    final userId = _userId;
    if (userId == null) return;

    final previousEmail = _allowSearchByEmail;
    final previousUsername = _allowSearchByUsername;
    setState(() {
      if (byEmail != null) _allowSearchByEmail = byEmail;
      if (byUsername != null) _allowSearchByUsername = byUsername;
      _savingDiscoverability = true;
    });

    try {
      await ProfileService()
          .setDiscoverability(userId, byEmail: byEmail, byUsername: byUsername);
      if (!mounted) return;
      setState(() => _savingDiscoverability = false);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'privacy_set_discoverability'});
      if (!mounted) return;
      // Put the switch back: showing it as off when the server still has it on
      // would misstate who can find the user.
      setState(() {
        _allowSearchByEmail = previousEmail;
        _allowSearchByUsername = previousUsername;
        _savingDiscoverability = false;
      });
      final message = e is AppException ? e.message : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $message')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        children: [
          _sectionHeader(context, 'Read receipts'),
          SwitchListTile(
            title: const Text('Send read receipts'),
            subtitle: const Text(
                'When off, you will not send read receipts and will not see '
                'other people\'s.'),
            value: _readReceipts,
            onChanged: (v) => setState(() => _readReceipts = v),
          ),
          const Divider(),
          _sectionHeader(context, 'Presence'),
          SwitchListTile(
            title: const Text('Show online status'),
            subtitle: const Text('Let others see when you are online.'),
            value: _showOnlineStatus,
            onChanged: (v) => setState(() => _showOnlineStatus = v),
          ),
          const Divider(),
          _sectionHeader(context, 'Discoverability'),
          SwitchListTile(
            title: const Text('Allow search by username'),
            subtitle: const Text(
                'Others can find you by typing your username or display name.'),
            value: _allowSearchByUsername,
            onChanged: _savingDiscoverability || !_loadedDiscoverability
                ? null
                : (v) => _setDiscoverability(byUsername: v),
          ),
          SwitchListTile(
            title: const Text('Allow search by email'),
            subtitle: const Text(
                'Others can find you by typing your full email address. Your '
                'address is never shown to them — it is only matched against.'),
            value: _allowSearchByEmail,
            onChanged: _savingDiscoverability || !_loadedDiscoverability
                ? null
                : (v) => _setDiscoverability(byEmail: v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked users'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).pushNamed(AppRoutes.blockedUsers),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'The two search toggles are saved to your profile and enforced '
              'by the database. Read receipts and presence are not saved yet — '
              'they apply to this device only.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
