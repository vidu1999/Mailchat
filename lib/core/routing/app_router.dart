import 'package:flutter/material.dart';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/features/auth/presentation/screens/forgot_password_screen.dart';
import 'package:mailchat/features/auth/presentation/screens/login_screen.dart';
import 'package:mailchat/features/auth/presentation/screens/registration_screen.dart';
import 'package:mailchat/features/auth/presentation/screens/paste_link_screen.dart';
import 'package:mailchat/features/auth/presentation/screens/reset_password_screen.dart';
import 'package:mailchat/features/auth/presentation/screens/splash_screen.dart';
import 'package:mailchat/features/auth/presentation/screens/email_verification_screen.dart';
import 'package:mailchat/features/contacts/presentation/screens/new_conversation_screen.dart';
import 'package:mailchat/features/contacts/presentation/screens/search_users_screen.dart';
import 'package:mailchat/features/conversations/presentation/screens/chat_list_screen.dart';
import 'package:mailchat/features/groups/presentation/screens/group_creation_screen.dart';
import 'package:mailchat/features/groups/presentation/screens/group_details_screen.dart';
import 'package:mailchat/features/messaging/presentation/screens/direct_chat_screen.dart';
import 'package:mailchat/features/attachments/presentation/screens/attachment_preview_screen.dart';
import 'package:mailchat/features/attachments/presentation/screens/media_viewer_screen.dart';
import 'package:mailchat/features/notifications/presentation/screens/notification_settings_screen.dart';
import 'package:mailchat/features/privacy/presentation/screens/blocked_users_screen.dart';
import 'package:mailchat/features/privacy/presentation/screens/privacy_settings_screen.dart';
import 'package:mailchat/features/privacy/presentation/screens/report_user_screen.dart';
import 'package:mailchat/features/profile/presentation/screens/edit_profile_screen.dart';
import 'package:mailchat/features/profile/presentation/screens/profile_screen.dart';
import 'package:mailchat/features/calls/presentation/screens/incoming_call_screen.dart';
import 'package:mailchat/features/calls/presentation/screens/active_call_screen.dart';
import 'package:mailchat/features/calls/presentation/screens/call_history_screen.dart';
import 'package:mailchat/features/settings/presentation/screens/application_settings_screen.dart';

/// Named routes used across MailChat.
class AppRoutes {
  AppRoutes._();

  static const String splash = '/';
  static const String welcome = '/welcome';
  static const String login = '/login';
  static const String register = '/register';
  static const String emailVerification = '/email-verification';
  static const String forgotPassword = '/forgot-password';
  static const String resetPassword = '/reset-password';
  static const String pasteLink = '/paste-link';
  static const String chatList = '/chat-list';
  static const String searchUsers = '/search-users';
  static const String newConversation = '/new-conversation';
  static const String directChat = '/direct-chat';
  static const String profile = '/profile';
  static const String editProfile = '/edit-profile';
  static const String mediaViewer = '/media-viewer';
  static const String attachmentPreview = '/attachment-preview';
  static const String notificationSettings = '/notification-settings';
  static const String privacySettings = '/privacy-settings';
  static const String blockedUsers = '/blocked-users';
  static const String reportUser = '/report-user';
  static const String groupCreation = '/group-creation';
  static const String groupDetails = '/group-details';
  static const String applicationSettings = '/application-settings';
  static const String incomingCall = '/incoming-call';
  static const String activeCall = '/active-call';
  static const String callHistory = '/call-history';
}

/// Observes route changes for analytics / deep-link handling.
class AppRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.info(
      'route_push',
      details: {'route': route.settings.name, 'from': previousRoute?.settings.name},
    );
  }
}

final AppRouteObserver routeObserver = AppRouteObserver();

/// Generates concrete routes from route names and optional arguments.
class AppRouter {
  AppRouter._();

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.splash:
        return _materialRoute(const SplashScreen(), settings);
      case AppRoutes.login:
        return _materialRoute(LoginScreen(arguments: _args(settings)), settings);
      case AppRoutes.register:
        return _materialRoute(const RegistrationScreen(), settings);
      case AppRoutes.emailVerification:
        return _materialRoute(EmailVerificationScreen(arguments: _args(settings)), settings);
      case AppRoutes.forgotPassword:
        return _materialRoute(const ForgotPasswordScreen(), settings);
      case AppRoutes.pasteLink:
        return _materialRoute(const PasteLinkScreen(), settings);
      case AppRoutes.resetPassword:
        return _materialRoute(ResetPasswordScreen(arguments: _args(settings)), settings);
      case AppRoutes.chatList:
        return _materialRoute(const ChatListScreen(), settings);
      case AppRoutes.searchUsers:
        return _materialRoute(
          SearchUsersScreen(
            callMode: _args(settings)?['callMode'] as bool? ?? false,
            isVideoCall: _args(settings)?['isVideoCall'] as bool? ?? false,
          ),
          settings,
        );
      case AppRoutes.newConversation:
        return _materialRoute(const NewConversationScreen(), settings);
      case AppRoutes.directChat:
        return _materialRoute(DirectChatScreen(arguments: _args(settings)), settings);
      case AppRoutes.profile:
        return _materialRoute(ProfileScreen(arguments: _args(settings)), settings);
      case AppRoutes.editProfile:
        return _materialRoute(const EditProfileScreen(), settings);
      case AppRoutes.mediaViewer:
        return _materialRoute(
          MediaViewerScreen(arguments: _args(settings)),
          settings,
        );
      case AppRoutes.attachmentPreview:
        return _materialRoute(
          AttachmentPreviewScreen(arguments: _args(settings)),
          settings,
        );
      case AppRoutes.notificationSettings:
        return _materialRoute(const NotificationSettingsScreen(), settings);
      case AppRoutes.privacySettings:
        return _materialRoute(const PrivacySettingsScreen(), settings);
      case AppRoutes.blockedUsers:
        return _materialRoute(BlockedUsersScreen(arguments: _args(settings)), settings);
      case AppRoutes.reportUser:
        return _materialRoute(ReportUserScreen(arguments: _args(settings)), settings);
      case AppRoutes.groupCreation:
        return _materialRoute(GroupCreationScreen(arguments: _args(settings)), settings);
      case AppRoutes.groupDetails:
        return _materialRoute(GroupDetailsScreen(arguments: _args(settings)), settings);
      case AppRoutes.applicationSettings:
        return _materialRoute(const ApplicationSettingsScreen(), settings);
      case AppRoutes.incomingCall:
        return _materialRoute(IncomingCallScreen(arguments: _args(settings)), settings);
      case AppRoutes.activeCall:
        return _materialRoute(ActiveCallScreen(arguments: _args(settings)), settings);
      case AppRoutes.callHistory:
        return _materialRoute(const CallHistoryScreen(), settings);
      default:
        return MaterialPageRoute(
          builder: (_) => const Scaffold(
            body: Center(child: Text('Unknown route')),
          ),
          settings: settings,
        );
    }
  }

  /// Screens accept a typed argument map; [RouteSettings.arguments] is Object?.
  static Map<String, dynamic>? _args(RouteSettings settings) {
    final raw = settings.arguments;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  static MaterialPageRoute<void> _materialRoute(
    Widget page,
    RouteSettings settings,
  ) {
    return MaterialPageRoute<void>(
      builder: (_) => page,
      settings: settings,
    );
  }
}
