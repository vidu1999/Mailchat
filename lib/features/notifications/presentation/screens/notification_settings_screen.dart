import 'package:flutter/material.dart';

/// Notification preferences. Push delivery requires FCM configuration
/// (google-services.json / GoogleService-Info.plist) plus a server-side sender;
/// see docs/push-notifications.md. Toggles here control the stored preference
/// shape consumed by that pipeline.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  bool _messages = true;
  bool _mentions = true;
  bool _reactions = false;
  bool _sound = true;
  bool _vibration = true;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('New messages'),
            value: _messages,
            onChanged: (v) => setState(() => _messages = v),
          ),
          SwitchListTile(
            title: const Text('Mentions'),
            value: _mentions,
            onChanged: (v) => setState(() => _mentions = v),
          ),
          SwitchListTile(
            title: const Text('Reactions'),
            value: _reactions,
            onChanged: (v) => setState(() => _reactions = v),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Sound'),
            value: _sound,
            onChanged: (v) => setState(() => _sound = v),
          ),
          SwitchListTile(
            title: const Text('Vibration'),
            value: _vibration,
            onChanged: (v) => setState(() => _vibration = v),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Push notifications require Firebase Cloud Messaging credentials '
              'for Android and iOS. Without them, in-app updates still work via '
              'realtime, but no OS-level push is delivered.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
