#!/usr/bin/env bash
#
# Install Xray binary for free-config probe on VPS/Termux.
# Tries pronet24 mirror first, then GitHub with resume/retry.
#
set -u

STATE_DIR="${XUI_STATE_DIR:-/etc/xui-outbound}"
XRAY_DIR="${XRAY_DIR:-$STATE_DIR/xray}"
RELEASE="${XRAY_RELEASE:-v26.6.27}"
TARGET="$XRAY_DIR/xray"
MIRROR_KEY="${XUI_MIRROR_KEY:-xui-pronet-diag-2026}"
MIRROR_BASE="${XUI_MIRROR_BASE:-https://pronet24.ir/wp-content/plugins/xui-vpn-manager}"

ARCH="$(uname -m 2>/dev/null || echo amd64)"
case "$ARCH" in
    x86_64|amd64) ZIP_NAME="Xray-linux-64.zip" ;;
    aarch64|arm64) ZIP_NAME="Xray-linux-arm64-v8a.zip" ;;
    *) ZIP_NAME="Xray-linux-64.zip" ;;
esac

mkdir -p "$XRAY_DIR"

if [ -x "$TARGET" ] && [ "$(stat -c%s "$TARGET" 2>/dev/null || stat -f%z "$TARGET" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    echo "==> Xray already installed: $TARGET"
    "$TARGET" version 2>/dev/null | head -n1 || true
    echo "XRAY_BIN=$TARGET"
    exit 0
fi

curl_download() {
    local url="$1"
    local out="$2"
    local max_time="${3:-600}"
    curl -fSL --connect-timeout 25 --max-time "$max_time" \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -C - "$url" -o "$out"
}

try_direct_binary() {
    local url="$1"
    local label="$2"
    echo "==> Trying direct binary ($label)…"
    if curl_download "$url" "$TARGET" 900; then
        chmod +x "$TARGET"
        if [ -x "$TARGET" ] && [ "$(stat -c%s "$TARGET" 2>/dev/null || echo 0)" -gt 1000000 ]; then
            if "$TARGET" version >/dev/null 2>&1; then
                echo "==> Xray installed from $label"
                ln -sf "$TARGET" /usr/local/bin/xray 2>/dev/null || true
                [ -d "$STATE_DIR" ] && echo "$TARGET" >"$STATE_DIR/xray-path.txt"
                "$TARGET" version 2>/dev/null | head -n1 || true
                echo "XRAY_BIN=$TARGET"
                return 0
            fi
        fi
        rm -f "$TARGET"
    fi
    return 1
}

try_zip_url() {
    local url="$1"
    local label="$2"
    local tmp
    tmp="$(mktemp -d)"
    echo "==> Trying zip ($label)…"
    if curl_download "$url" "$tmp/xray.zip" 900; then
        if command -v unzip >/dev/null 2>&1; then
            unzip -qo "$tmp/xray.zip" -d "$tmp" 2>/dev/null || true
            local found=""
            if [ -f "$tmp/xray" ]; then
                found="$tmp/xray"
            elif [ -f "$tmp/Xray-linux-64/xray" ]; then
                found="$tmp/Xray-linux-64/xray"
            else
                found="$(find "$tmp" -name xray -type f 2>/dev/null | head -n1)"
            fi
            if [ -n "$found" ] && [ -f "$found" ]; then
                cp -f "$found" "$TARGET"
                chmod +x "$TARGET"
                if "$TARGET" version >/dev/null 2>&1; then
                    echo "==> Xray installed from $label"
                    ln -sf "$TARGET" /usr/local/bin/xray 2>/dev/null || true
                    [ -d "$STATE_DIR" ] && echo "$TARGET" >"$STATE_DIR/xray-path.txt"
                    "$TARGET" version 2>/dev/null | head -n1 || true
                    echo "XRAY_BIN=$TARGET"
                    rm -rf "$tmp"
                    return 0
                fi
            fi
        fi
    fi
    rm -rf "$tmp"
    return 1
}

# 1) Host mirror (fast for pronet VPS)
if [ -n "${XRAY_URL:-}" ]; then
    try_direct_binary "$XRAY_URL" "XRAY_URL" && exit 0
fi

try_direct_binary \
    "${MIRROR_BASE}/bin/xray/xray" \
    "pronet24 direct" && exit 0

try_direct_binary \
    "${MIRROR_BASE}/bin/xray/xui-xray-download.php?key=${MIRROR_KEY}" \
    "pronet24 mirror" && exit 0

# 2) GitHub + common mirrors
GH="https://github.com/XTLS/Xray-core/releases/download/${RELEASE}/${ZIP_NAME}"
for url in \
    "$GH" \
    "https://ghfast.top/${GH}" \
    "https://mirror.ghproxy.com/${GH}"; do
    try_zip_url "$url" "$url" && exit 0
done

echo "[ERROR] All Xray download sources failed." >&2
echo "        Manual: curl -fsSL \"${MIRROR_BASE}/bin/xray/xui-xray-download.php?key=${MIRROR_KEY}\" -o $TARGET && chmod +x $TARGET" >&2
exit 1
