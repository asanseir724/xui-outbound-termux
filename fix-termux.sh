#!/data/data/com.termux/files/usr/bin/bash
#
# Repair a broken Termux before installing xui-outbound-termux.
#
# Common errors this fixes:
#   - libssl.so.1.1 not found
#   - Unable to lock directory ... apt/lists/
#   - git-remote-https / apt methods https aborted
#
# Usage:  bash fix-termux.sh
#
set -e

echo "=================================================="
echo "  Termux repair"
echo "=================================================="

# 1. Kill suspended pkg jobs (Ctrl+Z leaves them running)
echo "==> Clearing suspended jobs and apt locks..."
for _pid in $(jobs -p 2>/dev/null); do kill "$_pid" 2>/dev/null || true; done
pkill -x pkg 2>/dev/null || true
rm -f "$PREFIX/var/lib/apt/lists/lock" 2>/dev/null || true
rm -f "$PREFIX/var/lib/dpkg/lock" 2>/dev/null || true
rm -f "$PREFIX/var/lib/dpkg/lock-frontend" 2>/dev/null || true

# 2. Check OpenSSL library
if [ ! -f "$PREFIX/lib/libssl.so.1.1" ] && [ ! -f "$PREFIX/lib/libssl.so.3" ]; then
    echo ""
    echo "[WARN] OpenSSL library missing under $PREFIX/lib/"
    echo "       Update the Termux app from F-Droid first, then run this again."
    echo ""
fi

# 3. Refresh packages
echo "==> pkg update..."
pkg update -y

echo "==> pkg upgrade (may take a few minutes)..."
pkg upgrade -y

echo "==> Installing/repairing openssl..."
pkg install -y openssl

echo "==> Installing core tools..."
pkg install -y curl jq php cronie git unzip

echo ""
echo "==> Quick self-test..."
if curl -fsSL --max-time 15 https://github.com >/dev/null 2>&1; then
    echo "  curl HTTPS: OK"
else
    echo "  curl HTTPS: FAILED — connect VPN (Hiddify) and retry."
fi

if git ls-remote https://github.com/asanseir724/xui-outbound-termux.git HEAD >/dev/null 2>&1; then
    echo "  git HTTPS:  OK"
else
    echo "  git HTTPS:  FAILED — update Termux from F-Droid, then run this again."
fi

echo ""
echo "=================================================="
echo "  Repair done. Now run the one-line installer:"
echo ""
echo "  curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/setup.sh | bash"
echo "=================================================="
