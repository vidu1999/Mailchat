import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mailchat/core/deeplink/app_links.dart';
import 'package:mailchat/core/deeplink/auth_deep_link.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/theme/app_theme.dart';
import 'package:mailchat/shared/services/auth_service.dart';

/// Root widget of MailChat.
///
/// Holds the [MaterialApp], theme and routing. Authentication state
/// (session restoration) is resolved inside the splash screen so navigation can
/// react to login/logout without rebuilding the entire app.
class MailChatApp extends StatefulWidget {
  const MailChatApp({super.key});

  @override
  State<MailChatApp> createState() => _MailChatAppState();
}

class _MailChatAppState extends State<MailChatApp> {
  /// Needed because an email link can arrive before any screen exists, and
  /// later while the user is anywhere in the app.
  static final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  StreamSubscription<String>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    // The link that cold-started the app has to wait for the first frame: there
    // is no Navigator until the MaterialApp is built. Replaying it after the
    // splash has routed would land on the wrong screen, so it is handled first
    // and replaces the stack.
    _linkSubscription = AppLinks.links.listen(_handleLink);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final initial = await AppLinks.initialLink();
      if (!mounted) return;
      if (initial != null) {
        await _handleLink(initial);
        return;
      }
      // No link: normal start. The splash screen is the initial route and
      // decides between login and the chat list.
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  /// Exchanges a link for a session and routes to wherever it belongs.
  ///
  /// Navigation is deliberately explicit rather than "let the splash decide":
  /// the link is the user's intent, and the splash would otherwise race it.
  Future<void> _handleLink(String raw) async {
    final link = AuthDeepLink.parse(raw);
    if (link == null) {
      AppLogger.info('deeplink_ignored', details: {'reason': 'not_auth_link'});
      return;
    }
    if (!link.isActionable) {
      AppLogger.warning('deeplink_not_actionable',
          details: {'kind': link.kind.name});
      return;
    }

    final result = await AuthService().handleAuthLink(link);
    if (!mounted) return;

    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    if (!result.succeeded) {
      // Show the reason on the login screen: the user needs to sign in anyway,
      // and the message explains what to do about the bad link.
      navigator.pushNamedAndRemoveUntil(
        AppRoutes.login,
        (route) => false,
        arguments: {'notice': result.message},
      );
      return;
    }

    switch (link.kind) {
      case AuthLinkKind.recovery:
        // A recovery link establishes a session, but the user still has to
        // choose a password before that session is useful.
        navigator.pushNamedAndRemoveUntil(
          AppRoutes.resetPassword,
          (route) => false,
          arguments: {'notice': result.message},
        );
      case AuthLinkKind.confirmation:
        navigator.pushNamedAndRemoveUntil(
          AppRoutes.chatList,
          (route) => false,
          arguments: {'notice': result.message},
        );
        _showNotice(result.message);
      case AuthLinkKind.error:
        navigator.pushNamedAndRemoveUntil(
          AppRoutes.login,
          (route) => false,
          arguments: {'notice': result.message},
        );
    }
  }

  void _showNotice(String message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MailChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRouter.onGenerateRoute,
      navigatorKey: _navigatorKey,
      navigatorObservers: [routeObserver],
    );
  }
}
