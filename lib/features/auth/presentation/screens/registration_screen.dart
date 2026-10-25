import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/validators.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/services/auth_service.dart';
import 'package:mailchat/shared/services/profile_service.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Registration with email + password + username. No phone number, SMS OTP or
/// SIM card is ever requested (requirement: email-based identity only).
///
/// Email confirmation is handled by Supabase Auth; this screen does not
/// simulate verification. After sign-up the user is sent to
/// [AppRoutes.emailVerification] to check their inbox.
class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _errorMessage;
  String? _usernameError;

  @override
  void dispose() {
    _displayNameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _checkUsername(String value) async {
    final localError = Validators.username(value);
    if (localError != null) {
      setState(() => _usernameError = null);
      return;
    }
    try {
      final UsernameCheckResult result =
          await ProfileService().checkUsername(value.trim().toLowerCase());
      if (!mounted) return;
      setState(() => _usernameError =
          result.available ? null : (result.error ?? 'Username is taken'));
    } catch (_) {
      // Availability check is best-effort; the unique constraint is the
      // authority and its violation is surfaced on submit.
      if (mounted) setState(() => _usernameError = null);
    }
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
      final result = await AuthService().register(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        displayName: _displayNameController.text.trim(),
        username: _usernameController.text.trim().toLowerCase(),
      );
      if (!mounted) return;

      final navigator = Navigator.of(context);

      if (result.requiresConfirmation) {
        // Confirmation email sent; the account is not usable until the link is
        // followed. This is the normal path when the project requires it.
        navigator.pushNamedAndRemoveUntil(
          AppRoutes.emailVerification,
          (route) => false,
          arguments: {'email': result.email},
        );
        return;
      }

      // Confirmation disabled: the account is live and already signed in.
      navigator.pushNamedAndRemoveUntil(AppRoutes.chatList, (route) => false);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'register'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = e is AppException
            ? e.message
            : 'Registration failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Sign up with email',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'No phone number required.',
                  style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                AppInput(
                  controller: _displayNameController,
                  label: 'Display name',
                  hint: 'How others see you',
                  textInputAction: TextInputAction.next,
                  validator: Validators.displayName,
                ),
                const SizedBox(height: 16),
                AppInput(
                  controller: _usernameController,
                  label: 'Username',
                  hint: 'e.g. jane.doe',
                  textInputAction: TextInputAction.next,
                  errorText: _usernameError,
                  onChanged: _checkUsername,
                  validator: Validators.username,
                ),
                const SizedBox(height: 16),
                AppInput(
                  controller: _emailController,
                  label: 'Email',
                  hint: 'you@example.com',
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: Validators.email,
                ),
                const SizedBox(height: 16),
                AppInput(
                  controller: _passwordController,
                  label: 'Password',
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
                  label: 'Confirm password',
                  hint: 'Re-enter your password',
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
                  text: 'Create account',
                  isLoading: _loading,
                  onPressed: _submit,
                ),
                const SizedBox(height: 16),
                Text(
                  'You will receive a verification email. Open it to activate '
                  'your account.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
