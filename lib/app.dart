import 'package:flutter/material.dart';
import 'package:mailchat/core/routing/app_router.dart';
import 'package:mailchat/core/theme/app_theme.dart';
import 'package:mailchat/features/auth/presentation/screens/splash_screen.dart';

/// Root widget of MailChat.
///
/// Holds the [MaterialApp], theme and routing. Authentication state
/// (session restoration) is resolved inside [AuthGate] so navigation can
/// react to login/logout without rebuilding the entire app.
class MailChatApp extends StatelessWidget {
  const MailChatApp({super.key});

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
      navigatorObservers: [AppRouter.routeObserver],
    );
  }
}
