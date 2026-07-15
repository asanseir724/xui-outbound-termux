<?php
namespace XuiVpn\Services;

/**
 * تست واقعی کانفیگ: TCP RTT + اعتبارسنجی Xray + (اختیاری) real-delay.
 */
class FreeConfigXrayProbeService {

    public function is_xray_probe_enabled(): bool {
        return get_option('xui_free_config_xray_validate', '1') === '1'
            && $this->can_run_shell_commands();
    }

    public function get_probe_timeout_ms(): int {
        $stored = (int) get_option('xui_free_config_probe_timeout_ms', 3500);
        // تایم‌اوت‌های خیلی پایین روی نت ایران باعث رد اشتباه کانفیگ‌های سالم می‌شود.
        $effective = $stored < 1500 ? max($stored, 2000) : $stored;
        return max(1500, min(15000, $effective));
    }

    public function is_real_delay_enabled(): bool {
        return get_option('xui_free_config_real_delay_enabled', '1') === '1'
            && $this->can_run_real_delay_probe();
    }

    public function can_run_shell_commands(): bool {
        return function_exists('exec')
            || function_exists('shell_exec')
            || function_exists('proc_open');
    }

    public function can_run_real_delay_probe(): bool {
        return $this->resolve_binary() !== ''
            && function_exists('proc_open')
            && function_exists('curl_init');
    }

    /**
     * @return array{
     *   xray_binary:string,
     *   xray_binary_found:bool,
     *   exec_enabled:bool,
     *   shell_exec_enabled:bool,
     *   proc_open_enabled:bool,
     *   curl_enabled:bool,
     *   xray_validate_effective:bool,
     *   real_delay_effective:bool,
     *   probe_timeout_ms:int,
     *   warnings:array<int,string>
     * }
     */
    public function get_environment_status(): array {
        $bin      = $this->resolve_binary();
        $warnings = [];

        if ($bin === '') {
            $warnings[] = 'باینری Xray یافت نشد — فقط تست TCP انجام می‌شود.';
        }
        if (!function_exists('exec') && !function_exists('shell_exec') && !function_exists('proc_open')) {
            $warnings[] = 'تابع‌های exec/shell_exec/proc_open روی PHP غیرفعال‌اند — Xray قابل اجرا نیست.';
            if (class_exists(FreeConfigProbeRelayService::class)) {
                $warnings[] = 'تست Xray از طریق VPS واسط (probe relay) فعال است — xui-sync باید روی سرور خارج در حال اجرا باشد.';
            }
        }
        if ($bin !== '' && !function_exists('proc_open')) {
            $warnings[] = 'proc_open غیرفعال است — Real Delay و xray run امکان‌پذیر نیست.';
        }
        if (!function_exists('curl_init')) {
            $warnings[] = 'افزونه curl در PHP فعال نیست — Real Delay کار نمی‌کند.';
        }
        if ((int) get_option('xui_free_config_probe_timeout_ms', 3500) < 1500) {
            $warnings[] = 'تایم‌اوت TCP کمتر از ۱۵۰۰ms است — برای پایداری روی ۲۰۰۰ms+ اعمال می‌شود.';
        }

        return [
            'xray_binary'             => $bin,
            'xray_binary_found'       => $bin !== '',
            'exec_enabled'            => function_exists('exec'),
            'shell_exec_enabled'      => function_exists('shell_exec'),
            'proc_open_enabled'       => function_exists('proc_open'),
            'curl_enabled'            => function_exists('curl_init'),
            'xray_validate_effective' => $this->is_xray_probe_enabled(),
            'real_delay_effective'    => $this->is_real_delay_enabled(),
            'remote_probe_effective'  => class_exists(FreeConfigProbeRelayService::class)
                && FreeConfigProbeRelayService::uses_remote_probe(),
            'remote_probe_pending'    => class_exists(FreeConfigProbeRelayService::class)
                ? FreeConfigProbeRelayService::count_pending_jobs()
                : 0,
            'probe_timeout_ms'        => $this->get_probe_timeout_ms(),
            'warnings'                => $warnings,
        ];
    }

    public function get_real_delay_url(): string {
        $url = trim((string) get_option('xui_free_config_real_delay_url', ''));
        if ($url !== '') {
            return $url;
        }
        return 'https://www.gstatic.com/generate_204';
    }

