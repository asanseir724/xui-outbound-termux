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

RELAY_INTERVAL_SEC=4
LOG_FILE="/var/log/xui-outbound/sync.log"
SITE_URL=""
MOBILE_TOKEN=""
REST_STYLE=""
LAST_LOADED_SITE_URL=""

load_config() {
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    RELAY_INTERVAL_SEC="${RELAY_INTERVAL_SEC:-4}"
    LOG_FILE="${LOG_FILE:-/var/log/xui-outbound/sync.log}"
    if [ -n "${LAST_LOADED_SITE_URL:-}" ] && [ "${LAST_LOADED_SITE_URL}" != "${SITE_URL:-}" ]; then
        REST_STYLE=""
        log "Config reloaded — SITE_URL now ${SITE_URL:-<empty>}"
    fi
    LAST_LOADED_SITE_URL="${SITE_URL:-}"
}

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [relay] $*"
    echo "$line"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

validate_config() {
    if [ -z "${SITE_URL:-}" ] || [ -z "${MOBILE_TOKEN:-}" ]; then
        log "[ERROR] SITE_URL and MOBILE_TOKEN must be set in config"
        return 1
    fi
    return 0
}

api_curl() {
    curl --silent --show-error --location \
        --connect-timeout 20 --max-time 90 \
        "$@"
}

rest_url() {
    local route="$1"
    if [ "$REST_STYLE" = "query" ]; then
        echo "${SITE_URL%/}/index.php?rest_route=/$route"
    else
        echo "${SITE_URL%/}/wp-json/$route"
    fi
}

# Must match xui-sync.sh: HTTP 200 alone is not enough (some hosts return HTML on /wp-json/).
detect_rest_style() {
    local code tmp
    if [ -n "${REST_STYLE:-}" ]; then
        return 0
    fi
    if [ "${REST_FORCE_QUERY:-}" = "1" ]; then
        REST_STYLE="query"
        return 0
    fi
    tmp="$(mktemp 2>/dev/null || echo "/tmp/xui-relay-rest.$$")"
    code="$(api_curl -o "$tmp" -w '%{http_code}' \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        -H "Accept: application/json" \
        "${SITE_URL%/}/wp-json/xui/v1/outbound-mobile/panel-jobs?limit=1" 2>/dev/null)"
    if [ "$code" = "200" ] && jq -e '.success' "$tmp" >/dev/null 2>&1; then
        REST_STYLE="pretty"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    for query_base in \
        "${SITE_URL%/}/index.php?rest_route=/xui/v1/outbound-mobile/panel-jobs" \
        "${SITE_URL%/}/?rest_route=/xui/v1/outbound-mobile/panel-jobs"; do
        code="$(api_curl -o "$tmp" -w '%{http_code}' \
            -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
            -H "Accept: application/json" \
            "${query_base}&limit=1" 2>/dev/null)"
        if [ "$code" = "200" ] && jq -e '.success' "$tmp" >/dev/null 2>&1; then
            REST_STYLE="query"
            rm -f "$tmp"
            log "Note: using index.php?rest_route= for WordPress REST."
            return 0
        fi
        rm -f "$tmp"
    done
    REST_STYLE="query"
    return 0
}

# shellcheck source=panel-relay-lib.sh
. "$SCRIPT_DIR/panel-relay-lib.sh"

MODE="${1:-loop}"
case "$MODE" in
    once)
        load_config
        validate_config || exit 1
        detect_rest_style || true
        process_panel_jobs_once
        process_hooshpay_jobs_once 2>/dev/null || true
        ;;
    loop)
        load_config
        validate_config || exit 1
        detect_rest_style || true
        log "Panel relay loop started (every ${RELAY_INTERVAL_SEC}s) SITE_URL=${SITE_URL:-?}"
        while true; do
            load_config
            validate_config || { sleep "$RELAY_INTERVAL_SEC"; continue; }
            detect_rest_style || true
            process_panel_jobs_once || true
            process_hooshpay_jobs_once 2>/dev/null || true
            sleep "$RELAY_INTERVAL_SEC"
        done
        ;;
    *)
        echo "Usage: $0 {once|loop}" >&2
        exit 2
        ;;
esac
