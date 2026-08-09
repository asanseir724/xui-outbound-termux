#!/usr/bin/env bash
#
# Pick & install the best Persian-capable Ollama model for XUI Telegram AI.
#
# If registry.ollama.ai times out (common), falls back to HuggingFace GGUF
# + `ollama create` for qwen2.5:1.5b / 3b.
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-persian-ai.sh | bash
#   FORCE_MODEL=qwen2.5:1.5b bash install-persian-ai.sh
#
set -euo pipefail

STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"
FORCE_MODEL="${FORCE_MODEL:-}"
WITH_SWAP="${WITH_SWAP:-0}"
SWAP_GB="${SWAP_GB:-2}"
OLLAMA_HOME="${OLLAMA_HOME:-/usr/share/ollama/.ollama}"
PULL_RETRIES="${PULL_RETRIES:-5}"

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
}

remove_xui_swap_if_tight() {
    local free_mb
    free_mb="$(disk_free_mb)"
    if [ "${free_mb:-0}" -lt 2500 ] && [ -f /swap-xui-ai ]; then
        echo "==> Disk tight (${free_mb}MB free) — removing /swap-xui-ai…"
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
        echo "[WARN] Not enough disk for ${want_gb}G swap — skip."
        return 1
    fi
    if swapon --show 2>/dev/null | grep -q .; then
        swapon --show || true
        return 0
    fi
    if [ -f "$swapfile" ]; then
        chmod 600 "$swapfile"; mkswap "$swapfile" >/dev/null; swapon "$swapfile" || true
        return 0
    fi
    echo "==> Creating ${want_gb}G swap…"
    fallocate -l "${want_gb}G" "$swapfile" 2>/dev/null || dd if=/dev/zero of="$swapfile" bs=1M count=$((want_gb * 1024)) status=progress
    chmod 600 "$swapfile"; mkswap "$swapfile"; swapon "$swapfile"
    grep -q "$swapfile" /etc/fstab 2>/dev/null || echo "$swapfile none swap sw 0 0" >> /etc/fstab
    sysctl -w vm.swappiness=30 >/dev/null || true
}

model_need_mb() {
    case "$1" in
        partai/dorna*|mshojaei77/gemma3persian) echo 5500 ;;
        qwen2.5:3b*) echo 2500 ;;
        qwen2.5:1.5b*|*) echo 1400 ;;
    esac
}

model_already_local() {
    local m="$1"
    ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$m" && return 0
    ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^${m}:" && return 0
    return 1
}

# Retry ollama pull (TLS to registry.ollama.ai often flakes)
pull_registry() {
    local m="$1" i=1
    while [ "$i" -le "$PULL_RETRIES" ]; do
        echo "==> ollama pull $m (try $i/$PULL_RETRIES)…"
        cleanup_ollama_partials
        if ollama pull "$m"; then
            return 0
        fi
        sleep $((i * 3))
        i=$((i + 1))
    done
    return 1
}

# HuggingFace GGUF → ollama create (bypass registry.ollama.ai)
install_from_hf_gguf() {
    local tag="$1"
    local url=""
    local gguf=""
    case "$tag" in
        qwen2.5:1.5b)
            # Q4_K_M ~1GB — fits 2GB VPS
            url="https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
            gguf="/opt/xui-outbound/models/qwen2.5-1.5b-instruct-q4_k_m.gguf"
            ;;
        qwen2.5:3b)
            url="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
            gguf="/opt/xui-outbound/models/qwen2.5-3b-instruct-q4_k_m.gguf"
            ;;
        *)
            return 1
            ;;
    esac

    mkdir -p /opt/xui-outbound/models
    if [ ! -f "$gguf" ] || [ "$(stat -c%s "$gguf" 2>/dev/null || echo 0)" -lt 100000000 ]; then
        echo "==> Downloading GGUF from HuggingFace…"
        echo "    $url"
        # mirrors / retries help when ollama registry is blocked
        if ! curl -fL --retry 5 --retry-delay 4 --connect-timeout 30 --max-time 0 \
            -o "$gguf.partial" "$url"; then
            # hf-mirror (often works when huggingface.co is slow)
            local mirror="https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
            if [ "$tag" = "qwen2.5:3b" ]; then
                mirror="https://hf-mirror.com/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
            fi
            echo "==> Retry via hf-mirror…"
            curl -fL --retry 5 --retry-delay 4 --connect-timeout 30 --max-time 0 \
                -o "$gguf.partial" "$mirror" || return 1
        fi
        mv -f "$gguf.partial" "$gguf"
    fi

    local modelfile="/tmp/xui-Modelfile.$$"
    cat >"$modelfile" <<EOF
