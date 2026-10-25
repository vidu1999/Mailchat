import 'package:flutter/material.dart';

import 'package:mailchat/features/calls/domain/call_model.dart';
import 'package:mailchat/features/calls/presentation/screens/active_call_screen.dart';
import 'package:mailchat/core/theme/app_theme.dart';

/// Incoming call screen.
///
/// UI-only implementation of an incoming call prompt. Accepting opens
/// [ActiveCallScreen]; declining dismisses the prompt.
///
/// IMPORTANT: this screen does not establish a real media session. WebRTC
/// signalling, ICE/STUN-TURN and permission handling are not implemented yet
/// (requirements section 17 — calling is a later milestone). See docs/calls.md.
/// The UI is wired so it can be driven by a real signalling layer later.
class IncomingCallScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const IncomingCallScreen({super.key, this.arguments});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  late final String _callerName;
  late final String _callerId;
  late final bool _isVideo;

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _callerName = (args['callerName'] as String?) ?? 'Unknown';
    _callerId = (args['callerId'] as String?) ?? '';
    _isVideo = (args['isVideo'] as bool?) ?? false;
  }

  void _decline() {
    Navigator.of(context).pop();
  }

  void _accept() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ActiveCallScreen(
          arguments: {
            'callerName': _callerName,
            'callerId': _callerId,
            'isVideo': _isVideo,
            'isCaller': false,
            'callState': CallState.ongoing,
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            CircleAvatar(
              radius: 72,
              backgroundColor: colors.primaryContainer,
              child: Text(
                _callerName.isNotEmpty ? _callerName[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w700,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _isVideo ? 'Incoming video call' : 'Incoming call',
              style: TextStyle(
                fontSize: 15,
                color: colors.onSurfaceVariant,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _callerName,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
            if (_callerId.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('@$_callerId',
                  style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
            ],
            const Spacer(flex: 3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _decline,
                        icon: const Icon(Icons.call_end),
                        label: const Text('Decline'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colors.error,
                          side: BorderSide(color: colors.error, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: _accept,
                        icon: Icon(_isVideo ? Icons.videocam : Icons.call),
                        label: const Text('Accept'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF22C55E),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
