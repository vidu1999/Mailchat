/// What kind of path an ICE candidate describes, and what to tell the user
/// when a call is still connecting.
///
/// Kept free of `flutter_webrtc` so the sentences and the queues can be unit
/// tested. The peer connection only ever hands this file a candidate string.
library;

/// The `typ` token of one ICE candidate.
///
/// `host` is this phone's own address, `serverReflexive` is what STUN learned,
/// `relay` is an address on the TURN server — the only one that works when the
/// two phones cannot reach each other directly.
enum IceCandidateKind { host, serverReflexive, relay, peerReflexive, unknown }

/// A short name for logs. Not the enum name: `serverReflexive` would not match
/// the `typ srflx` token a bug report is compared against.
extension IceCandidateKindX on IceCandidateKind {
  String get logName => switch (this) {
        IceCandidateKind.host => 'host',
        IceCandidateKind.serverReflexive => 'srflx',
        IceCandidateKind.relay => 'relay',
        IceCandidateKind.peerReflexive => 'prflx',
        IceCandidateKind.unknown => 'unknown',
      };
}

final RegExp _typToken = RegExp(
  r'(?:^|\s)typ\s+(host|srflx|relay|prflx)(?:\s|$)',
);

final RegExp _candidateLine = RegExp(
  r'^(?:a=)?candidate:',
  caseSensitive: false,
);

/// Classifies [raw]. The address is intentionally not returned: logs and the
/// call screen only need the kind, and a candidate line contains an IP.
IceCandidateKind classifyIceCandidate(String raw) {
  final match = _typToken.firstMatch(raw.toLowerCase());
  return switch (match?.group(1)) {
    'host' => IceCandidateKind.host,
    'srflx' => IceCandidateKind.serverReflexive,
    'relay' => IceCandidateKind.relay,
    'prflx' => IceCandidateKind.peerReflexive,
    _ => IceCandidateKind.unknown,
  };
}

/// True for an SDP candidate line, with or without the `a=` prefix.
bool isIceCandidateLine(String line) =>
    _candidateLine.hasMatch(line.trim());

/// Counts of the paths gathered so far. Immutable, so a widget can keep the
/// previous value and a test can compare two snapshots.
class IcePathSnapshot {
  const IcePathSnapshot({
    this.host = 0,
    this.serverReflexive = 0,
    this.relay = 0,
    this.other = 0,
    this.gatheringComplete = false,
    this.remoteRelay = 0,
    this.remoteOther = 0,
  });

  final int host;
  final int serverReflexive;
  final int relay;
  final int other;
  final bool gatheringComplete;

  /// Relay addresses received from the other phone (SDP or trickle).
  final int remoteRelay;

  /// Non-relay addresses received from the other phone.
  final int remoteOther;

  int get localTotal => host + serverReflexive + relay + other;
  int get remoteAdded => remoteRelay + remoteOther;

  IcePathSnapshot addLocal(String candidate) {
    final kind = classifyIceCandidate(candidate);
    return _copy(
      host: host + (kind == IceCandidateKind.host ? 1 : 0),
      serverReflexive:
          serverReflexive + (kind == IceCandidateKind.serverReflexive ? 1 : 0),
      relay: relay + (kind == IceCandidateKind.relay ? 1 : 0),
      other: other +
          (kind == IceCandidateKind.peerReflexive ||
                  kind == IceCandidateKind.unknown
              ? 1
              : 0),
    );
  }

  IcePathSnapshot markGatheringComplete() => _copy(gatheringComplete: true);

  IcePathSnapshot noteRemoteCandidate(String candidate) {
    if (classifyIceCandidate(candidate) == IceCandidateKind.relay) {
      return _copy(remoteRelay: remoteRelay + 1);
    }
    return _copy(remoteOther: remoteOther + 1);
  }

  /// Counts candidate lines inside an offer or answer.
  ///
  /// Those lines are the other phone's addresses even when the candidate table
  /// never delivers a row, so the hint must see them.
  IcePathSnapshot noteRemoteSdp(String sdp) {
    var relayCount = remoteRelay;
    var otherCount = remoteOther;
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      if (!isIceCandidateLine(line)) continue;
      if (classifyIceCandidate(line) == IceCandidateKind.relay) {
        relayCount++;
      } else {
        otherCount++;
      }
    }
    return _copy(remoteRelay: relayCount, remoteOther: otherCount);
  }

  /// Credential-free, for `call_connect_slow` and `call_ice_gathered`.
  Map<String, dynamic> get logDetails => <String, dynamic>{
        'host': host,
        'srflx': serverReflexive,
        'relay': relay,
        'other': other,
        'gathering_complete': gatheringComplete,
        'remote_relay': remoteRelay,
        'remote_other': remoteOther,
      };

  IcePathSnapshot _copy({
    int? host,
    int? serverReflexive,
    int? relay,
    int? other,
    bool? gatheringComplete,
    int? remoteRelay,
    int? remoteOther,
  }) {
    return IcePathSnapshot(
      host: host ?? this.host,
      serverReflexive: serverReflexive ?? this.serverReflexive,
      relay: relay ?? this.relay,
      other: other ?? this.other,
      gatheringComplete: gatheringComplete ?? this.gatheringComplete,
      remoteRelay: remoteRelay ?? this.remoteRelay,
      remoteOther: remoteOther ?? this.remoteOther,
    );
  }
}

