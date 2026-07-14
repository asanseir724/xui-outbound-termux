<?php
namespace XuiVpn\Services;

/**
 * Fetch subscription config links and push them as Xray outbounds into 3x-ui panels.
 */
class OutboundSyncService {

    /**
     * @param array<string,mixed> $source
     * @return array{success:bool,links:array<int,string>,msg?:string}
     */
    public function fetch_sub_links_for_source(array $source): array {
        $sub_url = trim((string) ($source['sub_url'] ?? ''));
        if ($sub_url === '') {
            return ['success' => false, 'links' => [], 'msg' => 'آدرس ساب خالی است'];
        }

        $mode = strtolower(trim((string) ($source['fetch_mode'] ?? 'direct')));
        if ($mode === 'mobile' || $mode === 'relay') {
            return [
                'success' => false,
                'links'   => [],
                'msg'     => 'این منبع از اپ اندروید دریافت می‌شود — از اپ موبایل Push کنید.',
            ];
        }

        return $this->fetch_sub_links($sub_url);
    }

    /**
     * @return array{success:bool,links:array<int,string>,msg?:string}
     */
    public function fetch_sub_links(string $sub_url, array $extra_args = []): array {
        $sub_url = trim($sub_url);
        if ($sub_url === '') {
            return ['success' => false, 'links' => [], 'msg' => 'Empty sub URL'];
        }

        if (preg_match('/^(vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\/\//i', $sub_url)) {
            return ['success' => true, 'links' => [$sub_url]];
        }

        $timeout = max(10, (int) get_option('xui_outbound_fetch_timeout', 30));

        $args = array_merge([
            'timeout'     => $timeout,
            'redirection' => 5,
            'sslverify'   => false,
            'headers'     => [
                'User-Agent'      => 'HiddifyNext/4.1.0 (Android) v2rayNG/1.8.0',
                'Accept'          => '*/*',
                'Accept-Encoding' => 'identity',
            ],
        ], $extra_args);

        $response = $this->remote_get_with_timeout($sub_url, $args, $timeout);

        if (is_wp_error($response)) {
            return [
                'success' => false,
                'links'   => [],
                'msg'     => 'دریافت ساب ناموفق: ' . $response->get_error_message()
                    . ' (برای ساب خارجی حالت «اپ اندروید» را انتخاب کنید)',
            ];
        }

        $http_code = (int) wp_remote_retrieve_response_code($response);
        $body      = trim((string) wp_remote_retrieve_body($response));
        if ($http_code !== 200 || $body === '') {
            return [
                'success' => false,
                'links'   => [],
                'msg'     => "دریافت ساب ناموفق: HTTP {$http_code} یا بدنه خالی",
            ];
        }

        return $this->parse_sub_body($body);
    }

    /**
     * @return array{success:bool,links:array<int,string>,msg?:string}
     */
    public function parse_sub_body(string $body): array {
        $body = trim($body);
        if ($body === '') {
            return [
                'success' => false,
                'links'   => [],
                'msg'     => 'هیچ لینک معتبر vless/vmess/trojan/ss در ساب یافت نشد',
            ];
        }

        // Some providers return a JSON array of config URIs instead of base64 lines.
        if ($body[0] === '[' || $body[0] === '{') {
            $json = json_decode($body, true);
            if (is_array($json)) {
                $json_lines = [];
                $items = isset($json['links']) && is_array($json['links']) ? $json['links'] : $json;
                foreach ($items as $item) {
                    if (is_string($item)) {
                        $json_lines[] = trim($item);
                    } elseif (is_array($item) && !empty($item['url']) && is_string($item['url'])) {
                        $json_lines[] = trim($item['url']);
                    }
                }
                $json_valid = SubscriptionService::filter_protocol_config_lines($json_lines);
                if ($json_valid !== []) {
                    return ['success' => true, 'links' => $json_valid];
                }
            }
        }

        $decoded = base64_decode($body, true);
        if ($decoded === false || trim($decoded) === '') {
            $decoded = $body;
        } else {
            $inner = base64_decode(trim($decoded), true);
            if ($inner !== false && trim($inner) !== '') {
                $inner_lines = array_filter(array_map('trim', preg_split('/\r?\n/', $inner)));
                if (SubscriptionService::filter_protocol_config_lines($inner_lines) !== []
                    || preg_match('/^(vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\/\//im', $inner)) {
                    $decoded = $inner;
                }
            }
        }

        $lines = SubscriptionService::filter_protocol_config_lines(
            array_filter(array_map('trim', preg_split('/\r?\n/', (string) $decoded)))
        );

        if ($lines === []) {
            return [
                'success' => false,
                'links'   => [],
                'msg'     => 'هیچ لینک معتبر vless/vmess/trojan/ss در ساب یافت نشد',
            ];
        }

        return ['success' => true, 'links' => $lines];
    }

    /**
     * @param array<string,mixed> $args
     * @return array|\WP_Error
     */
    private function remote_get_with_timeout(string $url, array $args, int $timeout) {
        $force_timeout = static function () use ($timeout) {
            return $timeout;
        };
        add_filter('http_request_timeout', $force_timeout, 99);
        add_filter('http_request_args', $force_timeout_args = static function ($a) use ($timeout) {
            $a['timeout'] = $timeout;
            return $a;
        }, 99);

        $response = wp_remote_get($url, $args);

        remove_filter('http_request_timeout', $force_timeout, 99);
        remove_filter('http_request_args', $force_timeout_args, 99);

        return $response;
    }

    /**
     * @return array{tag:string,outbound:array<string,mixed>}|null
     */
    public function parse_link_to_outbound(string $uri, string $tag_prefix = 'ob'): ?array {
        $uri = trim($uri);
        if ($uri === '') {
            return null;
        }

        $scheme = strtolower((string) parse_url($uri, PHP_URL_SCHEME));
        $outbound = null;
        $fingerprint_core = '';

        switch ($scheme) {
            case 'vless':
                $parsed = $this->parse_vless_uri($uri);
                if ($parsed === null) {
                    return null;
                }
                $outbound = $parsed['outbound'];
                $fingerprint_core = $parsed['fingerprint'];
                break;
            case 'vmess':
                $parsed = $this->parse_vmess_uri($uri);
                if ($parsed === null) {
                    return null;
                }
                $outbound = $parsed['outbound'];
                $fingerprint_core = $parsed['fingerprint'];
                break;
            case 'trojan':
                $parsed = $this->parse_trojan_uri($uri);
                if ($parsed === null) {
                    return null;
                }
                $outbound = $parsed['outbound'];
                $fingerprint_core = $parsed['fingerprint'];
                break;
            case 'ss':
                $parsed = $this->parse_ss_uri($uri);
                if ($parsed === null) {
                    return null;
                }
                $outbound = $parsed['outbound'];
                $fingerprint_core = $parsed['fingerprint'];
                break;
            default:
                return null;
        }

        $tag = $this->build_outbound_tag($tag_prefix, $fingerprint_core);
        $outbound['tag'] = $tag;

        return ['tag' => $tag, 'outbound' => $this->normalize_outbound_for_panel($outbound)];
    }

    public function build_outbound_tag(string $prefix, string $fingerprint_core): string {
        $prefix = $this->sanitize_tag($prefix !== '' ? $prefix : 'ob');
        $hash   = substr(md5(strtolower(trim($fingerprint_core))), 0, 10);
        return $prefix . '_' . $hash;
    }

