import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mailchat/features/calls/domain/call_trace.dart';

/// Background: a call on a real device killed the process with no Dart
/// exception and — as it turned out — nothing in `adb logcat -b crash` either,
/// which only holds Java exceptions. A native signal or an out-of-memory kill
/// leaves the app back at the login screen with no record of which step was
/// running.
///
/// The trace file is that record. These tests pin the two properties that make
/// it trustworthy: it survives as valid JSON, and it is *removed* when a call
/// ends properly, so a leftover file always means "the process died".
void main() {
  late Directory temp;
  late CallTraceStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mailchat_trace_test');
    store = CallTraceStore(file: File('${temp.path}/trace.json'));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('CallTrace serialisation', () {
    test('round-trips step, kind and time', () {
      final at = DateTime.utc(2026, 10, 27, 12, 30);
      final trace = CallTrace(step: 'getUserMedia_begin', at: at, video: true);
      final restored = CallTrace.fromJson(trace.toJson());
      expect(restored, isNotNull);
      expect(restored!.step, 'getUserMedia_begin');
      expect(restored.video, isTrue);
      expect(restored.at, at);
    });

    test('describes itself in one readable line', () {
      final trace = CallTrace(
        step: 'peer_connection_begin',
        at: DateTime.utc(2026, 10, 27, 12, 30),
        video: false,
      );
      final text = trace.describe();
      expect(text, contains('peer_connection_begin'));
      expect(text, contains('voice'));
      expect(text, contains('2026-10-27'));
    });

    test('an unusable file is no trace, never a crash', () {
      // A corrupt breadcrumb must not become the next bug.
      expect(CallTrace.fromJson(null), isNull);
      expect(CallTrace.fromJson('not a map'), isNull);
      expect(CallTrace.fromJson(<String, dynamic>{}), isNull);
      expect(CallTrace.fromJson(<String, dynamic>{'step': ''}), isNull);
      expect(CallTrace.fromJson(<String, dynamic>{'step': 42}), isNull);
      // A missing or unparseable timestamp costs precision, not the report.
      final noTime = CallTrace.fromJson(<String, dynamic>{'step': 'x'});
      expect(noTime?.step, 'x');
      expect(noTime?.at, isNull);
      expect(noTime?.describe(), contains('unknown time'));
    });
  });

  group('CallTraceStore', () {
    test('records the step, and the file exists afterwards', () {
      store.record('getUserMedia_begin', video: false);
      expect(store.file.existsSync(), isTrue);
      expect(store.file.readAsStringSync(), contains('getUserMedia_begin'));
    });

    test('a later step replaces the earlier one', () {
      // Only the last step matters: everything before it completed.
      store.record('renderers_begin');
      store.record('tracks_added', video: true);
      final text = store.file.readAsStringSync();
      expect(text, contains('tracks_added'));
      expect(text, isNot(contains('renderers_begin')));
    });

    test('clear() removes the file, so a clean call leaves nothing', () async {
      store.record('renderers_begin');
      await store.clear();
      expect(store.file.existsSync(), isFalse);
    });

    test('takePrevious returns the trace once, then forgets it', () async {
      store.record('getUserMedia_begin', video: true);

      final first = await store.takePrevious();
      expect(first?.step, 'getUserMedia_begin');
      expect(first?.video, isTrue);

      // Reported once, not on every launch until someone deletes the file.
      expect(await store.takePrevious(), isNull);
      expect(store.file.existsSync(), isFalse);
    });

    test('no file means no trace', () async {
      expect(await store.takePrevious(), isNull);
    });

    test('a corrupt file is cleared and reported as nothing', () async {
      store.file.writeAsStringSync('{not json');
      expect(await store.takePrevious(), isNull);
      expect(store.file.existsSync(), isFalse);
    });

    test('an unreadable directory does not throw', () async {
      // Recording is fire-and-forget on the call path: a failed write must not
      // take down a call that is otherwise fine.
      final bad = CallTraceStore(
        file: File('${temp.path}/nope/deeper/trace.json'),
      );
      expect(() => bad.record('renderers_begin'), returnsNormally);
      await expectLater(bad.clear(), completes);
    });
  });
}
