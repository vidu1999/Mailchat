import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/shared/services/presence_service.dart';

/// Keeps this user's `user_presence` row fresh while the app is in the
/// foreground, which is what lets other people see "Online" and "last seen".
///
/// Deliberately a plain heartbeat rather than a "go offline" write on exit: a
/// process can be killed, lose signal or be swiped away without any chance to
/// send one, so the only reliable signal is the last time it managed to speak.
/// The server therefore treats a heartbeat older than
/// [PresenceService.onlineWindow] as offline.
///
/// Failures are logged and dropped. A late heartbeat is a cosmetic problem; a
/// retry storm from a flaky connection is a real one.
class LastSeenHeartbeat with WidgetsBindingObserver {
  LastSeenHeartbeat({
    PresenceService? presence,
    this.interval = PresenceService.heartbeatInterval,
  }) : _presence = presence ?? PresenceService();

  final PresenceService _presence;
  final Duration interval;

  Timer? _timer;
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(beat());
    _timer = Timer.periodic(interval, (_) => unawaited(beat()));
  }

  void stop() {
    if (!_running) return;
    _running = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  /// Writes one heartbeat now. Called on start and on every resume, so coming
  /// back to the app does not wait up to [interval] before showing online.
  Future<void> beat() async {
    try {
      await _presence.touchLastSeen();
    } catch (e, st) {
      AppLogger.error(e, st, {'where': 'last_seen_heartbeat'});
    }
  }

  /// Turns status sharing on or off, persisting the setting server-side.
  Future<void> setSharing(bool share) => _presence.touchLastSeen(share: share);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _running) {
      unawaited(beat());
    }
  }

  void dispose() => stop();
}