FROM $gguf
PARAMETER temperature 0.7
PARAMETER num_ctx 2048
PARAMETER num_predict 160
SYSTEM تو یک کاربر عادی ایرانی در گروه تلگرام هستی؛ کوتاه و محاوره‌ای جواب بده.
EOF
    echo "==> ollama create $tag from local GGUF…"
    ollama create "$tag" -f "$modelfile"
    rm -f "$modelfile"
    return 0
}

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
    local cand="qwen2.5:1.5b"
    if { [ "$effective" -ge 6500 ] || [ "$total_mb" -ge 7500 ]; } && [ "$free_disk_mb" -ge 5500 ]; then
        cand="partai/dorna-llama3:8b-instruct-q4_0"
    elif { [ "$effective" -ge 4500 ] || [ "$total_mb" -ge 5500 ]; } && [ "$free_disk_mb" -ge 4500 ]; then
        cand="mshojaei77/gemma3persian"
    elif { [ "$effective" -ge 2800 ] || [ "$total_mb" -ge 3500 ]; } && [ "$free_disk_mb" -ge 2500 ]; then
        cand="qwen2.5:3b"
    fi
    local need
    need="$(model_need_mb "$cand")"
    if [ "$free_disk_mb" -lt "$need" ]; then
        echo "qwen2.5:1.5b"
        return
    fi
    echo "$cand"
}

MODEL="$(pick_model)"
echo "==> Selected model: $MODEL"

if model_already_local "$MODEL"; then
    echo "==> Model already present locally — skip download."
    pull_ok=1
else
    pull_ok=0
    if pull_registry "$MODEL"; then
        pull_ok=1
    else
        echo "[WARN] registry.ollama.ai failed — trying HuggingFace GGUF…"
        if install_from_hf_gguf "$MODEL"; then
            pull_ok=1
        elif [ "$MODEL" != "qwen2.5:1.5b" ] && install_from_hf_gguf "qwen2.5:1.5b"; then
            MODEL="qwen2.5:1.5b"
            pull_ok=1
        fi
    fi
fi

if [ "${pull_ok:-0}" -ne 1 ]; then
    echo "[ERROR] could not install model (registry TLS / network)." >&2
    echo "    Check: curl -I https://registry.ollama.ai" >&2
    echo "    Or:    curl -I https://huggingface.co" >&2
    df -h /
    exit 1
fi

CFG="$STATE_DIR/config.sh"
mkdir -p "$STATE_DIR"
if [ -f "$CFG" ]; then
    if grep -q '^XUI_AI_MODEL=' "$CFG" 2>/dev/null; then
        sed -i "s|^XUI_AI_MODEL=.*|XUI_AI_MODEL=\"$MODEL\"|" "$CFG"
    else
        printf '\nXUI_AI_MODEL="%s"\n' "$MODEL" >> "$CFG"
    fi
    grep -q '^XUI_AI_ENDPOINT=' "$CFG" 2>/dev/null || printf 'XUI_AI_ENDPOINT="http://127.0.0.1:11434"\n' >> "$CFG"
else
    printf 'XUI_AI_ENDPOINT="http://127.0.0.1:11434"\nXUI_AI_MODEL="%s"\n' "$MODEL" >"$CFG"
fi

echo "==> Persian smoke test…"
smoke="$(curl -fsS --max-time 120 http://127.0.0.1:11434/api/chat -d "$(jq -n \
    --arg m "$MODEL" \
    '{model:$m,stream:false,messages:[{role:"system",content:"فقط فارسی کوتاه جواب بده."},{role:"user",content:"با یک جمله خودت را معرفی کن."}],options:{num_predict:60,temperature:0.7}}')" 2>/dev/null || true)"
reply="$(printf '%s' "$smoke" | jq -r '.message.content // empty' 2>/dev/null || true)"
if [ -n "$reply" ]; then
    echo "    reply: $reply"
else
    echo "[WARN] smoke empty — first load can be slow: ollama run $MODEL"
fi

systemctl restart xui-panel-relay 2>/dev/null || true

echo
echo "=================================================="
echo "  ✓ مدل آماده: $MODEL"
echo "  در وردپرس همین نام را بگذار و تست اتصال بزن."
echo "=================================================="
df -h / | awk 'NR==1 || NR==2'
ollama list || true
