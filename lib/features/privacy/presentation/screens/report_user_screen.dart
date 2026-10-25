import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Reports a user (optionally referencing a specific message).
class ReportUserScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const ReportUserScreen({super.key, this.arguments});

  @override
  State<ReportUserScreen> createState() => _ReportUserScreenState();
}

class _ReportUserScreenState extends State<ReportUserScreen> {
  static const _reasons = [
    'Spam',
    'Harassment or abuse',
    'Impersonation',
    'Inappropriate content',
    'Other',
  ];

  final _descriptionController = TextEditingController();
  String _reason = _reasons.first;
  bool _submitting = false;
  String? _errorMessage;

  String get _reporterId =>
      (widget.arguments?['currentUserId'] as String?) ??
      (SupabaseClient.instance.userId ?? '');
  String? get _reportedUserId =>
      widget.arguments?['reportedUserId'] as String?;
  String? get _messageId => widget.arguments?['messageId'] as String?;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_reportedUserId == null || _reportedUserId!.isEmpty) {
      setState(() => _errorMessage = 'No user selected to report.');
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await SupabaseClient.instance.insert(
        'user_reports',
        data: {
          'reporter_id': _reporterId,
          'reported_user_id': _reportedUserId,
          'message_id': _messageId,
          'reason': _reason,
          'description': _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          'status': 'open',
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report submitted. Thank you — our team will review it.'),
        ),
      );
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'report_user'});
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage =
            e is AppException ? e.message : 'Could not submit the report.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Report user')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Why are you reporting this user?',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          // Deliberately not `RadioListTile`: its `groupValue`/`onChanged` were
          // deprecated in Flutter 3.32 in favour of the `RadioGroup` ancestor,
          // which does not exist on the older SDKs this project supports.
          // A plain selectable tile has no deprecated surface on any version
          // and gives the same affordance.
          for (final reason in _reasons)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(reason),
              leading: Icon(
                _reason == reason
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: _reason == reason ? colors.primary : colors.outline,
              ),
              selected: _reason == reason,
              onTap: () => setState(() => _reason = reason),
              trailing: _reason == reason
                  ? Icon(Icons.check, size: 18, color: colors.primary)
                  : null,
            ),
          const SizedBox(height: 12),
          AppInput(
            controller: _descriptionController,
            label: 'Additional details (optional)',
            hint: 'Describe what happened',
            maxLines: 4,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(_errorMessage!,
                style: TextStyle(color: colors.error, fontSize: 13)),
          ],
          const SizedBox(height: 24),
          AppButton(
            text: 'Submit report',
            isLoading: _submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
