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
  group('ensureGoogleServicesPlugin', () {
    test('adds the plugin line to a settings plugins block exactly once', () {
      const settings = '''
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
}
''';
      final once = ensureGoogleServicesPlugin(
        settings,
        line: 'id("com.google.gms.google-services") version "4.4.2" apply false',
        pluginId: 'com.google.gms.google-services',
      );
      final twice = ensureGoogleServicesPlugin(
        once,
        line: 'id("com.google.gms.google-services") version "4.4.2" apply false',
        pluginId: 'com.google.gms.google-services',
      );
      expect(once, contains('id("com.google.gms.google-services") version "4.4.2" apply false'));
      expect(twice, once);
      expect(RegExp('com.google.gms.google-services').allMatches(twice), hasLength(1));
    });

    test('adds the app plugin to Groovy and preserves the closing brace', () {
      const app = 'plugins {\n    id "com.android.application"\n}\n';
      final patched = ensureGoogleServicesPlugin(
        app,
        line: 'id("com.google.gms.google-services")',
        pluginId: 'com.google.gms.google-services',
      );
      expect(patched, contains('    id("com.google.gms.google-services")\n}'));
    });
  });

  group('ensureMailchatLauncherIcon', () {
    test('selects the generated MailChat icon exactly once', () {
      const manifest = '''
<manifest>
    <application android:label="MailChat" android:icon="@mipmap/ic_launcher" android:roundIcon="@mipmap/ic_launcher_round">
    </application>
</manifest>
''';
      final once = ensureMailchatLauncherIcon(manifest);
      expect(once, contains('android:icon="@mipmap/ic_mailchat_launcher"'));
      expect(once, contains('android:roundIcon="@mipmap/ic_mailchat_launcher"'));
      expect(ensureMailchatLauncherIcon(once), once);
    });

    test('leaves a manifest without application unchanged', () {
      const manifest = '<manifest />';
      expect(ensureMailchatLauncherIcon(manifest), manifest);
    });
  });

  group('ensureNotificationActionReceiver', () {
    test('inserts the receiver under application exactly once', () {
      const manifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="MailChat">
        <activity android:name=".MainActivity" />
    </application>
</manifest>
''';
      final once = ensureNotificationActionReceiver(manifest);
      final twice = ensureNotificationActionReceiver(once);
      expect(once, contains('<application android:label="MailChat">\n        <receiver'));
      expect(once, contains('com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver'));
      expect(twice, once);
    });

    test('leaves a manifest without application unchanged', () {
      const manifest = '<manifest />';
      expect(ensureNotificationActionReceiver(manifest), manifest);
    });
  });

  group('enableCoreLibraryDesugaring', () {
    test('adds Groovy compile option and dependency exactly once', () {
      const app = '''
android {
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}

dependencies {
    implementation 'some:library:1.0'
}
''';
      final once = enableCoreLibraryDesugaring(app);
      final twice = enableCoreLibraryDesugaring(once);
      expect(once, contains('coreLibraryDesugaringEnabled true'));
      expect(once, contains("coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'"));
      expect(twice, once);
    });

    test('adds Kotlin DSL configuration while preserving Java version', () {
      const app = '''
android {
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation("some:library:1.0")
}
''';
      final patched = enableCoreLibraryDesugaring(app, kotlinDsl: true);
      expect(patched, contains('isCoreLibraryDesugaringEnabled = true'));
      expect(patched, contains('sourceCompatibility = JavaVersion.VERSION_17'));
      expect(patched, contains('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'));
    });

    test('corrects a disabled option and an older desugaring dependency', () {
      const app = '''
android {
    compileOptions {
        coreLibraryDesugaringEnabled false
    }
}
dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.3'
}
''';
      final patched = enableCoreLibraryDesugaring(app);
      expect(patched, contains('coreLibraryDesugaringEnabled true'));
      expect(patched, isNot(contains('coreLibraryDesugaringEnabled false')));
      expect(patched, contains("coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'"));
      expect(patched, isNot(contains('desugar_jdk_libs:2.0.3')));
    });

    test('creates a missing compileOptions block inside android', () {
      const app = 'android {\n    defaultConfig { }\n}\n'
          'dependencies {\n}\n';
      final patched = enableCoreLibraryDesugaring(app);
      expect(patched, contains('    compileOptions {\n        coreLibraryDesugaringEnabled true\n    }'));
      expect(patched, contains("coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'"));
    });

    test('creates dependencies block when generated scaffold omits it', () {
      const app = 'plugins { id "com.android.application" }\n'
          'android {\n    compileOptions {\n    }\n}\n';
      final patched = enableCoreLibraryDesugaring(app);
      expect(patched, contains('dependencies {\n    coreLibraryDesugaring'));
      expect(enableCoreLibraryDesugaring(patched), patched);
    });
  });

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

  // A second failure mode from the same cause: `flutter upgrade` replaces the
  // SDK but never rewrites an existing android/ folder. Its Gradle wrapper then
  // sits below what the new SDK accepts, and the build dies after minutes with
  // "Your project's Gradle version (8.3.0) is lower than Flutter's minimum
  // supported version of 8.14.0". These helpers read the three numbers that
  // decide it, so the tool can say so in a second.
  group('gradleWrapperVersion', () {
    test('reads the Windows-escaped distribution URL', () {
      // The wrapper file escapes the colon; the version is in the file name.
      const props = 'distributionUrl=https\\://services.gradle.org/'
          'distributions/gradle-8.3-all.zip';
      expect(gradleWrapperVersion(props), '8.3');
    });

    test('reads -bin and multi-digit minors', () {
      expect(
        gradleWrapperVersion(
          'distributionUrl=https://services.gradle.org/distributions/'
          'gradle-9.3.1-bin.zip',
        ),
        '9.3.1',
      );
    });

    test('a prerelease or versionless distribution is unknown', () {
      expect(
        gradleWrapperVersion(
          'distributionUrl=https://x/gradle-8.14-rc-1-all.zip',
        ),
        isNull,
      );
      expect(
        gradleWrapperVersion('distributionBase=GRADLE_USER_HOME'),
        isNull,
      );
    });
  });

  group('pluginVersion', () {
    test('reads the Kotlin DSL form', () {
      const settings = '''
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}''';
      expect(pluginVersion(settings, 'com.android.application'), '9.1.0');
      expect(pluginVersion(settings, 'org.jetbrains.kotlin.android'), '2.2.20');
    });

    test('reads the Groovy form', () {
      const settings = '''
plugins {
    id 'com.android.application' version '8.1.0' apply false
}''';
      expect(pluginVersion(settings, 'com.android.application'), '8.1.0');
    });

    test('an absent plugin is unknown, not current', () {
      const settings = 'plugins { id "dev.flutter.flutter-plugin-loader" }';
      expect(pluginVersion(settings, 'com.android.application'), isNull);
    });
  });

  group('classpathAgpVersion', () {
    test('reads the old buildscript coordinate', () {
      const build = '''
buildscript {
    dependencies {
        classpath 'com.android.tools.build:gradle:7.3.0'
    }
}''';
      expect(classpathAgpVersion(build), '7.3.0');
    });

    test('no classpath means unknown', () {
      expect(classpathAgpVersion('plugins { }'), isNull);
    });
  });

  group('AndroidToolchain.gapsAgainst', () {
    test('reports an android/ folder generated by an older SDK', () {
      // The situation behind the reported failure: a project folder from before
      // an upgrade, next to what the installed SDK scaffolds.
      const project = AndroidToolchain(
        gradle: '8.3',
        agp: '8.1.0',
        kotlin: '1.8.22',
      );
      const sdk = AndroidToolchain(
        gradle: '9.3.1',
        agp: '9.1.0',
        kotlin: '2.2.20',
      );
      expect(project.gapsAgainst(sdk), [
        'Gradle 8.3 → 9.3.1',
        'AGP 8.1.0 → 9.1.0',
        'Kotlin 1.8.22 → 2.2.20',
      ]);
    });

    test('a folder that matches the SDK has no gaps', () {
      const toolchain = AndroidToolchain(
        gradle: '9.3.1',
        agp: '9.1.0',
        kotlin: '2.2.20',
      );
      expect(toolchain.gapsAgainst(toolchain), isEmpty);
    });

    test('a newer folder is not flagged', () {
      const project = AndroidToolchain(gradle: '10.1', agp: '9.5.0');
      const sdk = AndroidToolchain(gradle: '9.3.1', agp: '9.1.0');
      expect(project.gapsAgainst(sdk), isEmpty);
    });

    test('an unreadable component is skipped, not guessed', () {
      // Old templates have no `plugins {}` block to read AGP and Kotlin from.
      const project = AndroidToolchain(gradle: '8.3');
      const sdk = AndroidToolchain(
        gradle: '9.3.1',
        agp: '9.1.0',
        kotlin: '2.2.20',
      );
      expect(project.gapsAgainst(sdk), ['Gradle 8.3 → 9.3.1']);
      expect(project.isEmpty, isFalse);
      expect(const AndroidToolchain().isEmpty, isTrue);
    });
  });

  // Third Windows-only failure: Kotlin's incremental compiler stores source
  // paths relative to the module, which throws "this and base files have
  // different roots" when the pub cache is on C: and the project is not. The
  // build dies after ~30 minutes with "Could not close incremental caches".
  group('kotlinIncrementalWorkaroundNeeded', () {
    test('a project on another drive than the pub cache needs it', () {
      // The reported layout: project on H:, pub cache under LOCALAPPDATA on C:.
      expect(
        kotlinIncrementalWorkaroundNeeded(
          projectPath: r'H:\Mailchat',
          pubCachePath: r'C:\Users\vidur\AppData\Local\Pub\Cache',
          isWindows: true,
        ),
        isTrue,
      );
    });

    test('the same drive needs nothing', () {
      expect(
        kotlinIncrementalWorkaroundNeeded(
          projectPath: r'C:\dev\mailchat',
          pubCachePath: r'C:\Users\vidur\AppData\Local\Pub\Cache',
          isWindows: true,
        ),
        isFalse,
      );
    });

    test('drive letters compare case-insensitively', () {
      expect(
        kotlinIncrementalWorkaroundNeeded(
          projectPath: r'c:\dev\mailchat',
          pubCachePath: r'C:\Pub\Cache',
          isWindows: true,
        ),
        isFalse,
      );
    });

    test('other platforms never need it', () {
      // No drive letters, and the POSIX path handling is fine.
      expect(
        kotlinIncrementalWorkaroundNeeded(
          projectPath: '/home/user/Mailchat',
          pubCachePath: '/home/user/.pub-cache',
          isWindows: false,
        ),
        isFalse,
      );
    });

    test('an unknown or UNC pub cache is assumed to need it', () {
      // Refusing to guess here would leave the user with the 30-minute failure.
      expect(
        kotlinIncrementalWorkaroundNeeded(
          projectPath: r'H:\Mailchat',
          pubCachePath: null,
          isWindows: true,
        ),
        isTrue,
      );
      expect(
        kotlinIncrementalWorkaroundNeeded(
          projectPath: r'\\nas\share\Mailchat',
          pubCachePath: r'C:\Users\v\AppData\Local\Pub\Cache',
          isWindows: true,
        ),
        isTrue,
      );
    });
  });

  group('disableKotlinIncremental', () {
    test('appends the setting with a marker to an empty file', () {
      final out = disableKotlinIncremental('');
      expect(out, contains('kotlin.incremental=false'));
      expect(out, contains(kotlinIncrementalMarker));
    });

    test('keeps the JVM heap settings the template wrote', () {
      // Losing these turns a Kotlin error into an out-of-memory one.
      const before = 'org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G\n'
          'android.useAndroidX=true\n';
      final out = disableKotlinIncremental(before);
      expect(out, contains('org.gradle.jvmargs=-Xmx4G'));
      expect(out, contains('android.useAndroidX=true'));
      expect(out, contains('kotlin.incremental=false'));
    });

    test('corrects an explicit true rather than trusting it', () {
      // `true` is exactly the setting that cannot work across drives.
      final out = disableKotlinIncremental('kotlin.incremental=true\n');
      expect(out.trim(), 'kotlin.incremental=false');
    });

    test('is idempotent', () {
      final once = disableKotlinIncremental('android.useAndroidX=true\n');
      expect(disableKotlinIncremental(once), once);
    });

    test('keeps a file that does not end with a newline readable', () {
      final out = disableKotlinIncremental('android.useAndroidX=true');
      expect(out, contains('android.useAndroidX=true\n'));
      expect(out, contains('kotlin.incremental=false'));
    });
  });
}
