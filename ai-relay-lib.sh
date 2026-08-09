#!/usr/bin/env bash
#
# AI chat relay — poll WordPress for LLM jobs and run via local Ollama on VPS.
# Sourced by panel-relay-lib.sh / xui-panel-relay.sh
#
# Can target a DIFFERENT WordPress than SITE_URL (panel/sync):
#   XUI_AI_SITE_URL="https://other-site.ir"
#   XUI_AI_MOBILE_TOKEN="token-from-that-site"
# If unset, falls back to SITE_URL + MOBILE_TOKEN.
#
# shellcheck disable=SC2034

AI_RELAY_VERSION="20260809-v2"

# Resolve AI WordPress target (may differ from panel SITE_URL).
ai_relay_target() {
    AI_SITE="${XUI_AI_SITE_URL:-${SITE_URL:-}}"
    AI_SITE="${AI_SITE%/}"
    AI_TOKEN="${XUI_AI_MOBILE_TOKEN:-${MOBILE_TOKEN:-}}"
}

ai_rest_url() {
    local route="$1"
    local style="${AI_REST_STYLE:-query}"
    if [ "$style" = "pretty" ]; then
        echo "${AI_SITE}/wp-json/$route"
    else
        echo "${AI_SITE}/index.php?rest_route=/$route"
    fi
}

# Detect REST style for the AI site only (cached in AI_REST_STYLE).
ai_detect_rest_style() {
    if [ -n "${AI_REST_STYLE:-}" ]; then
        return 0
    fi
    if [ "${XUI_AI_REST_FORCE_QUERY:-${REST_FORCE_QUERY:-}}" = "1" ]; then
        AI_REST_STYLE="query"
        return 0
    fi

    local code tmp
    tmp="$(mktemp 2>/dev/null || echo "/tmp/xui-ai-rest.$$")"
    code="$(api_curl -o "$tmp" -w '%{http_code}' \
        -H "X-XUI-Mobile-Token: $AI_TOKEN" \
        -H "Accept: application/json" \
        "${AI_SITE}/wp-json/xui/v1/outbound-mobile/ai-jobs?limit=1" 2>/dev/null)" || true
    if [ "$code" = "200" ] && jq -e '.success' "$tmp" >/dev/null 2>&1; then
        AI_REST_STYLE="pretty"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"

    local query_base
    for query_base in \
        "${AI_SITE}/index.php?rest_route=/xui/v1/outbound-mobile/ai-jobs" \
        "${AI_SITE}/?rest_route=/xui/v1/outbound-mobile/ai-jobs"; do
        code="$(api_curl -o "$tmp" -w '%{http_code}' \
            -H "X-XUI-Mobile-Token: $AI_TOKEN" \
            -H "Accept: application/json" \
            "${query_base}&limit=1" 2>/dev/null)" || true
        if [ "$code" = "200" ] && jq -e '.success' "$tmp" >/dev/null 2>&1; then
            AI_REST_STYLE="query"
            rm -f "$tmp"
            log "AI relay: using index.php?rest_route= for ${AI_SITE}"
            return 0
        fi
        rm -f "$tmp"
    done

    AI_REST_STYLE="query"
    return 0
}

process_ai_jobs_once() {
    ai_relay_target

    if [ -z "${AI_SITE:-}" ] || [ -z "${AI_TOKEN:-}" ]; then
        return 0
    fi

    # Reset REST cache if AI site URL changed
    if [ -n "${AI_LAST_SITE:-}" ] && [ "$AI_LAST_SITE" != "$AI_SITE" ]; then
        AI_REST_STYLE=""
    fi
    AI_LAST_SITE="$AI_SITE"

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
    ai_detect_rest_style
    jobs_url="$(ai_rest_url 'xui/v1/outbound-mobile/ai-jobs')"
    result_url="$(ai_rest_url 'xui/v1/outbound-mobile/ai-result')"

    tmp_dir="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/xui-ai-relay.$$")"
    mkdir -p "$tmp_dir" 2>/dev/null
    tmp_jobs="$tmp_dir/jobs.json"

    jobs_json="$(api_curl \
        -H "X-XUI-Mobile-Token: $AI_TOKEN" \
        -H "Accept: application/json" \
        -w $'\n%{http_code}' \
        "$(append_url_param "$jobs_url" "limit=5")")" || true
    http_code="${jobs_json##*$'\n'}"
    jobs_json="${jobs_json%$'\n'*}"

    if [ -z "$jobs_json" ]; then
        # DNS/network failure against AI site — log occasionally
        if [ "${http_code:-000}" = "000" ] || [ -z "${http_code:-}" ]; then
            log "[WARN] ai-jobs: empty response (HTTP=${http_code:-000}) site=${AI_SITE}"
        fi
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    printf '%s' "$jobs_json" >"$tmp_jobs"
    if ! jq -e . "$tmp_jobs" >/dev/null 2>&1; then
        log "[WARN] ai-jobs: not JSON (HTTP=$http_code) site=${AI_SITE}"
        rm -rf "$tmp_dir" 2>/dev/null
        return 0
    fi

    if [ "$(jq -r '.success // false' "$tmp_jobs")" != "true" ]; then
        local msg
        msg="$(jq -r '.msg // empty' "$tmp_jobs" 2>/dev/null)"
        if [ -n "$msg" ]; then
            log "[WARN] ai-jobs: $msg (site=${AI_SITE})"
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

    log "AI relay: $job_count job(s) ← ${AI_SITE}"

    local script_dir php_exec i jid job_json exec_out ok err result_json submit_body submit_resp
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    php_exec="$script_dir/ai-relay-exec.php"
    if [ ! -f "$php_exec" ]; then
        log "[WARN] ai-relay-exec.php not found — skip AI jobs"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi

    export XUI_AI_ENDPOINT="${XUI_AI_ENDPOINT:-http://127.0.0.1:11434}"
    export XUI_AI_MODEL="${XUI_AI_MODEL:-qwen2.5:1.5b}"

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
            -H "X-XUI-Mobile-Token: $AI_TOKEN" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -d "$submit_body" \
            "$(append_url_param "$result_url" "job_id=${jid}")")" || true
        if [ "$(printf '%s' "$submit_resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
            log "  ai #$jid: host rejected result — ${submit_resp:0:120}"
        fi
    done

    rm -rf "$tmp_dir" 2>/dev/null
    return 0
}
