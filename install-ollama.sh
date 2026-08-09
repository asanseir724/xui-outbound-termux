#!/usr/bin/env bash
#
# Install / start Ollama on the VPS for XUI Telegram AI relay.
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-ollama.sh | bash
#   MODEL=qwen2.5:1.5b bash install-ollama.sh
#
set -e

MODEL="${MODEL:-qwen2.5:3b}"
INSTALL_DIR="${INSTALL_DIR:-/opt/xui-outbound}"
STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] Please run as root." >&2
    exit 1
fi

echo "==> Installing Ollama (if missing)…"
if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
fi

echo "==> Enabling ollama service…"
systemctl enable ollama 2>/dev/null || true
systemctl restart ollama 2>/dev/null || true
sleep 2

echo "==> Pulling model: $MODEL (may take several minutes)…"
ollama pull "$MODEL"

# Wire config for AI relay
CFG="$STATE_DIR/config.sh"
if [ -f "$CFG" ]; then
    if ! grep -q '^XUI_AI_ENDPOINT=' "$CFG" 2>/dev/null; then
        printf '\n# Local Ollama for Telegram AI relay\nXUI_AI_ENDPOINT="http://127.0.0.1:11434"\nXUI_AI_MODEL="%s"\n' "$MODEL" >> "$CFG"
    else
        sed -i "s|^XUI_AI_MODEL=.*|XUI_AI_MODEL=\"$MODEL\"|" "$CFG" 2>/dev/null || true
    fi
fi

# Smoke test
echo "==> Smoke test /api/tags…"
curl -fsS --max-time 8 http://127.0.0.1:11434/api/tags | head -c 200 || true
echo
echo "==> Done. Restart relay: systemctl restart xui-panel-relay"
systemctl restart xui-panel-relay 2>/dev/null || true
echo "Model: $MODEL"
echo "Endpoint: http://127.0.0.1:11434"