/// Holds items until a listener is attached, then delivers them in order.
///
/// ICE gathering starts at `setLocalDescription`, which the call screen does
/// before it has a call id to write candidates against. Without this buffer
/// those early candidates — sometimes the only relay address — are dropped,
/// and the call sits on "Connecting..." with a relay that was never told
/// about the other phone.
class IceCandidateQueue<T> {
  void Function(T item)? _listener;
  final List<T> _pending = <T>[];

  int get pending => _pending.length;
  bool get hasListener => _listener != null;

  set listener(void Function(T item)? value) {
    _listener = value;
    if (value == null) return;
    final queued = List<T>.of(_pending);
    _pending.clear();
    for (final item in queued) {
      value(item);
    }
  }

  void add(T item) {
    final current = _listener;
    if (current == null) {
      _pending.add(item);
    } else {
      current(item);
    }
  }

  void clear() {
    _pending.clear();
    _listener = null;
  }
}

/// Remote candidates that arrived before `setRemoteDescription`.
///
/// Adding one earlier throws on the native stack. The previous code caught
/// that and forgot the candidate, which is how a relay address gathered by
/// the other phone never got used.
class RemoteCandidateGate<T> {
  bool _open = false;
  final List<T> _pending = <T>[];

  bool get isOpen => _open;
  int get pending => _pending.length;

  /// The item, when it may be added now. Null when it was queued instead.
  T? submit(T item) {
    if (_open) return item;
    _pending.add(item);
    return null;
  }

  /// Opens the gate and returns everything that was waiting, in order.
  List<T> open() {
    _open = true;
    final queued = List<T>.of(_pending);
    _pending.clear();
    return queued;
  }

  void reset() {
    _open = false;
    _pending.clear();
  }
}

/// One sentence for a call that has not connected, or null when there is
/// nothing useful to say yet.
///
/// Each sentence names a different cause. The previous single sentence
/// ("the network is blocking the call") sent people into phone settings when
/// the gap was a missing TCP address, a wrong password, or an answer the
/// caller never applied.
String? callConnectAdvice({
  required bool hasRelay,
  required bool hasTcpFallback,
  required bool slow,
  required int waitedSeconds,
  required bool isCaller,
  required bool answerApplied,
  required IcePathSnapshot path,
}) {
  if (!hasRelay) {
    if (!slow) {
      return isCaller
          ? 'No TURN relay configured: this call may fail on mobile data.'
          : null;
    }
    return 'Still not connected after $waitedSeconds seconds. This build has '
        'no relay (TURN), so the call only works when both phones can reach '
        'each other — mobile data usually cannot.';
  }
  if (!slow) return null;
  if (isCaller && !answerApplied) {
    return 'Waiting for the other phone to accept. If they already accepted, '
        'this phone cannot reach the server.';
  }
  if (path.relay == 0) {
    if (!hasTcpFallback) {
      return 'The relay on this phone has no TCP address, so this network is '
          'blocking it. Add the turns:443 line and rebuild the app.';
    }
    return 'The relay refused this phone. The username or password in the '
        'app config is wrong, or it was just created — wait two minutes.';
  }
  if (path.remoteAdded == 0) {
    return 'This phone reached the relay. Nothing has arrived from the other '
        'phone. Both phones need the new app, and both need internet.';
  }
  if (path.remoteRelay == 0) {
    return 'This phone reached the relay. The other phone did not. A computer '
        'needs the same TURN lines pasted in the page Settings. Same Wi-Fi '
        'can still connect without that.';
  }
  return 'Both phones reached the relay, but the audio is still blocked. '
      'Turn off Data saver and any VPN on both phones, then call again.';
}

/// Drops `a=extmap-allow-mixed`.
///
/// A browser offer includes that line. Some mobile WebRTC stacks reject the
/// whole description, so the call rings and then never connects. Removing
/// the line does not change the media.
String sdpForInterop(String sdp) {
  if (!sdp.contains('extmap-allow-mixed')) return sdp;
  final lines = sdp.split(RegExp(r'\r\n|\n|\r'));
  final kept = lines.where((line) => line != 'a=extmap-allow-mixed');
  final joined = kept.join('\r\n');
  if (sdp.endsWith('\n') || sdp.endsWith('\r')) return '$joined\r\n';
  return joined;
}
