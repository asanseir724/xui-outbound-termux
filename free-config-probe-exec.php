<?php
/**
 * Probe one free-config URI on VPS/Termux (Xray + TCP). Used by free-config-probe-lib.sh.
 * Reads JSON job from stdin; prints JSON {ok, probe:{alive,ping_ms,method}, error}.
 */
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "CLI only\n");
    exit(1);
}

require_once __DIR__ . '/free-config-probe-bootstrap.php';

$raw = stream_get_contents(STDIN);
$job = json_decode($raw ?: '', true);
if (!is_array($job)) {
    echo json_encode(['ok' => false, 'error' => 'invalid job json'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$uri = trim((string) ($job['config_uri'] ?? ''));
if ($uri === '') {
    echo json_encode(['ok' => false, 'error' => 'config_uri missing'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$probe_opts = is_array($job['probe'] ?? null) ? $job['probe'] : [];
if (!empty($probe_opts['probe_timeout_ms'])) {
    putenv('XUI_OPT_XUI_FREE_CONFIG_PROBE_TIMEOUT_MS=' . (int) $probe_opts['probe_timeout_ms']);
}
if (array_key_exists('xray_validate', $probe_opts)) {
    putenv('XUI_OPT_XUI_FREE_CONFIG_XRAY_VALIDATE=' . (!empty($probe_opts['xray_validate']) ? '1' : '0'));
}
if (array_key_exists('real_delay_enabled', $probe_opts)) {
    putenv('XUI_OPT_XUI_FREE_CONFIG_REAL_DELAY_ENABLED=' . (!empty($probe_opts['real_delay_enabled']) ? '1' : '0'));
}
if (!empty($probe_opts['xray_path'])) {
    putenv('XRAY_BIN=' . (string) $probe_opts['xray_path']);
    putenv('XUI_OPT_XUI_FREE_CONFIG_XRAY_PATH=' . (string) $probe_opts['xray_path']);
}
if (!empty($probe_opts['real_delay_url'])) {
    putenv('XUI_OPT_XUI_FREE_CONFIG_REAL_DELAY_URL=' . (string) $probe_opts['real_delay_url']);
}

if (xui_probe_bootstrap_plugin()) {
    $svc    = new XuiVpn\Services\FreeConfigXrayProbeService();
    $result = $svc->probe_uri($uri);
    echo json_encode([
        'ok'    => true,
        'probe' => [
            'alive'   => !empty($result['alive']),
            'ping_ms' => $result['ping_ms'] ?? null,
            'method'  => (string) ($result['method'] ?? 'tcp'),
        ],
    ], JSON_UNESCAPED_UNICODE);
    exit(0);
}

/**
 * TCP-only fallback when plugin sources are not available on VPS.
 *
 * @return array{alive:bool,ping_ms:?int,method:string}
 */
function xui_tcp_probe_fallback(string $uri, int $timeout_ms): array {
    $host = '';
    $port = 0;
    if (preg_match('/@([^:\/?#]+):(\d+)/', $uri, $m)) {
        $host = $m[1];
        $port = (int) $m[2];
    } elseif (preg_match('/^(?:vmess|vless|trojan|ss|hysteria2?|tuic):\/\//i', $uri)) {
        $host = '';
        $port = 443;
    }
    if ($host === '' || $port <= 0) {
        return ['alive' => false, 'ping_ms' => null, 'method' => 'tcp'];
    }

    $timeout_sec = max(1, (int) ceil($timeout_ms / 1000));
    $start       = microtime(true);
    $fp          = @fsockopen($host, $port, $errno, $errstr, $timeout_sec);
    if ($fp === false) {
        return ['alive' => false, 'ping_ms' => null, 'method' => 'tcp'];
    }
    fclose($fp);
    $ms = (int) round((microtime(true) - $start) * 1000);
    return ['alive' => true, 'ping_ms' => $ms, 'method' => 'tcp'];
}

$timeout = max(1500, (int) ($probe_opts['probe_timeout_ms'] ?? 3500));
$result  = xui_tcp_probe_fallback($uri, $timeout);
echo json_encode(['ok' => true, 'probe' => $result], JSON_UNESCAPED_UNICODE);