    /**
     * @return string[]
     */
    public function get_real_delay_url_candidates(): array {
        $urls = [];
        $custom = trim((string) get_option('xui_free_config_real_delay_url', ''));
        if ($custom !== '') {
            $urls[] = $custom;
        }
        foreach ([
            'https://www.gstatic.com/generate_204',
            'https://cp.cloudflare.com/generate_204',
            'http://connectivitycheck.gstatic.com/generate_204',
            'https://one.one.one.one/cdn-cgi/trace',
        ] as $fallback) {
            if (!in_array($fallback, $urls, true)) {
                $urls[] = $fallback;
            }
        }
        return $urls;
    }

    /**
     * @return array{alive:bool,ping_ms:?int,method:string,error?:string}
     */
    public function probe_uri(string $uri): array {
        $uri = trim($uri);
        if ($uri === '') {
            return ['alive' => false, 'ping_ms' => null, 'method' => 'none', 'error' => 'empty'];
        }

        $host = SubscriptionService::extract_config_address_host($uri);
        $port = self::extract_port($uri);
        if ($host === '' || $port <= 0) {
            return ['alive' => false, 'ping_ms' => null, 'method' => 'none', 'error' => 'no host/port'];
        }

        $tcp = $this->tcp_probe($host, $port, $this->get_probe_timeout_ms());
        if (empty($tcp['is_up'])) {
            $this->log_probe('warn', 'TCP down', ['host' => $host, 'port' => $port]);
            return ['alive' => false, 'ping_ms' => null, 'method' => 'tcp', 'error' => 'tcp down'];
        }

        $ping_ms = isset($tcp['response_ms']) ? (int) $tcp['response_ms'] : null;
        $method  = 'tcp';

        if ($this->is_xray_probe_enabled() && $this->resolve_binary() !== '') {
            $outbound = $this->build_outbound_from_uri($uri);
            if ($outbound === null) {
                $this->log_probe('warn', 'Parse outbound failed', ['host' => $host]);
                return [
                    'alive'   => false,
                    'ping_ms' => $ping_ms,
                    'method'  => 'tcp+xray',
                    'error'   => 'parse outbound',
                ];
            }

            $xr = $this->validate_with_xray($outbound);
            if (!$xr['ok']) {
                $this->log_probe('warn', 'xray -test failed', [
                    'host'  => $host,
                    'error' => (string) ($xr['error'] ?? ''),
                ]);
                return [
                    'alive'   => false,
                    'ping_ms' => $ping_ms,
                    'method'  => 'tcp+xray',
                    'error'   => $xr['error'] ?? 'xray invalid',
                ];
            }
            $method = 'tcp+xray';

            // تنظیمات: فقط Real Delay = سالم (مثل Ctrl+R در کلاینت، نه tcping)
            if ($this->wants_real_delay_only()) {
                if (!$this->can_run_real_delay_probe()) {
                    $why = [];
                    if ($this->resolve_binary() === '') {
                        $why[] = 'xray missing';
                    }
                    if (!function_exists('proc_open')) {
                        $why[] = 'proc_open disabled';
                    }
                    if (!function_exists('curl_init')) {
                        $why[] = 'curl missing';
                    }
                    $err = $why !== [] ? implode(', ', $why) : 'real delay unavailable';
                    $this->log_probe('warn', 'Real delay required but cannot run', [
                        'host'  => $host,
                        'error' => $err,
                    ]);
                    return [
                        'alive'   => false,
                        'ping_ms' => null,
                        'method'  => 'xray-real-delay',
                        'error'   => $err,
                    ];
                }

                $this->log_probe('debug', 'Real delay probe start', ['host' => $host]);
                $real = $this->measure_real_delay_with_xray($outbound);
                if (!empty($real['ok']) && isset($real['delay_ms']) && (int) $real['delay_ms'] > 0) {
                    $ping_ms = (int) $real['delay_ms'];
                    $this->log_probe('ok', 'Real delay OK', [
                        'host'     => $host,
                        'delay_ms' => $ping_ms,
                    ]);
                    return [
                        'alive'   => true,
                        'ping_ms' => $ping_ms,
                        'method'  => 'xray-real-delay',
                    ];
                }

                $this->log_probe('warn', 'Real delay failed — reject (no TCP fallback)', [
                    'host'  => $host,
                    'error' => (string) ($real['error'] ?? 'unknown'),
                    'tcp_ms'=> $ping_ms,
                ]);
                return [
                    'alive'   => false,
                    'ping_ms' => null,
                    'method'  => 'xray-real-delay',
                    'error'   => (string) ($real['error'] ?? 'real delay failed'),
                ];
            }

            // Real Delay خاموش است — tcp+xray مجاز.
            return ['alive' => true, 'ping_ms' => $ping_ms, 'method' => $method];
        }

        // بدون Xray / بدون Real Delay: TCP به‌تنهایی سالم محسوب نمی‌شود وقتی Real Delay روشن است.
        if ($this->wants_real_delay_only()) {
            $this->log_probe('warn', 'Real delay required but Xray unavailable', ['host' => $host]);
            return [
                'alive'   => false,
                'ping_ms' => null,
                'method'  => 'xray-real-delay',
                'error'   => 'xray/real-delay unavailable',
            ];
        }

        if ($ping_ms !== null) {
            $this->log_probe('info', 'Probe OK', [
                'host'    => $host,
                'ping_ms' => $ping_ms,
                'method'  => $method,
            ]);
        }

        return ['alive' => true, 'ping_ms' => $ping_ms, 'method' => $method];
    }

