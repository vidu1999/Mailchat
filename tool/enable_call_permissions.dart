// Adds the runtime permissions a WebRTC call needs to the generated Android
// project.
//
//   dart run tool/enable_call_permissions.dart
//
// Why a patcher rather than committed files: this repository deliberately does
// not commit generated platform folders (see .gitignore and the CI workflow), so
// `android/` is produced by `flutter create` on each machine and in CI. A file
// that is not checked in cannot carry the permissions, and hand-editing the
// manifest after every scaffold is how they get forgotten — the symptom is a
// call that rings and then reports "could not start the call", with nothing in
// the app to explain why.
//
// What it adds to android/app/src/main/AndroidManifest.xml:
//   * CAMERA                        video calls
//   * RECORD_AUDIO                  any call
//   * MODIFY_AUDIO_SETTINGS         routing audio to the earpiece/speaker
//   * ACCESS_NETWORK_STATE          ICE needs to know when the network changes
//   * BLUETOOTH_CONNECT             Android 12+ headsets (safe on older APIs)
//   * <uses-feature camera/microphone required="false">
//
// `required="false"` matters: a tablet without a camera must still be able to
// install the app and take voice calls.
//
// Idempotent: running it twice changes nothing. Run it after `flutter create`.

import 'dart:io';

const String _marker = 'mailchat:call-media';

const List<String> _permissions = [
  'android.permission.CAMERA',
  'android.permission.RECORD_AUDIO',
  'android.permission.MODIFY_AUDIO_SETTINGS',
  'android.permission.ACCESS_NETWORK_STATE',
  'android.permission.BLUETOOTH_CONNECT',
];

const String _features = '''
    <!-- Declared optional: a device without a camera can still take voice
         calls, and the Play Store would otherwise hide the app from it. -->
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
    <uses-feature android:name="android.hardware.microphone" android:required="false" />
''';

void main() {
  final manifest = File(
    '${_projectRoot().path}/android/app/src/main/AndroidManifest.xml',
  );
  if (!manifest.existsSync()) {
    _fail('No Android project found at ${manifest.path}.\n'
        'Generate it first, from the project root:\n'
        '  flutter create --platforms=android --org com.mailchat --project-name mailchat .');
  }

  final original = manifest.readAsStringSync();
  if (original.contains(_marker)) {
    stdout.writeln('• AndroidManifest.xml: call permissions already present');
    return;
  }

  final missing = <String>[
    for (final permission in _permissions)
      if (!original.contains(permission)) permission,
  ];
  if (missing.isEmpty && original.contains('android.hardware.microphone')) {
    stdout.writeln('• AndroidManifest.xml: permissions and features already present');
    return;
  }

  final buffer = StringBuffer();
  buffer.writeln('    <!-- $_marker: added by tool/enable_call_permissions.dart -->');
  if (missing.isNotEmpty) {
    for (final permission in missing) {
      buffer.writeln('    <uses-permission android:name="$permission" />');
    }
  }
  if (!original.contains('android.hardware.microphone')) {
    buffer.writeln(_features.trimRight());
  }
  buffer.writeln('    <!-- /$_marker -->');

  // Insert just before <application. `</manifest>` would also work, but placing
  // the declarations above the application element keeps them where a developer
  // expects to find them.
  final anchor = RegExp(r'\n?\s*<application\b').firstMatch(original);
  final patched = anchor == null
      ? original.replaceFirst('</manifest>', '${buffer.toString()}</manifest>')
      : original.replaceRange(
          anchor.start,
          anchor.start,
          '\n${buffer.toString()}',
        );

  manifest.writeAsStringSync(patched);

  stdout.writeln('');
  stdout.writeln('✓ AndroidManifest.xml: ${missing.length} permission(s) added');
  for (final permission in missing) {
    stdout.writeln('    + ${permission.split('.').last}');
  }
  stdout.writeln('');
  stdout.writeln('These are granted at runtime by getUserMedia() the first time a');
  stdout.writeln('call starts; denying it fails the call instead of muting it silently.');
}

/// The directory holding pubspec.yaml, searched upwards from the caller's cwd.
Directory _projectRoot() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) return Directory.current;
    dir = parent;
  }
  return dir;
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
