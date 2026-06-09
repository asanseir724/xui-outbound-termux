#!/data/data/com.termux/files/usr/bin/bash
#
# Installer for xui-outbound-termux.
#
# - Installs dependencies (curl, jq, php, cronie, termux-services)
# - Schedules an hourly sync via cron
# - Registers an always-on local web admin panel (runit service)
# - Enables wake-lock so it keeps running when Termux is in the background
# - Prints the local panel URL
#
# Run from inside the project folder in Termux:
#     bash install.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_PORT="${PANEL_PORT:-8088}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SV_DIR="$PREFIX/var/service"

echo "==> xui-outbound-termux installer"

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
echo "==> Installing dependencies…"
pkg install -y curl jq php cronie termux-services

# ---------------------------------------------------------------------------
# 2. Config
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.config/xui-sync"
if [ ! -f "$SCRIPT_DIR/config.sh" ]; then
    cp "$SCRIPT_DIR/config.example.sh" "$SCRIPT_DIR/config.sh"
    echo "==> Created config.sh (edit it from the web panel)."
fi
chmod +x "$SCRIPT_DIR/xui-sync.sh"

# ---------------------------------------------------------------------------
# 3. Hourly sync via cron
# ---------------------------------------------------------------------------
CRON_LINE="0 * * * * $SCRIPT_DIR/xui-sync.sh once >> $HOME/.config/xui-sync/cron.log 2>&1"
EXISTING="$(crontab -l 2>/dev/null || true)"
if echo "$EXISTING" | grep -Fq "$SCRIPT_DIR/xui-sync.sh once"; then
    echo "==> Cron job already installed."
else
    printf '%s\n%s\n' "$EXISTING" "$CRON_LINE" | grep -v '^$' | crontab -
    echo "==> Cron job installed (hourly)."
fi

# ---------------------------------------------------------------------------
# 4. Web admin panel as an always-on runit service
# ---------------------------------------------------------------------------
echo "==> Registering web panel service on port $PANEL_PORT…"
mkdir -p "$SV_DIR/xui-panel/log"

cat > "$SV_DIR/xui-panel/run" <<RUN
#!/data/data/com.termux/files/usr/bin/sh
exec php -S 0.0.0.0:$PANEL_PORT -t "$SCRIPT_DIR/panel" 2>&1
RUN
chmod +x "$SV_DIR/xui-panel/run"

cat > "$SV_DIR/xui-panel/log/run" <<'LOGRUN'
#!/data/data/com.termux/files/usr/bin/sh
exec logger -t xui-panel
LOGRUN
chmod +x "$SV_DIR/xui-panel/log/run"

# ---------------------------------------------------------------------------
# 5. Start services (crond + panel) and keep CPU awake
# ---------------------------------------------------------------------------
# termux-services needs its runit daemon running; sv-enable persists the choice.
sv-enable crond 2>/dev/null || true
sv-enable xui-panel 2>/dev/null || true
sv up crond 2>/dev/null || true
sv up xui-panel 2>/dev/null || true

# Keep running in the background even when the Termux UI is closed.
termux-wake-lock 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Auto-start on boot (Termux:Boot)
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.termux/boot"
if [ -f "$SCRIPT_DIR/termux-boot/start-xui-sync.sh" ]; then
    cp "$SCRIPT_DIR/termux-boot/start-xui-sync.sh" "$HOME/.termux/boot/start-xui-sync.sh"
    chmod +x "$HOME/.termux/boot/start-xui-sync.sh"
fi

# ---------------------------------------------------------------------------
# 7. Print local panel address
# ---------------------------------------------------------------------------
LAN_IP="$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -vE '^127\.' | head -n1)"

PANEL_LOCAL="http://localhost:$PANEL_PORT"
PANEL_LAN=""
if [ -n "$LAN_IP" ]; then
    PANEL_LAN="http://$LAN_IP:$PANEL_PORT"
fi

mkdir -p "$HOME/.config/xui-sync"
{
    echo "PANEL_LOCAL=$PANEL_LOCAL"
    [ -n "$PANEL_LAN" ] && echo "PANEL_LAN=$PANEL_LAN"
    echo "INSTALLED_AT=$(date -Iseconds 2>/dev/null || date)"
} > "$HOME/.config/xui-sync/panel-url.txt"

echo ""
echo "=================================================="
echo "  ✓ نصب کامل شد"
echo "=================================================="
echo "  پنل تنظیمات را در مرورگر باز کنید:"
echo ""
echo "    روی همین گوشی:   http://localhost:$PANEL_PORT"
if [ -n "$LAN_IP" ]; then
    echo "    از کامپیوتر/گوشی دیگر در همین وای‌فای:"
    echo "                     http://$LAN_IP:$PANEL_PORT"
fi
echo ""
echo "  در پنل: آدرس سایت و توکن را وارد و ذخیره کنید،"
echo "  سپس «اجرای همگام‌سازی الان» را بزنید."
echo ""
echo "  برای روشن‌ماندن بعد از ریبوت: اپ Termux:Boot را نصب کنید"
echo "  و بهینه‌سازی باتری Termux را خاموش کنید."
echo "=================================================="
