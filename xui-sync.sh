#!/usr/bin/env bash
#
# xui-outbound — fetch foreign subscription lists and push them to the
# X-UI VPN Manager WordPress plugin so they get registered as Xray outbounds
# inside the 3x-ui panel balancer. Works on a Linux VPS and on Termux.
#
# Usage:
#   ./xui-sync.sh once     # run a single sync cycle (use this from cron)
#   ./xui-sync.sh loop     # run forever, syncing every INTERVAL_MIN minutes
#
# Config is loaded from (first that exists):
#   $XUI_SYNC_CONFIG
#   ./config.sh   (next to this script)
#   ~/.config/xui-sync/config.sh
#
set -u

# systemd / PHP shell_exec often run without HOME — set a safe default first.
export HOME="${HOME:-/root}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${XUI_STATE_DIR:-/etc/xui-outbound}"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
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
    echo "[ERROR] No config file found. Copy config.example.sh to config.sh and edit it." >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

SITE_URL="${SITE_URL:-}"
MOBILE_TOKEN="${MOBILE_TOKEN:-}"
INTERVAL_MIN="${INTERVAL_MIN:-60}"
SUB_USER_AGENT="${SUB_USER_AGENT:-HiddifyNext/4.1.0 (Android) v2rayNG/1.8.0}"
PROXY_URL="${PROXY_URL:-}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-45}"
if [ -z "${LOG_FILE:-}" ]; then
    if [ -d "$STATE_DIR" ]; then
        LOG_FILE="/var/log/xui-outbound/sync.log"
    else
        LOG_FILE="$HOME/.config/xui-sync/sync.log"
    fi
fi

# Normalize site URL (strip trailing slash)
SITE_URL="${SITE_URL%/}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[ERROR] Missing dependency: $1 — run: pkg install $2" >&2
        exit 1
    fi
}

validate_config() {
    if [ -z "$SITE_URL" ] || [ -z "$MOBILE_TOKEN" ]; then
        log "[ERROR] SITE_URL and MOBILE_TOKEN must be set in $CONFIG_FILE"
        exit 1
    fi
}

# curl wrapper for talking to the WordPress host (push/list). Goes direct.
api_curl() {
    curl --silent --show-error --location \
        --connect-timeout 20 --max-time 60 \
        "$@"
}

# curl wrapper for fetching the foreign subscription. Uses PROXY_URL if set,
# otherwise direct (which, under a Hiddify VPN/tun connection, is already the
# tunnel).
sub_curl() {
    if [ -n "$PROXY_URL" ]; then
        curl --silent --show-error --location \
            --proxy "$PROXY_URL" \
            --connect-timeout 20 --max-time "$FETCH_TIMEOUT" \
            "$@"
    else
        curl --silent --show-error --location \
            --connect-timeout 20 --max-time "$FETCH_TIMEOUT" \
            "$@"
    fi
}

# ---------------------------------------------------------------------------
# Sync one cycle
# ---------------------------------------------------------------------------
# Build a REST endpoint URL. Pretty permalinks use /wp-json/<route>; if those
# are disabled (Plain permalinks / broken rewrite) WordPress still serves the
# API at ?rest_route=/<route>. We auto-detect which one works and cache it.
REST_STYLE=""
rest_url() {
    local route="$1"
    if [ "$REST_STYLE" = "query" ]; then
        echo "$SITE_URL/?rest_route=/$route"
    else
        echo "$SITE_URL/wp-json/$route"
    fi
}

detect_rest_style() {
    # Try pretty permalink first.
    local code
    code="$(api_curl -o /dev/null -w '%{http_code}' \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        "$SITE_URL/wp-json/xui/v1/outbound-mobile/sources" 2>/dev/null)"
    if [ "$code" = "200" ] || [ "$code" = "403" ]; then
        REST_STYLE="pretty"
        return 0
    fi
    # Fall back to ?rest_route= form.
    code="$(api_curl -o /dev/null -w '%{http_code}' \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        "$SITE_URL/?rest_route=/xui/v1/outbound-mobile/sources" 2>/dev/null)"
    if [ "$code" = "200" ] || [ "$code" = "403" ]; then
        REST_STYLE="query"
        log "Note: pretty permalinks unavailable, using ?rest_route= fallback."
        return 0
    fi
    REST_STYLE="pretty"
    return 1
}

