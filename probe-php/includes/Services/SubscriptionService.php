<?php
namespace XuiVpn\Services;

/**
 * حداقل stub برای اجرای probe روی VPS — extract host/port از URI.
 */
class SubscriptionService {

    public static function extract_config_address_host(string $line): string {
        $line = trim($line);
        if ($line === '') {
            return '';
        }
        // vless/trojan/ss و بعضی vmessهای غیر استاندارد: user@host:port
        if (preg_match('/^(?:vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\/\/[^@]+@([^:?#\/]+)/i', $line, $m)) {
            return trim($m[1], '[]');
        }
        // vmess استاندارد (v2rayNG): vmess://base64({add,port,...})
        if (preg_match('/^vmess:\/\/(.+)$/i', $line, $m)) {
            $payload = trim($m[1]);
            $hashPos = strpos($payload, '#');
            if ($hashPos !== false) {
                $payload = substr($payload, 0, $hashPos);
            }
            $json = base64_decode(strtr($payload, '-_', '+/'), true);
            if ($json === false || $json === '') {
                $json = base64_decode($payload, true);
            }
            if (is_string($json) && $json !== '') {
                $data = json_decode($json, true);
                if (is_array($data)) {
                    $add = trim((string) ($data['add'] ?? $data['host'] ?? $data['address'] ?? ''));
                    return trim($add, '[]');
                }
            }
        }
        return '';
    }
}
