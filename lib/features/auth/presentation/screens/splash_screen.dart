import 'package:flutter/material.dart';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/shared/services/auth_service.dart';

/// Splash screen — restores a persisted session and routes accordingly.
///
/// Session restoration uses [SessionStore] tokens. If a token is present the
/// user goes to the chat list; otherwise to login. Email verification state is
/// enforced by the backend, not simulated here.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Allow the splash to render for a moment.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    final auth = AuthService();
    var signedIn = false;
    try {
      await auth.init();
      signedIn = auth.isAuthenticated;
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'splash_restore'});
    }
    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil(
      signedIn ? AppRoutes.chatList : AppRoutes.login,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/mailchat_brand.jpg',
              width: 280,
              height: 153,
              fit: BoxFit.contain,
              semanticLabel: 'Flutter MailChat',
            ),
            const SizedBox(height: 8),
            Text(
              'Messaging without a phone number',
              style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 36),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: colors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