    /**
     * وقتی Real Delay در تنظیمات روشن است، TCP-only را سالم حساب نکن.
     */
    public function wants_real_delay_only(): bool {
        return get_option('xui_free_config_real_delay_enabled', '1') === '1';
    }

    public static function extract_port(string $uri): int {
        if (preg_match('/@[^:\/?#]+:(\d+)/', $uri, $m)) {
            return max(1, min(65535, (int) $m[1]));
        }
        if (preg_match('/^(?:vmess|vless|trojan|ss|hysteria2?|tuic):\/\//i', $uri)) {
            return 443;
        }
        return 0;
    }

    public function resolve_binary(): string {
        $candidates = [];

        $env = getenv('XRAY_BIN');
        if (is_string($env) && trim($env) !== '') {
            $candidates[] = trim($env);
        }

        $custom = trim((string) get_option('xui_free_config_xray_path', ''));
        if ($custom !== '') {
            $candidates[] = $custom;
        }

        $dir = defined('XUI_VPN_PLUGIN_DIR') ? XUI_VPN_PLUGIN_DIR . 'bin/xray/' : '';
        if ($dir !== '') {
            if (stripos(PHP_OS_FAMILY, 'Windows') !== false) {
                $candidates[] = $dir . 'xray.exe';
                $candidates[] = $dir . 'Xray-windows-64/xray.exe';
            } else {
                $candidates[] = $dir . 'xray';
                $candidates[] = $dir . 'Xray-linux-64/xray';
            }
        }
        foreach ([
            '/etc/xui-outbound/xray/xray',
            '/usr/local/bin/xray',
            '/usr/bin/xray',
            '/bin/xray',
        ] as $system_path) {
            $candidates[] = $system_path;
        }

        foreach ($candidates as $path) {
            if ($this->is_usable_binary($path)) {
                return $path;
            }
        }

        return '';
    }

    private function is_usable_binary(string $path): bool {
        if (!is_file($path)) {
            return false;
        }
        if (is_executable($path)) {
            return true;
        }
        return stripos(PHP_OS_FAMILY, 'Windows') === false;
    }

    /**
     * @return array<string,mixed>|null
     */
    private function build_outbound_from_uri(string $uri): ?array {
        $outbound_svc = new OutboundSyncService();
        $parsed       = $outbound_svc->parse_link_to_outbound($uri, 'fc');
        if (!is_array($parsed)) {
            return null;
        }
        // parse_link_to_outbound → {tag, outbound} — خودِ outbound لازم است.
        if (isset($parsed['outbound']) && is_array($parsed['outbound'])) {
            $ob = $parsed['outbound'];
            if (!empty($parsed['tag']) && empty($ob['tag'])) {
                $ob['tag'] = (string) $parsed['tag'];
            }
            return $this->to_xray_runtime_outbound($ob);
        }
        if (!empty($parsed['protocol'])) {
            return $this->to_xray_runtime_outbound($parsed);
        }
        return null;
    }

