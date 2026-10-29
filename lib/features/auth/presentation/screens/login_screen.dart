import 'package:flutter/material.dart';

import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/utils/validators.dart';
import 'package:mailchat/shared/services/auth_service.dart';
import 'package:mailchat/shared/widgets/app_button.dart';
import 'package:mailchat/shared/widgets/app_input.dart';

/// Email + password login. No phone number or SMS is involved anywhere.
///
/// Accepts an optional `notice` argument, used to report the result of a link
/// opened from an email (for example "Email confirmed") on the screen the user
/// lands on.
class LoginScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const LoginScreen({super.key, this.arguments});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _errorMessage;

  /// Message from a handled deep link, shown above the form.
  String? _notice;

  @override
  void initState() {
    super.initState();
    final notice = widget.arguments?['notice'];
    if (notice is String && notice.isNotEmpty) _notice = notice;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await AuthService().signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      Navigator.of(context)
          .pushNamedAndRemoveUntil(AppRoutes.chatList, (route) => false);
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'login'});
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage =
            e is AppException ? e.message : 'Sign in failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/images/mailchat_brand.jpg',
                      width: 260,
                      height: 142,
                      fit: BoxFit.contain,
                      semanticLabel: 'Flutter MailChat',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Welcome back',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in with your email address',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
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
                    hint: 'Enter your password',
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    validator: (value) => Validators.required(value, 'Password'),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  if (_notice != null && _errorMessage == null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline,
                              size: 18, color: colors.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _notice!,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      style: TextStyle(color: colors.error, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppTextButton(
                      text: 'Forgot password?',
                      onPressed: () => Navigator.of(context)
                          .pushNamed(AppRoutes.forgotPassword),
                    ),
                  ),
                  // Escape hatch for a confirmation link that opened somewhere
                  // this app is not — a computer, or a phone's own localhost.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AppTextButton(
                      text: 'Have a confirmation link?',
                      onPressed: () =>
                          Navigator.of(context).pushNamed(AppRoutes.pasteLink),
                    ),
                  ),
                  const SizedBox(height: 12),
                  AppButton(
                    text: 'Sign in',
                    isLoading: _loading,
                    onPressed: _submit,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('No account yet?',
                          style: TextStyle(
                              fontSize: 14, color: colors.onSurfaceVariant)),
                      AppTextButton(
                        text: 'Create one',
                        onPressed: () => Navigator.of(context)
                            .pushNamed(AppRoutes.register),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
