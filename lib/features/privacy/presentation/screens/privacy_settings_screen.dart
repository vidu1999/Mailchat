import 'package:flutter/material.dart';

import 'package:mailchat/core/routing/app_router.dart';

/// Privacy settings: who can message, discoverability, read receipts and
/// presence visibility.
///
/// The toggles persist through the profile/privacy API. Until that endpoint is
/// wired, changes are held in local state and clearly marked as not yet saved
/// so no false claim of server persistence is made.
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool _readReceipts = true;
  bool _showOnlineStatus = true;
  bool _allowSearchByUsername = true;
  bool _allowSearchByEmail = false;

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
            value: _allowSearchByUsername,
            onChanged: (v) => setState(() => _allowSearchByUsername = v),
          ),
          SwitchListTile(
            title: const Text('Allow search by email'),
            subtitle: const Text(
                'Off by default. Email lookup is never exposed to other users.'),
            value: _allowSearchByEmail,
            onChanged: (v) => setState(() => _allowSearchByEmail = v),
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
              'Changes on this screen are not yet persisted to the backend. '
              'Server-side enforcement ships with the privacy API migration.',
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
