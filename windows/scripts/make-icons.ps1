# Builds every app icon from the artwork at the repo root (icon.png, square, full-bleed, >= 1024 px).
# Run on Windows from anywhere:  powershell -ExecutionPolicy Bypass -File windows/scripts/make-icons.ps1
# Writes (all committed, so a Mac never needs to run this):
#   ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png  1024 px, opaque RGB (iOS rounds the corners itself;
#                                                            App Store rejects icons with an alpha channel)
#   windows/src-tauri/icons/{32x32.png,128x128.png,icon.png,icon.ico}  rounded tile via `tauri icon`
#                                                            (Windows doesn't round icons; a full-bleed square
#                                                            reads as a hard black block in the taskbar)
#   windows/ui/app-icon.png                                  the same rounded tile for the toast and the window
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$src = [System.Drawing.Image]::FromFile((Join-Path $repo 'icon.png'))

function Scaled([int]$size, [System.Drawing.Imaging.PixelFormat]$format) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, $format
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'
    $g.DrawImage($src, 0, 0, $size, $size)
    $g.Dispose()
    return $bmp
}

# A rounded tile with anti-aliased edges and a small transparent margin, like other Windows app icons.
function Rounded([int]$size) {
    $margin = [Math]::Round($size * 0.04); $tile = $size - 2 * $margin; $r = $tile * 0.22
    $art = Scaled $tile ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $path.AddArc($margin, $margin, $d, $d, 180, 90)
    $path.AddArc($margin + $tile - $d, $margin, $d, $d, 270, 90)
    $path.AddArc($margin + $tile - $d, $margin + $tile - $d, $d, $d, 0, 90)
    $path.AddArc($margin, $margin + $tile - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.TextureBrush $art
    $brush.TranslateTransform($margin, $margin)
    $g.FillPath($brush, $path)
    $g.Dispose(); $brush.Dispose(); $art.Dispose()
    return $bmp
}

# iPhone
$set = Join-Path $repo 'ios\App\Assets.xcassets\AppIcon.appiconset'
New-Item -ItemType Directory -Force $set | Out-Null
$ios = Scaled 1024 ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$ios.Save((Join-Path $set 'AppIcon.png'), [System.Drawing.Imaging.ImageFormat]::Png); $ios.Dispose()
Set-Content -Encoding ascii (Join-Path $repo 'ios\App\Assets.xcassets\Contents.json') '{ "info" : { "author" : "xcode", "version" : 1 } }'
Set-Content -Encoding ascii (Join-Path $set 'Contents.json') @'
{
  "images" : [
    { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
'@

# Windows: rounded tile -> tauri icon -> the four files the bundle and the tray use
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("grasp-icons-" + [guid]::NewGuid())
New-Item -ItemType Directory $tmp | Out-Null
$round = Rounded 1024
$round.Save((Join-Path $tmp 'rounded.png'), [System.Drawing.Imaging.ImageFormat]::Png); $round.Dispose()
Push-Location (Join-Path $repo 'windows')
try { npx tauri icon (Join-Path $tmp 'rounded.png') -o (Join-Path $tmp 'out') | Out-Null } finally { Pop-Location }
$icons = Join-Path $repo 'windows\src-tauri\icons'
foreach ($f in '32x32.png', '128x128.png', 'icon.png', 'icon.ico') { Copy-Item (Join-Path $tmp "out\$f") (Join-Path $icons $f) -Force }

# Toast and window header (shown at 40 px; 160 px for high-DPI screens)
$ui = Rounded 160
$ui.Save((Join-Path $repo 'windows\ui\app-icon.png'), [System.Drawing.Imaging.ImageFormat]::Png); $ui.Dispose()

Remove-Item -Recurse -Force $tmp
$src.Dispose()
Write-Output "icons written from $repo\icon.png"
