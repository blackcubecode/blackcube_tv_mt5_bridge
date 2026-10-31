"""
BlackCube TradingView -> MT5 Bridge (Packaged Edition)
Auto-detect Common Files, auto-generate secret, production WSGI.
"""
import json
import logging
import os
import re
import sys
import time
import secrets
from pathlib import Path
from datetime import datetime, timezone
from flask import Flask, request, jsonify, abort


def get_app_data_dir():
    if sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming"))
    else:
        base = Path.home() / ".config"
    app_dir = base / "BlackCubeBridge"
    app_dir.mkdir(parents=True, exist_ok=True)
    return app_dir


APP_DATA = get_app_data_dir()
SECRET_FILE = APP_DATA / "secret.txt"
LOG_FILE = APP_DATA / "bridge.log"
ENV_FILE = APP_DATA / ".env"


def load_env():
    try:
        from dotenv import load_dotenv
        if Path(".env").exists():
            load_dotenv(".env")
        if ENV_FILE.exists():
            load_dotenv(ENV_FILE, override=True)
    except ImportError:
        pass


load_env()


def auto_detect_common_files():
    candidates = []
    if sys.platform == "win32":
        appdata = Path(os.environ.get("APPDATA", ""))
        candidates.append(appdata / "MetaQuotes" / "Terminal" / "Common" / "Files")
    for c in candidates:
        c = c.resolve()
        if c.exists():
            return c
    return candidates[0] if candidates else Path("C:/Users/YOUR_USER/AppData/Roaming/MetaQuotes/Terminal/Common/Files")


def get_or_create_secret():
    env_secret = os.environ.get("BC_WEBHOOK_SECRET", "").strip()
    if env_secret and env_secret != "replace-with-url-safe-64-char-secret":
        return env_secret
    if SECRET_FILE.exists():
        s = SECRET_FILE.read_text().strip()
        if s:
            return s
    s = secrets.token_urlsafe(48)
    SECRET_FILE.write_text(s)
    return s


SECRET = get_or_create_secret()
COMMON_FILES = Path(os.environ.get("BC_COMMON_FILES") or auto_detect_common_files())
QUEUE_DIR = COMMON_FILES / "BlackCube" / "inbox"
MAX_AGE_SECONDS = int(os.getenv("BC_MAX_AGE_SECONDS", "180"))
MAX_FUTURE_SECONDS = int(os.getenv("BC_MAX_FUTURE_SECONDS", "30"))
ALLOWED_SYMBOLS = set(s.strip() for s in os.getenv("BC_ALLOWED_SYMBOLS", "XAUUSD").split(",") if s.strip())
MAX_SL_DISTANCE = float(os.getenv("BC_MAX_SL_DISTANCE", "100.0"))
MAX_TP_DISTANCE = float(os.getenv("BC_MAX_TP_DISTANCE", "200.0"))
HOST = os.getenv("BC_HOST", "127.0.0.1")
PORT = int(os.getenv("BC_PORT", "8000"))

logging.basicConfig(
    level=os.getenv("BC_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ]
)

app = Flask(__name__)


def safe_id(value):
    return bool(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(value or "")))


@app.get("/health")
def health():
    return jsonify({
        "ok": True,
        "service": "blackcube-bridge",
        "version": "1.1",
        "utc": datetime.now(timezone.utc).isoformat(),
        "common_files": str(COMMON_FILES),
        "queue": str(QUEUE_DIR),
        "queue_exists": QUEUE_DIR.exists(),
        "allowed_symbols": sorted(ALLOWED_SYMBOLS),
    })


@app.get("/")
def index():
    return jsonify({
        "service": "BlackCube Bridge",
        "endpoints": ["/health", "/tv/<secret>"],
        "secret_set": bool(SECRET),
    })


