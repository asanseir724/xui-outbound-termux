#!/data/data/com.termux/files/usr/bin/bash
#
# Remove cron job and stop background services.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Removing cron job..."
EXISTING="$(crontab -l 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
    echo "$EXISTING" | grep -Fv "$SCRIPT_DIR/xui-sync.sh once" | grep -v '^$' | crontab - || crontab -r 2>/dev/null || true
    echo "==> Cron job removed."
else
    echo "==> No crontab found."
fi

echo "==> Stopping services..."
bash "$SCRIPT_DIR/xui-services.sh" stop 2>/dev/null || true
rm -f "$HOME/.termux/boot/start-xui-sync.sh" 2>/dev/null || true

echo "==> Done. Config and logs kept at: $HOME/.config/xui-sync/"
