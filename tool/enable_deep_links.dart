// Prepares the generated Android project to install and run on a real device.
//
//   dart run tool/enable_deep_links.dart                      # links + INTERNET
//   dart run tool/enable_deep_links.dart --signing            # also wire a keystore
//   dart run tool/enable_deep_links.dart --host=auth.example.com --signing
//
// Why a patcher instead of committed files: the repository deliberately does
// not commit generated platform folders (see .gitignore and .github/workflows),
// and a generated `android/` already exists on a developer machine. Writing
// files from this script keeps that project intact — only the three things
// listed below are touched, and each is idempotent.
//
// What it changes:
//   1. android/app/src/main/AndroidManifest.xml
//        a. INTERNET permission (debug builds get it from a generated
//           debug manifest; release builds lose networking without it)
//        b. an intent-filter for `mailchat://auth/callback`
//        c. optionally an https app link for a domain you own
//   2. MainActivity — forwards the incoming link to Dart over the
//      `mailchat/links` channel read by lib/core/deeplink/app_links.dart.
//
// Run it again after `flutter create` regenerates the folder; it is safe.

import 'dart:io';

const String _manifestMarker = 'mailchat:deep-links';
const String _mainActivityMarker = 'mailchat/links';

void main(List<String> args) {
  final host = _argValue(args, '--host') ?? Platform.environment['MAILCHAT_LINK_HOST'];
  final root = _projectRoot();
  final manifest = File('${root.path}/android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    _fail('No Android project found at ${manifest.path}.\n'
        'Generate it first, from the project root:\n'
        '  flutter create --platforms=android --org com.mailchat --project-name mailchat .');
  }

  final manifestChanged = _patchManifest(manifest, host: host);
  final activityPath = _findMainActivity(root);
  final activityChanged =
      activityPath == null ? false : _patchMainActivity(activityPath);

  stdout.writeln('');
  stdout.writeln(manifestChanged
      ? '✓ AndroidManifest.xml: intent filter added'
      : '• AndroidManifest.xml: already patched');
  if (activityPath == null) {
    stdout.writeln('! MainActivity not found — links will not reach Dart. '
        'Search android/app/src/main for MainActivity.kt and re-run.');
  } else {
    stdout.writeln(activityChanged
        ? '✓ ${activityPath.path}: link forwarding added'
        : '• ${activityPath.path}: already patched');
  }
  stdout.writeln('');
  stdout.writeln('Release signing: '
      '${args.contains('--signing') ? _describeSigning(root) : 'not checked (pass --signing)'}');
  stdout.writeln('Next:');
  stdout.writeln('  1. Supabase dashboard → Authentication → URL Configuration');
  stdout.writeln('     Site URL:       https://${host ?? 'your-site.example'}');
  stdout.writeln('     Redirect URLs:  mailchat://auth/callback');
  if (host != null) {
    stdout.writeln('                     https://$host/auth/callback');
  }
  stdout.writeln('  2. AUTH_REDIRECT_URL=mailchat://auth/callback in assets/config/env');
  stdout.writeln('  3. flutter run   (a full rebuild — the manifest is native state)');
}

bool _patchManifest(File manifest, {String? host}) {
  final original = manifest.readAsStringSync();
  var content = original;

  // 1. INTERNET permission. `flutter create` only writes it into the debug and
  // profile manifests, so a release build silently has no networking.
  if (!content.contains('android.permission.INTERNET')) {
    final closing = content.indexOf('>', content.indexOf('<manifest'));
    content = '${content.substring(0, closing + 1)}\n'
        '    <!-- mailchat:internet: required by the Supabase HTTP client; the\n'
        '         generated debug manifest provides it, release builds do not. -->\n'
        '    <uses-permission android:name="android.permission.INTERNET"/>\n'
        '${content.substring(closing + 1)}';
  }

  // 2. Intent filters, inside <activity ...>.
  if (!content.contains(_manifestMarker)) {
    final hostData = (host == null || host.isEmpty)
        ? ''
        : '''
            <!-- https app link: preferred, because it survives being opened in
                 any browser or mail client. Requires the domain to be verified
                 (assetlinks.json) and matches AUTH_REDIRECT_URL. -->
            <data android:scheme="https" android:host="$host" android:pathPrefix="/auth/callback" />''';
    final filter = '''
            <!-- $_manifestMarker: Supabase redirects here after verifying an
                 emailed token. See lib/core/deeplink/auth_deep_link.dart. -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="mailchat" android:host="auth" />$hostData
            </intent-filter>
        ''';
    final activityEnd = content.lastIndexOf('</activity>');
    if (activityEnd == -1) {
      _fail('Found AndroidManifest.xml but no <activity> element to attach '
          'the intent filter to.');
    }
    content = '${content.substring(0, activityEnd)}$filter'
        '${content.substring(activityEnd)}';
  }

  if (content == original) return false;
  manifest.writeAsStringSync(content);
  return true;
}

