#!/data/data/com.termux/files/usr/bin/bash
#
# Start/stop background services without termux-services (works on all Termux).
#
# Usage: ./xui-services.sh {start|stop|restart|status}
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.config/xui-sync}"
PANEL_PORT="${PANEL_PORT:-8088}"
PANEL_PID="$STATE_DIR/panel.pid"
RELAY_PID="$STATE_DIR/panel-relay.pid"
PANEL_LOG="$STATE_DIR/panel.log"
RELAY_LOG="$STATE_DIR/panel-relay.log"

mkdir -p "$STATE_DIR"

panel_running() {
    [ -f "$PANEL_PID" ] && kill -0 "$(cat "$PANEL_PID")" 2>/dev/null
}

relay_running() {
    [ -f "$RELAY_PID" ] && kill -0 "$(cat "$RELAY_PID")" 2>/dev/null
}

crond_running() {
    pgrep -x crond >/dev/null 2>&1
}

start_crond() {
    if crond_running; then
        return 0
    fi
    if command -v crond >/dev/null 2>&1; then
        crond
        sleep 1
    fi
}

stop_crond() {
    if crond_running; then
        pkill -x crond 2>/dev/null || true
    fi
}

start_panel() {
    if panel_running; then
        return 0
    fi
    if ! command -v php >/dev/null 2>&1; then
        echo "[ERROR] php not installed — run: pkg install php" >&2
        return 1
    fi
    nohup php -S "0.0.0.0:$PANEL_PORT" -t "$SCRIPT_DIR/panel" >>"$PANEL_LOG" 2>&1 &
    echo $! >"$PANEL_PID"
    sleep 1
    if ! panel_running; then
        echo "[ERROR] Web panel failed to start. See: $PANEL_LOG" >&2
        return 1
    fi
}

stop_panel() {
    if panel_running; then
        kill "$(cat "$PANEL_PID")" 2>/dev/null || true
    fi
    rm -f "$PANEL_PID"
}

start_relay() {
    if relay_running; then
        return 0
    fi
    if [ ! -f "$SCRIPT_DIR/xui-panel-relay.sh" ]; then
        return 0
    fi
    nohup bash "$SCRIPT_DIR/xui-panel-relay.sh" loop >>"$RELAY_LOG" 2>&1 &
    echo $! >"$RELAY_PID"
    sleep 1
}

stop_relay() {
    if relay_running; then
        kill "$(cat "$RELAY_PID")" 2>/dev/null || true
    fi
    rm -f "$RELAY_PID"
}

restart_relay() {
    stop_relay
    start_relay
}

status_services() {
    if crond_running; then
        echo "crond: running"
    else
        echo "crond: stopped"
    fi
    if panel_running; then
        echo "panel: running (http://localhost:$PANEL_PORT)"
    else
        echo "panel: stopped"
    fi
    if relay_running; then
        echo "panel-relay: running"
    else
        echo "panel-relay: stopped"
    fi
}

case "${1:-start}" in
    start)
        start_crond
        start_panel
        start_relay
        termux-wake-lock 2>/dev/null || true
        ;;
    stop)
        stop_relay
        stop_panel
        stop_crond
        termux-wake-unlock 2>/dev/null || true
        ;;
    restart)
        stop_relay
        stop_panel
        stop_crond
        start_crond
        start_panel
        start_relay
        termux-wake-lock 2>/dev/null || true
        ;;
    restart-relay)
        restart_relay
        ;;
    status)
        status_services
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|restart-relay|status}" >&2
        exit 2
        ;;
esac
