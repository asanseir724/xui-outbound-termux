#!/usr/bin/env bash
#
# Pick & install the best Persian-capable Ollama model for XUI Telegram AI.
#
# Priority (by free RAM):
#   1) partai/dorna-llama3:8b-instruct-q4_0  — قوی‌ترین فارسی زیر ۱۰B
#   2) mshojaei77/gemma3persian               — فاین‌تیون فارسی ۴B
#   3) qwen2.5:3b                            — چندزبانه خوب، سبک‌تر
#   4) qwen2.5:1.5b                          — فقط اگر RAM خیلی کم باشد
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-persian-ai.sh | bash
#   FORCE_MODEL=qwen2.5:3b bash install-persian-ai.sh
#
set -euo pipefail

STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"
FORCE_MODEL="${FORCE_MODEL:-}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] run as root" >&2
    exit 1
fi

if ! command -v ollama >/dev/null 2>&1; then
    echo "==> Ollama missing — installing first…"
    bash /opt/xui-outbound/install-ollama.sh || {
        curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-ollama.sh | bash
    }
fi

systemctl enable ollama 2>/dev/null || true
systemctl start ollama 2>/dev/null || true
sleep 2

avail_mb="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
total_mb="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
echo "==> RAM total=${total_mb}MB available=${avail_mb}MB"

pick_model() {
    if [ -n "$FORCE_MODEL" ]; then
        echo "$FORCE_MODEL"
        return
    fi
    # leave headroom for OS + xui-panel-relay
    if [ "$avail_mb" -ge 6500 ] || [ "$total_mb" -ge 7500 ]; then
        echo "partai/dorna-llama3:8b-instruct-q4_0"
    elif [ "$avail_mb" -ge 4500 ] || [ "$total_mb" -ge 5500 ]; then
        echo "mshojaei77/gemma3persian"
    elif [ "$avail_mb" -ge 2800 ] || [ "$total_mb" -ge 3500 ]; then
        echo "qwen2.5:3b"
    else
        echo "qwen2.5:1.5b"
    fi
}

MODEL="$(pick_model)"
echo "==> Selected model: $MODEL"

pull_ok=0
if ollama pull "$MODEL"; then
    pull_ok=1
else
    echo "[WARN] pull failed for $MODEL — trying fallbacks…"
    for fb in mshojaei77/gemma3persian qwen2.5:3b qwen2.5:1.5b; do
        [ "$fb" = "$MODEL" ] && continue
        echo "==> Fallback: $fb"
        if ollama pull "$fb"; then
            MODEL="$fb"
            pull_ok=1
            break
        fi
    done
fi

if [ "$pull_ok" -ne 1 ]; then
    echo "[ERROR] could not pull any model" >&2
    exit 1
fi

# Wire config for AI relay
CFG="$STATE_DIR/config.sh"
mkdir -p "$STATE_DIR"
if [ -f "$CFG" ]; then
    if grep -q '^XUI_AI_MODEL=' "$CFG" 2>/dev/null; then
        sed -i "s|^XUI_AI_MODEL=.*|XUI_AI_MODEL=\"$MODEL\"|" "$CFG"
    else
        printf '\nXUI_AI_MODEL="%s"\n' "$MODEL" >> "$CFG"
    fi
    if ! grep -q '^XUI_AI_ENDPOINT=' "$CFG" 2>/dev/null; then
        printf 'XUI_AI_ENDPOINT="http://127.0.0.1:11434"\n' >> "$CFG"
    fi
else
    printf 'XUI_AI_ENDPOINT="http://127.0.0.1:11434"\nXUI_AI_MODEL="%s"\n' "$MODEL" >"$CFG"
fi

echo "==> Persian smoke test…"
smoke="$(curl -fsS --max-time 90 http://127.0.0.1:11434/api/chat -d "$(jq -n \
    --arg m "$MODEL" \
    '{model:$m,stream:false,messages:[{role:"system",content:"فقط فارسی کوتاه جواب بده."},{role:"user",content:"با یک جمله خودت را معرفی کن."}],options:{num_predict:60,temperature:0.7}}')" 2>/dev/null || true)"
reply="$(printf '%s' "$smoke" | jq -r '.message.content // empty' 2>/dev/null || true)"
if [ -n "$reply" ]; then
    echo "    reply: $reply"
else
    echo "[WARN] smoke reply empty — model may still be loading; check: ollama run $MODEL"
fi

systemctl restart xui-panel-relay 2>/dev/null || true

echo
echo "=================================================="
echo "  ✓ مدل آماده: $MODEL"
echo "  در وردپرس (قلب تپنده) همین نام مدل را بگذار:"
echo "      $MODEL"
echo "  سپس «تست اتصال مدل» را بزن."
echo "=================================================="
ollama list || true
