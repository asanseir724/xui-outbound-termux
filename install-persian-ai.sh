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
#   WITH_SWAP=1 bash install-persian-ai.sh   # روی VPSهای ۲GB برای رسیدن به 3b
#
set -euo pipefail

STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"
FORCE_MODEL="${FORCE_MODEL:-}"
WITH_SWAP="${WITH_SWAP:-0}"   # WITH_SWAP=1 → فایل سواپ ۴G بساز تا qwen2.5:3b ممکن شود
SWAP_GB="${SWAP_GB:-4}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] run as root" >&2
    exit 1
fi

ensure_swap() {
    local want_gb="${1:-4}"
    local swapfile="/swap-xui-ai"
    if swapon --show 2>/dev/null | grep -q .; then
        echo "==> Swap already present:"
        swapon --show || true
        return 0
    fi
    if [ -f "$swapfile" ]; then
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
        swapon "$swapfile" || true
        return 0
    fi
    echo "==> Creating ${want_gb}G swap at $swapfile (slow disk, helps load 3b)…"
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${want_gb}G" "$swapfile" || dd if=/dev/zero of="$swapfile" bs=1M count=$((want_gb * 1024)) status=progress
    else
        dd if=/dev/zero of="$swapfile" bs=1M count=$((want_gb * 1024)) status=progress
    fi
    chmod 600 "$swapfile"
    mkswap "$swapfile"
    swapon "$swapfile"
    if ! grep -q "$swapfile" /etc/fstab 2>/dev/null; then
        echo "$swapfile none swap sw 0 0" >> /etc/fstab
    fi
    sysctl -w vm.swappiness=40 >/dev/null || true
    swapon --show || true
}

if [ "$WITH_SWAP" = "1" ]; then
    ensure_swap "$SWAP_GB"
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
    # With swap, treat effective capacity higher for qwen2.5:3b
    local effective="$avail_mb"
    if [ "$WITH_SWAP" = "1" ] || swapon --show 2>/dev/null | grep -q .; then
        effective=$((avail_mb + SWAP_GB * 700))
    fi
    # leave headroom for OS + xui-panel-relay
    if [ "$effective" -ge 6500 ] || [ "$total_mb" -ge 7500 ]; then
        echo "partai/dorna-llama3:8b-instruct-q4_0"
    elif [ "$effective" -ge 4500 ] || [ "$total_mb" -ge 5500 ]; then
        echo "mshojaei77/gemma3persian"
    elif [ "$effective" -ge 2800 ] || [ "$total_mb" -ge 3500 ] || [ "$WITH_SWAP" = "1" ]; then
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