    /**
     * @return array<string,mixed>
     */
    public function sync_source(int $source_id): array {
        global $wpdb;

        $sources_table = $wpdb->prefix . 'xui_outbound_sources';
        $targets_table = $wpdb->prefix . 'xui_outbound_source_targets';
        $panels_table  = $wpdb->prefix . 'xui_panels';

        $source = $wpdb->get_row($wpdb->prepare(
            "SELECT * FROM {$sources_table} WHERE id = %d",
            $source_id
        ), ARRAY_A);

        if (!$source) {
            return [
                'success' => false,
                'msg'     => 'Source not found',
                'added'   => 0,
                'skipped' => 0,
                'errors'  => [],
            ];
        }

        $targets = $wpdb->get_results($wpdb->prepare(
            "SELECT t.*, p.name AS panel_name, p.url AS panel_url, p.username AS panel_user, p.password AS panel_pass
             FROM {$targets_table} t
             INNER JOIN {$panels_table} p ON p.id = t.panel_id
             WHERE t.source_id = %d AND p.is_active = 1",
            $source_id
        ), ARRAY_A);

        if (empty($targets)) {
            $result = [
                'success' => false,
                'msg'     => 'No active panel targets configured',
                'added'   => 0,
                'skipped' => 0,
                'errors'  => ['No panel targets'],
            ];
            $this->update_source_status((int) $source_id, $result);
            return $result;
        }

        $fetch = $this->fetch_sub_links_for_source($source);
        if (!$fetch['success']) {
            $result = [
                'success' => false,
                'msg'     => $fetch['msg'] ?? 'Fetch failed',
                'added'   => 0,
                'skipped' => 0,
                'errors'  => [(string) ($fetch['msg'] ?? 'Fetch failed')],
            ];
            $this->update_source_status((int) $source_id, $result);
            return $result;
        }

        return $this->sync_source_with_links($source_id, $fetch['links'], $source, $targets);
    }

    /**
     * @param array<string,mixed>      $source
     * @param list<array<string,mixed>> $targets
     * @param list<string>             $links
     * @return array<string,mixed>
     */
    public function sync_source_with_links(int $source_id, array $links, ?array $source = null, ?array $targets = null): array {
        global $wpdb;

        $sources_table = $wpdb->prefix . 'xui_outbound_sources';
        $targets_table = $wpdb->prefix . 'xui_outbound_source_targets';
        $panels_table  = $wpdb->prefix . 'xui_panels';

        if ($source === null) {
            $source = $wpdb->get_row($wpdb->prepare(
                "SELECT * FROM {$sources_table} WHERE id = %d",
                $source_id
            ), ARRAY_A);
        }

        if (!$source) {
            return [
                'success' => false,
                'msg'     => 'Source not found',
                'added'   => 0,
                'skipped' => 0,
                'errors'  => [],
            ];
        }

        if ($targets === null) {
            $targets = $wpdb->get_results($wpdb->prepare(
                "SELECT t.*, p.name AS panel_name, p.url AS panel_url, p.username AS panel_user, p.password AS panel_pass
                 FROM {$targets_table} t
                 INNER JOIN {$panels_table} p ON p.id = t.panel_id
                 WHERE t.source_id = %d AND p.is_active = 1",
                $source_id
            ), ARRAY_A);
        }

        if (empty($targets)) {
            $result = [
                'success' => false,
                'msg'     => 'No active panel targets configured',
                'added'   => 0,
                'skipped' => 0,
                'errors'  => ['No panel targets'],
            ];
            $this->update_source_status((int) $source_id, $result);
            return $result;
        }

        $tag_prefix = trim((string) ($source['tag_prefix'] ?? 'ob'));
        // Subscription links are ephemeral: any previously-added outbound that is
        // no longer in the freshly fetched list is dead and must be pruned so the
        // panel only keeps the current configs.
        $result = $this->push_links_to_targets($links, $targets, $tag_prefix, false, true);

        $this->update_source_status((int) $source_id, $result);
        return $result;
    }

    /**
     * Parse a set of config links and push them as outbounds into the given panel targets.
     * Targets must contain: panel_id, balancer_tag, panel_name, panel_url, panel_user, panel_pass.
     *
     * @param list<string>              $links
     * @param list<array<string,mixed>> $targets
     * @return array<string,mixed>
     */
    public function push_links_to_targets(array $links, array $targets, string $tag_prefix = 'ob', bool $replace = false, bool $prune_stale = false): array {
        $tag_prefix = trim($tag_prefix) !== '' ? trim($tag_prefix) : 'ob';
        $parsed_outbounds = [];
        $parse_errors = [];

        foreach ($links as $idx => $link) {
            $parsed = $this->parse_link_to_outbound((string) $link, $tag_prefix);
            if ($parsed === null) {
                $parse_errors[] = 'Unsupported or invalid link: ' . substr((string) $link, 0, 80);
                continue;
            }
            $tag = (string) ($parsed['tag'] ?? '');
            if ($tag === '') {
                continue;
            }
            // Same server fingerprint can appear multiple times in large subs — keep each line.
            if (isset($parsed_outbounds[$tag])) {
                $tag = $this->build_outbound_tag($tag_prefix, $tag . '|' . $idx);
                $parsed['outbound']['tag'] = $tag;
            }
            $parsed_outbounds[$tag] = $parsed['outbound'];
        }

        if ($parsed_outbounds === []) {
            return [
                'success' => false,
                'msg'     => 'No links could be parsed to outbounds',
                'added'   => 0,
                'skipped' => 0,
                'removed' => 0,
                'errors'  => $parse_errors,
                'panels'  => [],
            ];
        }

        $total_added   = 0;
        $total_skipped = 0;
        $total_removed = 0;
        $errors        = $parse_errors;
        $panel_reports = [];

        foreach ($targets as $target) {
            $panel_id     = (int) ($target['panel_id'] ?? 0);
            $balancer_tag = trim((string) ($target['balancer_tag'] ?? ''));
            $panel_name   = (string) ($target['panel_name'] ?? ('Panel #' . $panel_id));

            if ($panel_id <= 0) {
                continue;
            }
            if ($balancer_tag === '') {
                $errors[] = "{$panel_name}: balancer tag is empty";
                continue;
            }

            $panel_result = $this->sync_outbounds_to_panel(
                (string) ($target['panel_url'] ?? ''),
                (string) ($target['panel_user'] ?? ''),
                (string) ($target['panel_pass'] ?? ''),
                $balancer_tag,
                array_values($parsed_outbounds),
                $replace,
                $tag_prefix,
                $prune_stale,
                $panel_id
            );

            $total_added   += (int) ($panel_result['added'] ?? 0);
            $total_skipped += (int) ($panel_result['skipped'] ?? 0);
            $total_removed += (int) ($panel_result['removed'] ?? 0);
            if (!empty($panel_result['errors'])) {
                foreach ($panel_result['errors'] as $err) {
                    $errors[] = "{$panel_name}: {$err}";
                }
            }

            $panel_reports[] = [
                'panel'   => $panel_name,
                'added'   => (int) ($panel_result['added'] ?? 0),
                'skipped' => (int) ($panel_result['skipped'] ?? 0),
                'removed' => (int) ($panel_result['removed'] ?? 0),
                'success' => !empty($panel_result['success']),
            ];
        }

        $success = $panel_reports !== [] && empty(array_filter($panel_reports, static function ($r) {
            return empty($r['success']);
        }));
        $msg_parts = [];
        foreach ($panel_reports as $rep) {
            $msg_parts[] = sprintf(
                '%s: +%d / skip %d%s',
                $rep['panel'],
                $rep['added'],
                $rep['skipped'],
                !empty($rep['removed']) ? ' / del ' . $rep['removed'] : ''
            );
        }

        return [
            'success' => $success,
            'msg'     => $msg_parts !== [] ? implode(' | ', $msg_parts) : 'No panel updated',
            'added'   => $total_added,
            'skipped' => $total_skipped,
            'removed' => $total_removed,
            'errors'  => $errors,
            'panels'  => $panel_reports,
        ];
    }

