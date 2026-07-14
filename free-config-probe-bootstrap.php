<?php
/**
 * Minimal WordPress stubs so FreeConfigXrayProbeService can run on VPS/Termux CLI.
 */
declare(strict_types=1);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

if (!function_exists('get_option')) {
    function get_option(string $name, $default = false) {
        static $map = [
            'xui_free_config_xray_validate'      => '1',
            'xui_free_config_real_delay_enabled' => '1',
            'xui_free_config_probe_timeout_ms'   => '3500',
            'xui_free_config_real_delay_url'     => '',
            'xui_free_config_xray_path'          => '',
        ];
        $env_key = 'XUI_OPT_' . strtoupper(preg_replace('/[^a-z0-9_]/i', '_', $name));
        $env_val = getenv($env_key);
        if ($env_val !== false && $env_val !== '') {
            return $env_val;
        }
        if ($name === 'xui_free_config_xray_path') {
            $xray = getenv('XRAY_BIN');
            if (is_string($xray) && $xray !== '') {
                return $xray;
            }
        }
        return $map[$name] ?? $default;
    }
}

if (!function_exists('wp_json_encode')) {
    function wp_json_encode($data, int $options = 0, int $depth = 512) {
        return json_encode($data, $options | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES, $depth);
    }
}

if (!function_exists('current_time')) {
    function current_time(string $type) {
        return $type === 'mysql' ? gmdate('Y-m-d H:i:s') : (string) time();
    }
}

/**
 * @return bool
 */
function xui_probe_bootstrap_plugin(): bool {
    static $ready = null;
    if ($ready !== null) {
        return $ready;
    }

    $plugin_dir = getenv('XUI_VPN_PLUGIN_DIR') ?: '';
    if ($plugin_dir === '' || !is_dir($plugin_dir)) {
        $ready = false;
        return false;
    }

    if (!defined('XUI_VPN_PLUGIN_DIR')) {
        define('XUI_VPN_PLUGIN_DIR', rtrim(str_replace('\\', '/', $plugin_dir), '/') . '/');
    }

    spl_autoload_register(static function (string $class): void {
        $prefix  = 'XuiVpn\\';
        $base    = XUI_VPN_PLUGIN_DIR . 'includes/';
        if (strncmp($prefix, $class, strlen($prefix)) !== 0) {
            return;
        }
        $file = $base . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
        if (is_file($file)) {
            require_once $file;
        }
    });

    $ready = class_exists('XuiVpn\\Services\\FreeConfigXrayProbeService');
    return $ready;
}
