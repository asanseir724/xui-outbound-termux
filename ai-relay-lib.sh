#!/usr/bin/env bash
#
# AI chat relay — poll WordPress for LLM jobs and run via local Ollama on VPS.
# Sourced by panel-relay-lib.sh / xui-panel-relay.sh
#
# shellcheck disable=SC2034

AI_RELAY_VERSION="20260809-v1"

process_ai_jobs_once() {
    validate_config 2>/dev/null || return 0

    if [ -z "${SITE_URL:-}" ] || [ -z "${MOBILE_TOKEN:-}" ]; then
        return 0
    fi

    local lock_dir lock_file
    lock_dir="${XUI_STATE_DIR:-${STATE_DIR:-/etc/xui-outbound}}"
    mkdir -p "$lock_dir" 2>/dev/null
    lock_file="$lock_dir/ai-relay.lock"
    exec 7>"$lock_file"
    if command -v flock >/dev/null 2>&1; then
        if ! flock -n 7; then
            log "AI relay: skipped (another worker holds lock)"
            return 0
        fi
    fi

    local jobs_url result_url tmp_dir tmp_jobs jobs_json http_code
    detect_rest_style 2>/dev/null || true
    jobs_url="$(rest_url 'xui/v1/outbound-mobile/ai-jobs')"
    result_url="$(rest_url 'xui/v1/outbound-mobile/ai-result')"

    tmp_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/xui-ai-relay.$$")"
    mkdir -p "$tmp_dir" 2>/dev/null
    tmp_jobs="$tmp_dir/jobs.json"

    jobs_json="$(api_curl \
        -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
        -H "Accept: application/json" \
        -w $'\n%{http_code}' \
        "$(append_url_param "$jobs_url" "limit=5")")"
    http_code="${jobs_json##*$'\n'}"
    jobs_json="${jobs_json%$'\n'*}"

    if [ -z "$jobs_json" ]; then
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    printf '%s' "$jobs_json" >"$tmp_jobs"
    if ! jq -e . "$tmp_jobs" >/dev/null 2>&1; then
        log "[WARN] ai-jobs: not JSON (HTTP=$http_code)"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    if [ "$(jq -r '.success // false' "$tmp_jobs")" != "true" ]; then
        # relay_mode=false is normal when WP is on direct — stay quiet
        local msg
        msg="$(jq -r '.msg // empty' "$tmp_jobs" 2>/dev/null)"
        if [ -n "$msg" ]; then
            log "[WARN] ai-jobs: $msg"
        fi
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    local job_count
    job_count="$(jq '.jobs | length' "$tmp_jobs")"
    if [ "$job_count" -eq 0 ]; then
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    log "AI relay: $job_count job(s)"

    local script_dir php_exec i jid job_json exec_out ok err result_json submit_body submit_resp
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    php_exec="$script_dir/ai-relay-exec.php"
    if [ ! -f "$php_exec" ]; then
        log "[WARN] ai-relay-exec.php not found — skip AI jobs"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi

    export XUI_AI_ENDPOINT="${XUI_AI_ENDPOINT:-http://127.0.0.1:11434}"
    export XUI_AI_MODEL="${XUI_AI_MODEL:-qwen2.5:3b}"

    for i in $(seq 0 $((job_count - 1))); do
        jid="$(jq -r ".jobs[$i].id" "$tmp_jobs")"
        job_json="$(jq -c ".jobs[$i]" "$tmp_jobs")"

        exec_out="$(printf '%s' "$job_json" | php "$php_exec" 2>&1)" || true
        ok="$(printf '%s' "$exec_out" | jq -r '.ok // false' 2>/dev/null)"
        if [ "$ok" = "true" ]; then
            result_json="$(printf '%s' "$exec_out" | jq -c '.result' 2>/dev/null)"
            submit_body="$(jq -n --argjson job_id "$jid" --argjson result "$result_json" \
                '{job_id: $job_id, success: true, result: $result}')"
            log "  ai #$jid: OK chars=$(printf '%s' "$result_json" | jq -r '.text // ""' | wc -c)"
        else
            err="$(printf '%s' "$exec_out" | jq -r '.error // "unknown"' 2>/dev/null)"
            [ -z "$err" ] || [ "$err" = "null" ] && err="${exec_out:0:200}"
            submit_body="$(jq -n --argjson job_id "$jid" --arg error "$err" \
                '{job_id: $job_id, success: false, error: $error}')"
            log "  ai #$jid: FAILED — $err"
        fi

        submit_resp="$(api_curl \
            -X POST \
            -H "X-XUI-Mobile-Token: $MOBILE_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$submit_body" \
            "$(append_url_param "$result_url" "job_id=${jid}")")"
        if [ "$(printf '%s' "$submit_resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
            log "  ai #$jid: host rejected result — ${submit_resp:0:120}"
        fi
    done

    rm -rf "$tmp_dir" 2>/dev/null
    return 0
}