    /**
     * Manually register a pasted list of config links (or a base64 sub body) into panels/balancers.
     * No source row required — looks up panel credentials by id.
     *
     * @param list<array{panel_id:int,balancer_tag:string}> $panel_targets
     * @return array<string,mixed>
     */
    public function sync_manual_text(string $raw_text, array $panel_targets, string $tag_prefix = 'ob', bool $replace = false): array {
        $raw_text = trim($raw_text);
        if ($raw_text === '') {
            return [
                'success' => false,
                'msg'     => 'لیست کانفیگ خالی است',
                'added'   => 0,
                'skipped' => 0,
                'removed' => 0,
                'errors'  => ['Empty config list'],
                'panels'  => [],
            ];
        }

        $parsed = $this->parse_sub_body($raw_text);
        if (!$parsed['success']) {
            return [
                'success' => false,
                'msg'     => $parsed['msg'] ?? 'هیچ لینک معتبری یافت نشد',
                'added'   => 0,
                'skipped' => 0,
                'removed' => 0,
                'errors'  => [(string) ($parsed['msg'] ?? 'No valid links')],
                'panels'  => [],
            ];
        }

        $targets = $this->build_targets_from_ids($panel_targets);
        if ($targets === []) {
            return [
                'success' => false,
                'msg'     => 'هیچ پنل/بالانسر معتبری انتخاب نشده',
                'added'   => 0,
                'skipped' => 0,
                'removed' => 0,
                'errors'  => ['No valid panel/balancer target'],
                'panels'  => [],
            ];
        }

        return $this->push_links_to_targets($parsed['links'], $targets, $tag_prefix, $replace);
    }

    /**
     * Resolve panel credentials for manual targets.
     *
     * @param list<array{panel_id:int,balancer_tag:string}> $panel_targets
     * @return list<array<string,mixed>>
     */
    private function build_targets_from_ids(array $panel_targets): array {
        global $wpdb;
        $panels_table = $wpdb->prefix . 'xui_panels';
        $targets = [];

        foreach ($panel_targets as $pt) {
            $panel_id     = (int) ($pt['panel_id'] ?? 0);
            $balancer_tag = trim((string) ($pt['balancer_tag'] ?? ''));
            if ($panel_id <= 0 || $balancer_tag === '') {
                continue;
            }

            $panel = $wpdb->get_row($wpdb->prepare(
                "SELECT id, name, url, username, password FROM {$panels_table} WHERE id = %d",
                $panel_id
            ), ARRAY_A);

            if (!$panel) {
                continue;
            }

            $targets[] = [
                'panel_id'     => $panel_id,
                'balancer_tag' => $balancer_tag,
                'panel_name'   => (string) ($panel['name'] ?? ('Panel #' . $panel_id)),
                'panel_url'    => (string) ($panel['url'] ?? ''),
                'panel_user'   => (string) ($panel['username'] ?? ''),
                'panel_pass'   => (string) ($panel['password'] ?? ''),
            ];
        }

        return $targets;
    }

    /**
     * @return array<string,mixed>
     */
    public function sync_source_with_body(int $source_id, string $body): array {
        $parsed = $this->parse_sub_body($body);
        if (!$parsed['success']) {
            $result = [
                'success' => false,
                'msg'     => $parsed['msg'] ?? 'Invalid sub body',
                'added'   => 0,
                'skipped' => 0,
                'errors'  => [(string) ($parsed['msg'] ?? 'Invalid sub body')],
            ];
            $this->update_source_status($source_id, $result);
            return $result;
        }

        return $this->sync_source_with_links($source_id, $parsed['links']);
    }

    /**
     * Cron: only sources fetched directly from WP (mobile sources use Android app).
     *
     * @return array<string,mixed>
     */
    public function sync_all_active(): array {
        global $wpdb;
        $table = $wpdb->prefix . 'xui_outbound_sources';
        $ids = $wpdb->get_col(
            "SELECT id FROM {$table}
             WHERE is_active = 1
               AND (fetch_mode = 'direct' OR fetch_mode = 'proxy' OR fetch_mode IS NULL OR fetch_mode = '')
             ORDER BY id ASC"
        );
        $ids = is_array($ids) ? array_map('intval', $ids) : [];

        $summary = [
            'sources' => count($ids),
            'added'   => 0,
            'skipped' => 0,
            'removed' => 0,
            'errors'  => [],
            'details' => [],
        ];

        foreach ($ids as $source_id) {
            $res = $this->sync_source($source_id);
            $summary['added']   += (int) ($res['added'] ?? 0);
            $summary['skipped'] += (int) ($res['skipped'] ?? 0);
            $summary['removed'] += (int) ($res['removed'] ?? 0);
            if (!empty($res['errors'])) {
                foreach ($res['errors'] as $err) {
                    $summary['errors'][] = "Source #{$source_id}: {$err}";
                }
            }
            $summary['details'][$source_id] = $res;
        }

        update_option('xui_outbound_sync_last_run', time(), false);
        update_option('xui_outbound_sync_last_summary', wp_json_encode($summary, JSON_UNESCAPED_UNICODE), false);

        return $summary;
    }

    /**
     * Cron entry: ping every registered outbound on every active source's panels,
     * keep the reachable ones and evict those that fail repeatedly.
     *
     * @return array<string,mixed>
     */
    public function test_and_prune_all_active(): array {
        global $wpdb;
        $sources_table = $wpdb->prefix . 'xui_outbound_sources';
        $targets_table = $wpdb->prefix . 'xui_outbound_source_targets';
        $panels_table  = $wpdb->prefix . 'xui_panels';

        $targets = $wpdb->get_results(
            "SELECT t.panel_id, t.balancer_tag, s.tag_prefix,
                    p.name AS panel_name, p.url AS panel_url, p.username AS panel_user, p.password AS panel_pass
             FROM {$targets_table} t
             INNER JOIN {$sources_table} s ON s.id = t.source_id
             INNER JOIN {$panels_table}  p ON p.id = t.panel_id
             WHERE s.is_active = 1 AND p.is_active = 1
             ORDER BY t.panel_id ASC",
            ARRAY_A
        );
        $targets = is_array($targets) ? $targets : [];

        $summary = $this->prune_targets($targets);

        update_option('xui_outbound_test_last_run', time(), false);
        update_option('xui_outbound_test_last_summary', wp_json_encode($summary, JSON_UNESCAPED_UNICODE), false);

        return $summary;
    }

    /**
     * Test + prune the outbounds belonging to a single source's panels.
     *
     * @return array<string,mixed>
     */
    public function test_and_prune_source(int $source_id): array {
        global $wpdb;
        $sources_table = $wpdb->prefix . 'xui_outbound_sources';
        $targets_table = $wpdb->prefix . 'xui_outbound_source_targets';
        $panels_table  = $wpdb->prefix . 'xui_panels';

        $targets = $wpdb->get_results($wpdb->prepare(
            "SELECT t.panel_id, t.balancer_tag, s.tag_prefix,
                    p.name AS panel_name, p.url AS panel_url, p.username AS panel_user, p.password AS panel_pass
             FROM {$targets_table} t
             INNER JOIN {$sources_table} s ON s.id = t.source_id
             INNER JOIN {$panels_table}  p ON p.id = t.panel_id
             WHERE t.source_id = %d AND p.is_active = 1
             ORDER BY t.panel_id ASC",
            $source_id
        ), ARRAY_A);
        $targets = is_array($targets) ? $targets : [];

        return $this->prune_targets($targets);
    }

