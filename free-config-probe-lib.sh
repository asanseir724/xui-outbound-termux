#!/usr/bin/env bash
#
# Poll WordPress for free-config probe jobs and execute via PHP on VPS/Termux.
# Sourced by xui-sync.sh
#
# shellcheck disable=SC2034

FREE_CONFIG_PROBE_VERSION="20260715-v7"

# Append query params without breaking ?rest_route= URLs (use & not a second ?).
append_url_param() {
    local url="$1"
    local param="$2"
    if [[ "$url" == *'?'* ]]; then
        echo "${url}&${param}"
    else
        echo "${url}?${param}"
    fi
}

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

_probe_unlock() {
    flock -u 8 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    trap - RETURN 2>/dev/null || true
}

# Kill orphaned xray probe processes whose temp config is older than 2 minutes.
cleanup_stale_probe_xray() {
    local f
    for f in /tmp/xui-xray-*.json; do
        [ -e "$f" ] || continue
        # Only delete files older than 120s (GNU find -mmin; fallback: skip age check)
        if find "$f" -mmin +2 >/dev/null 2>&1; then
            pkill -9 -f "$(basename "$f")" 2>/dev/null || true
            rm -f "$f" 2>/dev/null || true
        fi
    done
}

# Run one probe job + submit result. Increment alive counter file on success.
_probe_run_one_job() {
    local jid="$1"
    local job_json="$2"
    local php_exec="$3"
    local result_url="$4"
    local alive_file="$5"

    local target exec_out ok err probe_json submit_body submit_resp method ping alive_flag perr
    target="$(printf '%s' "$job_json" | jq -r '.config_uri // empty' 2>/dev/null \
        | sed -nE 's#.*@([^:/?#]+):([0-9]+).*#\1:\2#p')"
    [ -n "$target" ] || target="?"

    # Do not let PHP/Xray inherit the flock fd.
    exec_out="$(printf '%s' "$job_json" | php "$php_exec" 8>&- 2>&1)" || true
    ok="$(printf '%s' "$exec_out" | jq -r '.ok // false' 2>/dev/null)"
    if [ "$ok" = "true" ]; then
        probe_json="$(printf '%s' "$exec_out" | jq -c '.probe' 2>/dev/null)"
        submit_body="$(jq -n --argjson job_id "$jid" --argjson probe "$probe_json" \
            '{job_id: $job_id, success: true, probe: $probe}')"
        method="$(printf '%s' "$probe_json" | jq -r '.method // "?"' 2>/dev/null)"
        ping="$(printf '%s' "$probe_json" | jq -r '.ping_ms // "?"' 2>/dev/null)"
        alive_flag="$(printf '%s' "$probe_json" | jq -r '.alive // false' 2>/dev/null)"
        if [ "$alive_flag" = "true" ] && [ "$method" = "xray-real-delay" ]; then
            log "  probe #$jid: ALIVE — $target — xray-real-delay ${ping}ms"
            printf '1\n' >>"$alive_file"
        elif [ "$alive_flag" = "true" ]; then
            log "  probe #$jid: REJECT $target method=$method (need xray-real-delay) ${ping}ms"
        else
            perr="$(printf '%s' "$probe_json" | jq -r '.error // "dead"' 2>/dev/null)"
            log "  probe #$jid: DEAD — $target — $method — $perr"
        fi
    else
        err="$(printf '%s' "$exec_out" | jq -r '.error // "unknown"' 2>/dev/null)"
        [ -z "$err" ] || [ "$err" = "null" ] && err="${exec_out:0:200}"
        submit_body="$(jq -n --argjson job_id "$jid" --arg error "$err" \
            '{job_id: $job_id, success: false, error: $error}')"
        log "  probe #$jid: FAILED — $target — $err"
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
    # Drop any leftover fd 8 from a prior call before reopening.
    exec 8>&- 2>/dev/null || true
    exec 8>"$lock_file"
    if command -v flock >/dev/null 2>&1; then
        if ! flock -n 8; then
            log "Free-config probe: skipped (another worker holds lock) pid=$$"
            exec 8>&- 2>/dev/null || true
            return 0
        fi
    fi
    # Never keep the lock across the loop's sleep interval.
    trap '_probe_unlock' RETURN

    cleanup_stale_probe_xray

    local jobs_url result_url tmp_dir tmp_jobs http_code jobs_json probe_count
    local batch_limit parallel
    batch_limit="${PROBE_BATCH_LIMIT:-40}"
    parallel="${PROBE_PARALLEL:-4}"
    if [ "$batch_limit" -lt 5 ] 2>/dev/null; then batch_limit=5; fi
    if [ "$batch_limit" -gt 40 ] 2>/dev/null; then batch_limit=40; fi
    if [ "$parallel" -lt 1 ] 2>/dev/null; then parallel=1; fi
    if [ "$parallel" -gt 8 ] 2>/dev/null; then parallel=8; fi

    detect_rest_style 2>/dev/null || true
    jobs_url="$(rest_url 'xui/v1/outbound-mobile/probe-jobs')"
    result_url="$(rest_url 'xui/v1/outbound-mobile/probe-result')"

    tmp_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/xui-probe.$$")"
    mkdir -p "$tmp_dir" 2>/dev/null
    tmp_jobs="$tmp_dir/jobs.json"

    local jobs_target
    jobs_target="$(append_url_param "$jobs_url" "limit=${batch_limit}")"

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

    log "Free-config probe: $job_count job(s) (pending on host: $pending_total) parallel=$parallel"

    local script_dir php_exec i job_json jid alive_file
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

    alive_file="$tmp_dir/alive.count"
    : >"$alive_file"

    for i in $(seq 0 $((job_count - 1))); do
        jid="$(jq -r ".jobs[$i].id" "$tmp_jobs")"
        job_json="$(jq -c ".jobs[$i]" "$tmp_jobs")"
        _probe_run_one_job "$jid" "$job_json" "$php_exec" "$result_url" "$alive_file" &
        while [ "$(jobs -rp | wc -l)" -ge "$parallel" ]; do
            wait -n 2>/dev/null || wait || sleep 0.2
        done
    done
    wait

    probe_count=0
    if [ -f "$alive_file" ]; then
        probe_count="$(wc -l <"$alive_file" | tr -d ' ')"
    fi

    cleanup_stale_probe_xray
    log "Free-config probe: batch done - alive $probe_count / $job_count"
    rm -rf "$tmp_dir" 2>/dev/null
    return 0
}
