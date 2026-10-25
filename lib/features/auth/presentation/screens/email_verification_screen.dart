import 'package:flutter/material.dart';

import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/widgets/app_button.dart';

/// Email verification screen.
///
/// Supabase Auth sends the confirmation email; this screen explains the step
/// and lets the user continue. It does NOT fake verification — the account is
/// only usable once the real email link has been followed. The database
/// enforces `email_confirmed_at` through RLS policies.
class EmailVerificationScreen extends StatelessWidget {
  final Map<String, dynamic>? arguments;

  const EmailVerificationScreen({super.key, this.arguments});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final email = arguments?['email'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('Verify email')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.mark_email_read_outlined, size: 72, color: colors.primary),
              const SizedBox(height: 24),
              Text(
                'Check your inbox',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                email == null
                    ? 'We sent you a verification link. Open it to activate your '
                        'account, then come back and sign in.'
                    : 'We sent a verification link to $email. Open it to activate '
                        'your account, then come back and sign in.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: colors.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Didn\'t get it? Check spam, or sign in again to resend '
                        'the confirmation email.',
                        style: TextStyle(
                            fontSize: 12.5, color: colors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              AppButton(
                text: 'Go to sign in',
                onPressed: () => Navigator.of(context)
                    .pushNamedAndRemoveUntil(AppRoutes.login, (route) => false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
