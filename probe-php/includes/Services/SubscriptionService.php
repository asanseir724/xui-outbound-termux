<?php
namespace XuiVpn\Services;

/**
 * حداقل stub برای اجرای probe روی VPS — فقط extract_config_address_host.
 */
class SubscriptionService {

    public static function extract_config_address_host(string $line): string {
        $line = trim($line);
        if ($line === '') {
            return '';
        }
        if (preg_match('/^(?:vless|vmess|trojan|ss|ssr|hysteria2?|tuic):\/\/[^@]+@([^:?#\/]+)/i', $line, $m)) {
            return trim($m[1], '[]');
        }
        return '';
    }
}
