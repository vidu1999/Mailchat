import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mailchat/core/deeplink/auth_deep_link.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/services/auth_service.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Completes an email link on this device by pasting it.
///
/// Needed whenever the confirmation email opens somewhere the app is not: the
/// project's Site URL is `http://localhost:3000`, so the phone's browser opens
/// the *phone's* localhost and shows "site can't be reached". The token in that
/// URL is still valid and single-use — copying it here finishes the job.
///
/// The paste is user-initiated, so any host is accepted (`allowedHosts` is
/// empty). The resulting account address is shown, so a link that signs the
/// user into the wrong account is at least visible.
class PasteLinkScreen extends StatefulWidget {
  const PasteLinkScreen({super.key});

  @override
  State<PasteLinkScreen> createState() => _PasteLinkScreenState();
}

class _PasteLinkScreenState extends State<PasteLinkScreen> {
  final _controller = TextEditingController();

  bool _loading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) {
        setState(() => _errorMessage = 'The clipboard is empty.');
        return;
      }
      _controller.text = text;
      setState(() => _errorMessage = null);
    } catch (_) {
      setState(() => _errorMessage = 'Could not read the clipboard.');
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _errorMessage = 'Paste the link from the email first.');
      return;
    }

    final link = AuthDeepLink.parse(raw);
    if (link == null) {
      setState(() => _errorMessage =
          'That does not look like a MailChat link. Copy the whole address '
          'from the email, including everything after the #.');
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final result = await AuthService().handleAuthLink(link);
    if (!mounted) return;

    if (!result.succeeded) {
      setState(() {
        _loading = false;
        _errorMessage = result.message;
      });
      return;
    }

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (link.kind == AuthLinkKind.recovery) {
      navigator.pushNamedAndRemoveUntil(
        AppRoutes.resetPassword,
        (route) => false,
        arguments: {'notice': result.message},
      );
      return;
    }

    navigator.pushNamedAndRemoveUntil(
      AppRoutes.chatList,
      (route) => false,
    );
    messenger.showSnackBar(SnackBar(content: Text(result.message)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Open email link')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.link_rounded, size: 56, color: colors.primary),
              const SizedBox(height: 16),
              Text(
                'Paste the link from the email',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'If the confirmation link opened on another device — or showed '
                '"site can\'t be reached" — copy the whole address from the '
                'email and paste it here.',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              AppInput(
                controller: _controller,
                label: 'Link',
                hint: 'http://…/#access_token=… or mailchat://auth/callback#…',
                maxLines: 4,
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: AppTextButton(
                  text: 'Paste from clipboard',
                  onPressed: _loading ? () {} : _pasteFromClipboard,
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: colors.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              AppButton(
                text: 'Confirm',
                isLoading: _loading,
                onPressed: _loading ? null : _submit,
              ),
              const SizedBox(height: 16),
              Text(
                'The link works once. If it has already been used, sign in with '
                'your password instead.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
