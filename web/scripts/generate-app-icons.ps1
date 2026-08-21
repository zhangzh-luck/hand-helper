param(
    [Parameter(Mandatory = $false)]
    [string]$SourcePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$webRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $webRoot
$canonicalSource = Join-Path $webRoot 'assets\hand-helper-app-icon.png'

if (-not $SourcePath) {
    $SourcePath = $canonicalSource
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Icon source file was not found: $SourcePath"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $canonicalSource) | Out-Null
if ((Resolve-Path -LiteralPath $SourcePath).Path -ne (Resolve-Path -LiteralPath $canonicalSource -ErrorAction SilentlyContinue).Path) {
    Copy-Item -LiteralPath $SourcePath -Destination $canonicalSource -Force
}

$source = [System.Drawing.Image]::FromFile($canonicalSource)

function Save-SquarePng {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Image]$Image,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int]$Size
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $canvas = New-Object System.Drawing.Bitmap($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($canvas)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.DrawImage($Image, 0, 0, $Size, $Size)
        $canvas.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $canvas.Dispose()
    }
}

try {
    $publicDir = Join-Path $webRoot 'public'
    Save-SquarePng $source (Join-Path $publicDir 'favicon-rounded.png') 512
    Save-SquarePng $source (Join-Path $publicDir 'apple-touch-icon.png') 180
    Save-SquarePng $source (Join-Path $publicDir 'pwa-192.png') 192
    Save-SquarePng $source (Join-Path $publicDir 'pwa-512.png') 512

    $androidRes = Join-Path $webRoot 'android\app\src\main\res'
    $androidDensities = @(
        @{ Name = 'mdpi'; Launcher = 48; Foreground = 108 },
        @{ Name = 'hdpi'; Launcher = 72; Foreground = 162 },
        @{ Name = 'xhdpi'; Launcher = 96; Foreground = 216 },
        @{ Name = 'xxhdpi'; Launcher = 144; Foreground = 324 },
        @{ Name = 'xxxhdpi'; Launcher = 192; Foreground = 432 }
    )
    foreach ($density in $androidDensities) {
        $directory = Join-Path $androidRes ("mipmap-{0}" -f $density.Name)
        Save-SquarePng $source (Join-Path $directory 'ic_launcher.png') $density.Launcher
        Save-SquarePng $source (Join-Path $directory 'ic_launcher_round.png') $density.Launcher
        Save-SquarePng $source (Join-Path $directory 'ic_launcher_foreground.png') $density.Foreground
    }

    $iosAppIcon = Join-Path $projectRoot 'ios\YNNuJwHelper\Assets.xcassets\AppIcon.appiconset'
    $iosIcons = @(
        @{ Name = 'Icon-App-20x20@2x.png'; Size = 40 },
        @{ Name = 'Icon-App-20x20@3x.png'; Size = 60 },
        @{ Name = 'Icon-App-29x29@2x.png'; Size = 58 },
        @{ Name = 'Icon-App-29x29@3x.png'; Size = 87 },
        @{ Name = 'Icon-App-40x40@2x.png'; Size = 80 },
        @{ Name = 'Icon-App-40x40@3x.png'; Size = 120 },
        @{ Name = 'Icon-App-60x60@2x.png'; Size = 120 },
        @{ Name = 'Icon-App-60x60@3x.png'; Size = 180 },
        @{ Name = 'Icon-App-20x20~ipad.png'; Size = 20 },
        @{ Name = 'Icon-App-20x20@2x~ipad.png'; Size = 40 },
        @{ Name = 'Icon-App-29x29~ipad.png'; Size = 29 },
        @{ Name = 'Icon-App-29x29@2x~ipad.png'; Size = 58 },
        @{ Name = 'Icon-App-40x40~ipad.png'; Size = 40 },
        @{ Name = 'Icon-App-40x40@2x~ipad.png'; Size = 80 },
        @{ Name = 'Icon-App-76x76~ipad.png'; Size = 76 },
        @{ Name = 'Icon-App-76x76@2x~ipad.png'; Size = 152 },
        @{ Name = 'Icon-App-83.5x83.5@2x~ipad.png'; Size = 167 },
        @{ Name = 'Icon-App-1024.png'; Size = 1024 }
    )
    foreach ($icon in $iosIcons) {
        Save-SquarePng $source (Join-Path $iosAppIcon $icon.Name) $icon.Size
    }
}
finally {
    $source.Dispose()
}

Write-Output 'Generated web/PWA, Android, and iOS app icon assets.'
