import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Renders FCM data messages as one actionable Android notification per chat.
/// The remote input and buttons are handled by the foreground app so actions
/// use the signed-in user's normal Supabase/RLS session.
class AndroidNotificationController {
  AndroidNotificationController._();
  static final AndroidNotificationController instance =
      AndroidNotificationController._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<NotificationResponse> _responses =
      StreamController<NotificationResponse>.broadcast();
  NotificationResponse? _launchResponse;
  bool _initialized = false;

  Stream<NotificationResponse> get responses => _responses.stream;

  Future<void> initialize({bool captureLaunchResponse = true}) async {
    if (_initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        if (!_responses.isClosed) _responses.add(response);
      },
    );
    if (captureLaunchResponse) {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        _launchResponse = launch?.notificationResponse;
      }
    }
    _initialized = true;
  }

  NotificationResponse? takeLaunchResponse() {
    final response = _launchResponse;
    _launchResponse = null;
    return response;
  }

  Future<void> showFromFcm(RemoteMessage message) async {
    await initialize(captureLaunchResponse: false);
    final data = message.data;
    final type = data['notificationType'] ?? data['type'];
    final isIncomingCall = type == 'incoming_call';
    final isMissedCall = type == 'missed_call';
    final isCall = isIncomingCall || isMissedCall;
    final conversationId =
        data['conversationId'] ?? data['callId'] ?? 'mailchat';
    final id = _stableId(
      isCall
          ? (data['callId'] ?? conversationId).toString()
          : conversationId.toString(),
    );
    final payload = jsonEncode(data);
    final title = message.notification?.title ?? data['title'] ?? 'MailChat';
    final body = message.notification?.body ?? data['body'] ?? '';

    final lines = _decodeLines(data['messages'], fallback: body);
    final actions = isIncomingCall
        ? const <AndroidNotificationAction>[
            AndroidNotificationAction(
              'answer_call',
              'Answer',
              showsUserInterface: true,
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              'decline_call',
              'Decline',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ]
        : type == 'message'
        ? const <AndroidNotificationAction>[
            AndroidNotificationAction(
              'reply',
              'Reply',
              showsUserInterface: true,
              cancelNotification: false,
              allowGeneratedReplies: true,
              inputs: <AndroidNotificationActionInput>[
                AndroidNotificationActionInput(label: 'Write a reply'),
              ],
            ),
            AndroidNotificationAction(
              'mark_read',
              'Mark as read',
              showsUserInterface: true,
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              'mute_chat',
              'Mute for 8 hours',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ]
        : const <AndroidNotificationAction>[];

    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          isCall ? 'mailchat_calls' : 'mailchat_messages',
          isCall ? 'Incoming calls' : 'Messages',
          channelDescription: isCall
              ? 'Incoming MailChat calls'
              : 'New MailChat messages',
          importance: Importance.max,
          priority: Priority.high,
          category: isCall
              ? AndroidNotificationCategory.call
              : AndroidNotificationCategory.message,
          groupKey: isCall ? 'mailchat_calls' : 'mailchat_chat_$conversationId',
          onlyAlertOnce: false,
          styleInformation: isCall || lines.length < 2
              ? BigTextStyleInformation(body)
              : InboxStyleInformation(
                  lines,
                  contentTitle: title,
                  summaryText: '${lines.length} recent messages',
                ),
          actions: actions,
        ),
      ),
      payload: payload,
    );
  }

  List<String> _decodeLines(Object? raw, {required String fallback}) {
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final lines = decoded
              .whereType<String>()
              .where((line) => line.isNotEmpty)
              .take(5)
              .toList();
          if (lines.isNotEmpty) return lines;
        }
      } catch (_) {
        // Use the single-message body when the optional summary is malformed.
      }
    }
    return fallback.isEmpty ? const <String>[] : <String>[fallback];
  }

  int _stableId(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
