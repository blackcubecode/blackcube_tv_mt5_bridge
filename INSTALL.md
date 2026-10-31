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
