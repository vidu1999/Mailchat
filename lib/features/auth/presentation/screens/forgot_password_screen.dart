import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/utils/validators.dart';
import 'package:mailchat/shared/services/auth_service.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Password reset request. Supabase Auth sends the reset email; this screen
/// only requests it and reports the outcome.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      await AuthService().resetPassword(_emailController.text.trim());
      if (!mounted) return;
      setState(() {
        _loading = false;
        _sent = true;
      });
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'forgot_password'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage =
            e is AppException ? e.message : 'Could not send reset email.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _sent ? _buildSent(colors) : _buildForm(colors),
        ),
      ),
    );
  }

  Widget _buildSent(ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 48),
        Icon(Icons.outgoing_mail, size: 64, color: colors.primary),
        const SizedBox(height: 20),
        Text(
          'Reset link sent',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.w700, color: colors.onSurface),
        ),
        const SizedBox(height: 10),
        Text(
          'If an account exists for ${_emailController.text.trim()}, a password '
          'reset link is on its way.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        AppButton(
          text: 'Back to sign in',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildForm(ColorScheme colors) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Forgot your password?',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w700, color: colors.onSurface),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your email and we will send you a reset link.',
            style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          AppInput(
            controller: _emailController,
            label: 'Email',
            hint: 'you@example.com',
            keyboardType: TextInputType.emailAddress,
            validator: Validators.email,
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(_errorMessage!,
                style: TextStyle(color: colors.error, fontSize: 13)),
          ],
          const SizedBox(height: 24),
          AppButton(
            text: 'Send reset link',
            isLoading: _loading,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