    /**
     * تبدیل فرمت پنل ثنایی (flat) به فرمت اجرایی Xray-core.
     *
     * @param array<string,mixed> $ob
     * @return array<string,mixed>|null
     */
    private function to_xray_runtime_outbound(array $ob): ?array {
        $protocol = strtolower((string) ($ob['protocol'] ?? ''));
        $settings = is_array($ob['settings'] ?? null) ? $ob['settings'] : [];
        $stream   = is_array($ob['streamSettings'] ?? null) ? $ob['streamSettings'] : new \stdClass();
        $tag      = (string) ($ob['tag'] ?? 'proxy');

        if ($protocol === '') {
            return null;
        }

        if ($protocol === 'vless') {
            // پنل: address/port/id — Xray نیاز به vnext دارد.
            if (!empty($settings['address']) && empty($settings['vnext'])) {
                $user = [
                    'id'         => (string) ($settings['id'] ?? ''),
                    'encryption' => (string) ($settings['encryption'] ?? 'none'),
                ];
                $flow = trim((string) ($settings['flow'] ?? ''));
                if ($flow !== '') {
                    $user['flow'] = $flow;
                }
                $settings = [
                    'vnext' => [[
                        'address' => (string) $settings['address'],
                        'port'    => max(1, (int) ($settings['port'] ?? 443)),
                        'users'   => [$user],
                    ]],
                ];
            }
        } elseif ($protocol === 'vmess') {
            if (!empty($settings['address']) && empty($settings['vnext'])) {
                $settings = [
                    'vnext' => [[
                        'address' => (string) $settings['address'],
                        'port'    => max(1, (int) ($settings['port'] ?? 443)),
                        'users'   => [[
                            'id'       => (string) ($settings['id'] ?? ''),
                            'security' => (string) ($settings['security'] ?? 'auto'),
                        ]],
                    ]],
                ];
            }
        } elseif ($protocol === 'trojan' || $protocol === 'shadowsocks') {
            if (!empty($settings['address']) && empty($settings['servers'])) {
                $server = [
                    'address'  => (string) $settings['address'],
                    'port'     => max(1, (int) ($settings['port'] ?? 443)),
                    'password' => (string) ($settings['password'] ?? ''),
                ];
                if ($protocol === 'shadowsocks') {
                    $server['method'] = (string) ($settings['method'] ?? 'aes-256-gcm');
                }
                $settings = ['servers' => [$server]];
            }
        }

        $out = [
            'tag'            => $tag !== '' ? $tag : 'proxy',
            'protocol'       => $protocol,
            'settings'       => $settings,
            'streamSettings' => $stream === [] ? new \stdClass() : $stream,
        ];

        return $out;
    }

