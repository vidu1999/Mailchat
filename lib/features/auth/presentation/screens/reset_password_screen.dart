import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/validators.dart';
import 'package:mailchat/shared/services/auth_service.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Sets a new password after a recovery link has been followed.
///
/// Reached only from a real Supabase recovery redirect: the link establishes a
/// session first (`AuthService.handleAuthLink`), and `PUT /auth/v1/user` uses
/// that session. Without one the update fails and the user is sent back to
/// "forgot password" — this screen never pretends the session exists.
class ResetPasswordScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const ResetPasswordScreen({super.key, this.arguments});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    if (_passwordController.text != _confirmController.text) {
      setState(() => _errorMessage = 'Passwords do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await AuthService().updatePassword(_passwordController.text);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.chatList,
        (route) => false,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Password updated.')),
      );
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'reset_password'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e is AppException
            ? e.message
            : 'Could not update the password. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final notice = widget.arguments?['notice'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('New password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notice != null) ...[
                  Text(
                    notice,
                    style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                ],
                AppInput(
                  controller: _passwordController,
                  label: 'New password',
                  hint: 'At least 8 characters',
                  obscureText: _obscure,
                  textInputAction: TextInputAction.next,
                  validator: Validators.password,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                const SizedBox(height: 16),
                AppInput(
                  controller: _confirmController,
                  label: 'Confirm new password',
                  hint: 'Re-enter the password',
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  validator: (value) => Validators.required(value, 'Password'),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: colors.error, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 24),
                AppButton(
                  text: 'Update password',
                  isLoading: _loading,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
