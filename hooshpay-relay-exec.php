<?php
/**
 * Execute one HooshPay API job from WordPress relay queue.
 * stdin: JSON job { id, method, path, api_key, body }
 * stdout: JSON { ok: true, result: { http_code, body, raw } } or { ok: false, error }
 */
declare(strict_types=1);

$raw = stream_get_contents(STDIN);
$job = json_decode($raw ?: '', true);
if (!is_array($job)) {
    echo json_encode(['ok' => false, 'error' => 'invalid job json'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$method  = strtoupper(trim((string) ($job['method'] ?? 'POST')));
$path    = (string) ($job['path'] ?? '');
$api_key = trim((string) ($job['api_key'] ?? ''));
$body    = $job['body'] ?? null;

if ($api_key === '') {
    echo json_encode(['ok' => false, 'error' => 'missing api_key'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$path = '/' . ltrim($path, '/');
if (!preg_match('#^/api/v1/invoices(/|$)#', $path)) {
    echo json_encode(['ok' => false, 'error' => 'path not allowed'], JSON_UNESCAPED_UNICODE);
    exit(1);
}
if (!in_array($method, ['GET', 'POST'], true)) {
    echo json_encode(['ok' => false, 'error' => 'method not allowed'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$base = 'https://pay.hooshnet.com';
$url  = $base . $path;

$ch = curl_init($url);
if ($ch === false) {
    echo json_encode(['ok' => false, 'error' => 'curl_init failed'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$headers = [
    'Accept: application/json',
    'X-API-KEY: ' . $api_key,
];

$opts = [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_CONNECTTIMEOUT => 15,
    CURLOPT_TIMEOUT        => 30,
    CURLOPT_FOLLOWLOCATION => true,
    CURLOPT_MAXREDIRS      => 3,
    CURLOPT_SSL_VERIFYPEER => true,
    CURLOPT_SSL_VERIFYHOST => 2,
    CURLOPT_HTTPHEADER     => $headers,
];

if ($method === 'GET') {
    $opts[CURLOPT_HTTPGET] = true;
} else {
    $headers[] = 'Content-Type: application/json';
    $opts[CURLOPT_HTTPHEADER] = $headers;
    $opts[CURLOPT_POST] = true;
    $opts[CURLOPT_POSTFIELDS] = is_array($body)
        ? json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)
        : '{}';
}

curl_setopt_array($ch, $opts);
$resp = curl_exec($ch);
$errno = curl_errno($ch);
$err   = curl_error($ch);
$code  = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($errno !== 0) {
    echo json_encode(['ok' => false, 'error' => 'curl: ' . $err], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$rawBody = is_string($resp) ? $resp : '';
$decoded = json_decode($rawBody, true);

echo json_encode([
    'ok'     => true,
    'result' => [
        'http_code' => $code,
        'body'      => is_array($decoded) ? $decoded : null,
        'raw'       => is_array($decoded) ? '' : substr($rawBody, 0, 4000),
    ],
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
