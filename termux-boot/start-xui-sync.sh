#!/data/data/com.termux/files/usr/bin/bash
#
# Termux:Boot startup script — copied to ~/.termux/boot/ by install.sh
#

INSTALL_DIR="${INSTALL_DIR:-$HOME/xui-outbound-termux}"

termux-wake-lock 2>/dev/null || true

if [ -f "$INSTALL_DIR/xui-services.sh" ]; then
    PANEL_PORT="${PANEL_PORT:-8088}" bash "$INSTALL_DIR/xui-services.sh" start
fi
