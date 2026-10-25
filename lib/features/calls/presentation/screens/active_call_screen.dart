import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mailchat/core/theme/color_alpha.dart';

/// Active call screen.
///
/// Displays an in-progress call with a local duration timer and mute / camera /
/// speaker toggles. The toggles currently change local UI state only.
///
/// IMPORTANT: no audio or video is captured, transmitted or received. Real
/// calling requires WebRTC plus a signalling channel and STUN/TURN servers
/// (requirements section 17). See docs/calls.md. Nothing here should be
/// presented to users as a working call.
class ActiveCallScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const ActiveCallScreen({super.key, this.arguments});

  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen> {
  late final String _peerName;
  late final bool _isVideo;

  Timer? _timer;
  int _seconds = 0;
  bool _micMuted = false;
  bool _cameraOff = false;
  bool _speakerOn = true;

  @override
  void initState() {
    super.initState();
    final args = widget.arguments ?? const <String, dynamic>{};
    _peerName = (args['callerName'] as String?) ?? 'Unknown';
    _isVideo = (args['isVideo'] as bool?) ?? false;
    _startTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timerText {
    final minutes = (_seconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 48),
            CircleAvatar(
              radius: 88,
              backgroundColor: colors.primaryContainer,
              child: Text(
                _peerName.isNotEmpty ? _peerName[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.w700,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _peerName,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _isVideo ? 'Video call' : 'Voice call',
              style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Text(
              _timerText,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CallControl(
                        icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                        label: _cameraOff ? 'Video off' : 'Video',
                        active: _cameraOff,
                        onTap: () => setState(() => _cameraOff = !_cameraOff),
                      ),
                      _CallControl(
                        icon: _micMuted ? Icons.mic_off : Icons.mic,
                        label: _micMuted ? 'Muted' : 'Mic',
                        active: _micMuted,
                        onTap: () => setState(() => _micMuted = !_micMuted),
                      ),
                      _CallControl(
                        icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                        label: _speakerOn ? 'Speaker' : 'Earpiece',
                        active: !_speakerOn,
                        onTap: () => setState(() => _speakerOn = !_speakerOn),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.call_end),
                      label: const Text('End call'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.error,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
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

class _CallControl extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _CallControl({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(32),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: active
                    ? colors.primary.withAlphaFactor(0.15)
                    : colors.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 24,
                color: active ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? colors.primary : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
