#!/usr/bin/env bash
#
# Fast loop for X-UI panel API relay jobs (foreign panels via VPS/Android).
# Keeps polling WordPress so subscription builds complete within seconds.
#
# Usage:
#   ./xui-panel-relay.sh once
#   ./xui-panel-relay.sh loop    # every RELAY_INTERVAL_SEC (default 4)
#
set -u

export HOME="${HOME:-/root}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${XUI_STATE_DIR:-/etc/xui-outbound}"

CONFIG_FILE=""
for candidate in \
    "${XUI_SYNC_CONFIG:-}" \
    "$SCRIPT_DIR/config.sh" \
    "$HOME/.config/xui-sync/config.sh"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        CONFIG_FILE="$candidate"
        break
    fi
done

if [ -z "$CONFIG_FILE" ]; then
    echo "[ERROR] No config file found." >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

RELAY_INTERVAL_SEC="${RELAY_INTERVAL_SEC:-4}"
LOG_FILE="${LOG_FILE:-/var/log/xui-outbound/sync.log}"

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [relay] $*"
    echo "$line"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

validate_config() {
    if [ -z "${SITE_URL:-}" ] || [ -z "${MOBILE_TOKEN:-}" ]; then
        log "[ERROR] SITE_URL and MOBILE_TOKEN must be set in config"
        exit 1
    fi
}

api_curl() {
    curl --silent --show-error --location \
        --connect-timeout 20 --max-time 90 \
        "$@"
}

REST_STYLE=""
rest_url() {
    local route="$1"
    if [ "$REST_STYLE" = "query" ]; then
        echo "${SITE_URL%/}/?rest_route=/$route"
    else
        echo "${SITE_URL%/}/wp-json/$route"
    fi
}

detect_rest_style() {
    local code
    code="$(api_curl -o /dev/null -w '%{http_code}' \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        "${SITE_URL%/}/wp-json/xui/v1/outbound-mobile/panel-jobs" 2>/dev/null)"
    if [ "$code" = "200" ] || [ "$code" = "403" ]; then
        REST_STYLE="pretty"
        return 0
    fi
    REST_STYLE="query"
    return 0
}

# shellcheck source=panel-relay-lib.sh
. "$SCRIPT_DIR/panel-relay-lib.sh"

MODE="${1:-loop}"
case "$MODE" in
    once)
        validate_config
        detect_rest_style || true
        process_panel_jobs_once
        ;;
    loop)
        validate_config
        detect_rest_style || true
        log "Panel relay loop started (every ${RELAY_INTERVAL_SEC}s)"
        while true; do
            process_panel_jobs_once || true
            sleep "$RELAY_INTERVAL_SEC"
        done
        ;;
    *)
        echo "Usage: $0 {once|loop}" >&2
        exit 2
        ;;
esac
