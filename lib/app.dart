import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:mailchat/core/config/app_config.dart';
import 'package:mailchat/core/deeplink/app_links.dart';
import 'package:mailchat/core/deeplink/auth_deep_link.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/features/calls/domain/call_service.dart';
import 'package:mailchat/shared/services/conversation_service.dart';
import 'package:mailchat/shared/services/android_notification_controller.dart';
import 'package:mailchat/shared/services/message_service.dart';
import 'package:mailchat/shared/services/notification_service.dart';
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
  StreamSubscription<RemoteMessage>? _pushTapSubscription;
  StreamSubscription<NotificationResponse>? _notificationActionSubscription;
  StreamSubscription<dynamic>? _notificationAuthSubscription;
  final List<NotificationResponse> _pendingNotificationActions = [];

  @override
  void initState() {
    super.initState();
    // The link that cold-started the app has to wait for the first frame: there
    // is no Navigator until the MaterialApp is built. Replaying it after the
    // splash has routed would land on the wrong screen, so it is handled first
    // and replaces the stack.
    _linkSubscription = AppLinks.links.listen(_handleLink);
    _notificationActionSubscription =
        AndroidNotificationController.instance.responses.listen(
      (response) => unawaited(_handleNotificationResponse(response)),
    );
    _notificationAuthSubscription = AuthService().userStream.listen((user) {
      if (user != null) unawaited(_drainPendingNotificationActions());
    });
    if (Firebase.apps.isNotEmpty) {
      _pushTapSubscription =
          FirebaseMessaging.onMessageOpenedApp.listen(_handlePushTap);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final initial = await AppLinks.initialLink();
      if (!mounted) return;
      if (initial != null) {
        await _handleLink(initial);
        return;
      }
      final notificationAction =
          AndroidNotificationController.instance.takeLaunchResponse();
      if (notificationAction != null) {
        await _handleNotificationResponse(notificationAction);
      }
      if (Firebase.apps.isNotEmpty) {
        final notification = await FirebaseMessaging.instance.getInitialMessage();
        if (notification != null) _handlePushTap(notification);
      }
      // No link: normal start. The splash screen is the initial route and
      // decides between login and the chat list.
    });
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _pushTapSubscription?.cancel();
    _notificationActionSubscription?.cancel();
    _notificationAuthSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    if (!AuthService().isAuthenticated) {
      _pendingNotificationActions.add(response);
      return;
    }
    await _processNotificationResponse(response);
  }

  Future<void> _drainPendingNotificationActions() async {
    if (!AuthService().isAuthenticated || _pendingNotificationActions.isEmpty) {
      return;
    }
    // On cold start the splash may still be replacing its route after session
    // restoration. Let that navigation finish before a call action pushes UI.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || !AuthService().isAuthenticated) return;
    final queued = List<NotificationResponse>.of(_pendingNotificationActions);
    _pendingNotificationActions.clear();
    for (final response in queued) {
      await _processNotificationResponse(response);
    }
  }

  Future<void> _processNotificationResponse(
    NotificationResponse response,
  ) async {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(response.payload ?? '{}');
      if (decoded is! Map) return;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    final userId = SupabaseClient.instance.userId;
    if (userId == null ||
        (data['recipientId'] is String && data['recipientId'] != userId)) {
      return;
    }
    final conversationId = data['conversationId'] as String? ?? '';
    final callId = data['callId'] as String? ?? '';
    final action = response.actionId;
    try {
      switch (action) {
        case 'reply':
          final text = response.input?.trim() ?? '';
          if (text.isNotEmpty && conversationId.isNotEmpty) {
            await MessageService().sendText(
              conversationId: conversationId,
              senderId: userId,
              text: text,
            );
            await NotificationService().markConversationRead(conversationId);
            await ConversationService().markConversationRead(conversationId);
          }
          break;
        case 'mark_read':
          await NotificationService().markConversationRead(conversationId);
          await ConversationService().markConversationRead(conversationId);
          break;
        case 'mute_chat':
          await NotificationService().muteConversation(conversationId);
          break;
        case 'decline_call':
          if (callId.isNotEmpty) {
            final calls = CallService();
            try {
              await calls.decline(callId);
            } finally {
              calls.dispose();
            }
          }
          break;
        case 'answer_call':
          final navigator = _navigatorKey.currentState;
          if (navigator == null || callId.isEmpty) return;
          navigator.pushNamed(AppRoutes.incomingCall, arguments: {
            'callId': callId,
            'conversationId': conversationId,
            'callerId': data['callerId'] ?? data['actorId'] ?? '',
            'callerName': data['callerName'] ?? 'MailChat user',
            'selfId': userId,
            'isVideo': data['isVideo'] == 'true',
            'autoAccept': true,
          });
          break;
        default:
          _routeNotificationData(
            data,
            fallbackTitle: data['title'] as String? ?? 'Chat',
          );
      }
    } catch (error, stack) {
      AppLogger.error(error, stack, {'where': 'notification_action'});
    }
  }

  void _handlePushTap(RemoteMessage message) => _routeNotificationData(
        message.data,
        fallbackTitle: message.notification?.title ??
            message.data['title'] as String? ??
            'Chat',
      );

  Future<void> _markNotificationInboxRead(String conversationId) async {
    try {
      await NotificationService().markConversationRead(conversationId);
    } catch (error, stack) {
      AppLogger.error(error, stack, {'where': 'notification_open_mark_read'});
    }
  }

  void _routeNotificationData(
    Map<String, dynamic> data, {
    required String fallbackTitle,
  }) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    final type = data['notificationType'] ?? data['type'];
    if (type == 'missed_call') {
      navigator.pushNamed(AppRoutes.callHistory);
      return;
    }
    if (type == 'incoming_call') {
      navigator.pushNamed(AppRoutes.incomingCall, arguments: {
        'callId': data['callId'] ?? '',
        'conversationId': data['conversationId'] ?? '',
        'callerId': data['callerId'] ?? '',
        'callerName': data['callerName'] ?? 'MailChat user',
        'selfId': data['recipientId'] ?? SupabaseClient.instance.userId ?? '',
        'isVideo': data['isVideo'] == 'true',
        'autoAccept': false,
      });
      return;
    }
    final conversationId = data['conversationId'];
    if (conversationId is! String || conversationId.isEmpty) return;
    unawaited(_markNotificationInboxRead(conversationId));
    final isGroup = data['conversationType'] == 'group';
    final name = data['conversationName'];
    navigator.pushNamed(AppRoutes.directChat, arguments: {
      'conversationId': conversationId,
      'isGroup': isGroup,
      'title': name is String && name.isNotEmpty ? name : fallbackTitle,
      if (data['actorId'] is String) 'otherUserId': data['actorId'],
    });
  }

  /// Exchanges a link for a session and routes to wherever it belongs.
  ///
  /// Navigation is deliberately explicit rather than "let the splash decide":
  /// the link is the user's intent, and the splash would otherwise race it.
  Future<void> _handleLink(String raw) async {
    // Only links whose host matches this project are trusted without a callback
    // path; anything else could be a crafted link that signs the user into an
    // account they do not own.
    final link = AuthDeepLink.parse(
      raw,
      allowedHosts: AuthDeepLink.trustedHosts(
        supabaseUrl: AppConfig.instance.supabaseUrl,
        authRedirectUrl: AppConfig.instance.authRedirectUrl,
      ),
    );
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
