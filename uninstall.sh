#!/data/data/com.termux/files/usr/bin/bash
#
# Remove the scheduled cron job and the web panel service for
# xui-outbound-termux. (Does not uninstall packages or delete your config.)
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SV_DIR="$PREFIX/var/service"

echo "==> Removing cron job…"
EXISTING="$(crontab -l 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
    echo "$EXISTING" | grep -Fv "$SCRIPT_DIR/xui-sync.sh once" | grep -v '^$' | crontab - || crontab -r 2>/dev/null || true
    echo "==> Cron job removed."
else
    echo "==> No crontab found."
fi

echo "==> Stopping & removing web panel service…"
sv down xui-panel 2>/dev/null || true
rm -rf "$SV_DIR/xui-panel"
rm -f "$HOME/.termux/boot/start-xui-sync.sh" 2>/dev/null || true

echo "==> Done. Config and logs kept at: $HOME/.config/xui-sync/"
echo "    To stop the hourly cron service entirely: sv down crond"
