param(
  [string]$Flutter = 'C:\flutter\bin\flutter.bat',
  [string[]]$DartDefine = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$apkPath = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-debug.apk'
if (-not (Test-Path -LiteralPath $Flutter)) {
  throw "Flutter executable not found: $Flutter"
}

Add-Type -AssemblyName System.IO.Compression

function Test-IconFonts {
  if (-not (Test-Path -LiteralPath $apkPath)) { return $false }
  $archive = [System.IO.Compression.ZipFile]::OpenRead($apkPath)
  try {
    $entries = @{}
    foreach ($entry in $archive.Entries) {
      $entries[$entry.FullName] = $entry.Length
    }
    return (
      $entries['assets/flutter_assets/fonts/MaterialIcons-Regular.otf'] -gt 0 -and
      $entries['assets/flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf'] -gt 0 -and
      $entries['assets/flutter_assets/FontManifest.json'] -gt 0
    )
  } finally {
    $archive.Dispose()
  }
}

function Invoke-ApkBuild {
  $defineArgs = @($DartDefine | ForEach-Object { "--dart-define=$_" })
  & $Flutter build apk --debug @defineArgs
  if ($LASTEXITCODE -ne 0) { throw 'Flutter APK build failed.' }
}

Push-Location $projectRoot
try {
  Invoke-ApkBuild
  if (-not (Test-IconFonts)) {
    Write-Warning 'Icon fonts are missing from the APK; cleaning generated files and rebuilding.'
    & $Flutter clean
    if ($LASTEXITCODE -ne 0) { throw 'Flutter clean failed.' }
    Invoke-ApkBuild
  }
  if (-not (Test-IconFonts)) {
    throw 'APK is still missing Material or Cupertino icon fonts; do not install it.'
  }
  Write-Output "Verified icon fonts in $apkPath"
} finally {
  Pop-Location
}
