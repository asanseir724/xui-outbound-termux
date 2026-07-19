<?php
/**
 * Execute one X-UI panel API job (login + request). Used by xui-panel-relay.sh on VPS/Termux.
 * Reads JSON job from stdin; prints JSON {ok, result, error} to stdout.
 */
declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "CLI only\n");
    exit(1);
}

$raw = stream_get_contents(STDIN);
$job = json_decode($raw ?: '', true);
if (!is_array($job)) {
    echo json_encode(['ok' => false, 'error' => 'invalid job json'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$panel_url = rtrim((string) ($job['panel_url'] ?? ''), '/');
$user      = (string) ($job['username'] ?? '');
$pass      = (string) ($job['password'] ?? '');
$endpoint  = (string) ($job['endpoint'] ?? '');
$method    = strtoupper((string) ($job['method'] ?? 'GET'));
$payload   = $job['payload'] ?? [];
$forceForm = !empty($job['force_form']);

if ($panel_url === '' || $endpoint === '') {
    echo json_encode(['ok' => false, 'error' => 'panel_url or endpoint missing'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

if (!function_exists('curl_init')) {
    echo json_encode(['ok' => false, 'error' => 'php-curl extension required'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

/**
 * @return array{code:int,body:string,cookies:array<int,string>}
 */
function relay_http(string $url, string $method, $body, array $headers, int $timeout = 45): array
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 5,
        CURLOPT_CONNECTTIMEOUT => 15,
        CURLOPT_TIMEOUT        => $timeout,
        CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_SSL_VERIFYHOST => 0,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_HEADER         => true,
    ]);
    if ($body !== null && $body !== '') {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    }
    $resp = curl_exec($ch);
    if ($resp === false) {
        $err = curl_error($ch);
        curl_close($ch);
        return ['code' => 0, 'body' => '', 'cookies' => [], 'error' => $err];
    }
    $code     = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $hdr_size = (int) curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);
    $hdr  = substr($resp, 0, $hdr_size);
    $body = substr($resp, $hdr_size);
    $cookies = [];
    foreach (preg_split('/\r\n|\n|\r/', $hdr) as $line) {
        if (stripos($line, 'set-cookie:') === 0) {
            $cookies[] = trim(substr($line, 11));
        }
    }
    return ['code' => $code, 'body' => $body, 'cookies' => $cookies];
}

/**
 * @param array<int,string> $setCookies
 */
function cookie_header(array $setCookies): string
{
    $pairs = [];
    foreach ($setCookies as $line) {
        $part = explode(';', $line)[0] ?? '';
        if ($part !== '') {
            $pairs[] = trim($part);
        }
    }
    return implode('; ', $pairs);
}

/**
 * @return array{ok:bool,cookie:string,error:string}
 */
function relay_login(string $panel_url, string $user, string $pass, string $twoFactorCode = ''): array
{
    // 3x-ui / MHSanaei UI posts application/x-www-form-urlencoded via Qs.stringify
    // (JSON body → "The Input data format is invalid").
    $attempts = [
        [
            'headers' => [
                'Content-Type: application/x-www-form-urlencoded; charset=UTF-8',
                'Accept: application/json',
                'X-Requested-With: XMLHttpRequest',
            ],
            'body'    => http_build_query([
                'username'      => $user,
                'password'      => $pass,
                'twoFactorCode' => $twoFactorCode,
            ]),
        ],
        [
            'headers' => [
                'Content-Type: application/x-www-form-urlencoded; charset=UTF-8',
                'Accept: application/json',
                'X-Requested-With: XMLHttpRequest',
            ],
            'body'    => http_build_query([
                'username' => $user,
                'password' => $pass,
            ]),
        ],
        [
            'headers' => ['Content-Type: application/json', 'Accept: application/json'],
            'body'    => json_encode([
                'username'      => $user,
                'password'      => $pass,
                'twoFactorCode' => $twoFactorCode,
            ], JSON_UNESCAPED_UNICODE),
        ],
    ];

    $lastMsg = '';
    $lastCode = 0;
    $lastCurl = '';

    foreach ($attempts as $attempt) {
        $res = relay_http(
            $panel_url . '/login',
            'POST',
            $attempt['body'],
            $attempt['headers'],
            45
        );
        if (!empty($res['error'])) {
            $lastCurl = (string) $res['error'];
            continue;
        }
        $lastCode = (int) ($res['code'] ?? 0);
        $decoded = json_decode($res['body'], true);
        if (!is_array($decoded)) {
            $lastMsg = 'non-JSON login response HTTP ' . $lastCode;
            continue;
        }
        if (empty($decoded['success'])) {
            $lastMsg = trim((string) ($decoded['msg'] ?? $decoded['message'] ?? 'login rejected'));
            continue;
        }
        $cookie = cookie_header($res['cookies']);
        if ($cookie === '') {
            $cookie = 'session=relay';
        }
        return ['ok' => true, 'cookie' => $cookie, 'error' => ''];
    }

    $err = 'panel login failed';
    if ($lastMsg !== '') {
        $err .= ': ' . $lastMsg;
    } elseif ($lastCurl !== '') {
        $err .= ': ' . $lastCurl;
    } elseif ($lastCode > 0) {
        $err .= ' HTTP ' . $lastCode;
    }
    return ['ok' => false, 'cookie' => '', 'error' => $err];
}

function relay_cookie_cache_path(string $panel_url, string $user): string
{
    $dir = '/etc/xui-outbound/cache';
    if (!is_dir($dir)) {
        @mkdir($dir, 0700, true);
    }
    if (!is_dir($dir) || !is_writable($dir)) {
        $dir = sys_get_temp_dir();
    }
    return rtrim($dir, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR
        . 'panel-cookie-' . hash('sha256', $panel_url . "\0" . $user) . '.txt';
}

function relay_load_cached_cookie(string $panel_url, string $user): string
{
    $path = relay_cookie_cache_path($panel_url, $user);
    if (!is_file($path)) {
        return '';
    }
    if (filemtime($path) < time() - 1800) {
        @unlink($path);
        return '';
    }
    $raw = trim((string) @file_get_contents($path));
    return $raw;
}

function relay_save_cached_cookie(string $panel_url, string $user, string $cookie): void
{
    if ($cookie === '') {
        return;
    }
    @file_put_contents(relay_cookie_cache_path($panel_url, $user), $cookie, LOCK_EX);
}

function relay_clear_cached_cookie(string $panel_url, string $user): void
{
    $path = relay_cookie_cache_path($panel_url, $user);
    if (is_file($path)) {
        @unlink($path);
    }
}


/**
 * @param array<string,mixed> $payload
 * @return array{ok:bool,result:array<string,mixed>|null,error:string}
 */
function relay_request(
    string $panel_url,
    string $endpoint,
    string $method,
    array $payload,
    string $cookie,
    bool $forceForm
): array {
    $url = $panel_url . $endpoint;
    $headers = ['Cookie: ' . $cookie, 'Accept: application/json'];

    $body = null;
    if ($payload !== []) {
        if (!$forceForm && strpos($endpoint, '/api/') !== false) {
            $headers[] = 'Content-Type: application/json';
            $body = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        } else {
            $body = http_build_query($payload);
        }
    }

    $timeout = 180;
    $ep      = strtolower($endpoint);
    if (str_contains($ep, '/inbounds/update/') || str_contains($ep, 'addclient')) {
        $timeout = 300;
    }

    $res = relay_http($url, $method, $body, $headers, $timeout);
    if (!empty($res['error'])) {
        return ['ok' => false, 'result' => null, 'error' => $res['error']];
    }
    if ($res['code'] === 401 || $res['code'] === 403) {
        return ['ok' => false, 'result' => null, 'error' => 'unauthorized HTTP ' . $res['code']];
    }

    $decoded = json_decode($res['body'], true);
    if (!is_array($decoded)) {
        // /sub/{id} returns plain base64 text — not JSON.
        if ($res['code'] === 200 && $res['body'] !== '' && stripos($endpoint, '/sub/') !== false) {
            return [
                'ok'     => true,
                'result' => [
                    'success'  => true,
                    'raw_body' => $res['body'],
                ],
                'error'  => '',
            ];
        }
        // Raw SQLite backup (e.g. /server/getDb) is not JSON — relay as base64.
        if ($res['code'] === 200 && strlen($res['body']) > 500) {
            return [
                'ok'     => true,
                'result' => [
                    'success'    => true,
                    'raw_base64' => base64_encode($res['body']),
                ],
                'error'  => '',
            ];
        }
        return ['ok' => false, 'result' => null, 'error' => 'invalid JSON from panel HTTP ' . $res['code']];
    }

    return ['ok' => true, 'result' => $decoded, 'error' => ''];
}

/**
 * Optionally shrink huge inbounds/list JSON before posting back to WordPress.
 * Prefer keeping settings.clients — stripping them breaks merge/update on WP.
 * Only strip when payload is enormous; prefer dropping clientStats first.
 *
 * @param array<string,mixed> $result
 * @return array{result:array<string,mixed>, clients_stripped:bool}
 */
function maybe_trim_inbounds_list_result(array $result): array
{
    $encoded = json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $size    = is_string($encoded) ? strlen($encoded) : 0;
    // Keep full clients under ~1.5MB — WP REST can handle this; host may struggle above.
    if ($size > 0 && $size <= 1500000) {
        return ['result' => $result, 'clients_stripped' => false];
    }

    if (empty($result['obj']) || !is_array($result['obj'])) {
        return ['result' => $result, 'clients_stripped' => false];
    }

    // First pass: drop clientStats (stats only) — keep settings.clients.
    foreach ($result['obj'] as $idx => $ib) {
        if (!is_array($ib)) {
            continue;
        }
        unset($ib['clientStats']);
        $result['obj'][$idx] = $ib;
    }

    $encoded = json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $size    = is_string($encoded) ? strlen($encoded) : 0;
    if ($size > 0 && $size <= 1500000) {
        return ['result' => $result, 'clients_stripped' => false];
    }

    // Last resort for huge panels: strip clients but mark so WP never merges.
    foreach ($result['obj'] as $idx => $ib) {
        if (!is_array($ib)) {
            continue;
        }
        if (isset($ib['settings']) && is_string($ib['settings'])) {
            $settings = json_decode($ib['settings'], true);
            if (is_array($settings)) {
                unset($settings['clients']);
                $ib['settings'] = json_encode($settings, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            }
        } elseif (isset($ib['settings']) && is_array($ib['settings'])) {
            unset($ib['settings']['clients']);
        }
        $result['obj'][$idx] = $ib;
    }
    $result['_xui_clients_stripped'] = true;

    return ['result' => $result, 'clients_stripped' => true];
}

$cookie = relay_load_cached_cookie($panel_url, $user);
if ($cookie === '') {
    $login = relay_login($panel_url, $user, $pass);
    if (!$login['ok']) {
        echo json_encode(['ok' => false, 'error' => $login['error']], JSON_UNESCAPED_UNICODE);
        exit(1);
    }
    $cookie = $login['cookie'];
    relay_save_cached_cookie($panel_url, $user, $cookie);
}

// Job endpoint is login only — relay_login above is enough (avoid second POST → HTTP 404).
$ep_norm = rtrim(strtolower($endpoint), '/');
if ($ep_norm === '/login' || str_ends_with($ep_norm, '/login')) {
    echo json_encode(['ok' => true, 'result' => ['success' => true, 'msg' => 'login ok']], JSON_UNESCAPED_UNICODE);
    exit(0);
}

if (!is_array($payload)) {
    $payload = [];
}

$req = relay_request(
    $panel_url,
    $endpoint,
    $method,
    $payload,
    $cookie,
    $forceForm
);

// Stale session → refresh cookie once and retry
if (!$req['ok'] && (
    stripos((string) ($req['error'] ?? ''), 'unauthorized') !== false
    || stripos((string) ($req['error'] ?? ''), '401') !== false
    || stripos((string) ($req['error'] ?? ''), '403') !== false
)) {
    relay_clear_cached_cookie($panel_url, $user);
    $login = relay_login($panel_url, $user, $pass);
    if (!$login['ok']) {
        echo json_encode(['ok' => false, 'error' => $login['error']], JSON_UNESCAPED_UNICODE);
        exit(1);
    }
    $cookie = $login['cookie'];
    relay_save_cached_cookie($panel_url, $user, $cookie);
    $req = relay_request($panel_url, $endpoint, $method, $payload, $cookie, $forceForm);
}

if (!$req['ok']) {
    echo json_encode(['ok' => false, 'error' => $req['error']], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$result = $req['result'];
if (is_array($result) && stripos($endpoint, 'inbounds/list') !== false) {
    $trimmed = maybe_trim_inbounds_list_result($result);
    $result  = $trimmed['result'];
}

echo json_encode(['ok' => true, 'result' => $result], JSON_UNESCAPED_UNICODE);