    /**
     * @param list<array<string,mixed>> $targets
     * @return array<string,mixed>
     */
    private function prune_targets(array $targets): array {
        $summary = [
            'panels'       => 0,
            'tested'       => 0,
            'passed'       => 0,
            'failed'       => 0,
            'removed'      => 0,
            'inconclusive' => 0,
            'errors'       => [],
            'details'      => [],
        ];

        if ($targets === []) {
            $summary['errors'][] = 'No active panel targets';
            return $summary;
        }

        $deadline = time() + $this->test_time_budget();

        foreach ($targets as $target) {
            if (time() >= $deadline) {
                break;
            }
            $panel_id   = (int) ($target['panel_id'] ?? 0);
            $panel_name = (string) ($target['panel_name'] ?? ('Panel #' . $panel_id));
            $res = $this->test_and_prune_panel(
                (string) ($target['panel_url'] ?? ''),
                (string) ($target['panel_user'] ?? ''),
                (string) ($target['panel_pass'] ?? ''),
                (string) ($target['balancer_tag'] ?? ''),
                (string) ($target['tag_prefix'] ?? 'ob'),
                $panel_id,
                $deadline
            );

            $summary['panels']++;
            $summary['tested']       += (int) ($res['tested'] ?? 0);
            $summary['passed']       += (int) ($res['passed'] ?? 0);
            $summary['failed']       += (int) ($res['failed'] ?? 0);
            $summary['removed']      += (int) ($res['removed'] ?? 0);
            $summary['inconclusive'] += (int) ($res['inconclusive'] ?? 0);
            foreach ((array) ($res['errors'] ?? []) as $err) {
                $summary['errors'][] = "{$panel_name}: {$err}";
            }
            $summary['details'][] = ['panel' => $panel_name] + $res;
        }

        $summary['success'] = $summary['errors'] === [];
        return $summary;
    }

    /**
     * Test all prefix outbounds on one panel and remove those that fail the
     * configured number of consecutive checks.
     *
     * @return array{success:bool,tested:int,passed:int,failed:int,removed:int,inconclusive:int,errors:list<string>}
     */
    private function test_and_prune_panel(
        string $panel_url,
        string $username,
        string $password,
        string $balancer_tag,
        string $tag_prefix,
        int $panel_id,
        int $deadline
    ): array {
        $result = ['success' => false, 'tested' => 0, 'passed' => 0, 'failed' => 0, 'removed' => 0, 'inconclusive' => 0, 'errors' => []];

        $prefix = $this->sanitize_tag($tag_prefix !== '' ? $tag_prefix : 'ob');
        if ($panel_url === '' || $username === '') {
            $result['errors'][] = 'Invalid panel credentials';
            return $result;
        }

        $api = XuiApiService::from_credentials($panel_url, $username, $password, $panel_id);
        if (!$api->login()) {
            $result['errors'][] = $api->get_last_error() ?: 'Login failed';
            return $result;
        }

        $cfg_res = $api->get_xray_config();
        if (empty($cfg_res['success']) || !is_array($cfg_res['config'])) {
            $result['errors'][] = (string) ($cfg_res['msg'] ?? 'Could not read xray config');
            return $result;
        }

        $config    = $cfg_res['config'];
        $outbounds = (isset($config['outbounds']) && is_array($config['outbounds'])) ? $config['outbounds'] : [];
        $test_url  = (string) ($cfg_res['outbound_test_url'] ?? '');

        // Collect prefix outbounds (tag => outbound) preserving order.
        $prefix_obs = [];
        foreach ($outbounds as $ob) {
            if (!is_array($ob)) {
                continue;
            }
            $tag = (string) ($ob['tag'] ?? '');
            if ($tag !== '' && $this->tag_has_prefix($tag, $prefix)) {
                $prefix_obs[$tag] = $ob;
            }
        }
        if ($prefix_obs === []) {
            $result['success'] = true;
            return $result;
        }

        $threshold = $this->test_max_strikes();
        $strikes   = $this->load_strikes();
        $remove    = [];
        $present   = [];

        foreach ($prefix_obs as $tag => $ob) {
            if (time() >= $deadline) {
                break;
            }
            $present[$tag] = true;
            $key = $panel_id . '|' . $tag;
            $result['tested']++;

            $r = $api->test_outbound($ob, $outbounds, $test_url, 'tcp');

            if (!empty($r['inconclusive'])) {
                $result['inconclusive']++;
                continue;
            }

            if (!empty($r['ok'])) {
                $result['passed']++;
                unset($strikes[$key]);
                continue;
            }

            $result['failed']++;
            $count = (int) ($strikes[$key] ?? 0) + 1;
            if ($count >= $threshold) {
                $remove[$tag] = true;
                unset($strikes[$key]);
            } else {
                $strikes[$key] = $count;
            }
        }

        // Drop strike entries for this panel whose outbound no longer exists.
        foreach ($strikes as $key => $_) {
            if (strpos((string) $key, $panel_id . '|') !== 0) {
                continue;
            }
            $tag = substr((string) $key, strlen($panel_id . '|'));
            if (!isset($present[$tag]) && $this->tag_has_prefix($tag, $prefix)) {
                unset($strikes[$key]);
            }
        }

        $changed = false;
        if ($remove !== []) {
            $kept = [];
            foreach ($config['outbounds'] as $ob) {
                $tag = is_array($ob) ? (string) ($ob['tag'] ?? '') : '';
                if ($tag !== '' && isset($remove[$tag])) {
                    $result['removed']++;
                    continue;
                }
                $kept[] = $ob;
            }
            $config['outbounds'] = array_values($kept);

            $balancers = $config['routing']['balancers'] ?? [];
            if (is_array($balancers)) {
                $bidx = $this->find_balancer_index($balancers, $balancer_tag);
                if ($bidx !== null) {
                    $selector = $config['routing']['balancers'][$bidx]['selector'] ?? [];
                    if (is_array($selector)) {
                        $config['routing']['balancers'][$bidx]['selector'] = array_values(array_filter(
                            $selector,
                            static function ($t) use ($remove) {
                                return !isset($remove[(string) $t]);
                            }
                        ));
                    }
                }
            }
            $changed = true;
        }

        $this->save_strikes($strikes);

        if ($changed) {
            $save = $api->update_xray_config($config, $test_url !== '' ? $test_url : null);
            if (empty($save['success'])) {
                $result['errors'][] = (string) ($save['msg'] ?? 'Failed to save xray config');
                return $result;
            }
        }

        $result['success'] = true;
        return $result;
    }

    /**
     * Consecutive failed tests before an outbound is removed.
     */
    private function test_max_strikes(): int {
        $value = (int) get_option('xui_outbound_test_max_strikes', 3);
        return $value > 0 ? $value : 3;
    }

    /**
     * Wall-clock budget (seconds) for one test/prune run; the rest continues next run.
     */
    private function test_time_budget(): int {
        $value = (int) get_option('xui_outbound_test_budget_seconds', 240);
        return $value >= 30 ? $value : 240;
    }

    /**
     * @return array<string,int>
     */
    private function load_strikes(): array {
        $raw = get_option('xui_outbound_test_strikes', '');
        $decoded = is_string($raw) ? json_decode($raw, true) : $raw;
        return is_array($decoded) ? $decoded : [];
    }

    /**
     * @param array<string,int> $strikes
     */
    private function save_strikes(array $strikes): void {
        update_option('xui_outbound_test_strikes', wp_json_encode($strikes), false);
    }

