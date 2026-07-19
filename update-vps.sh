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
for f in xui-sync.sh xui-panel-relay.sh xui-free-config-probe.sh panel-relay-lib.sh free-config-probe-lib.sh panel-relay-exec.php hooshpay-relay-lib.sh hooshpay-relay-exec.php free-config-probe-exec.php free-config-probe-bootstrap.php install-xray.sh enable-free-config-probe.sh xui-services.sh install-vps.sh update-vps.sh config.example.sh; do
    if [ -f "$src/$f" ]; then
        cp -f "$src/$f" "$INSTALL_DIR/$f"
    fi
done
if [ -d "$src/probe-php" ]; then
    mkdir -p "$INSTALL_DIR/probe-php"
    cp -rf "$src/probe-php/"* "$INSTALL_DIR/probe-php/" 2>/dev/null || true
fi
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

# Ensure php-curl is present (required by panel-relay-exec.php).
if ! php -m 2>/dev/null | grep -qi '^curl$'; then
    echo "==> Installing php-curl…"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y php-curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y php-curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y php-curl
    fi
fi

# Keep config symlink intact.
if [ -f "$STATE_DIR/config.sh" ] && [ ! -L "$INSTALL_DIR/config.sh" ]; then
    ln -sf "$STATE_DIR/config.sh" "$INSTALL_DIR/config.sh"
fi

# Migrate: add RELAY_INTERVAL_SEC if missing (panel relay poll interval).
if [ -f "$STATE_DIR/config.sh" ] && ! grep -q '^RELAY_INTERVAL_SEC=' "$STATE_DIR/config.sh" 2>/dev/null; then
    echo "==> Adding RELAY_INTERVAL_SEC=2 to config.sh"
    printf '\n# Panel relay poll interval (seconds)\nRELAY_INTERVAL_SEC=2\n' >> "$STATE_DIR/config.sh"
fi

ver=""
relay_ver=""
probe_ver=""
if grep -q '^XUI_SYNC_VERSION=' "$INSTALL_DIR/xui-sync.sh" 2>/dev/null; then
    ver="$(grep '^XUI_SYNC_VERSION=' "$INSTALL_DIR/xui-sync.sh" | head -n1 | cut -d'"' -f2)"
fi
if grep -q '^PANEL_RELAY_VERSION=' "$INSTALL_DIR/panel-relay-lib.sh" 2>/dev/null; then
    relay_ver="$(grep '^PANEL_RELAY_VERSION=' "$INSTALL_DIR/panel-relay-lib.sh" | head -n1 | cut -d'"' -f2)"
fi
hp_ver=""
if grep -q '^HOOSHPAY_RELAY_VERSION=' "$INSTALL_DIR/hooshpay-relay-lib.sh" 2>/dev/null; then
    hp_ver="$(grep '^HOOSHPAY_RELAY_VERSION=' "$INSTALL_DIR/hooshpay-relay-lib.sh" | head -n1 | cut -d'"' -f2)"
fi

if grep -q '^FREE_CONFIG_PROBE_VERSION=' "$INSTALL_DIR/free-config-probe-lib.sh" 2>/dev/null; then
    probe_ver="$(grep '^FREE_CONFIG_PROBE_VERSION=' "$INSTALL_DIR/free-config-probe-lib.sh" | head -n1 | cut -d'"' -f2)"
fi

# Ensure Xray is present
if [ -f "$INSTALL_DIR/install-xray.sh" ] && [ ! -x "$STATE_DIR/xray/xray" ]; then
    echo "==> Installing Xray…"
    bash "$INSTALL_DIR/install-xray.sh" || echo "[WARN] Xray install failed"
fi

systemctl daemon-reload 2>/dev/null || true

# Install free-config-probe service if missing
if [ -f "$INSTALL_DIR/xui-free-config-probe.sh" ] && [ ! -f /etc/systemd/system/xui-free-config-probe.service ]; then
    cat > /etc/systemd/system/xui-free-config-probe.service <<UNIT
[Unit]
Description=XUI free-config probe relay (VPS → WordPress)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=XUI_STATE_DIR=$STATE_DIR
Environment=XUI_SYNC_CONFIG=$STATE_DIR/config.sh
Environment=XUI_VPN_PLUGIN_DIR=$INSTALL_DIR/probe-php/
Environment=XRAY_BIN=$STATE_DIR/xray/xray
ExecStart=/usr/bin/env bash $INSTALL_DIR/xui-free-config-probe.sh loop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload 2>/dev/null || true

# Install panel-relay service if missing (upgrade from older installs)
if [ -f "$INSTALL_DIR/xui-panel-relay.sh" ] && [ ! -f /etc/systemd/system/xui-panel-relay.service ]; then
    cat > /etc/systemd/system/xui-panel-relay.service <<UNIT
[Unit]
Description=XUI panel API relay (foreign panels → WordPress)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=XUI_STATE_DIR=$STATE_DIR
Environment=XUI_SYNC_CONFIG=$STATE_DIR/config.sh
ExecStart=/usr/bin/env bash $INSTALL_DIR/xui-panel-relay.sh loop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl enable xui-panel-relay.service 2>/dev/null || true
systemctl enable xui-free-config-probe.service 2>/dev/null || true
systemctl restart xui-panel-relay.service 2>/dev/null || true
systemctl restart xui-free-config-probe.service 2>/dev/null || true
systemctl restart xui-panel.service 2>/dev/null || true

echo ""
echo "=================================================="
echo "  ✓ به‌روزرسانی انجام شد"
if [ -n "$ver" ]; then
    echo "  نسخه xui-sync: $ver"
fi
if [ -n "$relay_ver" ]; then
    echo "  نسخه panel-relay: $relay_ver"
fi
if [ -n "${probe_ver:-}" ]; then
    echo "  نسخه free-config-probe: $probe_ver"
fi
if [ -n "${hp_ver:-}" ]; then
    echo "  نسخه hooshpay-relay: $hp_ver"
fi
echo "  پنل را باز کنید و «اجرای همگام‌سازی الان» را بزنید."
echo "  باید در لاگ ببینید: xui-sync $ver"
echo "=================================================="
