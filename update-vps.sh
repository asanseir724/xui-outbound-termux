#!/usr/bin/env bash
#
# Update xui-outbound scripts on an existing VPS install (keeps config intact).
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/update-vps.sh | bash
#
set -e

ZIP_URL="${ZIP_URL:-https://codeload.github.com/asanseir724/xui-outbound-termux/zip/refs/heads/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/xui-outbound}"
STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "==> Re-running with sudo…"
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] Please run as root." >&2
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] $INSTALL_DIR not found. Run install-vps.sh first." >&2
    exit 1
fi

echo "==> Downloading latest xui-outbound…"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL --connect-timeout 15 --max-time 120 "$ZIP_URL" -o "$tmp/main.zip"; then
    echo "[ERROR] Download failed. Check network / firewall." >&2
    exit 1
fi
unzip -qo "$tmp/main.zip" -d "$tmp"
src="$(find "$tmp" -maxdepth 1 -type d -name 'xui-outbound-termux-*' | head -n1)"
if [ -z "$src" ]; then
    echo "[ERROR] Unexpected ZIP layout." >&2
    exit 1
fi

echo "==> Updating scripts in $INSTALL_DIR (config untouched)…"
for f in xui-sync.sh xui-services.sh install-vps.sh update-vps.sh config.example.sh; do
    if [ -f "$src/$f" ]; then
        cp -f "$src/$f" "$INSTALL_DIR/$f"
    fi
done
if [ -d "$src/panel" ]; then
    mkdir -p "$INSTALL_DIR/panel"
    cp -f "$src/panel/"* "$INSTALL_DIR/panel/" 2>/dev/null || true
fi
if [ -d "$src/termux-boot" ]; then
    mkdir -p "$INSTALL_DIR/termux-boot"
    cp -f "$src/termux-boot/"* "$INSTALL_DIR/termux-boot/" 2>/dev/null || true
fi

if command -v sed >/dev/null 2>&1; then
    find "$INSTALL_DIR" -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
fi
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# Keep config symlink intact.
if [ -f "$STATE_DIR/config.sh" ] && [ ! -L "$INSTALL_DIR/config.sh" ]; then
    ln -sf "$STATE_DIR/config.sh" "$INSTALL_DIR/config.sh"
fi

ver=""
if grep -q '^XUI_SYNC_VERSION=' "$INSTALL_DIR/xui-sync.sh" 2>/dev/null; then
    ver="$(grep '^XUI_SYNC_VERSION=' "$INSTALL_DIR/xui-sync.sh" | head -n1 | cut -d'"' -f2)"
fi

systemctl daemon-reload 2>/dev/null || true
systemctl restart xui-panel.service 2>/dev/null || true

echo ""
echo "=================================================="
echo "  ✓ به‌روزرسانی انجام شد"
if [ -n "$ver" ]; then
    echo "  نسخه xui-sync: $ver"
fi
echo "  پنل را باز کنید و «اجرای همگام‌سازی الان» را بزنید."
echo "  باید در لاگ ببینید: xui-sync $ver"
echo "=================================================="
