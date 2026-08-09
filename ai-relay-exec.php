<?php
/**
 * Execute one AI chat job for WordPress relay queue.
 * stdin: JSON { id, op, model, payload: { system, user, messages, max_tokens, temperature } }
 * stdout: JSON { ok:true, result:{ text } } or { ok:false, error }
 *
 * Talks to local Ollama / OpenAI-compatible server on the VPS (default 127.0.0.1:11434).
 */
declare(strict_types=1);

$raw = stream_get_contents(STDIN);
$job = json_decode($raw ?: '', true);
if (!is_array($job)) {
    echo json_encode(['ok' => false, 'error' => 'invalid job json'], JSON_UNESCAPED_UNICODE);
    exit(1);
}

$payload = $job['payload'] ?? [];
if (!is_array($payload)) {
    $payload = [];
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
$maxTokens = max(40, min(280, $maxTokens));
$temperature = (float) ($payload['temperature'] ?? 0.85);

/**
 * @return array{ok:bool,text?:string,error?:string,http?:int}
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
