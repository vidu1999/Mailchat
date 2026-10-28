import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/features/calls/domain/ice_path.dart';

void main() {
  const host =
      'candidate:1 1 UDP 2122252543 192.0.2.1 54321 typ host generation 0';
  const srflx =
      'candidate:2 1 UDP 1686052607 198.51.100.2 40000 typ srflx raddr 192.0.2.1 rport 54321';
  const relay =
      'a=candidate:3 1 UDP 41885439 203.0.113.5 50000 typ relay raddr 198.51.100.2 rport 40000';
  const prflx = 'candidate:4 1 UDP 100 203.0.113.9 50001 typ prflx';

  group('classifyIceCandidate', () {
    test('reads the typ token and ignores the address', () {
      expect(classifyIceCandidate(host), IceCandidateKind.host);
      expect(classifyIceCandidate(srflx), IceCandidateKind.serverReflexive);
      expect(classifyIceCandidate(relay), IceCandidateKind.relay);
      expect(classifyIceCandidate(prflx), IceCandidateKind.peerReflexive);
      expect(classifyIceCandidate(''), IceCandidateKind.unknown);
      expect(classifyIceCandidate('not a candidate'), IceCandidateKind.unknown);
    });

    test('log names match the token a bug report is compared against', () {
      expect(IceCandidateKind.serverReflexive.logName, 'srflx');
      expect(IceCandidateKind.relay.logName, 'relay');
    });
  });

  group('IcePathSnapshot', () {
    test('counts local kinds and remote SDP lines separately', () {
      final path = const IcePathSnapshot()
          .addLocal(host)
          .addLocal(relay)
          .noteRemoteSdp('v=0\r\n$relay\r\n$srflx\r\n')
          .noteRemoteCandidate(host);

      expect(path.host, 1);
      expect(path.relay, 1);
      expect(path.remoteRelay, 1);
      expect(path.remoteOther, 2);
      expect(path.remoteAdded, 3);
      expect(path.logDetails['relay'], 1);
      // The log is what gets pasted. It must not grow a place to put an IP.
      expect(path.logDetails.keys, isNot(contains('candidate')));
    });

    test('gathering complete does not reset the counts', () {
      final path = const IcePathSnapshot().addLocal(relay).markGatheringComplete();
      expect(path.gatheringComplete, isTrue);
      expect(path.relay, 1);
    });
  });

  group('IceCandidateQueue', () {
    test('keeps items until a listener exists, then delivers in order', () {
      final queue = IceCandidateQueue<String>();
      queue.add('a');
      queue.add('b');
      expect(queue.pending, 2);

      final got = <String>[];
      queue.listener = got.add;
      expect(got, ['a', 'b']);
      expect(queue.pending, 0);

      queue.add('c');
      expect(got, ['a', 'b', 'c']);
    });

    test('clear drops both the buffer and the listener', () {
      final queue = IceCandidateQueue<String>();
      final got = <String>[];
      queue.listener = got.add;
      queue.clear();
      queue.add('later');
      expect(got, isEmpty);
      expect(queue.pending, 1);
    });
  });

  group('RemoteCandidateGate', () {
    test('holds candidates until the remote description exists', () {
      final gate = RemoteCandidateGate<String>();
      expect(gate.submit('a'), isNull);
      expect(gate.submit('b'), isNull);
      expect(gate.isOpen, isFalse);

      expect(gate.open(), ['a', 'b']);
      expect(gate.isOpen, isTrue);
      expect(gate.pending, 0);
      expect(gate.submit('c'), 'c');
    });
  });

  group('callConnectAdvice', () {
    const empty = IcePathSnapshot();
    const reached = IcePathSnapshot(relay: 2, gatheringComplete: true);

    test('no relay: a warning now, and a different sentence once it is slow', () {
      expect(
        callConnectAdvice(
          hasRelay: false,
          hasTcpFallback: false,
          slow: false,
          waitedSeconds: 15,
          isCaller: true,
          answerApplied: false,
          path: empty,
        ),
        contains('No TURN relay'),
      );
      expect(
        callConnectAdvice(
          hasRelay: false,
          hasTcpFallback: false,
          slow: false,
          waitedSeconds: 15,
          isCaller: false,
          answerApplied: false,
          path: empty,
        ),
        isNull,
      );
      expect(
        callConnectAdvice(
          hasRelay: false,
          hasTcpFallback: false,
          slow: true,
          waitedSeconds: 15,
          isCaller: true,
          answerApplied: false,
          path: empty,
        ),
        contains('no relay (TURN)'),
      );
    });

    test('a configured relay says nothing until the wait is long', () {
      expect(
        callConnectAdvice(
          hasRelay: true,
          hasTcpFallback: true,
          slow: false,
          waitedSeconds: 15,
          isCaller: true,
          answerApplied: false,
          path: empty,
        ),
        isNull,
      );
    });

    test('names the gap instead of blaming the network in general', () {
      String advice({
        bool tcp = true,
        bool answer = true,
        IcePathSnapshot? path,
      }) {
        return callConnectAdvice(
          hasRelay: true,
          hasTcpFallback: tcp,
          slow: true,
          waitedSeconds: 15,
          isCaller: true,
          answerApplied: answer,
          path: path ?? empty,
        )!;
      }

      expect(advice(answer: false), contains('Waiting for the other phone'));
      expect(
        advice(
          tcp: false,
          path: const IcePathSnapshot(gatheringComplete: true),
        ),
        contains('no TCP address'),
      );
      expect(
        advice(path: const IcePathSnapshot(gatheringComplete: true)),
        contains('refused this phone'),
      );
      expect(advice(), contains('call description was rejected'));
      expect(
        advice(path: reached),
        contains('Nothing has arrived from the other phone'),
      );
      expect(
        advice(path: const IcePathSnapshot(relay: 1, remoteOther: 2)),
        contains('The other phone did not'),
      );
      final both = advice(
        path: const IcePathSnapshot(relay: 1, remoteRelay: 1),
      );
      expect(both, contains('Data saver'));
      // The old sentence sent people looking in the wrong place.
      expect(both, isNot(contains('relay has not taken over')));
    });
  });

  test('sdpForInterop drops the browser-only line and keeps the rest', () {
    const raw = 'v=0\r\na=extmap-allow-mixed\r\na=group:BUNDLE 0\r\n';
    final cleaned = sdpForInterop(raw);
    expect(cleaned, isNot(contains('extmap-allow-mixed')));
    expect(cleaned, contains('a=group:BUNDLE 0'));
    expect(cleaned, contains('\r\n'));
    expect(sdpForInterop('v=0\r\n'), 'v=0\r\n');
  });

  test('sdpForInterop repairs the shapes Android reports as a null description', () {
    final lfOnly = sdpForInterop('v=0\na=group:BUNDLE 0\n');
    expect(lfOnly, 'v=0\r\na=group:BUNDLE 0\r\n');

    final blank = sdpForInterop('v=0\r\n\r\na=group:BUNDLE 0\r\n');
    expect(blank, isNot(contains('\r\n\r\n')));
    expect(blank, contains('a=group:BUNDLE 0'));

    final literal = sdpForInterop(r'v=0\r\na=extmap-allow-mixed\r\na=mid:0');
    expect(literal, isNot(contains('extmap-allow-mixed')));
    expect(literal, contains('a=mid:0'));
    expect(literal, startsWith('v=0\r\n'));

    expect(sdpForInterop('not an offer'), isEmpty);
    expect(
      friendlyCallFailure('SessionDescription is NULL'),
      contains('could not read'),
    );
  });
}
