#!/data/data/com.termux/files/usr/bin/bash
#
# One-line bootstrap installer for xui-outbound-termux.
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/setup.sh | bash
#
# If you see "$'\r': command not found", pipe through sed first:
#   curl -fsSL .../setup.sh | sed 's/\r$//' | bash
#
set -e

XUI_REPO="${XUI_REPO:-https://github.com/asanseir724/xui-outbound-termux.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/xui-outbound-termux}"

echo "=================================================="
echo "  xui-outbound-termux — one-line setup"
echo "=================================================="

echo "==> Updating package lists..."
yes | pkg update >/dev/null 2>&1 || true

echo "==> Installing dependencies (curl, jq, php, cronie, git)..."
pkg install -y git curl jq php cronie

echo "==> Fetching project..."
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only || true
else
    rm -rf "$INSTALL_DIR"
    git clone "$XUI_REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# Fix CRLF if the repo was checked out on Windows
if command -v sed >/dev/null 2>&1; then
    for f in setup.sh install.sh uninstall.sh xui-sync.sh xui-services.sh termux-boot/start-xui-sync.sh; do
        [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || sed 's/\r$//' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    done
fi

chmod +x setup.sh install.sh uninstall.sh xui-sync.sh xui-services.sh 2>/dev/null || true
chmod +x termux-boot/start-xui-sync.sh 2>/dev/null || true

echo "==> Running installer..."
bash install.sh

echo ""
echo "=================================================="
echo "  نصب کامل شد. آدرس پنل در بالا چاپ شده است."
echo "=================================================="
