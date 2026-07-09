#!/usr/bin/env bash
#
# Shared panel-relay helpers — poll WordPress for X-UI API jobs and execute via PHP.
# Sourced by xui-sync.sh and xui-panel-relay.sh
#
# shellcheck disable=SC2034

PANEL_RELAY_VERSION="20260709-v3"

process_panel_jobs_once() {
    validate_config 2>/dev/null || return 0

    if [ -z "${SITE_URL:-}" ] || [ -z "${MOBILE_TOKEN:-}" ]; then
        return 0
    fi

    local jobs_url result_url tmp_dir tmp_jobs http_code jobs_json relay_count
    detect_rest_style 2>/dev/null || true
    jobs_url="$(rest_url 'xui/v1/outbound-mobile/panel-jobs')"
    result_url="$(rest_url 'xui/v1/outbound-mobile/panel-result')"

    tmp_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/xui-relay.$$")"
    mkdir -p "$tmp_dir" 2>/dev/null
    tmp_jobs="$tmp_dir/jobs.json"

    jobs_json="$(api_curl \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        -H "Accept: application/json" \
        -w $'\n%{http_code}' \
        "$jobs_url?limit=15")"
    http_code="${jobs_json##*$'\n'}"
    jobs_json="${jobs_json%$'\n'*}"

    if [ -z "$jobs_json" ]; then
        log "[WARN] panel-jobs: empty response (HTTP=${http_code:-?}) from $jobs_url — check SITE_URL / DNS"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    printf '%s' "$jobs_json" >"$tmp_jobs"
    if ! jq -e . "$tmp_jobs" >/dev/null 2>&1; then
        log "[WARN] panel-jobs: not JSON (HTTP=$http_code) — try REST_FORCE_QUERY=1 in config.sh"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    if [ "$(jq -r '.success // false' "$tmp_jobs")" != "true" ]; then
        log "[WARN] panel-jobs: host rejected request (HTTP=$http_code): $(jq -r '.msg // "unknown"' "$tmp_jobs" 2>/dev/null)"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    relay_count="$(jq -r '.relay_panels // 0' "$tmp_jobs")"
    local job_count
    job_count="$(jq '.jobs | length' "$tmp_jobs")"
    if [ "$job_count" -eq 0 ]; then
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    log "Panel relay: $job_count job(s) (relay panels on host: $relay_count)"

    local script_dir php_exec i job_json exec_out ok err result_json submit_body submit_resp
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    php_exec="$script_dir/panel-relay-exec.php"
    if [ ! -f "$php_exec" ]; then
        log "[WARN] panel-relay-exec.php not found — skip panel jobs"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi

    for i in $(seq 0 $((job_count - 1))); do
        local jid pname
        jid="$(jq -r ".jobs[$i].id" "$tmp_jobs")"
        pname="$(jq -r ".jobs[$i].panel_name // \"panel\"" "$tmp_jobs")"
        job_json="$(jq -c ".jobs[$i]" "$tmp_jobs")"

        exec_out="$(printf '%s' "$job_json" | php "$php_exec" 2>&1)" || true
        ok="$(printf '%s' "$exec_out" | jq -r '.ok // false' 2>/dev/null)"
        if [ "$ok" = "true" ]; then
            result_json="$(printf '%s' "$exec_out" | jq -c '.result')"
            submit_body="$(jq -n --argjson job_id "$jid" --argjson result "$result_json" \
                '{job_id: $job_id, success: true, result: $result}')"
            log "  job #$jid ($pname): OK"
        else
            err="$(printf '%s' "$exec_out" | jq -r '.error // "unknown"' 2>/dev/null)"
            [ -z "$err" ] || [ "$err" = "null" ] && err="${exec_out:0:200}"
            submit_body="$(jq -n --argjson job_id "$jid" --arg error "$err" \
                '{job_id: $job_id, success: false, error: $error}')"
            log "  job #$jid ($pname): FAILED — $err"
        fi

        submit_resp="$(api_curl \
            -X POST \
            -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$submit_body" \
            "$result_url")"
        if [ "$(printf '%s' "$submit_resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
            log "  job #$jid: host rejected result — ${submit_resp:0:120}"
        fi
    done

    rm -rf "$tmp_dir" 2>/dev/null
    return 0
}