    /**
     * @param list<array<string,mixed>> $outbounds
     * @return array{success:bool,added:int,skipped:int,errors:list<string>}
     */
    private function sync_outbounds_to_panel(
        string $panel_url,
        string $username,
        string $password,
        string $balancer_tag,
        array $outbounds,
        bool $replace = false,
        string $tag_prefix = '',
        bool $prune_stale = false,
        int $panel_id = 0
    ): array {
        $result = ['success' => false, 'added' => 0, 'skipped' => 0, 'removed' => 0, 'errors' => []];

        if ($panel_url === '' || $username === '') {
            $result['errors'][] = 'Invalid panel credentials';
            return $result;
        }

        $api = XuiApiService::from_credentials($panel_url, $username, $password, $panel_id);
        if (!$api->login()) {
            $result['errors'][] = $api->get_last_error() ?: 'Login failed';
            return $result;
        }

        $cfg_res = $api->get_xray_config();
        if (empty($cfg_res['success']) || !is_array($cfg_res['config'])) {
            $result['errors'][] = $cfg_res['msg'] ?? 'Could not read xray config';
            return $result;
        }

        $config = $cfg_res['config'];
        if (!isset($config['outbounds']) || !is_array($config['outbounds'])) {
            $config['outbounds'] = [];
        }
        if (!isset($config['routing']) || !is_array($config['routing'])) {
            $config['routing'] = [];
        }
        if (!isset($config['routing']['balancers']) || !is_array($config['routing']['balancers'])) {
            $config['routing']['balancers'] = [];
        }

        $balancer_index = $this->find_balancer_index($config['routing']['balancers'], $balancer_tag);
        if ($balancer_index === null) {
            $result['errors'][] = "Balancer tag \"{$balancer_tag}\" not found in panel config";
            return $result;
        }

        $prefix        = $this->sanitize_tag($tag_prefix !== '' ? $tag_prefix : 'ob');
        $max_outbounds = $this->max_outbounds_per_source();
        $max_selector  = $this->max_balancer_selector();

        $config_changed = false;

        // Replace mode: drop every existing outbound whose tag matches the prefix
        // (both from the outbounds array and the balancer selector) before re-adding.
        if ($replace) {
            $removed_tags = [];

            $kept_outbounds = [];
            foreach ($config['outbounds'] as $ob) {
                $tag = is_array($ob) ? (string) ($ob['tag'] ?? '') : '';
                if ($tag !== '' && $this->tag_has_prefix($tag, $prefix)) {
                    $removed_tags[$tag] = true;
                    $result['removed']++;
                    continue;
                }
                $kept_outbounds[] = $ob;
            }

            if ($result['removed'] > 0) {
                $config['outbounds'] = array_values($kept_outbounds);
                $config_changed = true;

                $selector = $config['routing']['balancers'][$balancer_index]['selector'] ?? [];
                if (is_array($selector)) {
                    $config['routing']['balancers'][$balancer_index]['selector'] = array_values(
                        array_filter($selector, static function ($tag) use ($removed_tags) {
                            return !isset($removed_tags[(string) $tag]);
                        })
                    );
                }
            }
        }

        $existing_tags = [];
        foreach ($config['outbounds'] as $ob) {
            if (is_array($ob) && !empty($ob['tag'])) {
                $existing_tags[(string) $ob['tag']] = true;
            }
        }

        // Tags present in the current incoming list — these are still actively
        // served, so they are protected from cap eviction below.
        $incoming_tags = [];
        foreach ($outbounds as $ob) {
            $ob = $this->normalize_outbound_for_panel($ob);
            $tag = (string) ($ob['tag'] ?? '');
            if ($tag === '') {
                continue;
            }
            $incoming_tags[$tag] = true;
            if (isset($existing_tags[$tag])) {
                $existing_idx = $this->find_outbound_index_by_tag($config['outbounds'], $tag);
                if ($existing_idx !== null && $this->is_broken_outbound($config['outbounds'][$existing_idx])) {
                    $config['outbounds'][$existing_idx] = $ob;
                    $result['added']++;
                } else {
                    $result['skipped']++;
                }
                continue;
            }
            $config['outbounds'][] = $ob;
            $existing_tags[$tag] = true;
            $result['added']++;
        }

        // Prune mode: subscription links are not permanent — once an outbound is
        // no longer present in the freshly fetched list it is dead, so drop every
        // prefix outbound that is missing from the incoming set (both from the
        // outbounds array and the balancer selector). The ones still present are
        // left untouched so the config is only rewritten when something changed.
        if ($prune_stale && $prefix !== '') {
            $removed_stale = [];
            $kept_outbounds = [];
            foreach ($config['outbounds'] as $ob) {
                $tag = is_array($ob) ? (string) ($ob['tag'] ?? '') : '';
                if ($tag !== '' && $this->tag_has_prefix($tag, $prefix) && !isset($incoming_tags[$tag])) {
                    $removed_stale[$tag] = true;
                    $result['removed']++;
                    continue;
                }
                $kept_outbounds[] = $ob;
            }

            if ($removed_stale !== []) {
                $config['outbounds'] = array_values($kept_outbounds);
                $config_changed = true;

                $selector = $config['routing']['balancers'][$balancer_index]['selector'] ?? [];
                if (is_array($selector)) {
                    $config['routing']['balancers'][$balancer_index]['selector'] = array_values(
                        array_filter($selector, static function ($tag) use ($removed_stale) {
                            return !isset($removed_stale[(string) $tag]);
                        })
                    );
                }
            }
        }

        // Enforce the outbound cap for this source's prefix using FIFO eviction:
        // when the pool exceeds the cap, drop the oldest prefix outbounds (those
        // earliest in the array) to make room. Outbounds still present in the
        // incoming list are protected and never evicted.
        if ($this->enforce_outbound_cap($config, $prefix, $max_outbounds, array_keys($incoming_tags), $result)) {
            $config_changed = true;
        }

        // Rebuild the balancer selector so it always holds the newest prefix
        // outbounds (up to the selector cap), while preserving any selector
        // entries that belong to other sources/prefixes.
        if ($this->rebuild_balancer_selector($config, $balancer_index, $prefix, $max_selector)) {
            $config_changed = true;
        }

        if (!$config_changed && $result['added'] === 0) {
            $result['success'] = true;
            return $result;
        }

        $test_url = isset($cfg_res['outbound_test_url']) ? (string) $cfg_res['outbound_test_url'] : null;
        $save = $api->update_xray_config($config, $test_url !== '' ? $test_url : null);
        if (empty($save['success'])) {
            $result['errors'][] = (string) ($save['msg'] ?? 'Failed to save xray config');
            return $result;
        }

        $result['success'] = true;
        return $result;
    }

    /**
     * Max number of outbounds kept per source prefix before old ones are evicted.
     * 0 = unlimited (default).
     */
    private function max_outbounds_per_source(): int {
        $value = (int) get_option('xui_outbound_max_per_source', 0);
        return max(0, $value);
    }

    /**
     * Max number of (newest) prefix tags kept inside a balancer selector.
     * 0 = unlimited (default).
     */
    private function max_balancer_selector(): int {
        $value = (int) get_option('xui_outbound_balancer_selector_max', 0);
        return max(0, $value);
    }

    /**
     * FIFO eviction: keep at most $max prefix outbounds, removing the oldest
     * (earliest in the array) first. Outbounds whose tag is in $protected_tags
     * (e.g. the ones just added/refreshed this run) are never evicted.
     *
     * @param array<string,mixed> $config        Passed by reference.
     * @param list<string>        $protected_tags
     * @param array<string,mixed> $result         Passed by reference (updates "removed").
     * @return bool True when the config was modified.
     */
    private function enforce_outbound_cap(array &$config, string $prefix, int $max, array $protected_tags, array &$result): bool {
        if ($max <= 0 || $prefix === '') {
            return false;
        }

        $prefix_indices = [];
        foreach ($config['outbounds'] as $idx => $ob) {
            $tag = is_array($ob) ? (string) ($ob['tag'] ?? '') : '';
            if ($tag !== '' && $this->tag_has_prefix($tag, $prefix)) {
                $prefix_indices[$idx] = $tag;
            }
        }

        $overflow = count($prefix_indices) - $max;
        if ($overflow <= 0) {
            return false;
        }

        $protected = array_flip($protected_tags);
        $remove = [];
        foreach ($prefix_indices as $idx => $tag) {
            if ($overflow <= 0) {
                break;
            }
            if (isset($protected[$tag])) {
                continue;
            }
            $remove[$idx] = true;
            $overflow--;
        }

        if ($remove === []) {
            return false;
        }

        $kept = [];
        foreach ($config['outbounds'] as $idx => $ob) {
            if (isset($remove[$idx])) {
                $result['removed'] = (int) ($result['removed'] ?? 0) + 1;
                continue;
            }
            $kept[] = $ob;
        }
        $config['outbounds'] = array_values($kept);

        return true;
    }

