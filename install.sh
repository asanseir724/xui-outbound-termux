#!/data/data/com.termux/files/usr/bin/bash
#
# Installer for xui-outbound-termux.
#
# Run from inside the project folder in Termux:
#     bash install.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_PORT="${PANEL_PORT:-8088}"
STATE_DIR="$HOME/.config/xui-sync"

echo "==> xui-outbound-termux installer"

echo "==> Installing dependencies..."
pkg install -y curl jq php cronie

mkdir -p "$STATE_DIR"
if [ ! -f "$SCRIPT_DIR/config.sh" ]; then
    cp "$SCRIPT_DIR/config.example.sh" "$SCRIPT_DIR/config.sh"
    echo "==> Created config.sh (edit it from the web panel)."
fi

chmod +x "$SCRIPT_DIR/xui-sync.sh" "$SCRIPT_DIR/xui-services.sh"

echo "==> Scheduling hourly sync (cron)..."
CRON_LINE="0 * * * * $SCRIPT_DIR/xui-sync.sh once >> $STATE_DIR/cron.log 2>&1"
EXISTING="$(crontab -l 2>/dev/null || true)"
if echo "$EXISTING" | grep -Fq "$SCRIPT_DIR/xui-sync.sh once"; then
    echo "==> Cron job already installed."
else
    printf '%s\n%s\n' "$EXISTING" "$CRON_LINE" | grep -v '^$' | crontab -
    echo "==> Cron job installed (hourly)."
fi

echo "==> Starting web panel on port $PANEL_PORT..."
PANEL_PORT="$PANEL_PORT" bash "$SCRIPT_DIR/xui-services.sh" start

mkdir -p "$HOME/.termux/boot"
if [ -f "$SCRIPT_DIR/termux-boot/start-xui-sync.sh" ]; then
    cp "$SCRIPT_DIR/termux-boot/start-xui-sync.sh" "$HOME/.termux/boot/start-xui-sync.sh"
    chmod +x "$HOME/.termux/boot/start-xui-sync.sh"
fi

LAN_IP="$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -vE '^127\.' | head -n1)"

PANEL_LOCAL="http://localhost:$PANEL_PORT"
PANEL_LAN=""
if [ -n "$LAN_IP" ]; then
    PANEL_LAN="http://$LAN_IP:$PANEL_PORT"
fi

{
    echo "PANEL_LOCAL=$PANEL_LOCAL"
    [ -n "$PANEL_LAN" ] && echo "PANEL_LAN=$PANEL_LAN"
    echo "INSTALLED_AT=$(date -Iseconds 2>/dev/null || date)"
} > "$STATE_DIR/panel-url.txt"

echo ""
echo "=================================================="
echo "  نصب کامل شد"
echo "=================================================="
echo "  پنل تنظیمات را در مرورگر باز کنید:"
echo ""
echo "    روی همین گوشی:   http://localhost:$PANEL_PORT"
if [ -n "$LAN_IP" ]; then
    echo "    از دستگاه دیگر در همین وای‌فای:"
    echo "                     http://$LAN_IP:$PANEL_PORT"
fi
echo ""
echo "  در پنل: آدرس سایت و توکن را وارد و ذخیره کنید."
echo "  سپس «اجرای همگام‌سازی الان» را بزنید."
echo ""
echo "  برای روشن ماندن بعد از ریبوت:"
echo "    - اپ Termux:Boot را نصب کنید"
echo "    - بهینه‌سازی باتری Termux را خاموش کنید"
echo "=================================================="
