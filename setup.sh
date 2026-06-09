#!/data/data/com.termux/files/usr/bin/bash
#
# One-line bootstrap installer for xui-outbound-termux.
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/setup.sh | bash
#
set -e

XUI_REPO="${XUI_REPO:-https://github.com/asanseir724/xui-outbound-termux.git}"
XUI_ZIP_URL="${XUI_ZIP_URL:-https://codeload.github.com/asanseir724/xui-outbound-termux/zip/refs/heads/main}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/xui-outbound-termux}"

die() {
    echo ""
    echo "[ERROR] $*" >&2
    echo "" >&2
    echo "Termux may be broken. Run repair first:" >&2
    echo "  curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/fix-termux.sh | bash" >&2
    echo "" >&2
    echo "Or manually:" >&2
    echo "  kill %1; rm -f \$PREFIX/var/lib/apt/lists/lock" >&2
    echo "  pkg update -y && pkg upgrade -y && pkg install -y openssl curl git" >&2
    echo "  (Also update Termux app from F-Droid)" >&2
    exit 1
}

preflight() {
    # Clear apt lock from interrupted pkg (Ctrl+Z)
    for _pid in $(jobs -p 2>/dev/null); do kill "$_pid" 2>/dev/null || true; done
    rm -f "$PREFIX/var/lib/apt/lists/lock" 2>/dev/null || true
    rm -f "$PREFIX/var/lib/dpkg/lock" 2>/dev/null || true
    rm -f "$PREFIX/var/lib/dpkg/lock-frontend" 2>/dev/null || true

    if [ ! -f "$PREFIX/lib/libssl.so.1.1" ] && [ ! -f "$PREFIX/lib/libssl.so.3" ]; then
        die "OpenSSL library not found. Update Termux from F-Droid, then run fix-termux.sh"
    fi
}

install_deps() {
    echo "==> Updating package lists..."
    pkg update -y || die "pkg update failed — run fix-termux.sh first"

    echo "==> Installing dependencies..."
    pkg install -y curl jq php cronie unzip || die "pkg install failed"
    # git is optional — we can download ZIP if git HTTPS is broken
    pkg install -y git 2>/dev/null || echo "==> git install skipped (will use ZIP download)"
}

fetch_via_git() {
    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi
    if ! git ls-remote "$XUI_REPO" HEAD >/dev/null 2>&1; then
        return 1
    fi
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" pull --ff-only
    else
        rm -rf "$INSTALL_DIR"
        git clone "$XUI_REPO" "$INSTALL_DIR"
    fi
    return 0
}

fetch_via_zip() {
    echo "==> Downloading project ZIP (git unavailable)..."
    local tmpzip="$HOME/.cache/xui-outbound-termux-main.zip"
    mkdir -p "$(dirname "$tmpzip")"
    curl -fsSL "$XUI_ZIP_URL" -o "$tmpzip" || return 1
    rm -rf "$INSTALL_DIR"
    unzip -qo "$tmpzip" -d "$HOME" || return 1
    mv "$HOME/xui-outbound-termux-main" "$INSTALL_DIR"
    rm -f "$tmpzip"
    return 0
}

fix_crlf() {
    if ! command -v sed >/dev/null 2>&1; then
        return 0
    fi
    for f in setup.sh install.sh uninstall.sh xui-sync.sh xui-services.sh fix-termux.sh termux-boot/start-xui-sync.sh; do
        [ -f "$f" ] || continue
        sed -i 's/\r$//' "$f" 2>/dev/null || sed 's/\r$//' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    done
}

echo "=================================================="
echo "  xui-outbound-termux — one-line setup"
echo "=================================================="

preflight
install_deps

echo "==> Fetching project..."
if fetch_via_git; then
    echo "==> Fetched via git."
elif fetch_via_zip; then
    echo "==> Fetched via ZIP."
else
    die "Could not download project. Check VPN/network and run fix-termux.sh"
fi

cd "$INSTALL_DIR"
fix_crlf
chmod +x setup.sh install.sh uninstall.sh xui-sync.sh xui-services.sh fix-termux.sh 2>/dev/null || true
chmod +x termux-boot/start-xui-sync.sh 2>/dev/null || true

echo "==> Running installer..."
bash install.sh

echo ""
echo "=================================================="
echo "  نصب کامل شد. آدرس پنل در بالا چاپ شده است."
echo "=================================================="
