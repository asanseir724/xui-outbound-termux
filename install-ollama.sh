#!/usr/bin/env bash
#
# Install / start Ollama on the VPS for XUI Telegram AI relay.
#
# Falls back to GitHub release tarball when ollama.com returns 403
# (common on some VPS / regions).
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-ollama.sh | bash
#   MODEL=qwen2.5:1.5b bash install-ollama.sh
#
set -euo pipefail

MODEL="${MODEL:-qwen2.5:3b}"
INSTALL_DIR="${INSTALL_DIR:-/opt/xui-outbound}"
STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"
OLLAMA_VERSION="${OLLAMA_VERSION:-}" # e.g. v0.9.6 — empty = latest GitHub release
BIN_PATH="/usr/local/bin/ollama"
LIB_DIR="/usr/local/lib/ollama"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] Please run as root." >&2
    exit 1
fi

arch="$(uname -m)"
case "$arch" in
    x86_64|amd64) OLLAMA_ARCH="amd64" ;;
    aarch64|arm64) OLLAMA_ARCH="arm64" ;;
    *)
        echo "[ERROR] Unsupported arch: $arch" >&2
        exit 1
        ;;
esac

ensure_zstd() {
    if command -v zstd >/dev/null 2>&1 || tar --help 2>&1 | grep -q zstd; then
        return 0
    fi
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq zstd 2>/dev/null || true
}

extract_bundle() {
    # $1 = archive path (.tgz | .tar.zst | .tar.gz)
    local archive="$1"
    local dest="${2:-/usr/local}"
    mkdir -p "$dest"
    case "$archive" in
        *.tar.zst|*.zst)
            ensure_zstd
            if tar --help 2>&1 | grep -q -- '--zstd'; then
                tar --zstd -xf "$archive" -C "$dest"
            else
                zstd -d -c "$archive" | tar -xf - -C "$dest"
            fi
            ;;
        *.tgz|*.tar.gz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *)
            tar -xf "$archive" -C "$dest"
            ;;
    esac
}

install_from_github() {
    echo "==> Official installer blocked/unavailable — installing from GitHub releases…"
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq curl ca-certificates tar 2>/dev/null || true
    ensure_zstd

    local ver="${OLLAMA_VERSION}"
    if [ -z "$ver" ]; then
        ver="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest \
            | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4 || true)"
    fi
    if [ -z "$ver" ]; then
        ver="v0.9.6"
        echo "[WARN] Could not resolve latest tag; using $ver"
    fi
    echo "    version: $ver  arch: $OLLAMA_ARCH"

    local tmp
    tmp="$(mktemp -d)"
    # Prefer .tgz then .tar.zst (asset names vary by release)
    local url ok=0 name
    for name in \
        "ollama-linux-${OLLAMA_ARCH}.tgz" \
        "ollama-linux-${OLLAMA_ARCH}.tar.zst" \
        "ollama-linux-${OLLAMA_ARCH}.tar.gz"
    do
        url="https://github.com/ollama/ollama/releases/download/${ver}/${name}"
        echo "    try: $url"
        if curl -fL --retry 3 --retry-delay 2 -o "$tmp/$name" "$url"; then
            echo "==> Extracting $name → /usr/local …"
            rm -rf "$LIB_DIR"
            extract_bundle "$tmp/$name" /usr/local
            ok=1
            break
        fi
    done
    rm -rf "$tmp"

    if [ "$ok" -ne 1 ]; then
        echo "[ERROR] Failed to download Ollama from GitHub." >&2
        exit 1
    fi

    # Normalize binary location
    if [ -x /usr/local/bin/ollama ]; then
        :
    elif [ -x /usr/local/ollama ]; then
        ln -sfn /usr/local/ollama /usr/local/bin/ollama
    elif [ -x /usr/bin/ollama ]; then
        ln -sfn /usr/bin/ollama /usr/local/bin/ollama
    else
        found="$(find /usr/local -type f -name ollama 2>/dev/null | head -n1 || true)"
        if [ -n "$found" ] && [ -x "$found" ]; then
            ln -sfn "$found" /usr/local/bin/ollama
        else
            echo "[ERROR] ollama binary not found after extract." >&2
            exit 1
        fi
    fi

    hash -r 2>/dev/null || true
    command -v ollama >/dev/null 2>&1 || export PATH="/usr/local/bin:$PATH"
}

