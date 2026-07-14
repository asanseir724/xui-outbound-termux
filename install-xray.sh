#!/usr/bin/env bash
#
# Install Xray binary for free-config probe on VPS/Termux.
#
set -e

STATE_DIR="${XUI_STATE_DIR:-/etc/xui-outbound}"
INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
XRAY_DIR="${XRAY_DIR:-$STATE_DIR/xray}"
RELEASE="${XRAY_RELEASE:-v26.6.27}"
ARCH="$(uname -m 2>/dev/null || echo amd64)"

case "$ARCH" in
    x86_64|amd64) ZIP_NAME="Xray-linux-64.zip" ;;
    aarch64|arm64) ZIP_NAME="Xray-linux-arm64-v8a.zip" ;;
    *)
        echo "[WARN] Unknown arch $ARCH — trying linux-64 zip"
        ZIP_NAME="Xray-linux-64.zip"
        ;;
esac

URL="https://github.com/XTLS/Xray-core/releases/download/${RELEASE}/${ZIP_NAME}"
TARGET="$XRAY_DIR/xray"

mkdir -p "$XRAY_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Downloading Xray $RELEASE ($ZIP_NAME)…"
if ! curl -fsSL --connect-timeout 20 --max-time 180 "$URL" -o "$tmp/xray.zip"; then
    echo "[ERROR] Xray download failed: $URL" >&2
    exit 1
fi

if command -v unzip >/dev/null 2>&1; then
    unzip -qo "$tmp/xray.zip" -d "$tmp"
else
    echo "[ERROR] unzip not found" >&2
    exit 1
fi

if [ -f "$tmp/xray" ]; then
    cp -f "$tmp/xray" "$TARGET"
elif [ -f "$tmp/Xray-linux-64/xray" ]; then
    cp -f "$tmp/Xray-linux-64/xray" "$TARGET"
else
    found="$(find "$tmp" -name xray -type f | head -n1)"
    if [ -z "$found" ]; then
        echo "[ERROR] xray binary not found in zip" >&2
        exit 1
    fi
    cp -f "$found" "$TARGET"
fi

chmod +x "$TARGET"
ln -sf "$TARGET" /usr/local/bin/xray 2>/dev/null || true

echo "==> Xray installed: $TARGET"
"$TARGET" version 2>/dev/null | head -n1 || true

# Persist for systemd units
if [ -d "$STATE_DIR" ]; then
    echo "$TARGET" >"$STATE_DIR/xray-path.txt"
fi

export XRAY_BIN="$TARGET"
echo "XRAY_BIN=$TARGET"
