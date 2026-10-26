# Building and releasing an APK

Two ways to get an installable APK. Both bake the Supabase URL and anon key into
the bundle (`docs/running.md` §1), so an APK is tied to one project.

---

## 1. Build with your own config (recommended)

```powershell
# Windows
.\tool\build_apk.ps1
```

```bash
# bash
./tool/build_apk.sh
```

What the script does, in order, so a build cannot silently produce an APK that
shows a configuration error screen:

1. Copies a root `.env` into `assets/config/env` if one exists.
2. Runs `dart run tool/check_config.dart`, which parses the file with **the same
   parser the app uses** and refuses to continue when the URL is a placeholder,
   is not a valid `https://` URL, points at `localhost`, when the key is missing
   or truncated, or when the key is the `service_role` key.
3. Runs `dart run tool/enable_deep_links.dart` so confirmation emails can open
   the app.
4. Runs `flutter build apk --debug --split-per-abi` and prints the APK paths.

Useful flags:

| Command | Result |
|---|---|
| `.\tool\build_apk.ps1` | debug, one APK per ABI — installable, debug-signed |
| `.\tool\build_apk.ps1 -FatApk` | one APK for every ABI (larger; use when splitting confuses you) |
| `.\tool\build_apk.ps1 -Abi arm64-v8a` | single ABI — smallest file |
| `.\tool\build_apk.ps1 -Mode release -SigningHelp` | what to do before a signed release |

Install the result:

```powershell
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk
```

**Debug APKs are signed with the debug key.** They install fine by sideload and
cannot be published to Play. They also cannot be upgraded into a release build
later without uninstalling first, because the signing key differs.

---

## 2. Build in CI, without a local toolchain

`.github/workflows/build-apk-with-env.yml` is manual — it never runs on push.

Actions tab → **Build APK with my config** → *Run workflow*, or:

```bash
gh workflow run build-apk-with-env.yml \
  -f supabase_url=https://YOUR-PROJECT.supabase.co \
  -f supabase_anon_key=YOUR-ANON-KEY
gh run watch
gh run download --name mailchat-apk-debug
```

Prefer repository secrets (`SUPABASE_URL`, `SUPABASE_ANON_KEY` under Settings →
Secrets → Actions) if you do not want the values in the run inputs; the workflow
falls back to them when the inputs are blank, and masks the key in the log.

On which key is safe: the **anon / publishable** key is embedded in every APK by
design, so it is not a secret in the "could read my data" sense — RLS is the
authorization boundary, and every table must keep it enabled. The **service_role**
key *is* a real secret; it bypasses RLS, and both the build script and the
workflow refuse it.

---

## 3. Signed release builds are not configured

There is no keystore in this repository, and there should not be. A release APK
built without one is unsigned, and Android refuses to install it. To set it up:

```powershell
keytool -genkey -v -keystore $env:USERPROFILE\mailchat-upload.jks `
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then create `android/key.properties` (gitignored):

```ini
storeFile=C:\\Users\\YOU\\mailchat-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

and add a `signingConfigs` block referencing those properties to
`android/app/build.gradle`. After that, `.\tool\build_apk.ps1 -Mode release`
produces an installable, signed APK.

Keep the keystore and its passwords backed up somewhere else: losing them means
existing installs can never be updated, only replaced by a new app id.

---

## Before calling any build "releasable"

Honest checklist — none of these are true yet:

- [ ] Migrations applied to a production project (`docs/running.md` §2)
- [ ] Custom SMTP configured, so emails reach addresses that are not team
      members (`docs/auth-links.md`)
- [ ] `INTERNET` permission in the main manifest — handled by
      `tool/enable_deep_links.dart`, but confirm for your own build
- [ ] Release signed with a keystore you control
- [ ] Session storage moved off `FileSessionStore` (`docs/security.md`)
- [ ] Token refresh implemented; today an expired access token signs the user out
- [ ] The manual checklist in `docs/testing.md` completed on a real device