install_systemd_unit() {
    local unit=/etc/systemd/system/ollama.service
    local bin
    bin="$(command -v ollama || true)"
    [ -n "$bin" ] || bin="$BIN_PATH"
    if [ ! -x "$bin" ]; then
        echo "[ERROR] ollama binary missing at $bin" >&2
        exit 1
    fi

    id -u ollama >/dev/null 2>&1 || useradd -r -s /bin/false -m -d /usr/share/ollama ollama 2>/dev/null || true
    mkdir -p /usr/share/ollama
    chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true

    cat >"$unit" <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${bin} serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_HOST=127.0.0.1:11434"

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ollama
}

echo "==> Installing Ollama (if missing)…"
if command -v ollama >/dev/null 2>&1; then
    echo "    already installed: $(command -v ollama) ($(ollama --version 2>/dev/null || echo '?'))"
else
    if curl -fsSL --max-time 25 https://ollama.com/install.sh -o /tmp/ollama-install.sh 2>/dev/null; then
        echo "==> Running official install.sh…"
        sh /tmp/ollama-install.sh || install_from_github
        rm -f /tmp/ollama-install.sh
    else
        echo "==> ollama.com/install.sh unavailable (403/blocked) — GitHub fallback"
        install_from_github
    fi
fi

if ! command -v ollama >/dev/null 2>&1; then
    export PATH="/usr/local/bin:$PATH"
fi
if ! command -v ollama >/dev/null 2>&1; then
    echo "[ERROR] ollama still not in PATH after install." >&2
    exit 1
fi

echo "==> Enabling ollama service…"
if ! systemctl cat ollama >/dev/null 2>&1; then
    install_systemd_unit
else
    # Ensure bind localhost for relay-only use
    systemctl daemon-reload
fi
systemctl enable ollama 2>/dev/null || true
systemctl restart ollama
sleep 3
if ! systemctl is-active --quiet ollama; then
    echo "[WARN] systemd ollama not active — trying foreground check…"
    systemctl status ollama --no-pager -l || true
    # last resort: start serve briefly to verify binary
    if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "[ERROR] Ollama service failed to start. Check: journalctl -u ollama -n 50" >&2
        exit 1
    fi
fi

echo "==> Pulling model: $MODEL (may take several minutes)…"
ollama pull "$MODEL"

# Wire config for AI relay
CFG="$STATE_DIR/config.sh"
if [ -f "$CFG" ]; then
    if ! grep -q '^XUI_AI_ENDPOINT=' "$CFG" 2>/dev/null; then
        printf '\n# Local Ollama for Telegram AI relay\nXUI_AI_ENDPOINT="http://127.0.0.1:11434"\nXUI_AI_MODEL="%s"\n' "$MODEL" >> "$CFG"
    else
        sed -i "s|^XUI_AI_MODEL=.*|XUI_AI_MODEL=\"$MODEL\"|" "$CFG" 2>/dev/null || true
        if ! grep -q '^XUI_AI_ENDPOINT=' "$CFG" 2>/dev/null; then
            printf 'XUI_AI_ENDPOINT="http://127.0.0.1:11434"\n' >> "$CFG"
        fi
    fi
fi

echo "==> Smoke test /api/tags…"
curl -fsS --max-time 8 http://127.0.0.1:11434/api/tags | head -c 300 || true
echo
echo "==> Done. Restart relay…"
systemctl daemon-reload 2>/dev/null || true
systemctl restart xui-panel-relay 2>/dev/null || true
echo "Model: $MODEL"
echo "Endpoint: http://127.0.0.1:11434"
echo "Binary: $(command -v ollama)"