sync_once() {
    validate_config

    local sources_url push_url sources_json ok_count fail_count
    detect_rest_style || true
    sources_url="$(rest_url 'xui/v1/outbound-mobile/sources')"
    push_url="$(rest_url 'xui/v1/outbound-mobile/push')"

    log "Fetching source list from host…"
    local http_code
    sources_json="$(api_curl \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        -H "Accept: application/json" \
        -w $'\n%{http_code}' \
        "$sources_url")"
    http_code="${sources_json##*$'\n'}"
    sources_json="${sources_json%$'\n'*}"

    if [ -z "$sources_json" ]; then
        log "[ERROR] Empty response from host (check SITE_URL / network). HTTP=$http_code"
        return 1
    fi

    # If the response is not valid JSON, the URL is wrong or WP returned HTML.
    if ! echo "$sources_json" | jq -e . >/dev/null 2>&1; then
        local preview
        preview="$(echo "$sources_json" | tr '\n' ' ' | cut -c1-160)"
        log "[ERROR] Host did not return JSON (HTTP=$http_code). URL: $sources_url"
        log "        Response starts with: $preview"
        log "        Check SITE_URL is correct and the xui-vpn-manager plugin is active."
        return 1
    fi

    if [ "$(echo "$sources_json" | jq -r '.success // false')" != "true" ]; then
        log "[ERROR] Host rejected request (HTTP=$http_code): $(echo "$sources_json" | jq -r '.msg // "unknown error"')"
        return 1
    fi

    local count
    count="$(echo "$sources_json" | jq '.sources | length')"
    if [ "$count" -eq 0 ]; then
        log "No active mobile sources configured on host. Nothing to do."
        return 0
    fi

    log "Got $count source(s)."
    ok_count=0
    fail_count=0

    local i id name sub_url body push_resp p_ok p_msg
    for i in $(seq 0 $((count - 1))); do
        id="$(echo "$sources_json"   | jq -r ".sources[$i].id")"
        name="$(echo "$sources_json" | jq -r ".sources[$i].name")"
        sub_url="$(echo "$sources_json" | jq -r ".sources[$i].sub_url")"

        if [ -z "$sub_url" ] || [ "$sub_url" = "null" ]; then
            log "  #$id $name: sub_url is empty — skipped."
            fail_count=$((fail_count + 1))
            continue
        fi

        log "  #$id $name: fetching subscription…"
        body="$(sub_curl \
            -H "User-Agent: $SUB_USER_AGENT" \
            -H "Accept: */*" \
            "$sub_url")"

        if [ -z "$body" ]; then
            log "  #$id $name: FAILED — empty subscription body (proxy/VPN issue?)."
            fail_count=$((fail_count + 1))
            continue
        fi

        # Let the server parse the raw body (it handles base64 + protocol filtering).
        local payload
        payload="$(jq -n --argjson sid "$id" --arg body "$body" \
            '{source_id: $sid, body: $body}')"

        push_resp="$(api_curl \
            -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --data-binary "$payload" \
            "$push_url")"

        p_ok="$(echo "$push_resp" | jq -r '.success // false' 2>/dev/null)"
        p_msg="$(echo "$push_resp" | jq -r '.msg // ""' 2>/dev/null)"

        if [ "$p_ok" = "true" ]; then
            local added skipped
            added="$(echo "$push_resp" | jq -r '.added // 0')"
            skipped="$(echo "$push_resp" | jq -r '.skipped // 0')"
            log "  #$id $name: OK — added $added, skipped $skipped. $p_msg"
            ok_count=$((ok_count + 1))
        else
            log "  #$id $name: FAILED — ${p_msg:-$push_resp}"
            fail_count=$((fail_count + 1))
        fi
    done

    log "Cycle done. success=$ok_count fail=$fail_count"
    [ "$fail_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_cmd curl curl
require_cmd jq jq

MODE="${1:-once}"
case "$MODE" in
    once)
        sync_once
        ;;
    loop)
        log "Starting loop mode (every ${INTERVAL_MIN} min). Keep Termux awake with: termux-wake-lock"
        while true; do
            sync_once || log "Cycle reported errors; will retry next interval."
            log "Sleeping ${INTERVAL_MIN} minute(s)…"
            sleep "$((INTERVAL_MIN * 60))"
        done
        ;;
    *)
        echo "Usage: $0 {once|loop}" >&2
        exit 2
        ;;
esac