@app.post("/tv/<path_secret>")
def tradingview_webhook(path_secret):
    if not SECRET or path_secret != SECRET:
        abort(403)

    if not request.is_json:
        return jsonify({"ok": False, "error": "Content-Type must be application/json"}), 400
    try:
        data = request.get_json(force=False, silent=False)
    except Exception:
        return jsonify({"ok": False, "error": "invalid JSON"}), 400

    if not isinstance(data, dict):
        return jsonify({"ok": False, "error": "JSON object required"}), 400

    required = {"id", "action", "symbol", "time", "sl", "tp"}
    missing = required - set(data)
    if missing:
        return jsonify({"ok": False, "error": "missing fields", "fields": sorted(missing)}), 400

    signal_id = str(data["id"])
    action = str(data["action"]).lower()
    symbol = str(data["symbol"]).upper()
    if not safe_id(signal_id):
        return jsonify({"ok": False, "error": "invalid id"}), 400
    if action not in {"buy", "sell"}:
        return jsonify({"ok": False, "error": "action must be buy or sell"}), 400
    if symbol not in ALLOWED_SYMBOLS:
        return jsonify({"ok": False, "error": "symbol not allowed"}), 400

    try:
        signal_ts = float(data["time"])
        sl = float(data["sl"])
        tp = float(data["tp"])
        signal_price = float(data.get("price", 0))
    except (TypeError, ValueError):
        return jsonify({"ok": False, "error": "time/sl/tp/price must be numeric"}), 400

    now = time.time()
    if signal_ts > now + MAX_FUTURE_SECONDS or now - signal_ts > MAX_AGE_SECONDS:
        return jsonify({"ok": False, "error": "stale or future signal"}), 400
    if not all(map(lambda x: x == x and abs(x) != float("inf"), [sl, tp, signal_price])):
        return jsonify({"ok": False, "error": "non-finite prices"}), 400
    if sl <= 0 or tp <= 0:
        return jsonify({"ok": False, "error": "SL and TP must be positive"}), 400
    if signal_price > 0:
        if abs(signal_price - sl) > MAX_SL_DISTANCE or abs(tp - signal_price) > MAX_TP_DISTANCE:
            return jsonify({"ok": False, "error": "SL/TP distance exceeds bridge limits"}), 400
        if action == "buy" and not (sl < signal_price < tp):
            return jsonify({"ok": False, "error": "BUY requires SL < price < TP"}), 400
        if action == "sell" and not (tp < signal_price < sl):
            return jsonify({"ok": False, "error": "SELL requires TP < price < SL"}), 400

    try:
        QUEUE_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "id": signal_id,
            "action": action,
            "symbol": symbol,
            "time": int(signal_ts),
            "sl": sl,
            "tp": tp,
            "price": signal_price,
            "source": "tradingview"
        }
        target = QUEUE_DIR / f"{signal_id}.json"
        temp = QUEUE_DIR / f".{signal_id}.tmp"
        if target.exists():
            return jsonify({"ok": True, "accepted": False, "duplicate": True}), 200
        temp.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        os.replace(temp, target)
    except Exception:
        logging.exception("Failed to enqueue signal")
        return jsonify({"ok": False, "error": "queue write failed"}), 500

    logging.info("queued id=%s action=%s symbol=%s", signal_id, action, symbol)
    return jsonify({"ok": True, "accepted": True, "id": signal_id}), 200


def print_banner():
    print()
    print("=" * 70)
    print("  BlackCube TV -> MT5 Bridge")
    print("=" * 70)
    print(f"  URL           : http://{HOST}:{PORT}")
    print(f"  Health check  : http://{HOST}:{PORT}/health")
    print(f"  Webhook URL   : http://{HOST}:{PORT}/tv/{SECRET}")
    print(f"  Common Files  : {COMMON_FILES}")
    print(f"  Queue Dir     : {QUEUE_DIR}")
    print(f"  Secret file   : {SECRET_FILE}")
    print(f"  Log file      : {LOG_FILE}")
    print()
    print("  PENTING: URL webhook di atas WAJIB dipakai di TradingView alert.")
    print("           Jangan share URL ini ke orang lain.")
    print("=" * 70)
    print()


# Import di level modul - supaya PyInstaller detect dengan benar
try:
    from waitress import serve as _waitress_serve
    _HAS_WAITRESS = True
except ImportError:
    _HAS_WAITRESS = False
    _waitress_serve = None


def main():
    print_banner()
    if _HAS_WAITRESS:
        logging.info("Starting with waitress (production WSGI)")
        _waitress_serve(app, host=HOST, port=PORT, _quiet=True)
    else:
        logging.warning("waitress not installed, using Flask dev server")
        app.run(host=HOST, port=PORT, debug=False)


if __name__ == "__main__":
    main()