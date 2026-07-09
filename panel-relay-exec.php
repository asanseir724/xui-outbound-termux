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
function relay_login(string $panel_url, string $user, string $pass): array
{
    $attempts = [
        [
            'headers' => ['Content-Type: application/json', 'Accept: application/json'],
            'body'    => json_encode(['username' => $user, 'password' => $pass]),
        ],
        [
            'headers' => ['Accept: application/json'],
            'body'    => http_build_query(['username' => $user, 'password' => $pass]),
        ],
    ];

    foreach ($attempts as $attempt) {
        $res = relay_http(
            $panel_url . '/login',
            'POST',
            $attempt['body'],
            $attempt['headers']
        );
        if (!empty($res['error'])) {
            continue;
        }
        $decoded = json_decode($res['body'], true);
        if (!is_array($decoded) || empty($decoded['success'])) {
            continue;
        }
        $cookie = cookie_header($res['cookies']);
        if ($cookie === '') {
            $cookie = 'session=relay';
        }
        return ['ok' => true, 'cookie' => $cookie, 'error' => ''];
    }

    return ['ok' => false, 'cookie' => '', 'error' => 'panel login failed'];
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

    $res = relay_http($url, $method, $body, $headers, 120);
    if (!empty($res['error'])) {
        return ['ok' => false, 'result' => null, 'error' => $res['error']];
    }
    if ($res['code'] === 401 || $res['code'] === 403) {
        return ['ok' => false, 'result' => null, 'error' => 'unauthorized HTTP ' . $res['code']];
    }

    $decoded = json_decode($res['body'], true);
    if (!is_array($decoded)) {
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

$login = relay_login($panel_url, $user, $pass);
if (!$login['ok']) {
    echo json_encode(['ok' => false, 'error' => $login['error']], JSON_UNESCAPED_UNICODE);
    exit(1);
}

if (!is_array($payload)) {
    $payload = [];
}

$req = relay_request(
    $panel_url,
    $endpoint,
    $method,
    $payload,
    $login['cookie'],
    $forceForm
);

if (!$req['ok']) {
    echo json_encode(['ok' => false, 'error' => $req['error']], JSON_UNESCAPED_UNICODE);
    exit(1);
}

echo json_encode(['ok' => true, 'result' => $req['result']], JSON_UNESCAPED_UNICODE);
