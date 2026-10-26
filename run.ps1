# Runs MailChat on a device, with no --dart-define flags.
#
# Configuration is read from `assets/config/env` at runtime (see
# assets/config/README.md), so `flutter run` alone is enough. This script only
# saves the copy step: if you keep a root `.env` out of habit, it is synced into
# the bundled asset first.
#
#   .\run.ps1                    # first available device
#   .\run.ps1 -d SM_M146B        # anything after the script goes to flutter run
#   .\run.ps1 --release
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $RunArgs
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root '.env'
$target = Join-Path $root 'assets/config/env'

if (Test-Path $source) {
    Copy-Item $source $target -Force
    Write-Host 'Synced .env -> assets/config/env' -ForegroundColor DarkGray
}
elseif (-not (Test-Path $target)) {
    Write-Warning 'No configuration found. Copy assets/config/env.example to assets/config/env and fill it in.'
}

Push-Location $root
try {
    flutter run @RunArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