    /**
     * Rebuild a balancer selector so it contains the newest prefix outbounds
     * (up to $max), preserving any non-prefix selector entries untouched.
     *
     * @param array<string,mixed> $config Passed by reference.
     * @return bool True when the selector was modified.
     */
    private function rebuild_balancer_selector(array &$config, int $balancer_index, string $prefix, int $max): bool {
        if ($prefix === '') {
            return false;
        }

        $prefix_tags = [];
        foreach ($config['outbounds'] as $ob) {
            $tag = is_array($ob) ? (string) ($ob['tag'] ?? '') : '';
            if ($tag !== '' && $this->tag_has_prefix($tag, $prefix)) {
                $prefix_tags[] = $tag;
            }
        }

        // Newest = appended last, so keep the tail of the list.
        $newest = ($max > 0 && count($prefix_tags) > $max)
            ? array_slice($prefix_tags, -$max)
            : $prefix_tags;

        $current = $config['routing']['balancers'][$balancer_index]['selector'] ?? [];
        if (!is_array($current)) {
            $current = [];
        }
        $current = array_values($current);

        // Keep entries from other sources/prefixes, then append our newest tags.
        $preserved = array_values(array_filter($current, function ($tag) use ($prefix) {
            return !$this->tag_has_prefix((string) $tag, $prefix);
        }));
        $rebuilt = array_values(array_merge($preserved, $newest));

        if ($rebuilt === $current) {
            return false;
        }

        $config['routing']['balancers'][$balancer_index]['selector'] = $rebuilt;
        return true;
    }

    /**
     * Does an outbound tag belong to the given prefix? Tags are built as "prefix_hash".
     */
    private function tag_has_prefix(string $tag, string $prefix): bool {
        if ($prefix === '') {
            return false;
        }
        return $tag === $prefix || strpos($tag, $prefix . '_') === 0;
    }

    /**
     * @param list<array<string,mixed>> $balancers
     */
    private function find_balancer_index(array $balancers, string $tag): ?int {
        foreach ($balancers as $idx => $balancer) {
            if (is_array($balancer) && (string) ($balancer['tag'] ?? '') === $tag) {
                return (int) $idx;
            }
        }
        return null;
    }

    /**
     * @param list<array<string,mixed>> $outbounds
     */
    private function find_outbound_index_by_tag(array $outbounds, string $tag): ?int {
        foreach ($outbounds as $idx => $ob) {
            if (is_array($ob) && (string) ($ob['tag'] ?? '') === $tag) {
                return (int) $idx;
            }
        }
        return null;
    }

    /**
     * Detect outbounds saved with empty/invalid settings (e.g. undefined:undefined in panel UI).
     *
     * @param array<string,mixed> $ob
     */
    private function is_broken_outbound(array $ob): bool {
        $protocol = strtolower((string) ($ob['protocol'] ?? ''));
        $settings = $this->normalize_outbound_settings($ob['settings'] ?? null);

        if ($settings === []) {
            return true;
        }

        switch ($protocol) {
            case 'vless':
                if (($settings['address'] ?? '') !== '' && ($settings['port'] ?? 0) > 0 && ($settings['id'] ?? '') !== '') {
                    return false;
                }
                $vnext = $settings['vnext'][0] ?? null;
                if (is_array($vnext) && ($vnext['address'] ?? '') !== '' && ($vnext['port'] ?? 0) > 0) {
                    $users = $vnext['users'][0] ?? null;
                    return !is_array($users) || ($users['id'] ?? '') === '';
                }
                return true;
            case 'vmess':
                $vnext = $settings['vnext'][0] ?? null;
                if (!is_array($vnext) || ($vnext['address'] ?? '') === '' || ($vnext['port'] ?? 0) <= 0) {
                    return true;
                }
                $users = $vnext['users'][0] ?? null;
                return !is_array($users) || ($users['id'] ?? '') === '';
            case 'trojan':
            case 'shadowsocks':
                $server = $settings['servers'][0] ?? null;
                if (!is_array($server)) {
                    return true;
                }
                return ($server['address'] ?? '') === '' || ($server['port'] ?? 0) <= 0;
            default:
                return false;
        }
    }

    /**
     * @return array<string,mixed>
     */
    private function normalize_outbound_settings($settings): array {
        if (is_string($settings)) {
            $decoded = json_decode($settings, true);
            return is_array($decoded) ? $decoded : [];
        }
        return is_array($settings) ? $settings : [];
    }

    /**
     * Normalize outbound to 3x-ui wire JSON (same shape as OutboundFormModal JSON tab).
     *
     * @param array<string,mixed> $ob
     * @return array<string,mixed>
     */
    private function normalize_outbound_for_panel(array $ob): array {
        $protocol = strtolower((string) ($ob['protocol'] ?? ''));
        $settings = $this->normalize_outbound_settings($ob['settings'] ?? null);
        $stream   = is_array($ob['streamSettings'] ?? null) ? $ob['streamSettings'] : [];

        switch ($protocol) {
            case 'vless':
                if (($settings['address'] ?? '') === '' && !empty($settings['vnext'][0])) {
                    $v = $settings['vnext'][0];
                    $u = is_array($v['users'][0] ?? null) ? $v['users'][0] : [];
                    $settings = [
                        'address'    => (string) ($v['address'] ?? ''),
                        'port'       => (int) ($v['port'] ?? 443),
                        'id'         => (string) ($u['id'] ?? ''),
                        'flow'       => (string) ($u['flow'] ?? ''),
                        'encryption' => (string) ($u['encryption'] ?? 'none'),
                    ];
                } else {
                    $settings = [
                        'address'    => (string) ($settings['address'] ?? ''),
                        'port'       => (int) ($settings['port'] ?? 443),
                        'id'         => (string) ($settings['id'] ?? ''),
                        'flow'       => (string) ($settings['flow'] ?? ''),
                        'encryption' => (string) ($settings['encryption'] ?? 'none'),
                    ];
                }
                break;
            case 'vmess':
                if (!empty($settings['vnext'][0])) {
                    $v = $settings['vnext'][0];
                    $u = is_array($v['users'][0] ?? null) ? $v['users'][0] : [];
                    $settings = [
                        'vnext' => [[
                            'address' => (string) ($v['address'] ?? ''),
                            'port'    => (int) ($v['port'] ?? 443),
                            'users'   => [[
                                'id'       => (string) ($u['id'] ?? ''),
                                'security' => (string) ($u['security'] ?? 'auto'),
                            ]],
                        ]],
                    ];
                }
                break;
            case 'trojan':
            case 'shadowsocks':
                if (!empty($settings['servers'][0])) {
                    $s = $settings['servers'][0];
                    $server = [
                        'address' => (string) ($s['address'] ?? ''),
                        'port'    => (int) ($s['port'] ?? 443),
                        'password' => (string) ($s['password'] ?? ''),
                    ];
                    if ($protocol === 'shadowsocks') {
                        $server['method'] = (string) ($s['method'] ?? 'aes-256-gcm');
                    }
                    $settings = ['servers' => [$server]];
                }
                break;
        }

        $network  = strtolower((string) ($stream['network'] ?? 'tcp'));
        $security = strtolower((string) ($stream['security'] ?? 'none'));
        if ($network === 'splithttp') {
            $network = 'xhttp';
            if (!empty($stream['splithttpSettings']) && empty($stream['xhttpSettings'])) {
                $stream['xhttpSettings'] = $stream['splithttpSettings'];
            }
            unset($stream['splithttpSettings']);
        }

        $q = $this->stream_to_query_params($stream, $settings, $protocol);
        $address = '';
        if ($protocol === 'vless') {
            $address = (string) ($settings['address'] ?? '');
        } elseif ($protocol === 'vmess' && !empty($settings['vnext'][0]['address'])) {
            $address = (string) $settings['vnext'][0]['address'];
        } elseif (!empty($settings['servers'][0]['address'])) {
            $address = (string) $settings['servers'][0]['address'];
        }

        $normalized = [
            'protocol' => $protocol,
            'settings' => $settings,
        ];
        if (!empty($ob['tag'])) {
            $normalized['tag'] = (string) $ob['tag'];
        }
        if (in_array($protocol, ['vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria'], true)) {
            $normalized['streamSettings'] = $this->build_stream_settings($network, $security, $q, $address);
        }
        if (!empty($ob['sendThrough'])) {
            $normalized['sendThrough'] = (string) $ob['sendThrough'];
        }
        if (!empty($ob['mux']) && is_array($ob['mux'])) {
            $normalized['mux'] = $ob['mux'];
        }

        return $normalized;
    }

