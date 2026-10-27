import 'dart:convert';
import 'dart:io';

import 'package:mailchat/core/logging/app_logger.dart';

/// Remembers that a call was in progress, so a call that kills the process
/// leaves evidence behind.
///
/// Why this exists: media runs in native code (camera, WebRTC, video textures).
/// When one of them takes the process down there is no Dart exception, no stack
/// trace, and — for a native signal kill or an out-of-memory kill — not even an
/// entry in `adb logcat -b crash`, which only holds Java exceptions. The console
/// simply stops and the app comes back at the login screen, and the one piece of
/// information needed to fix it ("which step was running?") is gone with the
/// process.
///
/// So the last step is written to a small file *before* it runs. On the next
/// launch, a trace still sitting there means the previous process never reached
/// its cleanup — the app died mid-call — and the log says which step.
///
/// This is diagnostics, not state: the file is deleted when the call screen
/// disposes normally, and a stale one is only ever logged, never acted on.
class CallTrace {
  const CallTrace({required this.step, this.at, this.video = false});

  /// The last step that started, e.g. `getUserMedia_begin`.
  final String step;

  /// When it started. Null when the file was written without a clock we could
  /// read back, which is not worth failing over.
  final DateTime? at;

  /// Whether the call was a video call — a camera path is a likelier suspect
  /// than an audio-only one.
  final bool video;

  Map<String, dynamic> toJson() => {
        'step': step,
        'video': video,
        if (at != null) 'at': at!.toIso8601String(),
      };

  /// Parses a stored trace, or null when the contents are not usable.
  ///
  /// Anything unreadable is treated as "no trace": a corrupt diagnostic file
  /// must never be the reason the app misbehaves again.
  static CallTrace? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final step = raw['step'];
    if (step is! String || step.isEmpty) return null;
    final at = raw['at'];
    return CallTrace(
      step: step,
      video: raw['video'] == true,
      at: at is String ? DateTime.tryParse(at) : null,
    );
  }

  /// A one-line message for the log and for a bug report.
  String describe() {
    final when = at == null ? 'at an unknown time' : 'at ${at!.toIso8601String()}';
    return 'step "$step" (${video ? 'video' : 'voice'} call) $when';
  }
}

/// Writes and clears the trace file.
///
/// Lives in the app's temporary/cache directory: it is a breadcrumb, not data,
/// and losing it is harmless.
class CallTraceStore {
  CallTraceStore({File? file}) : _override = file;

  final File? _override;
  File? _resolved;

  File get file {
    final cached = _resolved ?? _override;
    if (cached != null) return cached;
    Directory base;
    try {
      base = Directory.systemTemp;
    } catch (_) {
      base = Directory.current;
    }
    final resolved =
        File('${base.path}${Platform.pathSeparator}mailchat_call_trace.json');
    _resolved = resolved;
    return resolved;
  }

  /// Records the step that is about to start. Fire-and-forget: a failed write
  /// must not slow down or fail a call.
  void record(String step, {bool video = false}) {
    final trace = CallTrace(step: step, at: DateTime.now(), video: video);
    try {
      file.writeAsStringSync(jsonEncode(trace.toJson()));
    } catch (e) {
      AppLogger.warning('call_trace_write_failed', details: {'error': '$e'});
    }
  }

  /// Removes the trace: the call ended the way it was supposed to.
  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Leaving a stale file only costs an extra warning on the next launch.
    }
  }

  /// Returns and clears a trace left by a previous process.
  ///
  /// Clearing as it is read is deliberate: the warning is reported once, not on
  /// every launch until someone deletes the file by hand.
  Future<CallTrace?> takePrevious() async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      await clear();
      final decoded = raw.trim().isEmpty ? null : jsonDecode(raw);
      return CallTrace.fromJson(decoded);
    } catch (e) {
      AppLogger.warning('call_trace_read_failed', details: {'error': '$e'});
      await clear();
      return null;
    }
  }

  /// Reads a previous trace and logs it, if there is one. Called once at
  /// startup.
  Future<void> reportPreviousIfAny() async {
    final previous = await takePrevious();
    if (previous == null) return;
    AppLogger.warning(
      'previous_call_ended_without_cleanup',
      details: {
        'trace': previous.describe(),
        'hint': 'the app died during a call; the last step above was running',
      },
    );
  }
}