    /**
     * @param array<string,mixed> $config
     * @return string|false absolute path to .json config
     */
    private function write_xray_config_json(array $config) {
        $json = wp_json_encode($config, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if (!is_string($json) || $json === '' || $json === 'false') {
            $json = json_encode($config, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        }
        if (!is_string($json) || strlen($json) < 20) {
            return false;
        }

        $dir = function_exists('sys_get_temp_dir') ? sys_get_temp_dir() : '/tmp';
        $path = rtrim($dir, '/\\') . '/xui-xray-' . bin2hex(random_bytes(6)) . '.json';
        if (@file_put_contents($path, $json) === false) {
            return false;
        }
        return $path;
    }

    /**
     * @param array<string,mixed> $outbound
     * @return array{ok:bool,error?:string,skipped?:bool}
     */
    private function validate_with_xray(array $outbound): array {
        $bin = $this->resolve_binary();
        if ($bin === '' || !$this->can_run_shell_commands()) {
            return ['ok' => true, 'skipped' => true];
        }

        $config = [
            'log'       => ['loglevel' => 'error'],
            'inbounds'  => [[
                'listen'   => '127.0.0.1',
                'port'     => 10890,
                'protocol' => 'socks',
                'settings' => ['udp' => false],
            ]],
            'outbounds' => [
                $outbound,
                ['protocol' => 'freedom', 'tag' => 'direct'],
            ],
        ];

        $tmp = $this->write_xray_config_json($config);
        if ($tmp === false) {
            return ['ok' => false, 'error' => 'config json encode failed'];
        }

        $cmd = escapeshellarg($bin) . ' run -test -format json -c ' . escapeshellarg($tmp);
        $run = $this->run_shell_command($cmd);
        @unlink($tmp);

        if (!empty($run['skipped'])) {
            return ['ok' => true, 'skipped' => true];
        }
        if (empty($run['ok'])) {
            $error = trim(implode("\n", $run['output'] ?? []));
            // کوتاه کن — لاگ systemd را شلوغ نکند
            $error = preg_replace('/\s+/', ' ', $error) ?? $error;
            if (strlen($error) > 220) {
                $error = substr($error, 0, 220) . '…';
            }
            return ['ok' => false, 'error' => $error !== '' ? $error : 'xray -test failed'];
        }

        return ['ok' => true];
    }

    /**
     * @return array{ok:bool,output:array<int,string>,code:int,skipped?:bool}
     */
    private function run_shell_command(string $command): array {
        if (function_exists('exec')) {
            $out  = [];
            $code = 1;
            @exec($command . ' 2>&1', $out, $code);
            return ['ok' => $code === 0, 'output' => $out, 'code' => $code];
        }
        if (function_exists('shell_exec')) {
            $result = @shell_exec($command . ' 2>&1');
            $text   = is_string($result) ? trim($result) : '';
            $ok     = $text === ''
                || (stripos($text, 'failed') === false && stripos($text, 'error') === false);
            return [
                'ok'     => $ok,
                'output' => $text !== '' ? preg_split('/\r\n|\r|\n/', $text) ?: [] : [],
                'code'   => $ok ? 0 : 1,
            ];
        }
        return ['ok' => true, 'output' => [], 'code' => 0, 'skipped' => true];
    }

    /**
     * @param array<string,mixed> $outbound
     * @return array{ok:bool,delay_ms?:int,error?:string}
     */
    private function measure_real_delay_with_xray(array $outbound): array {
        $bin = $this->resolve_binary();
        if ($bin === '') {
            return ['ok' => false, 'error' => 'xray missing'];
        }
        if (!function_exists('proc_open')) {
            return ['ok' => false, 'error' => 'proc_open disabled'];
        }
        if (!function_exists('curl_init')) {
            return ['ok' => false, 'error' => 'curl extension missing'];
        }

        $proxy_port = $this->pick_local_port();
        if ($proxy_port <= 0) {
            return ['ok' => false, 'error' => 'no free local port'];
        }

        $config = [
            'log'       => ['loglevel' => 'error'],
            'inbounds'  => [[
                'listen'   => '127.0.0.1',
                'port'     => $proxy_port,
                'protocol' => 'socks',
                'settings' => ['udp' => false],
            ]],
            'outbounds' => [
                $outbound,
                ['protocol' => 'freedom', 'tag' => 'direct'],
            ],
        ];
        $cfg_file = $this->write_xray_config_json($config);
        if ($cfg_file === false) {
            return ['ok' => false, 'error' => 'tmp config json'];
        }

        $cmd = escapeshellarg($bin) . ' run -format json -c ' . escapeshellarg($cfg_file);
        $desc = [
            0 => ['pipe', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        $pipes = [];
        $proc  = @proc_open($cmd, $desc, $pipes);
        if (!is_resource($proc)) {
            @unlink($cfg_file);
            return ['ok' => false, 'error' => 'xray start failed'];
        }

        if (isset($pipes[0]) && is_resource($pipes[0])) {
            @fclose($pipes[0]);
        }

        try {
            if (!$this->wait_for_local_port('127.0.0.1', $proxy_port, 4000)) {
                $err = '';
                if (isset($pipes[2]) && is_resource($pipes[2])) {
                    $err = trim((string) stream_get_contents($pipes[2]));
                    $err = preg_replace('/\s+/', ' ', $err) ?? $err;
                    if (strlen($err) > 160) {
                        $err = substr($err, 0, 160) . '…';
                    }
                }
                return ['ok' => false, 'error' => $err !== '' ? $err : 'xray proxy not ready'];
            }

            $delay = 0;
            foreach ($this->get_real_delay_url_candidates() as $url) {
                $delay = $this->http_probe_via_socks5(
                    '127.0.0.1',
                    $proxy_port,
                    $url,
                    max(2000, $this->get_probe_timeout_ms())
                );
                if ($delay > 0) {
                    break;
                }
            }
            if ($delay <= 0) {
                return ['ok' => false, 'error' => 'real delay request failed'];
            }

            return ['ok' => true, 'delay_ms' => $delay];
        } finally {
            foreach ([1, 2] as $idx) {
                if (isset($pipes[$idx]) && is_resource($pipes[$idx])) {
                    @fclose($pipes[$idx]);
                }
            }
            $this->force_stop_proc($proc, $cfg_file);
            @unlink($cfg_file);
        }
    }

    /**
     * SIGTERM alone often leaves orphan xray processes — force SIGKILL + pkill by config path.
     *
     * @param resource $proc
     */
    private function force_stop_proc($proc, string $cfg_file = ''): void {
        if (!is_resource($proc)) {
            return;
        }

        $status = @proc_get_status($proc);
        $pid    = (int) ($status['pid'] ?? 0);

        @proc_terminate($proc, 15);
        $deadline = microtime(true) + 0.4;
        while (microtime(true) < $deadline) {
            $status = @proc_get_status($proc);
            if (empty($status['running'])) {
                break;
            }
            usleep(40000);
        }

        $status = @proc_get_status($proc);
        if (!empty($status['running'])) {
            @proc_terminate($proc, 9);
            if ($pid > 0 && function_exists('posix_kill')) {
                @posix_kill($pid, 9);
            }
        }

        if ($cfg_file !== '' && function_exists('exec')) {
            $needle = basename($cfg_file);
            if ($needle !== '' && preg_match('/^xui-xray-[a-f0-9]+\.json$/', $needle)) {
                @exec('pkill -9 -f ' . escapeshellarg($needle) . ' 2>/dev/null');
            }
        }

        @proc_close($proc);
    }

    private function pick_local_port(): int {
        for ($i = 0; $i < 8; $i++) {
            $port = random_int(20000, 52000);
            $fp = @stream_socket_server('tcp://127.0.0.1:' . $port, $errno, $errstr);
            if ($fp) {
                @fclose($fp);
                return $port;
            }
        }
        return 0;
    }

    private function wait_for_local_port(string $host, int $port, int $timeout_ms): bool {
        $started = microtime(true);
        while (((microtime(true) - $started) * 1000) < $timeout_ms) {
            $fp = @stream_socket_client(
                'tcp://' . $host . ':' . $port,
                $errno,
                $errstr,
                0.25,
                STREAM_CLIENT_CONNECT
            );
            if ($fp) {
                @fclose($fp);
                return true;
            }
            usleep(120000);
        }
        return false;
    }

    private function http_probe_via_socks5(string $proxy_host, int $proxy_port, string $url, int $timeout_ms): int {
        $ch = curl_init($url);
        if ($ch === false) {
            return 0;
        }

        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_NOBODY, true);
        curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
        curl_setopt($ch, CURLOPT_MAXREDIRS, 1);
        curl_setopt($ch, CURLOPT_CONNECTTIMEOUT_MS, max(500, min(15000, $timeout_ms)));
        curl_setopt($ch, CURLOPT_TIMEOUT_MS, max(800, min(20000, $timeout_ms + 1500)));
        curl_setopt($ch, CURLOPT_PROXYTYPE, defined('CURLPROXY_SOCKS5_HOSTNAME') ? CURLPROXY_SOCKS5_HOSTNAME : 7);
        curl_setopt($ch, CURLOPT_PROXY, $proxy_host . ':' . $proxy_port);
        curl_setopt($ch, CURLOPT_USERAGENT, 'XUI-RealDelay/1.0');
        curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
        curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);

        $started = microtime(true);
        $ok      = curl_exec($ch);
        $code    = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        if ($ok === false) {
            return 0;
        }
        if ($code > 0 && $code >= 400) {
            return 0;
        }
        return max(1, (int) round((microtime(true) - $started) * 1000));
    }

    /**
     * Lightweight TCP connect probe.
     * @return array{is_up:bool,response_ms:?int}
     */
    private function tcp_probe(string $host, int $port, int $timeout_ms): array {
        $started = microtime(true);
        $errno   = 0;
        $errstr  = '';
        $fp = @stream_socket_client(
            'tcp://' . $host . ':' . max(1, $port),
            $errno,
            $errstr,
            max(0.2, $timeout_ms / 1000),
            STREAM_CLIENT_CONNECT
        );
        if (!$fp) {
            return ['is_up' => false, 'response_ms' => null];
        }
        @fclose($fp);
        return [
            'is_up'       => true,
            'response_ms' => max(1, (int) round((microtime(true) - $started) * 1000)),
        ];
    }

    private function make_temp_file(string $prefix) {
        $dir = function_exists('sys_get_temp_dir') ? sys_get_temp_dir() : '/tmp';
        $tmp = @tempnam($dir, $prefix);
        return $tmp === false ? false : $tmp;
    }

    /**
     * @param array<string,mixed> $context
     */
    private function log_probe(string $level, string $message, array $context = []): void {
        if (!class_exists(FreeConfigProbeLogService::class)) {
            return;
        }
        (new FreeConfigProbeLogService())->append($level, $message, $context);
    }
}
