#!/data/data/com.termux/files/usr/bin/bash
#
# One-line bootstrap installer for xui-outbound-termux.
#
# Run on the phone (Termux) with a single command:
#
#   curl -fsSL https://raw.githubusercontent.com/USERNAME/xui-outbound-termux/main/setup.sh | bash
#
# It will: install all dependencies, clone the project, set up the always-on
# services (hourly sync + local web panel), and print the local panel address.
#
set -e

# Repo to clone — override with: XUI_REPO=https://github.com/you/repo.git
XUI_REPO="${XUI_REPO:-https://github.com/USERNAME/xui-outbound-termux.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/xui-outbound-termux}"

echo "=================================================="
echo "  xui-outbound-termux — one-line setup"
echo "=================================================="

echo "==> Updating package lists & installing dependencies…"
yes | pkg update >/dev/null 2>&1 || true
pkg install -y git curl jq php cronie termux-services

echo "==> Fetching project…"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only || true
else
    rm -rf "$INSTALL_DIR"
    git clone "$XUI_REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"
chmod +x install.sh xui-sync.sh uninstall.sh 2>/dev/null || true

echo "==> Running installer…"
bash install.sh

echo ""
echo "=================================================="
echo "  نصب کامل شد. حالا آدرس پنل را در مرورگر باز کنید."
echo "=================================================="
