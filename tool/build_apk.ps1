# Builds an installable APK for MailChat, using your local .env / assets/config/env.
#
#   .\tool\build_apk.ps1                 # debug build, signed with the debug key
#   .\tool\build_apk.ps1 -Mode release   # needs a keystore (see -SigningHelp)
#   .\tool\build_apk.ps1 -FatApk         # one APK for every ABI, bigger
#
# Why this exists: the app reads its Supabase URL and anon key from the bundled
# `assets/config/env` asset (or --dart-define), so an APK built without those
# values is a configuration-error screen. This script refuses to build until it
# finds them, instead of producing an APK that cannot work.
param(
    [ValidateSet('debug', 'release', 'profile')]
    [string] $Mode = 'debug',

    # Install one APK on any device instead of per-ABI splits.
    [switch] $FatApk,

    # Build for a single ABI (smaller download, e.g. for a low-storage phone).
    [string] $Abi = '',

    # Skip the deep-link manifest patch (it is idempotent; this is only useful
    # when diagnosing the patch itself).
    [switch] $SkipDeepLinks,

    [switch] $SigningHelp
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $root

try {
    if ($SigningHelp) {
        Write-Host @'
Release signing is not configured in this repository (no keystore is
committed, and none should be). To build a signed release APK:

1. Create a keystore (once, keep it safe and backed up):

   keytool -genkey -v -keystore $env:USERPROFILE\mailchat-upload.jks `
     -keyalg RSA -keysize 2048 -validity 10000 -alias upload

2. Create android/key.properties (gitignored, never commit it):

   storeFile=C:\\Users\\YOU\\mailchat-upload.jks
   storePassword=...
   keyAlias=upload
   keyPassword=...

3. Add a signingConfigs block to android/app/build.gradle referencing those
   properties, then run: .\tool\build_apk.ps1 -Mode release

Without step 3 the release APK is unsigned and Android refuses to install it.
'@
        return
    }

    # --- 0. Dependencies --------------------------------------------------
    # The tool scripts import package:mailchat, which needs a resolved package
    # graph; `dart run` fails outright without one.
    if (-not (Test-Path (Join-Path $root '.dart_tool/package_config.json'))) {
        Write-Host 'Resolving dependencies (first run)' -ForegroundColor DarkGray
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }
    }

    # --- 1. Configuration -------------------------------------------------
    $envFile    = Join-Path $root 'assets/config/env'
    $rootDotEnv = Join-Path $root '.env'

    if (Test-Path $rootDotEnv) {
        Copy-Item $rootDotEnv $envFile -Force
        Write-Host 'Synced .env -> assets/config/env' -ForegroundColor DarkGray
    }

    if (-not (Test-Path $envFile)) {
        throw "No configuration found. Create assets/config/env from assets/config/env.example and fill in SUPABASE_URL and SUPABASE_ANON_KEY (docs/running.md section 1)."
    }

    # Validation lives in one place — tool/check_config.dart uses the same parser
    # the app does (lib/core/config/env_file.dart), so this cannot disagree with
    # what the APK will actually read at startup.
    dart run tool/check_config.dart
    if ($LASTEXITCODE -ne 0) { throw "Fix assets/config/env before building." }

    # --- 2. Platform folder -----------------------------------------------
    # compileSdk (flutter_webrtc needs 36), the deep-link intent filter and the
    # camera/mic permissions all live in the generated android/ folder. This
    # script is idempotent, and it fails with a readable message when the Flutter
    # SDK itself is too old for call media.
    if (-not $SkipDeepLinks) {
        dart run tool/fix_android_build.dart
        if ($LASTEXITCODE -ne 0) { throw "Preparing the Android project failed. See docs/running.md." }
    }

    # --- 3. Build ---------------------------------------------------------
    $apkArgs = @('build', 'apk', "--$Mode")
    if ($Abi) {
        # Flutter's --target-platform values differ from Android ABI names.
        $targetPlatform = switch ($Abi.ToLowerInvariant()) {
            'armeabi-v7a' { 'android-arm' }
            'arm64-v8a'   { 'android-arm64' }
            'x86_64'      { 'android-x64' }
            default { throw "Unsupported Android ABI '$Abi'. Use armeabi-v7a, arm64-v8a, or x86_64." }
        }
        $apkArgs += "--target-platform=$targetPlatform"
    } elseif (-not $FatApk) {
        # Per-ABI splits: the fat APK bundles an engine per architecture and is
        # routinely too large for INSTALL_FAILED_INSUFFICIENT_STORAGE.
        $apkArgs += '--split-per-abi'
    }

    Write-Host "Building: flutter $($apkArgs -join ' ')" -ForegroundColor Cyan
    & flutter @apkArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed (exit $LASTEXITCODE)." }

    # --- 4. Report --------------------------------------------------------
    $outDir = Join-Path $root "build/app/outputs/flutter-apk"
    $apks = Get-ChildItem $outDir -Filter '*.apk' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'unsigned' } |
        Sort-Object LastWriteTime -Descending

    if (-not $apks) {
        throw "Build reported success but no APK was found in $outDir."
    }

    Write-Host ''
    Write-Host 'APK(s):' -ForegroundColor Green
    foreach ($apk in $apks) {
        $mb = [math]::Round($apk.Length / 1MB, 1)
        Write-Host ("  {0}  ({1} MB)" -f $apk.FullName, $mb)
    }

    Write-Host ''
    Write-Host 'Install on a connected device:' -ForegroundColor Green
    Write-Host "  adb install -r `"$($apks[0].FullName)`""

    if ($Mode -eq 'release') {
        Write-Host ''
        Write-Host 'Release builds are unsigned unless android/key.properties is configured; Android will refuse to install an unsigned APK. Use -SigningHelp.' -ForegroundColor Yellow
    }
}
finally {
    Pop-Location
}