    /**
     * Best-effort reverse of streamSettings into query-like params for rebuild.
     *
     * @param array<string,mixed> $stream
     * @param array<string,mixed> $settings
     * @return array<string,string>
     */
    private function stream_to_query_params(array $stream, array $settings, string $protocol): array {
        $q = [];
        $network = strtolower((string) ($stream['network'] ?? 'tcp'));

        if ($network === 'ws' && !empty($stream['wsSettings'])) {
            $ws = $stream['wsSettings'];
            $q['host'] = (string) ($ws['host'] ?? ($ws['headers']['Host'] ?? ''));
            $q['path'] = (string) ($ws['path'] ?? '/');
        } elseif ($network === 'grpc' && !empty($stream['grpcSettings'])) {
            $grpc = $stream['grpcSettings'];
            $q['serviceName'] = (string) ($grpc['serviceName'] ?? '');
            $q['mode'] = !empty($grpc['multiMode']) ? 'multi' : '';
        } elseif ($network === 'httpupgrade' && !empty($stream['httpupgradeSettings'])) {
            $hu = $stream['httpupgradeSettings'];
            $q['host'] = (string) ($hu['host'] ?? '');
            $q['path'] = (string) ($hu['path'] ?? '/');
        } elseif ($network === 'xhttp' && !empty($stream['xhttpSettings'])) {
            $xh = $stream['xhttpSettings'];
            $q['host'] = (string) ($xh['host'] ?? '');
            $q['path'] = (string) ($xh['path'] ?? '/');
            $q['mode'] = (string) ($xh['mode'] ?? '');
        } elseif ($network === 'tcp' && !empty($stream['tcpSettings']['header']['type'])) {
            $q['headerType'] = (string) $stream['tcpSettings']['header']['type'];
        }

        if (($stream['security'] ?? '') === 'tls' && !empty($stream['tlsSettings'])) {
            $tls = $stream['tlsSettings'];
            $q['sni'] = (string) ($tls['serverName'] ?? '');
            $q['fp'] = (string) ($tls['fingerprint'] ?? '');
            if (!empty($tls['alpn']) && is_array($tls['alpn'])) {
                $q['alpn'] = implode(',', $tls['alpn']);
            }
        } elseif (($stream['security'] ?? '') === 'reality' && !empty($stream['realitySettings'])) {
            $re = $stream['realitySettings'];
            $q['sni'] = (string) ($re['serverName'] ?? '');
            $q['fp'] = (string) ($re['fingerprint'] ?? 'chrome');
            $q['pbk'] = (string) ($re['publicKey'] ?? '');
            $q['sid'] = (string) ($re['shortId'] ?? '');
            $q['spx'] = (string) ($re['spiderX'] ?? '');
        }

        if ($protocol === 'vless') {
            $q['flow'] = (string) ($settings['flow'] ?? '');
            $q['encryption'] = (string) ($settings['encryption'] ?? 'none');
        }

        return $q;
    }

    /**
     * @param array<string,mixed> $result
     */
    private function update_source_status(int $source_id, array $result): void {
        global $wpdb;
        $table = $wpdb->prefix . 'xui_outbound_sources';
        $status = wp_json_encode([
            'success' => !empty($result['success']),
            'msg'     => (string) ($result['msg'] ?? ''),
            'added'   => (int) ($result['added'] ?? 0),
            'skipped' => (int) ($result['skipped'] ?? 0),
            'errors'  => array_values((array) ($result['errors'] ?? [])),
            'at'      => current_time('mysql'),
        ], JSON_UNESCAPED_UNICODE);

        $wpdb->update(
            $table,
            [
                'last_synced_at' => current_time('mysql'),
                'last_status'    => $status,
            ],
            ['id' => $source_id],
            ['%s', '%s'],
            ['%d']
        );
    }

    /**
     * Split an "host:port" authority into [host, port], handling IPv6 brackets.
     *
     * @return array{0:string,1:int}
     */
    private function split_address_port(string $authority, int $default_port): array {
        $authority = trim(rawurldecode($authority));

        // IPv6 in brackets, e.g. [2001:db8::1]:443
        if (preg_match('~^\[([^\]]+)\](?::(\d+))?$~', $authority, $m)) {
            $port = isset($m[2]) && $m[2] !== '' ? (int) $m[2] : $default_port;
            return [$m[1], $port];
        }

        $pos = strrpos($authority, ':');
        if ($pos !== false) {
            $host = substr($authority, 0, $pos);
            $port = substr($authority, $pos + 1);
            // Only treat as port if numeric and host isn't a bare IPv6 (multiple colons).
            if ($port !== '' && ctype_digit($port) && strpos($host, ':') === false) {
                return [$host, (int) $port];
            }
        }

        return [$authority, $default_port];
    }

    private function sanitize_tag(string $tag): string {
        $tag = preg_replace('/[^a-zA-Z0-9_-]/', '_', $tag) ?? 'ob';
        $tag = trim($tag, '_');
        return $tag !== '' ? $tag : 'ob';
    }

    /**
     * @return array{outbound:array<string,mixed>,fingerprint:string}|null
     */
    private function parse_vless_uri(string $uri): ?array {
        if (!preg_match('~^vless://([^@]+)@([^/?#]+)(?:\?([^#]*))?(?:#.*)?$~i', $uri, $m)) {
            return null;
        }

        $uuid = rawurldecode($m[1]);
        [$address, $port] = $this->split_address_port($m[2], 443);
        parse_str((string) ($m[3] ?? ''), $q);

        $network  = strtolower((string) ($q['type'] ?? 'tcp'));
        $security = strtolower((string) ($q['security'] ?? 'none'));
        $flow     = (string) ($q['flow'] ?? '');

        $stream = $this->build_stream_settings($network, $security, $q, $address);

        $fingerprint = "{$address}:{$port}:{$uuid}:{$network}";

        // 3x-ui panel stores VLESS settings in flat form (address/port/id),
        // not vnext — otherwise the UI shows undefined:undefined.
        return [
            'fingerprint' => $fingerprint,
            'outbound'    => [
                'protocol'       => 'vless',
                'settings'       => [
                    'address'    => $address,
                    'port'       => $port,
                    'id'         => $uuid,
                    'flow'       => $flow,
                    'encryption' => (string) ($q['encryption'] ?? 'none'),
                ],
                'streamSettings' => $stream,
            ],
        ];
    }

    /**
     * @return array{outbound:array<string,mixed>,fingerprint:string}|null
     */
    private function parse_vmess_uri(string $uri): ?array {
        $payload = substr($uri, 8);
        $json_str = base64_decode($payload, true);
        if ($json_str === false) {
            $json_str = base64_decode(strtr($payload, '-_', '+/'), true);
        }
        if ($json_str === false) {
            return null;
        }

        $data = json_decode($json_str, true);
        if (!is_array($data)) {
            return null;
        }

        $address = (string) ($data['add'] ?? $data['host'] ?? '');
        $port    = (int) ($data['port'] ?? 443);
        $uuid    = (string) ($data['id'] ?? '');
        if ($address === '' || $uuid === '') {
            return null;
        }

        $network  = strtolower((string) ($data['net'] ?? 'tcp'));
        $tls      = strtolower((string) ($data['tls'] ?? ''));
        $security = ($tls === 'tls' || $tls === 'reality') ? $tls : 'none';

        $q = [
            'host'    => (string) ($data['host'] ?? ''),
            'path'    => (string) ($data['path'] ?? ''),
            'sni'     => (string) ($data['sni'] ?? $data['host'] ?? ''),
            'fp'      => (string) ($data['fp'] ?? ''),
            'alpn'    => (string) ($data['alpn'] ?? ''),
            'pbk'     => (string) ($data['pbk'] ?? ''),
            'sid'     => (string) ($data['sid'] ?? ''),
            'spx'     => (string) ($data['spx'] ?? ''),
            'headerType' => (string) ($data['type'] ?? ''),
            'serviceName' => (string) ($data['serviceName'] ?? $data['grpcServiceName'] ?? ''),
            'mode'    => (string) ($data['mode'] ?? ''),
        ];

        $stream = $this->build_stream_settings($network, $security, $q, $address);

        $fingerprint = "{$address}:{$port}:{$uuid}:{$network}";

        return [
            'fingerprint' => $fingerprint,
            'outbound'    => [
                'protocol'       => 'vmess',
                'settings'       => [
                    'vnext' => [[
                        'address' => $address,
                        'port'    => $port,
                        'users'   => [[
                            'id'       => $uuid,
                            'security' => (string) ($data['scy'] ?? 'auto'),
                        ]],
                    ]],
                ],
                'streamSettings' => $stream,
            ],
        ];
    }

