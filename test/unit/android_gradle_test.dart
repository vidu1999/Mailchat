import 'package:flutter_test/flutter_test.dart';

// The build repair script is checked here on purpose: it edits a generated
// Gradle file that no test can otherwise exercise, and a bad rewrite would break
// every Android build with a syntax error rather than a message.
import '../../tool/fix_android_build.dart';

/// Background: two independent failures from the same cause — an Android
/// toolchain older than `flutter_webrtc` needs.
///
/// ```text
/// Warning: The plugin flutter_webrtc requires Android SDK version 36 or higher.
/// error: <anonymous ...$1> is not abstract and does not override abstract
///        method onSurfaceDestroyed() in Callback
/// Execution failed for task ':flutter_webrtc:compileDebugJavaWithJavac'.
/// ```
///
/// The first is compileSdk; the second is the Flutter embedding's
/// `SurfaceProducer.Callback`, which only gained `onSurfaceCleanup()` in 3.29.
/// `tool/fix_android_build.dart` fixes the first and refuses to pretend it can
/// fix the second.
void main() {
  group('pinCompileSdk', () {
    test('rewrites the old Groovy form', () {
      const gradle = '''
android {
    compileSdkVersion 34
    defaultConfig {
        minSdkVersion 21
    }
}''';
      final out = pinCompileSdk(gradle);
      expect(out, contains('compileSdkVersion 36'));
      expect(out, isNot(contains('compileSdkVersion 34')));
      // Everything else is untouched.
      expect(out, contains('minSdkVersion 21'));
    });

    test('rewrites the assignment form', () {
      expect(
        pinCompileSdk('android {\n    compileSdkVersion = 34\n}'),
        contains('compileSdk = 36'),
      );
    });

    test('rewrites the modern short form', () {
      expect(
        pinCompileSdk('android {\n    compileSdk 34\n}'),
        contains('compileSdkVersion 36'),
      );
      expect(
        pinCompileSdk('android {\n    compileSdk = 34\n}'),
        contains('compileSdk = 36'),
      );
    });

    test('a symbolic value is left to the Flutter SDK', () {
      // When this resolves to something older, the SDK is the problem, and a
      // literal here would hide that behind a different failure.
      const groovy = 'android {\n    compileSdkVersion flutter.compileSdkVersion\n}';
      const kts = 'android {\n    compileSdk = flutter.compileSdkVersion\n}';
      expect(pinCompileSdk(groovy), groovy);
      expect(pinCompileSdk(kts), kts);
    });

    test('a Kotlin DSL file always gets the assignment form', () {
      // build.gradle.kts has no compileSdkVersion property; emitting the Groovy
      // name there would trade a Java error for a Gradle script error.
      expect(
        pinCompileSdk('android {\n    compileSdkVersion 34\n}', kotlinDsl: true),
        contains('compileSdk = 36'),
      );
      expect(
        pinCompileSdk('android {\n    compileSdk 34\n}', kotlinDsl: true),
        contains('compileSdk = 36'),
      );
    });

    test('is idempotent', () {
      final once = pinCompileSdk('android {\n    compileSdk = 34\n}');
      expect(pinCompileSdk(once), once);
      expect(pinCompileSdk(once), contains('36'));
    });

    test('a higher value is not lowered', () {
      // If the project already compiles against 37, dragging it back to 36 would
      // break whatever needed 37. The tool only ever raises.
      const newer = 'android {\n    compileSdk = 37\n}';
      expect(pinCompileSdk(newer, sdk: 36), newer);
    });

    test('inserts a line when none exists', () {
      final out = pinCompileSdk('android {\n    defaultConfig {\n    }\n}');
      expect(out, contains('compileSdk = 36'));
      expect(out.indexOf('compileSdk = 36'),
          lessThan(out.indexOf('defaultConfig')));
    });

    test('a file with no android block is returned unchanged', () {
      const other = 'plugins {\n    id "dev.flutter.flutter-plugin-loader"\n}';
      expect(pinCompileSdk(other), other);
    });
  });

  group('versionAtLeast', () {
    test('equal and newer pass', () {
      expect(versionAtLeast('3.35.0', '3.35.0'), isTrue);
      expect(versionAtLeast('3.35.1', '3.35.0'), isTrue);
      expect(versionAtLeast('3.36.0', '3.35.0'), isTrue);
      expect(versionAtLeast('4.0.0', '3.35.0'), isTrue);
    });

    test('older fails, including the two-digit trap', () {
      expect(versionAtLeast('3.34.9', '3.35.0'), isFalse);
      // "3.9" is ninth minor of 3, not 3.90: a string comparison would get this
      // backwards and happily build on an SDK that cannot compile the plugin.
      expect(versionAtLeast('3.9.0', '3.35.0'), isFalse);
      expect(versionAtLeast('2.99.99', '3.35.0'), isFalse);
    });

    test('a shorter version is compared as if padded with zeros', () {
      expect(versionAtLeast('3.35', '3.35.0'), isTrue);
      expect(versionAtLeast('3.35', '3.35.1'), isFalse);
    });

    test('pre-release tails are ignored, unparseable input is too old', () {
      expect(versionAtLeast('3.35.0-1.2.pre', '3.35.0'), isTrue);
      expect(versionAtLeast('', '3.35.0'), isFalse);
      expect(versionAtLeast('unknown', '3.35.0'), isFalse);
    });
  });
}
