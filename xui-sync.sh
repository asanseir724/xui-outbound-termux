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

# Bump when push/sync behaviour changes (shown in panel + first log line).
XUI_SYNC_VERSION="20260701-panelrelay"

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
FETCH_RETRIES="${FETCH_RETRIES:-3}"
FETCH_RETRY_DELAY="${FETCH_RETRY_DELAY:-15}"
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

# Fetch subscription body into $1 with retries (DNS/proxy blips are common).
# Returns 0 when the file is non-empty, 1 otherwise.
fetch_sub_to_file() {
    local dest="$1"
    local url="$2"
    local label="${3:-subscription}"
    local attempt max_attempts delay curl_err

    max_attempts=$((FETCH_RETRIES > 0 ? FETCH_RETRIES : 1))
    delay=$((FETCH_RETRY_DELAY > 0 ? FETCH_RETRY_DELAY : 10))

    attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        : >"$dest"
        curl_err="$(sub_curl \
            -H "User-Agent: $SUB_USER_AGENT" \
            -H "Accept: */*" \
            -o "$dest" \
            "$url" 2>&1)"
        local curl_rc=$?

        if [ "$curl_rc" -eq 0 ] && [ -s "$dest" ]; then
            if [ "$attempt" -gt 1 ]; then
                log "  $label: fetch OK on attempt $attempt/$max_attempts."
            fi
            return 0
        fi

        if [ -n "$curl_err" ]; then
            log "  $label: attempt $attempt/$max_attempts failed — ${curl_err//$'\n'/ }"
        else
            log "  $label: attempt $attempt/$max_attempts failed — empty body."
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            log "  $label: retrying in ${delay}s…"
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    return 1
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
    log "xui-sync $XUI_SYNC_VERSION"

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

    # Temp dir for JSON + subscription bodies. Never pass large data on argv.
    local tmp_dir tmp_sources
    tmp_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/xui-sync.$$")"
    mkdir -p "$tmp_dir" 2>/dev/null
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN
    tmp_sources="$tmp_dir/sources.json"
    printf '%s' "$sources_json" >"$tmp_sources"

    # If the response is not valid JSON, the URL is wrong or WP returned HTML.
    if ! jq -e . "$tmp_sources" >/dev/null 2>&1; then
        local preview
        preview="$(tr '\n' ' ' <"$tmp_sources" | cut -c1-160)"
        log "[ERROR] Host did not return JSON (HTTP=$http_code). URL: $sources_url"
        log "        Response starts with: $preview"
        log "        Check SITE_URL is correct and the xui-vpn-manager plugin is active."
        return 1
    fi

    if [ "$(jq -r '.success // false' "$tmp_sources")" != "true" ]; then
        log "[ERROR] Host rejected request (HTTP=$http_code): $(jq -r '.msg // "unknown error"' "$tmp_sources")"
        return 1
    fi

    local count
    count="$(jq '.sources | length' "$tmp_sources")"
    if [ "$count" -eq 0 ]; then
        log "No active mobile sources configured on host. Nothing to do."
        return 0
    fi

    log "Got $count source(s)."
    ok_count=0
    fail_count=0

    local i id name sub_url pool push_resp p_ok p_msg
    local tmp_body tmp_push_resp
    tmp_body="$tmp_dir/body"
    tmp_push_resp="$tmp_dir/push_resp.json"

    for i in $(seq 0 $((count - 1))); do
        id="$(jq -r ".sources[$i].id" "$tmp_sources")"
        name="$(jq -r ".sources[$i].name" "$tmp_sources")"
        sub_url="$(jq -r ".sources[$i].sub_url" "$tmp_sources")"
        pool="$(jq -r ".sources[$i].pool // \"outbound\"" "$tmp_sources")"

        if [ -z "$sub_url" ] || [ "$sub_url" = "null" ]; then
            log "  #$id $name: sub_url is empty — skipped."
            fail_count=$((fail_count + 1))
            continue
        fi

        log "  #$id $name: fetching subscription…"
        if ! fetch_sub_to_file "$tmp_body" "$sub_url" "#$id $name"; then
            log "  #$id $name: FAILED — empty subscription body after $FETCH_RETRIES attempt(s) (DNS/proxy/VPN?)."
            fail_count=$((fail_count + 1))
            continue
        fi

        # Push: source_id + pool in query string, raw sub body as POST data.
        # Avoids jq entirely — large subs hit ARG_MAX if embedded in JSON.
        local push_target
        if [[ "$push_url" == *'?'* ]]; then
            push_target="${push_url}&source_id=${id}&pool=${pool}"
        else
            push_target="${push_url}?source_id=${id}&pool=${pool}"
        fi

        push_resp="$(api_curl \
            -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
            -H "Content-Type: text/plain; charset=utf-8" \
            -H "Accept: application/json" \
            --data-binary @"$tmp_body" \
            "$push_target")"
        printf '%s' "$push_resp" >"$tmp_push_resp"

        p_ok="$(jq -r '.success // false' "$tmp_push_resp" 2>/dev/null)"
        p_msg="$(jq -r '.msg // ""' "$tmp_push_resp" 2>/dev/null)"

        if [ "$p_ok" = "true" ]; then
            local added skipped promoted tested active
            added="$(jq -r '.added // 0' "$tmp_push_resp")"
            skipped="$(jq -r '.skipped // 0' "$tmp_push_resp")"
            promoted="$(jq -r '.promoted // 0' "$tmp_push_resp" 2>/dev/null)"
            tested="$(jq -r '.tested // 0' "$tmp_push_resp" 2>/dev/null)"
            active="$(jq -r '.active // 0' "$tmp_push_resp" 2>/dev/null)"
            if [ "${promoted:-0}" -gt 0 ] 2>/dev/null; then
                log "  #$id $name: OK — added $added, promoted $promoted, active $active. $p_msg"
            elif [ "${tested:-0}" -gt 0 ] 2>/dev/null; then
                log "  #$id $name: OK — added $added, tested $tested (staging). $p_msg"
            else
                log "  #$id $name: OK — added $added, skipped $skipped. $p_msg"
            fi
            ok_count=$((ok_count + 1))
        else
            log "  #$id $name: FAILED — ${p_msg:-$push_resp}"
            fail_count=$((fail_count + 1))
        fi
    done

    log "Cycle done. success=$ok_count fail=$fail_count"

    # Relay jobs: only when no dedicated xui-panel-relay service (avoid double-claim).
    if [ -f "$SCRIPT_DIR/panel-relay-lib.sh" ]; then
        # shellcheck source=panel-relay-lib.sh
        . "$SCRIPT_DIR/panel-relay-lib.sh"
        if should_skip_sync_relay 2>/dev/null; then
            log "Panel relay: skipped (xui-panel-relay service is active)"
        else
            process_panel_jobs_once || true
        fi
    fi

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
