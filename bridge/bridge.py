import json
import logging
import os
import re
import time
from pathlib import Path
from datetime import datetime, timezone
from flask import Flask, request, jsonify, abort

# Demo-first webhook receiver. Put this behind HTTPS (e.g. Caddy/Nginx).
# Configure BC_WEBHOOK_SECRET and BC_COMMON_FILES to match your environment.
app = Flask(__name__)
logging.basicConfig(level=os.getenv("BC_LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(message)s")

SECRET = os.environ.get("BC_WEBHOOK_SECRET", "")
COMMON_FILES = Path(os.environ.get(
    "BC_COMMON_FILES",
    r"C:\Users\YOUR_WINDOWS_USER\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
))
QUEUE_DIR = COMMON_FILES / "BlackCube" / "inbox"
MAX_AGE_SECONDS = int(os.getenv("BC_MAX_AGE_SECONDS", "180"))
MAX_FUTURE_SECONDS = int(os.getenv("BC_MAX_FUTURE_SECONDS", "30"))
ALLOWED_SYMBOLS = set(s.strip() for s in os.getenv("BC_ALLOWED_SYMBOLS", "XAUUSD").split(",") if s.strip())
MAX_SL_DISTANCE = float(os.getenv("BC_MAX_SL_DISTANCE", "100.0"))  # price units; adjust for broker
MAX_TP_DISTANCE = float(os.getenv("BC_MAX_TP_DISTANCE", "200.0"))  # price units; adjust for broker

if not SECRET:
    logging.warning("BC_WEBHOOK_SECRET is not set; webhook endpoint will reject all requests.")

def safe_id(value):
    return bool(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(value or "")))

@app.get("/health")
def health():
    return jsonify({"ok": True, "service": "blackcube-bridge", "utc": datetime.now(timezone.utc).isoformat()})

@app.post("/tv/<path_secret>")
def tradingview_webhook(path_secret):
    # A high-entropy secret in the URL is the practical auth mechanism for TradingView webhooks.
    # Use HTTPS, do not publish the URL, and rotate the secret if exposed.
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
        # One command per file avoids overwriting a burst of alerts.
        # Write temp then rename so EA never sees a partially written command.
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

if __name__ == "__main__":
    # Local development only. Use a production WSGI server + HTTPS reverse proxy for public webhook.
    app.run(host="127.0.0.1", port=8000, debug=False)
