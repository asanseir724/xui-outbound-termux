#!/usr/bin/env bash
#
# Pick & install the best Persian-capable Ollama model for XUI Telegram AI.
#
# Priority (by free RAM + free disk):
#   1) partai/dorna-llama3:8b-instruct-q4_0  — قوی‌ترین فارسی زیر ۱۰B (~5GB)
#   2) mshojaei77/gemma3persian               — فاین‌تیون فارسی ۴B (~4GB)
#   3) qwen2.5:3b                            — چندزبانه خوب (~2GB)
#   4) qwen2.5:1.5b                          — سبک (~1GB) — مناسب VPSهای ۲GB
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-persian-ai.sh | bash
#   FORCE_MODEL=qwen2.5:1.5b bash install-persian-ai.sh
#   WITH_SWAP=1 bash install-persian-ai.sh   # فقط اگر دیسک آزاد ≥ ۶GB
#
set -euo pipefail

STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"
FORCE_MODEL="${FORCE_MODEL:-}"
WITH_SWAP="${WITH_SWAP:-0}"
SWAP_GB="${SWAP_GB:-2}"   # پیش‌فرض ۲G (نه ۴G) تا دیسک ۱۵G پر نشود
OLLAMA_HOME="${OLLAMA_HOME:-/usr/share/ollama/.ollama}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] run as root" >&2
    exit 1
fi

disk_free_mb() {
    df -Pm / 2>/dev/null | awk 'NR==2 {print $4}'
}

cleanup_ollama_partials() {
    echo "==> Cleaning incomplete Ollama downloads…"
    find "$OLLAMA_HOME/models/blobs" -type f \( -name '*-partial*' -o -name '*.tmp' \) -delete 2>/dev/null || true
    # orphan huge partials sometimes lack the suffix on crash
    find "$OLLAMA_HOME/models/blobs" -type f -name 'sha256-*-partial*' -delete 2>/dev/null || true
}

remove_xui_swap_if_tight() {
    local free_mb want_mb
    free_mb="$(disk_free_mb)"
    want_mb=2500
    if [ "${free_mb:-0}" -lt "$want_mb" ] && [ -f /swap-xui-ai ]; then
        echo "==> Disk tight (${free_mb}MB free) — removing /swap-xui-ai to free space…"
        swapoff /swap-xui-ai 2>/dev/null || true
        rm -f /swap-xui-ai
        sed -i '\#/swap-xui-ai#d' /etc/fstab 2>/dev/null || true
    fi
}

ensure_swap() {
    local want_gb="${1:-2}"
    local swapfile="/swap-xui-ai"
    local free_mb need_mb
    free_mb="$(disk_free_mb)"
    need_mb=$((want_gb * 1024 + 2500))
    if [ "${free_mb:-0}" -lt "$need_mb" ]; then
        echo "[WARN] Not enough disk for ${want_gb}G swap (free=${free_mb}MB, need≥${need_mb}MB) — skip swap."
        return 1
    fi
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
    echo "==> Creating ${want_gb}G swap at $swapfile…"
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
    sysctl -w vm.swappiness=30 >/dev/null || true
    swapon --show || true
}

model_need_mb() {
    case "$1" in
        partai/dorna*|mshojaei77/gemma3persian) echo 5500 ;;
        qwen2.5:3b*) echo 2500 ;;
        qwen2.5:1.5b*|*) echo 1400 ;;
    esac
}

# --- recovery first ---
echo "==> Disk before cleanup: $(df -h / | awk 'NR==2{print $4}') free"
remove_xui_swap_if_tight
cleanup_ollama_partials
apt-get clean >/dev/null 2>&1 || true
journalctl --vacuum-size=80M >/dev/null 2>&1 || true
echo "==> Disk after cleanup: $(df -h / | awk 'NR==2{print $4}') free  ($(disk_free_mb)MB)"

if [ "$WITH_SWAP" = "1" ]; then
    ensure_swap "$SWAP_GB" || true
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
free_disk_mb="$(disk_free_mb)"
echo "==> RAM total=${total_mb}MB available=${avail_mb}MB | disk free=${free_disk_mb}MB"

pick_model() {
    if [ -n "$FORCE_MODEL" ]; then
        echo "$FORCE_MODEL"
        return
    fi
    local effective="$avail_mb"
    if swapon --show 2>/dev/null | grep -q .; then
        effective=$((avail_mb + SWAP_GB * 600))
    fi
    local cand=""
    if { [ "$effective" -ge 6500 ] || [ "$total_mb" -ge 7500 ]; } && [ "$free_disk_mb" -ge 5500 ]; then
        cand="partai/dorna-llama3:8b-instruct-q4_0"
    elif { [ "$effective" -ge 4500 ] || [ "$total_mb" -ge 5500 ]; } && [ "$free_disk_mb" -ge 4500 ]; then
        cand="mshojaei77/gemma3persian"
    elif { [ "$effective" -ge 2800 ] || [ "$total_mb" -ge 3500 ] || [ "$WITH_SWAP" = "1" ]; } && [ "$free_disk_mb" -ge 2500 ]; then
        cand="qwen2.5:3b"
    else
        cand="qwen2.5:1.5b"
    fi
    # hard disk gate
    local need
    need="$(model_need_mb "$cand")"
    if [ "$free_disk_mb" -lt "$need" ]; then
        echo "qwen2.5:1.5b"
        return
    fi
    echo "$cand"
}

MODEL="$(pick_model)"
echo "==> Selected model: $MODEL (needs ~$(model_need_mb "$MODEL")MB free disk)"

if [ "$free_disk_mb" -lt "$(model_need_mb "$MODEL")" ]; then
    echo "[ERROR] Not enough disk for $MODEL. Free space and retry." >&2
    df -h /
    exit 1
fi

pull_one() {
    local m="$1"
    cleanup_ollama_partials
    ollama pull "$m"
}

pull_ok=0
if pull_one "$MODEL"; then
    pull_ok=1
else
    echo "[WARN] pull failed for $MODEL — trying fallbacks…"
    cleanup_ollama_partials
    for fb in qwen2.5:1.5b qwen2.5:3b; do
        [ "$fb" = "$MODEL" ] && continue
        need="$(model_need_mb "$fb")"
        if [ "$(disk_free_mb)" -lt "$need" ]; then
            echo "==> Skip $fb (disk free=$(disk_free_mb)MB < ${need}MB)"
            continue
        fi
        echo "==> Fallback: $fb"
        if pull_one "$fb"; then
            MODEL="$fb"
            pull_ok=1
            break
        fi
        cleanup_ollama_partials
    done
fi

if [ "$pull_ok" -ne 1 ]; then
    echo "[ERROR] could not pull any model — disk/RAM too tight." >&2
    df -h /
    du -sh "$OLLAMA_HOME" /swap-xui-ai 2>/dev/null || true
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
    echo "[WARN] smoke reply empty — try: ollama run $MODEL"
fi

systemctl restart xui-panel-relay 2>/dev/null || true

echo
echo "=================================================="
echo "  ✓ مدل آماده: $MODEL"
echo "  در وردپرس همین نام را بگذار و تست اتصال بزن."
echo "=================================================="
df -h / | awk 'NR==1 || NR==2'
ollama list || true
