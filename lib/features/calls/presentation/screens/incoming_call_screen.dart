import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/features/calls/domain/call_service.dart';
import 'package:mailchat/features/calls/presentation/screens/active_call_screen.dart';

/// A call that is ringing for this user.
///
/// Deliberately does no media work: accepting hands over to [ActiveCallScreen],
/// which prepares the camera and microphone **before** writing the accept. That
/// order is what stops a refused microphone from producing a call row that says
/// "accepted" while nobody can hear anybody.
///
/// Declining, or simply leaving this screen, writes a terminal state, so a
/// ringing row never outlives the prompt. The database decides whether the write
/// is legal; this screen only offers the two choices the trigger permits.
class IncomingCallScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const IncomingCallScreen({super.key, this.arguments});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  final CallService _calls = CallService();

  late final String _callId;
  late final String _conversationId;
  late final String _callerId;
  late final String _callerName;
  late final String _selfId;
  late final bool _isVideo;

  bool _busy = false;
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _callId = (args['callId'] as String?) ?? '';
    _conversationId = (args['conversationId'] as String?) ?? '';
    _callerId = (args['callerId'] as String?) ?? '';
    _callerName = (args['callerName'] as String?) ?? 'Unknown';
    _isVideo = (args['isVideo'] as bool?) ?? false;
    _selfId = (args['selfId'] as String?) ??
        (SupabaseClient.instance.userId ?? '');
  }

  Future<void> _decline() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _calls.decline(_callId);
    } catch (e, st) {
      // The call may have been cancelled between the ring and the tap; the
      // trigger's refusal is the correct answer in that case.
      AppLogger.error(e, st, {'where': 'call_decline', 'callId': _callId});
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _accept() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _answered = true;
    });
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ActiveCallScreen(
          arguments: {
            'callId': _callId,
            'conversationId': _conversationId,
            'peerId': _callerId,
            'peerName': _callerName,
            'selfId': _selfId,
            'isVideo': _isVideo,
            'isCaller': false,
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Dismissed without answering: leave the row in a state that means "nobody
    // picked up" rather than a ring forever.
    if (!_answered && _callId.isNotEmpty) {
      unawaited(_calls.markMissed(_callId).catchError((Object e, StackTrace st) {
        AppLogger.error(e, st, {'where': 'call_missed_on_close'});
      }));
    }
    _calls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            CircleAvatar(
              radius: 52,
              backgroundColor: colors.primaryContainer,
              child: Icon(
                _isVideo ? Icons.videocam_outlined : Icons.call_outlined,
                size: 44,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _callerName,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _isVideo ? 'Incoming video call' : 'Incoming voice call',
              style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    children: [
                      IconButton.filled(
                        onPressed: _busy ? null : _decline,
                        iconSize: 30,
                        style: IconButton.styleFrom(
                          backgroundColor: colors.error,
                          foregroundColor: colors.onError,
                          minimumSize: const Size(66, 66),
                        ),
                        icon: const Icon(Icons.call_end),
                      ),
                      const SizedBox(height: 8),
                      const Text('Decline'),
                    ],
                  ),
                  Column(
                    children: [
                      IconButton.filled(
                        onPressed: _busy ? null : _accept,
                        iconSize: 30,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(66, 66),
                        ),
                        icon: Icon(_isVideo ? Icons.videocam : Icons.call),
                      ),
                      const SizedBox(height: 8),
                      const Text('Accept'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}
