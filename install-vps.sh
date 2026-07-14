#!/usr/bin/env bash
#
# One-line VPS installer for xui-outbound (Debian/Ubuntu/CentOS).
#
#   curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-vps.sh | bash
#
# Installs dependencies, sets up an hourly sync (systemd timer) and an
# always-on web admin panel (systemd service). If your VPS is OUTSIDE Iran it
# fetches foreign subscriptions directly — no VPN needed.
#
set -e

REPO="${REPO:-https://github.com/asanseir724/xui-outbound-termux.git}"
ZIP_URL="${ZIP_URL:-https://codeload.github.com/asanseir724/xui-outbound-termux/zip/refs/heads/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/xui-outbound}"
PANEL_PORT="${PANEL_PORT:-8088}"
STATE_DIR="/etc/xui-outbound"

# Never let apt/needrestart or git open an interactive prompt — this script is
# often piped through `| bash`, where a prompt would hang forever.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=true

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "==> Re-running with sudo…"
        exec sudo -E bash "$0" "$@"
    fi
    echo "[ERROR] Please run as root (or install sudo)." >&2
    exit 1
fi

echo "=================================================="
echo "  xui-outbound — VPS installer"
echo "=================================================="

# ---------------------------------------------------------------------------
# 1. Detect package manager & install dependencies
# ---------------------------------------------------------------------------
echo "==> Installing dependencies (curl, jq, php, git)…"
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl jq git unzip php-cli php-curl
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq git unzip php-cli php-curl
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq git unzip php-cli php-curl
else
    echo "[ERROR] No supported package manager (apt/dnf/yum) found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Fetch project
# ---------------------------------------------------------------------------
echo "==> Fetching project to $INSTALL_DIR…"
fetched=""

# Prefer ZIP download (no git prompts, no hangs, very reliable).
download_zip() {
    local tmp
    tmp="$(mktemp -d)"
    if curl -fsSL --connect-timeout 15 --max-time 120 "$ZIP_URL" -o "$tmp/main.zip" \
        && unzip -qo "$tmp/main.zip" -d "$tmp" 2>/dev/null; then
        rm -rf "$INSTALL_DIR"
        mv "$tmp"/xui-outbound-termux-* "$INSTALL_DIR"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

if download_zip; then
    echo "==> Fetched via ZIP."
    fetched="yes"
elif command -v git >/dev/null 2>&1; then
    echo "==> ZIP failed, trying git clone…"
    rm -rf "$INSTALL_DIR"
    if git clone --depth 1 "$REPO" "$INSTALL_DIR"; then
        echo "==> Fetched via git."
        fetched="yes"
    fi
fi

if [ -z "$fetched" ]; then
    echo "[ERROR] Could not download the project (network/firewall?)." >&2
    echo "        Test: curl -I $ZIP_URL" >&2
    exit 1
fi

# Normalize line endings + perms
if command -v sed >/dev/null 2>&1; then
    find "$INSTALL_DIR" -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
fi
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2b. Xray for free-config probe
# ---------------------------------------------------------------------------
echo "==> Installing Xray for config probe…"
if bash "$INSTALL_DIR/install-xray.sh"; then
    echo "==> Xray OK."
else
    echo "[WARN] Xray install failed — probe will use TCP-only fallback until fixed."
fi

# ---------------------------------------------------------------------------
# 3. Config
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR" /var/log/xui-outbound
if [ ! -f "$STATE_DIR/config.sh" ]; then
    cp "$INSTALL_DIR/config.example.sh" "$STATE_DIR/config.sh"
fi
# VPS paths: no $HOME dependency.
if grep -q '^LOG_FILE=' "$STATE_DIR/config.sh" 2>/dev/null; then
    sed -i 's|^LOG_FILE=.*|LOG_FILE="/var/log/xui-outbound/sync.log"|' "$STATE_DIR/config.sh"
else
    echo 'LOG_FILE="/var/log/xui-outbound/sync.log"' >> "$STATE_DIR/config.sh"
fi
ln -sf "$STATE_DIR/config.sh" "$INSTALL_DIR/config.sh"

# Panel password. Override with: PANEL_PASSWORD=... before running.
PANEL_PASS="${PANEL_PASSWORD:-1895233171}"
echo "$PANEL_PASS" > "$STATE_DIR/panel-password.txt"
chmod 600 "$STATE_DIR/panel-password.txt"

# ---------------------------------------------------------------------------
# 4. systemd: hourly sync (service + timer)
# ---------------------------------------------------------------------------
echo "==> Installing systemd units…"

cat > /etc/systemd/system/xui-sync.service <<UNIT
[Unit]
Description=XUI outbound sync (one shot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=XUI_STATE_DIR=$STATE_DIR
Environment=XUI_SYNC_CONFIG=$STATE_DIR/config.sh
ExecStart=/usr/bin/env bash $INSTALL_DIR/xui-sync.sh once
UNIT

cat > /etc/systemd/system/xui-sync.timer <<UNIT
[Unit]
Description=Run XUI outbound sync every hour

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# ---------------------------------------------------------------------------
# 5b. systemd: fast panel API relay loop (foreign X-UI panels)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 5c. systemd: free-config probe loop (Xray tests for WordPress host)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 6. systemd: always-on web panel
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/xui-panel.service <<UNIT
[Unit]
Description=XUI outbound web admin panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
Environment=XUI_SYNC_CONFIG=$STATE_DIR/config.sh
Environment=XUI_PANEL_PASSWORD_FILE=$STATE_DIR/panel-password.txt
Environment=XUI_STATE_DIR=$STATE_DIR
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/php -S 0.0.0.0:$PANEL_PORT -t $INSTALL_DIR/panel
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now xui-sync.timer
systemctl enable --now xui-panel-relay.service
systemctl enable --now xui-free-config-probe.service
systemctl enable --now xui-panel.service

# ---------------------------------------------------------------------------
# 6. Open firewall port if a firewall is active
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PANEL_PORT"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 7. Report
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo ""
echo "=================================================="
echo "  ✓ نصب کامل شد"
echo "=================================================="
echo "  پنل تنظیمات:"
if [ -n "$PUBLIC_IP" ]; then
    echo "      http://$PUBLIC_IP:$PANEL_PORT"
fi
echo "      http://localhost:$PANEL_PORT  (روی خود سرور)"
echo ""
echo "  رمز ورود پنل:  $PANEL_PASS"
echo "  (ذخیره‌شده در $STATE_DIR/panel-password.txt)"
echo ""
echo "  در پنل: آدرس سایت وردپرس و توکن را وارد و ذخیره کنید."
echo ""
echo "  دستورات مفید:"
echo "    systemctl status xui-panel        وضعیت پنل"
echo "    systemctl status xui-panel-relay  وضعیت relay پنل خارجی"
echo "    systemctl status xui-free-config-probe  وضعیت تست کانفیگ رایگان"
echo "    systemctl status xui-sync.timer   وضعیت زمان‌بندی"
echo "    systemctl start  xui-sync         اجرای دستی همگام‌سازی"
echo "    journalctl -u xui-sync -n 50      لاگ همگام‌سازی"
echo "=================================================="
