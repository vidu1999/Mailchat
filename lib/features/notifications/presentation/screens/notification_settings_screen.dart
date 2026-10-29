import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/shared/services/notification_service.dart';

/// Notification preferences.
///
/// The three message switches are stored per user in `notification_preferences`
/// (one row with a null conversation id is the global setting) and are read back
/// on open, so a change survives a restart.
///
/// Sound and vibration are device settings, not account settings: they are kept
/// in this screen's state and will move to local storage with the FCM work. Push
/// delivery itself still requires Firebase credentials — see
/// docs/notifications.md — and this screen does not claim otherwise.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  final _service = NotificationService();

  NotificationPreferences _preferences = const NotificationPreferences();
  bool _sound = true;
  bool _vibration = true;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    NotificationPreferences? stored;
    try {
      stored = await _service.getGlobal();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'notification_settings_load'});
    }
    if (!mounted) return;
    setState(() {
      if (stored != null) _preferences = stored;
      // Enabled even if the read failed: the switches still save, and a
      // permanently greyed-out screen is worse than a visible error.
      _loaded = true;
    });
  }

  Future<void> _save(NotificationPreferences next) async {
    final previous = _preferences;
    setState(() {
      _preferences = next;
      _saving = true;
    });
    try {
      await _service.saveGlobal(next);
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'notification_settings_save'});
      if (!mounted) return;
      // Show what is actually stored, not what the user just tapped.
      setState(() {
        _preferences = previous;
        _saving = false;
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
    final enabled = _loaded && !_saving;

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('New messages'),
            subtitle: const Text('Alert me about new messages.'),
            value: _preferences.messages,
            onChanged: enabled
                ? (v) => _save(_preferences.copyWith(messages: v))
                : null,
          ),
          SwitchListTile(
            title: const Text('Mentions'),
            subtitle: const Text('Alert me when someone mentions me.'),
            value: _preferences.mentions,
            onChanged: enabled
                ? (v) => _save(_preferences.copyWith(mentions: v))
                : null,
          ),
          SwitchListTile(
            title: const Text('Reactions'),
            subtitle: const Text('Alert me when someone reacts to my message.'),
            value: _preferences.reactions,
            onChanged: enabled
                ? (v) => _save(_preferences.copyWith(reactions: v))
                : null,
          ),
          SwitchListTile(
            title: const Text('Missed calls'),
            subtitle: const Text('Alert me when a call is not answered.'),
            value: _preferences.calls,
            onChanged: enabled
                ? (v) => _save(_preferences.copyWith(calls: v))
                : null,
          ),
          SwitchListTile(
            title: const Text('System updates'),
            subtitle: const Text('Alert me about conversation and account events.'),
            value: _preferences.system,
            onChanged: enabled
                ? (v) => _save(_preferences.copyWith(system: v))
                : null,
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Sound'),
            subtitle: const Text('This device only.'),
            value: _sound,
            onChanged: (v) => setState(() => _sound = v),
          ),
          SwitchListTile(
            title: const Text('Vibration'),
            subtitle: const Text('This device only.'),
            value: _vibration,
            onChanged: (v) => setState(() => _vibration = v),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Message, missed-call, and system-event switches are saved to '
              'your account. Sound and vibration currently apply only in this '
              'screen. The durable inbox and foreground realtime alerts work '
              'without Firebase; background or OS push still requires a trusted '
              'Firebase Cloud Messaging sender and project credentials.',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
