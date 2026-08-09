<?php
/**
 * Execute one AI / utility job for WordPress relay queue.
 * stdin: JSON { id, op, model, payload }
 * stdout: JSON { ok:true, result:{...} } or { ok:false, error }
 *
 * ops:
 *  - chat (default): local Ollama
 *  - proxy_fetch: download public SOCKS/HTTP lists on VPS and TCP-probe survivors
 */
declare(strict_types=1);

$raw = stream_get_contents(STDIN);
$job = json_decode($raw ?: '', true);
if (!is_array($job)) {
    echo json_encode(['ok' => false, 'error' => 'invalid job json'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$op = strtolower(trim((string) ($job['op'] ?? 'chat')));
$payload = $job['payload'] ?? [];
if (!is_array($payload)) {
    $payload = [];
}

if ($op === 'proxy_fetch') {
    echo json_encode(xui_proxy_fetch_job($payload), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit(0);
}

$model = trim((string) ($job['model'] ?? ''));
if ($model === '') {
    $model = trim((string) (getenv('XUI_AI_MODEL') ?: 'qwen2.5:3b'));
}
$endpoint = rtrim(trim((string) (getenv('XUI_AI_ENDPOINT') ?: 'http://127.0.0.1:11434')), '/');

$messages = [];
if (!empty($payload['messages']) && is_array($payload['messages'])) {
    foreach ($payload['messages'] as $m) {
        if (!is_array($m)) {
            continue;
        }
        $role = (string) ($m['role'] ?? '');
        $content = trim((string) ($m['content'] ?? ''));
        if ($role !== '' && $content !== '') {
            $messages[] = ['role' => $role, 'content' => $content];
        }
    }
}
if ($messages === []) {
    $system = trim((string) ($payload['system'] ?? ''));
    $user = trim((string) ($payload['user'] ?? ''));
    if ($system !== '') {
        $messages[] = ['role' => 'system', 'content' => $system];
    }
    if ($user !== '') {
        $messages[] = ['role' => 'user', 'content' => $user];
    }
}
if ($messages === []) {
    echo json_encode(['ok' => false, 'error' => 'empty messages'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$maxTokens = (int) ($payload['max_tokens'] ?? 160);
$maxTokens = max(40, min(560, $maxTokens));
$temperature = (float) ($payload['temperature'] ?? 0.85);

/**
 * @return array{ok:bool,text?:string,error?:string,http?:int,data?:array}
 */
function xui_ai_http_json(string $url, array $body, int $timeout = 55): array {
    $ch = curl_init($url);
    if ($ch === false) {
        return ['ok' => false, 'error' => 'curl_init failed'];
    }
    $json = json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST           => true,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json', 'Accept: application/json'],
        CURLOPT_POSTFIELDS     => $json,
        CURLOPT_CONNECTTIMEOUT => 8,
        CURLOPT_TIMEOUT        => $timeout,
    ]);
    $resp = curl_exec($ch);
    $errno = curl_errno($ch);
    $err = curl_error($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($errno !== 0) {
        return ['ok' => false, 'error' => 'curl: ' . $err, 'http' => $code];
    }
    $decoded = json_decode(is_string($resp) ? $resp : '', true);
    if (!is_array($decoded)) {
        return ['ok' => false, 'error' => 'bad json from LLM http=' . $code, 'http' => $code];
    }
    return ['ok' => true, 'data' => $decoded, 'http' => $code];
}

/**
 * @param array<string,mixed> $payload
 * @return array{ok:bool,result?:array,error?:string}
 */
function xui_proxy_fetch_job(array $payload): array {
    $want = max(5, min(40, (int) ($payload['limit'] ?? 20)));
    $urls = [
        ['u' => 'https://api.proxyscrape.com/v2/?request=displayproxies&protocol=socks5&timeout=3000&country=all&ssl=all&anonymity=all', 't' => 'socks5'],
        ['u' => 'https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=3000&country=all&ssl=all&anonymity=all', 't' => 'http'],
        ['u' => 'https://raw.githubusercontent.com/hookzof/socks5_list/master/proxy.txt', 't' => 'socks5'],
        ['u' => 'https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/socks5.txt', 't' => 'socks5'],
        ['u' => 'https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/socks5.txt', 't' => 'socks5'],
    ];
    $candidates = [];
    foreach ($urls as $row) {
        $body = xui_http_get_body($row['u'], 10);
        if ($body === '') {
            continue;
        }
        foreach (preg_split('/\R+/', $body) ?: [] as $line) {
            $line = trim($line);
            if (!preg_match('/^(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})$/', $line, $m)) {
                continue;
            }
            $port = (int) $m[2];
            if ($port < 1 || $port > 65535) {
                continue;
            }
            $candidates[] = ['host' => $m[1], 'port' => $port, 'type' => $row['t']];
            if (count($candidates) >= 250) {
                break 2;
            }
        }
    }
    if ($candidates === []) {
        return ['ok' => false, 'error' => 'no proxy candidates from public lists'];
    }

    shuffle($candidates);
    $alive = [];
    $tested = 0;
    foreach ($candidates as $c) {
        if (count($alive) >= $want) {
            break;
        }
        if ($tested >= 120) {
            break;
        }
        $tested++;
        $ms = xui_tcp_ping($c['host'], (int) $c['port'], 1.6);
        if ($ms < 0) {
            continue;
        }
        $alive[] = [
            'host'       => $c['host'],
            'port'       => (int) $c['port'],
            'type'       => $c['type'],
            'latency_ms' => $ms,
        ];
    }

    if ($alive === []) {
        return ['ok' => false, 'error' => 'no tcp-alive proxies after probe tested=' . $tested];
    }

    return [
        'ok'     => true,
        'result' => [
            'proxies' => $alive,
            'tested'  => $tested,
            'found'   => count($candidates),
            'alive'   => count($alive),
            'text'    => 'proxy_fetch ok ' . count($alive),
        ],
    ];
}

function xui_http_get_body(string $url, int $timeout = 10): string {
    $ch = curl_init($url);
    if ($ch === false) {
        return '';
    }
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT        => $timeout,
        CURLOPT_USERAGENT      => 'XUI-ProxyFetch/1.0',
    ]);
    $resp = curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code >= 400 || !is_string($resp)) {
        return '';
    }
    return $resp;
}

function xui_tcp_ping(string $host, int $port, float $timeout = 1.5): int {
    $start = microtime(true);
    $fp = @fsockopen($host, $port, $errno, $errstr, $timeout);
    if (!$fp) {
        return -1;
    }
    $ms = (int) round((microtime(true) - $start) * 1000);
    fclose($fp);
    return max(1, $ms);
}

$text = '';

// 1) OpenAI-compatible
$r1 = xui_ai_http_json($endpoint . '/v1/chat/completions', [
    'model'       => $model,
    'messages'    => $messages,
    'max_tokens'  => $maxTokens,
    'temperature' => $temperature,
    'stream'      => false,
]);
if (!empty($r1['ok']) && is_array($r1['data'] ?? null)) {
    $text = trim((string) ($r1['data']['choices'][0]['message']['content'] ?? ''));
}

// 2) Ollama /api/chat
if ($text === '') {
    $r2 = xui_ai_http_json($endpoint . '/api/chat', [
        'model'    => $model,
        'messages' => $messages,
        'stream'   => false,
        'options'  => [
            'temperature' => $temperature,
            'num_predict' => $maxTokens,
        ],
    ]);
    if (!empty($r2['ok']) && is_array($r2['data'] ?? null)) {
        $text = trim((string) ($r2['data']['message']['content'] ?? ''));
    } elseif (empty($r1['ok'])) {
        $err = (string) ($r2['error'] ?? $r1['error'] ?? 'LLM unreachable');
        echo json_encode(['ok' => false, 'error' => $err], JSON_UNESCAPED_UNICODE);
        exit(1);
    }
}

$text = preg_replace('/^["«»\']+|["«»\']+$/u', '', $text ?? '');
$text = trim((string) $text);
if ($text === '') {
    echo json_encode(['ok' => false, 'error' => 'empty model response'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

echo json_encode([
    'ok'     => true,
    'result' => [
        'text'  => $text,
        'model' => $model,
    ],
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
