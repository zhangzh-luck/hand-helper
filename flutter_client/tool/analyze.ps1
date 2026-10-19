param(
  [string]$Flutter = 'C:\flutter\bin\flutter.bat'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath $Flutter)) {
  throw "Flutter executable not found: $Flutter"
}

# This Flutter SDK counts UTF-16 characters, not UTF-8 bytes, in the LSP
# Content-Length header. An ASCII drive alias avoids truncating Chinese paths.
$driveLetter = @('X', 'Y', 'Z') |
  Where-Object { -not (Test-Path -LiteralPath "${_}:\") } |
  Select-Object -First 1
if (-not $driveLetter) {
  throw 'No unused X:, Y:, or Z: drive is available for Flutter analysis.'
}

subst "${driveLetter}:" $projectRoot
if ($LASTEXITCODE -ne 0) {
  throw "Could not create temporary ${driveLetter}: drive mapping."
}

try {
  Push-Location "${driveLetter}:\"
  try {
    & $Flutter analyze --no-pub --no-fatal-infos
    $analysisExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
} finally {
  subst "${driveLetter}:" /D
}

exit $analysisExitCode