    /**
     * @return array{outbound:array<string,mixed>,fingerprint:string}|null
     */
    private function parse_trojan_uri(string $uri): ?array {
        if (!preg_match('~^trojan://([^@]+)@([^/?#]+)(?:\?([^#]*))?(?:#.*)?$~i', $uri, $m)) {
            return null;
        }

        $password = rawurldecode($m[1]);
        [$address, $port] = $this->split_address_port($m[2], 443);
        parse_str((string) ($m[3] ?? ''), $q);

        $network  = strtolower((string) ($q['type'] ?? 'tcp'));
        $security = strtolower((string) ($q['security'] ?? 'tls'));
        if ($security === '' || $security === 'none') {
            $security = 'tls';
        }

        $stream = $this->build_stream_settings($network, $security, $q, $address);
        $fingerprint = "{$address}:{$port}:{$password}:{$network}";

        return [
            'fingerprint' => $fingerprint,
            'outbound'    => [
                'protocol'       => 'trojan',
                'settings'       => [
                    'servers' => [[
                        'address'  => $address,
                        'port'     => $port,
                        'password' => $password,
                    ]],
                ],
                'streamSettings' => $stream,
            ],
        ];
    }

    /**
     * @return array{outbound:array<string,mixed>,fingerprint:string}|null
     */
    private function parse_ss_uri(string $uri): ?array {
        $rest = substr($uri, 5);
        $method = '';
        $password = '';
        $address = '';
        $port = 8388;

        if (strpos($rest, '@') !== false) {
            if (!preg_match('#^(.+?)@([^:]+):(\d+)#', $rest, $m)) {
                return null;
            }
            $userinfo = rawurldecode($m[1]);
            $address  = rawurldecode($m[2]);
            $port     = (int) $m[3];
            if (strpos($userinfo, ':') === false) {
                $decoded = base64_decode($userinfo, true);
                if ($decoded !== false) {
                    $userinfo = $decoded;
                }
            }
            [$method, $password] = array_pad(explode(':', $userinfo, 2), 2, '');
        } else {
            $decoded = base64_decode($rest, true);
            if ($decoded === false) {
                $decoded = base64_decode(strtr($rest, '-_', '+/'), true);
            }
            if ($decoded === false || !preg_match('#^(.+?):(.+?)@([^:]+):(\d+)#', $decoded, $m)) {
                return null;
            }
            $method   = $m[1];
            $password = $m[2];
            $address  = $m[3];
            $port     = (int) $m[4];
        }

        if ($method === '' || $password === '' || $address === '') {
            return null;
        }

        $fingerprint = "{$address}:{$port}:{$method}:{$password}";

        return [
            'fingerprint' => $fingerprint,
            'outbound'    => [
                'protocol' => 'shadowsocks',
                'settings' => [
                    'servers' => [[
                        'address'  => $address,
                        'port'     => $port,
                        'method'   => $method,
                        'password' => $password,
                    ]],
                ],
            ],
        ];
    }

    /**
     * @param array<string,string> $q
     * @return array<string,mixed>
     */
    private function build_stream_settings(string $network, string $security, array $q, string $address): array {
        $network  = $network !== '' ? $network : 'tcp';
        $security = $security !== '' ? $security : 'none';
        if ($network === 'splithttp') {
            $network = 'xhttp';
        }

        $stream = [
            'network'  => $network,
            'security' => $security,
        ];

        switch ($network) {
            case 'tcp':
                $headerType = (string) ($q['headerType'] ?? 'none');
                if ($headerType === 'http' || ($q['type'] ?? '') === 'http') {
                    $stream['tcpSettings'] = [
                        'header' => [
                            'type' => 'http',
                            'request' => [
                                'version' => '1.1',
                                'method'  => 'GET',
                                'path'    => array_values(array_filter(explode(',', (string) ($q['path'] ?? '/')))),
                                'headers' => [
                                    'Host' => array_values(array_filter(explode(',', (string) ($q['host'] ?? '')))),
                                ],
                            ],
                        ],
                    ];
                } else {
                    $stream['tcpSettings'] = [
                        'header' => ['type' => 'none'],
                    ];
                }
                break;
            case 'ws':
                $stream['wsSettings'] = [
                    'path'            => (string) ($q['path'] ?? '/'),
                    'host'            => (string) ($q['host'] ?? $q['sni'] ?? $address),
                    'headers'         => new \stdClass(),
                    'heartbeatPeriod' => 0,
                ];
                break;
            case 'grpc':
                $stream['grpcSettings'] = [
                    'serviceName' => (string) ($q['serviceName'] ?? $q['path'] ?? ''),
                    'authority'   => (string) ($q['authority'] ?? ''),
                    'multiMode'   => ((string) ($q['mode'] ?? '')) === 'multi',
                ];
                break;
            case 'httpupgrade':
                $stream['httpupgradeSettings'] = [
                    'path'    => (string) ($q['path'] ?? '/'),
                    'host'    => (string) ($q['host'] ?? $q['sni'] ?? $address),
                    'headers' => new \stdClass(),
                ];
                break;
            case 'xhttp':
                $stream['xhttpSettings'] = [
                    'path'               => (string) ($q['path'] ?? '/'),
                    'host'               => (string) ($q['host'] ?? $q['sni'] ?? $address),
                    'mode'               => (string) ($q['mode'] ?? 'auto'),
                    'headers'            => new \stdClass(),
                    'xPaddingBytes'      => (string) ($q['xPaddingBytes'] ?? '100-1000'),
                    'scMaxEachPostBytes' => (string) ($q['scMaxEachPostBytes'] ?? '1000000'),
                ];
                break;
            default:
                $stream['network'] = 'tcp';
                $stream['tcpSettings'] = [
                    'header' => ['type' => 'none'],
                ];
                break;
        }

        if ($security === 'tls') {
            $alpn = [];
            if (!empty($q['alpn'])) {
                $alpn = array_values(array_filter(array_map('trim', explode(',', (string) $q['alpn']))));
            }
            $stream['tlsSettings'] = [
                'serverName'           => (string) ($q['sni'] ?? ($network !== 'tcp' ? ($q['host'] ?? '') : '')),
                'alpn'                 => $alpn,
                'fingerprint'          => (string) ($q['fp'] ?? ''),
                'echConfigList'        => (string) ($q['ech'] ?? ''),
                'verifyPeerCertByName' => '',
                'pinnedPeerCertSha256' => (string) ($q['pcs'] ?? ''),
            ];
        } elseif ($security === 'reality') {
            $stream['realitySettings'] = [
                'publicKey'     => (string) ($q['pbk'] ?? ''),
                'fingerprint'   => (string) ($q['fp'] ?? 'chrome'),
                'serverName'    => (string) ($q['sni'] ?? $address),
                'shortId'       => (string) ($q['sid'] ?? ''),
                'spiderX'       => (string) ($q['spx'] ?? ''),
                'mldsa65Verify' => (string) ($q['pqv'] ?? ''),
            ];
        }

        return $stream;
    }
}
