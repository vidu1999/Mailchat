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
/// Decides how often a failing heartbeat may be retried.
///
/// Why this exists: when the phone loses its network — no DNS, or UDP and TCP
/// both blocked — every beat fails, and a fixed 30-second timer writes two ERROR
/// lines (one from the client, one from here) into the log that the user is
/// being asked to send. Those lines all say the same thing, and they bury the
/// one failure that actually explains the problem. So the first failure is
/// reported in full and the repeats are spaced out: 30 s, 60 s, 2 min, 4 min,
/// then every 5 minutes until one succeeds.
///
/// Deliberately independent of the timer: it is pure state plus a clock, so it
/// can be tested without waiting for real seconds to pass.
class HeartbeatBackoff {
  HeartbeatBackoff({
    this.interval = PresenceService.heartbeatInterval,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The heartbeat period. Also the shortest wait between retries.
  final Duration interval;

  /// Waits are capped here: a phone that was offline overnight should not take
  /// hours to look online again after the network returns.
  static const Duration maxDelay = Duration(minutes: 5);

  final DateTime Function() _clock;

  int _failures = 0;
  DateTime? _retryAt;

  /// Consecutive failures since the last success.
  int get failures => _failures;

  /// How long until the next attempt is allowed. Zero when one is allowed now.
  Duration get retryIn {
    final at = _retryAt;
    if (at == null) return Duration.zero;
    final remaining = at.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// The wait after [failures] consecutive failures.
  static Duration delayFor(int failures, Duration interval) {
    if (failures <= 0) return Duration.zero;
    // 2^(n-1) periods, with the shift capped so a long outage cannot overflow.
    final doublings = failures - 1 > 5 ? 5 : failures - 1;
    final delay = interval * (1 << doublings);
    return delay > maxDelay ? maxDelay : delay;
  }

  /// Whether a beat may run now.
  bool shouldAttempt() => retryIn == Duration.zero;

  void recordSuccess() {
    _failures = 0;
    _retryAt = null;
  }

  void recordFailure() {
    _failures++;
    _retryAt = _clock().add(delayFor(_failures, interval));
  }
}

class LastSeenHeartbeat with WidgetsBindingObserver {
  LastSeenHeartbeat({
    PresenceService? presence,
    this.interval = PresenceService.heartbeatInterval,
    HeartbeatBackoff? backoff,
  })  : _presence = presence ?? PresenceService(),
        _backoff = backoff ?? HeartbeatBackoff(interval: interval);

  final PresenceService _presence;
  final Duration interval;
  final HeartbeatBackoff _backoff;

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
    if (!_backoff.shouldAttempt()) {
      // Still inside the wait a previous failure earned: the network was down a
      // moment ago, so another request would fail the same way and only add
      // noise to the log.
      AppLogger.info('heartbeat_skipped', details: {
        'consecutive_failures': _backoff.failures,
        'retry_in_seconds': _backoff.retryIn.inSeconds,
      });
      return;
    }
    try {
      await _presence.touchLastSeen();
      _backoff.recordSuccess();
    } catch (e, st) {
      _backoff.recordFailure();
      if (_backoff.failures == 1) {
        // The first failure is the evidence; later ones are the same cause.
        AppLogger.error(e, st, {'where': 'last_seen_heartbeat'});
      } else {
        AppLogger.info('heartbeat_backoff', details: {
          'consecutive_failures': _backoff.failures,
          'retry_in_seconds': _backoff.retryIn.inSeconds,
        });
      }
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
