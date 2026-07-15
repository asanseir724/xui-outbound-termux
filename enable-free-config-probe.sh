#!/usr/bin/env bash
#
# One-shot: install/update free-config probe automation on existing VPS.
# Run as root on the relay server:
#   bash /opt/xui-outbound/enable-free-config-probe.sh
#
set -e

INSTALL_DIR="${INSTALL_DIR:-/opt/xui-outbound}"
STATE_DIR="${STATE_DIR:-/etc/xui-outbound}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root." >&2
    exit 1
fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[ERROR] $INSTALL_DIR not found. Run install-vps.sh first." >&2
    exit 1
fi

cd "$INSTALL_DIR"

if [ -f "$INSTALL_DIR/install-xray.sh" ]; then
    echo "==> Installing Xray…"
    bash "$INSTALL_DIR/install-xray.sh" || echo "[WARN] Xray install failed"
fi

if [ ! -f /etc/systemd/system/xui-free-config-probe.service ]; then
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

systemctl daemon-reload
systemctl enable --now xui-free-config-probe.service

echo ""
echo "=================================================="
echo "  ✓ free-config probe relay فعال شد"
echo "=================================================="
systemctl --no-pager status xui-free-config-probe.service | head -n 8 || true
echo ""
echo "  لاگ: journalctl -u xui-free-config-probe -f"
echo "  تست یک‌بار: bash $INSTALL_DIR/xui-free-config-probe.sh once"
echo "=================================================="
