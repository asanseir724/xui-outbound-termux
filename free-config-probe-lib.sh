#!/usr/bin/env bash
#
# Poll WordPress for free-config probe jobs and execute via PHP on VPS/Termux.
# Sourced by xui-sync.sh
#
# shellcheck disable=SC2034

FREE_CONFIG_PROBE_VERSION="20260714-v1"

# True when dedicated probe loop is already running (avoid duplicate workers).
should_skip_sync_probe() {
    if [ "${XUI_SYNC_SKIP_PROBE:-}" = "1" ]; then
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet xui-free-config-probe 2>/dev/null; then
        return 0
    fi
    return 1
}

process_free_config_probe_jobs_once() {
    validate_config 2>/dev/null || return 0

    if [ -z "${SITE_URL:-}" ] || [ -z "${MOBILE_TOKEN:-}" ]; then
        return 0
    fi

    local lock_dir lock_file
    lock_dir="${XUI_STATE_DIR:-${STATE_DIR:-/etc/xui-outbound}}"
    mkdir -p "$lock_dir" 2>/dev/null
    lock_file="$lock_dir/free-config-probe.lock"
    exec 8>"$lock_file"
    if command -v flock >/dev/null 2>&1; then
        if ! flock -n 8; then
            log "Free-config probe: skipped (another worker holds lock)"
            return 0
        fi
    fi

    local jobs_url result_url tmp_dir tmp_jobs http_code jobs_json probe_count
    detect_rest_style 2>/dev/null || true
    jobs_url="$(rest_url 'xui/v1/outbound-mobile/probe-jobs')"
    result_url="$(rest_url 'xui/v1/outbound-mobile/probe-result')"

    tmp_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/xui-probe.$$")"
    mkdir -p "$tmp_dir" 2>/dev/null
    tmp_jobs="$tmp_dir/jobs.json"

    local jobs_target
    jobs_target="$(append_url_param "$jobs_url" "limit=20")"

    jobs_json="$(api_curl \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        -H "Accept: application/json" \
        -w $'\n%{http_code}' \
        "$jobs_target")"
    http_code="${jobs_json##*$'\n'}"
    jobs_json="${jobs_json%$'\n'*}"

    if [ -z "$jobs_json" ]; then
        log "[WARN] probe-jobs: empty response (HTTP=${http_code:-?}) URL=$jobs_target"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    printf '%s' "$jobs_json" >"$tmp_jobs"
    if ! jq -e . "$tmp_jobs" >/dev/null 2>&1; then
        log "[WARN] probe-jobs: not JSON (HTTP=$http_code) URL=$jobs_target"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    if [ "$(jq -r '.success // false' "$tmp_jobs")" != "true" ]; then
        log "[WARN] probe-jobs: host rejected (HTTP=$http_code) URL=$jobs_target"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    local job_count pending_total
    job_count="$(jq '.jobs | length' "$tmp_jobs")"
    pending_total="$(jq -r '.pending_total // 0' "$tmp_jobs")"
    if [ "$job_count" -eq 0 ]; then
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    log "Free-config probe: $job_count job(s) (pending on host: $pending_total)"

    local script_dir php_exec i job_json exec_out ok err probe_json submit_body submit_resp jid
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    php_exec="$script_dir/free-config-probe-exec.php"
    if [ ! -f "$php_exec" ]; then
        log "[WARN] free-config-probe-exec.php not found — skip probe jobs"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi

    if [ -n "${XUI_VPN_PLUGIN_DIR:-}" ]; then
        export XUI_VPN_PLUGIN_DIR
    fi
    if [ -n "${XRAY_BIN:-}" ]; then
        export XRAY_BIN
    fi

    probe_count=0
    for i in $(seq 0 $((job_count - 1))); do
        jid="$(jq -r ".jobs[$i].id" "$tmp_jobs")"
        job_json="$(jq -c ".jobs[$i]" "$tmp_jobs")"

        exec_out="$(printf '%s' "$job_json" | php "$php_exec" 2>&1)" || true
        ok="$(printf '%s' "$exec_out" | jq -r '.ok // false' 2>/dev/null)"
        if [ "$ok" = "true" ]; then
            probe_json="$(printf '%s' "$exec_out" | jq -c '.probe' 2>/dev/null)"
            submit_body="$(jq -n --argjson job_id "$jid" --argjson probe "$probe_json" \
                '{job_id: $job_id, success: true, probe: $probe}')"
            local method ping
            method="$(printf '%s' "$probe_json" | jq -r '.method // "?"' 2>/dev/null)"
            ping="$(printf '%s' "$probe_json" | jq -r '.ping_ms // "?"' 2>/dev/null)"
            log "  probe #$jid: OK — $method ${ping}ms"
            probe_count=$((probe_count + 1))
        else
            err="$(printf '%s' "$exec_out" | jq -r '.error // "unknown"' 2>/dev/null)"
            [ -z "$err" ] || [ "$err" = "null" ] && err="${exec_out:0:200}"
            submit_body="$(jq -n --argjson job_id "$jid" --arg error "$err" \
                '{job_id: $job_id, success: false, error: $error}')"
            log "  probe #$jid: FAILED — $err"
        fi

        submit_resp="$(api_curl \
            -X POST \
            -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$submit_body" \
            "$(append_url_param "$result_url" "job_id=${jid}")")"
        if [ "$(printf '%s' "$submit_resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
            log "  probe #$jid: host rejected result — ${submit_resp:0:120}"
        fi
    done

    log "Free-config probe: completed $probe_count / $job_count"
    rm -rf "$tmp_dir" 2>/dev/null
    return 0
}
