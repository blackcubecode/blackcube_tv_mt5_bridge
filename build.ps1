param(
    [string]$Version = "1.0"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridge = Join-Path $root "bridge"

Write-Host ""
Write-Host "=== BlackCube Bridge Build ===" -ForegroundColor Cyan
Write-Host "Root: $root"

$venv = Join-Path $bridge ".venv\Scripts\Activate.ps1"
if(-not (Test-Path $venv)) {
    Write-Host "Venv tidak ada. Membuat baru..." -ForegroundColor Yellow
    Push-Location $bridge
    python -m venv .venv
    Pop-Location
}
& $venv

Write-Host ""
Write-Host "=== Install dependencies ===" -ForegroundColor Cyan
Push-Location $bridge
pip install -r requirements.txt
pip install pyinstaller
Pop-Location

Write-Host ""
Write-Host "=== Build .exe ===" -ForegroundColor Cyan
Push-Location $bridge
if(Test-Path "build") { Remove-Item "build" -Recurse -Force }
if(Test-Path "dist") { Remove-Item "dist" -Recurse -Force }
pyinstaller bridge.spec --clean --noconfirm
Pop-Location

Write-Host ""
Write-Host "=== Buat paket distribusi ===" -ForegroundColor Cyan
$pkgName = "BlackCubeBridge-v$Version-Windows"
$pkgDir = Join-Path $root "release\$pkgName"
if(Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null

Copy-Item "$bridge\dist\BlackCubeBridge.exe" $pkgDir
Copy-Item "$root\README.md" $pkgDir
Copy-Item "$root\LICENSE" $pkgDir
Copy-Item "$root\qris-donasi.jpg" $pkgDir
Copy-Item "$root\.env.example" (Join-Path $pkgDir ".env.example")

New-Item -ItemType Directory -Path "$pkgDir\mt5" -Force | Out-Null
New-Item -ItemType Directory -Path "$pkgDir\tradingview" -Force | Out-Null
Copy-Item "$root\mt5\BlackCubeBridgeEA.mq5" "$pkgDir\mt5\"
Copy-Item "$root\tradingview\blackcube_breakout.pine" "$pkgDir\tradingview\"

$startBat = @"
@echo off
title BlackCube Bridge
echo.
echo ============================================================
echo   BlackCube TV - MT5 Bridge
echo ============================================================
echo.
echo  Pastikan file .env sudah dikonfigurasi.
echo  Jika belum, copy .env.example ke .env lalu edit.
echo.
pause
BlackCubeBridge.exe
pause
"@
$startBat | Out-File "$pkgDir\start.bat" -Encoding ASCII

$installMd = @"
# BlackCube Bridge - Cara Pakai

## 1. Extract
Extract folder ini ke C:\BlackCubeBridge atau di mana saja.

## 2. Konfigurasi
- Copy .env.example ke .env
- Buka .env di Notepad, isi:
  - BC_COMMON_FILES - folder Common Files MT5 (biasanya auto-detect)
  - BC_WEBHOOK_SECRET - biarkan kosong (auto-generate saat pertama run)
  - BC_ALLOWED_SYMBOLS=XAUUSD

## 3. Jalankan
Double-click start.bat

Akan muncul URL webhook, contoh:
  http://127.0.0.1:8000/tv/AbCdEf123...

CATAT URL INI - akan dipakai di TradingView.

## 4. Setup EA MT5
- Copy mt5\BlackCubeBridgeEA.mq5 ke MQL5\Experts\ di MT5
- Buka MetaEditor, compile
- Attach ke chart XAUUSD M5, enable Algo Trading

## 5. Setup TradingView
- Copy tradingview\blackcube_breakout.pine ke Pine Editor
- Add to chart XAUUSD M5
- Buat Alert -> "Any alert() function call"
- Webhook URL: paste URL dari langkah 3

## 6. Test
- Tunggu sinyal atau kirim manual via browser
- Cek MT5 Experts tab untuk log EA

## Troubleshooting
- Log: %APPDATA%\BlackCubeBridge\bridge.log
- Secret: %APPDATA%\BlackCubeBridge\secret.txt
- Health: buka http://127.0.0.1:8000/health di browser

Selamat trading!
"@
$installMd | Out-File "$pkgDir\INSTALL.md" -Encoding UTF8

Write-Host ""
Write-Host "=== Buat ZIP ===" -ForegroundColor Cyan
$zip = Join-Path $root "release\$pkgName.zip"
if(Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$pkgDir\*" -DestinationPath $zip -Force

Write-Host ""
Write-Host "=== SELESAI ===" -ForegroundColor Green
Write-Host "EXE    : $bridge\dist\BlackCubeBridge.exe" -ForegroundColor Yellow
Write-Host "Paket  : $zip" -ForegroundColor Yellow
Write-Host "Folder : $pkgDir" -ForegroundColor Yellow