bool _patchMainActivity(File activity) {
  final original = activity.readAsStringSync();
  if (original.contains(_mainActivityMarker)) return false;

  // Preserve whatever package the project was generated with: `flutter create`
  // derives it from --org and the project name, so it differs between machines.
  final packageMatch =
      RegExp(r'^package\s+([A-Za-z0-9_.]+)', multiLine: true).firstMatch(original);
  final packageName = packageMatch?.group(1) ?? 'com.mailchat.mailchat';

  final activityName = activity.uri.pathSegments.last.replaceAll('.kt', '');
  final source = _mainActivitySource(packageName, activityName);
  activity.writeAsStringSync(source);

  // A leftover Java activity would shadow the Kotlin one.
  final java = File(activity.path.replaceAll(RegExp(r'\.kt$'), '.java'));
  if (java.existsSync()) {
    stdout.writeln('! Found ${java.path}; delete it, or the Kotlin activity '
        'will not be the one registered in the manifest.');
  }
  return true;
}

String _mainActivitySource(String packageName, String className) => '''
package $packageName

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Forwards Supabase auth redirect links to Dart.
 *
 * Generated by tool/enable_deep_links.dart — re-run that script instead of
 * editing this file, or the changes are lost on the next `flutter create`.
 *
 * The Dart side is lib/core/deeplink/app_links.dart; the channel is
 * `$_mainActivityMarker`. A link arrives either as the intent that started the
 * app (cold start) or through onNewIntent (app already running).
 */
class $className : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "$_mainActivityMarker").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        // `intent` is the launch intent, valid by the time the
                        // engine is configured; pendingLink covers a link that
                        // arrived before the channel existed.
                        result.success(pendingLink ?: linkFrom(intent))
                        pendingLink = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkFrom(intent)
        if (link == null) return
        val ch = channel
        if (ch == null) {
            pendingLink = link
        } else {
            ch.invokeMethod("incomingLink", link)
        }
    }

    /** dataString keeps the fragment, which is where the tokens are. */
    private fun linkFrom(intent: Intent?): String? {
        val data = intent?.dataString
        return if (data.isNullOrEmpty()) null else data
    }
}
''';

/// Reports whether a signed release build is possible, and prints the exact
/// Gradle snippet when it is not.
///
/// Deliberately read-only. Rewriting a Gradle file that cannot be compiled in
/// this environment would risk breaking a working project for the sake of a
/// configuration step that takes a minute to do by hand.
///
/// Why it matters: a release APK built without a signing config is
/// **unsigned**, and Android refuses to install it ("There was a problem
/// parsing the package"). Debug APKs are signed with the debug key, which is
/// why sideloading debug works and `--release` does not.
String _describeSigning(Directory root) {
  final gradle = _findAppGradle(root);
  final keystoreProps = File('${root.path}/android/key.properties');
  // "Configured" means a storeFile value is actually filled in, not just the
  // `storeFile=` label an empty template leaves behind.
  var hasProps = false;
  if (keystoreProps.existsSync()) {
    for (final line in keystoreProps.readAsStringSync().split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('storeFile=')) continue;
      if (trimmed.substring('storeFile='.length).trim().isNotEmpty) {
        hasProps = true;
      }
    }
  }

  final gradleText = gradle?.readAsStringSync() ?? '';
  final wired = gradleText.contains('mailchat:signing') ||
      gradleText.contains('signingConfig signingConfigs.release') ||
      gradleText.contains('signingConfig = signingConfigs.getByName("release")');

  if (hasProps && wired) return 'ready';

  if (gradle == null) {
    return 'cannot tell (no android/app/build.gradle — run flutter create first)';
  }

  stdout.writeln('''
! Release signing is NOT configured, so `--release` produces an APK Android
  will refuse to install. Debug builds are unaffected. To enable it:

  1. Create a keystore, once (back it up — losing it means no future updates):
       keytool -genkey -v -keystore "%USERPROFILE%\\mailchat-upload.jks" \\
         -keyalg RSA -keysize 2048 -validity 10000 -alias upload

  2. Create android/key.properties (gitignored):
       storeFile=C:/Users/YOU/mailchat-upload.jks
       storePassword=YOUR_STORE_PASSWORD
       keyAlias=upload
       keyPassword=YOUR_KEY_PASSWORD

  3. Add this to android/app/build.gradle. MailChat does not edit your Gradle
     file for you, because an unverifiable rewrite of a build script is worse
     than a one-minute manual step.

     Before the `android {` block:

       // mailchat:signing
       def keystoreProperties = new Properties()
       def keystoreFile = rootProject.file('key.properties')
       if (keystoreFile.exists()) {
           keystoreFile.withInputStream { keystoreProperties.load(it) }
       }

     Inside `android {`:

       signingConfigs {
           release {
               if (keystoreFile.exists()) {
                   storeFile file(keystoreProperties['storeFile'])
                   storePassword keystoreProperties['storePassword']
                   keyAlias keystoreProperties['keyAlias']
                   keyPassword keystoreProperties['keyPassword']
               }
           }
       }

     In buildTypes -> release:

       signingConfig signingConfigs.release

  Then: ./tool/build_apk.ps1 -Mode release
''');
  return 'not configured (instructions above)';
}

File? _findAppGradle(Directory root) {
  for (final name in ['build.gradle.kts', 'build.gradle']) {
    final file = File('${root.path}/android/app/$name');
    if (file.existsSync()) return file;
  }
  return null;
}

File? _findMainActivity(Directory root) {
  for (final base in ['kotlin', 'java']) {
    final dir = Directory('${root.path}/android/app/src/main/$base');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('MainActivity.kt')) {
        return entity;
      }
    }
  }
  return null;
}

Directory _projectRoot() {
  var dir = Directory.current;
  // Allow running from a subdirectory.
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

String? _argValue(List<String> args, String name) {
  for (final arg in args) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
