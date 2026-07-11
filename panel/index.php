<?php
/**
 * xui-outbound — web admin panel (single file).
 *
 * Served by the PHP built-in server (Termux or a Linux VPS). Lets you edit
 * config.sh, run a sync, test the connection and read the log from a browser.
 *
 * When XUI_PANEL_PASSWORD_FILE points at a file with a password (set by the
 * VPS installer), the panel requires login — important since a VPS exposes it
 * to the public internet.
 */

error_reporting(E_ALL & ~E_DEPRECATED & ~E_NOTICE);

session_start();

$PROJECT_DIR = dirname(__DIR__);
$CONFIG_FILE = $PROJECT_DIR . '/config.sh';
$EXAMPLE_FILE = $PROJECT_DIR . '/config.example.sh';
$SYNC_SCRIPT = $PROJECT_DIR . '/xui-sync.sh';

// ---------------------------------------------------------------------------
// Optional password gate (enabled on VPS where the panel is public)
// ---------------------------------------------------------------------------
$PANEL_PASSWORD = '';
$pwFile = getenv('XUI_PANEL_PASSWORD_FILE');
if ($pwFile && is_file($pwFile)) {
    $PANEL_PASSWORD = trim((string) file_get_contents($pwFile));
}
if ($PANEL_PASSWORD === '') {
    $envPw = getenv('XUI_PANEL_PASSWORD');
    if ($envPw !== false && trim((string) $envPw) !== '') {
        $PANEL_PASSWORD = trim((string) $envPw);
    }
}
if ($PANEL_PASSWORD === '') {
    $PANEL_PASSWORD = '1895233171';
}
$AUTH_REQUIRED = $PANEL_PASSWORD !== '';

if ($AUTH_REQUIRED) {
    if (isset($_GET['logout'])) {
        $_SESSION = [];
        session_destroy();
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
        exit;
    }

    $login_error = '';
    if (($_POST['action'] ?? '') === 'login') {
        if (hash_equals($PANEL_PASSWORD, (string) ($_POST['password'] ?? ''))) {
            $_SESSION['xui_auth'] = true;
        } else {
            $login_error = 'رمز اشتباه است.';
        }
    }

    if (empty($_SESSION['xui_auth'])) {
        ?>
<!DOCTYPE html>
<html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ورود — XUI Outbound</title>
<style>
  :root{--bg:#f4f4f5;--card:#fff;--line:#e4e4e7;--txt:#18181b;--mut:#71717a;--acc:#2563eb;--err:#dc2626;}
  *{box-sizing:border-box}
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Vazirmatn,Tahoma,sans-serif;background:var(--bg);color:var(--txt);display:flex;min-height:100vh;align-items:center;justify-content:center;padding:20px}
  .box{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:28px 24px;width:340px;max-width:100%;box-shadow:0 1px 3px rgba(0,0,0,.04)}
  .logo{font-size:13px;color:var(--mut);margin-bottom:4px}
  h1{font-size:20px;font-weight:600;margin:0 0 20px;letter-spacing:-.02em}
  input{width:100%;padding:10px 12px;border-radius:8px;border:1px solid var(--line);background:#fff;color:var(--txt);font-size:14px}
  input:focus{outline:none;border-color:var(--acc);box-shadow:0 0 0 3px rgba(37,99,235,.12)}
  button{width:100%;margin-top:16px;padding:11px;border:0;border-radius:8px;background:var(--acc);color:#fff;font-size:14px;font-weight:600;cursor:pointer}
  button:hover{background:#1d4ed8}
  .err{color:var(--err);font-size:13px;margin-top:12px}
</style></head><body>
  <form class="box" method="post">
    <div class="logo">XUI Outbound</div>
    <h1>ورود به پنل</h1>
    <input type="hidden" name="action" value="login">
    <input type="password" name="password" placeholder="رمز ورود" autofocus>
    <button type="submit">ورود</button>
    <?php if (!empty($login_error)): ?><div class="err"><?= htmlspecialchars($login_error) ?></div><?php endif; ?>
  </form>
</body></html>
        <?php
        exit;
    }
}

$FIELDS = [
    'SITE_URL'       => ['label' => 'آدرس سایت وردپرس', 'placeholder' => 'https://your-wp-site.com', 'type' => 'text'],
    'MOBILE_TOKEN'   => ['label' => 'توکن اپ موبایل', 'placeholder' => 'از Outbound Sync کپی کنید', 'type' => 'text'],
    'INTERVAL_MIN'   => ['label' => 'فاصله همگام‌سازی (دقیقه)', 'placeholder' => '60', 'type' => 'number'],
    'SUB_USER_AGENT' => ['label' => 'User-Agent دریافت ساب', 'placeholder' => 'HiddifyNext/4.1.0 ...', 'type' => 'text'],
    'PROXY_URL'      => ['label' => 'پراکسی ساب (فقط حالت Proxy هیدیفای)', 'placeholder' => 'socks5h://127.0.0.1:2334 — خالی برای حالت VPN', 'type' => 'text'],
    'FETCH_TIMEOUT'  => ['label' => 'مهلت دریافت ساب (ثانیه)', 'placeholder' => '45', 'type' => 'number'],
];

$DEFAULTS = [
    'SITE_URL'       => '',
    'MOBILE_TOKEN'   => '',
    'INTERVAL_MIN'   => '60',
    'SUB_USER_AGENT' => 'HiddifyNext/4.1.0 (Android) v2rayNG/1.8.0',
    'PROXY_URL'      => '',
    'FETCH_TIMEOUT'  => '45',
    'LOG_FILE'       => '',
];

/** Parse KEY="value" lines from config.sh (bash-compatible). */
function read_config(string $file, array $defaults): array {
    $cfg = $defaults;
    if (is_file($file)) {
        foreach (file($file, FILE_IGNORE_NEW_LINES) as $line) {
            if (preg_match('/^\s*([A-Z_][A-Z0-9_]*)="(.*)"\s*$/', $line, $m)) {
                $val = $m[2];
                $val = str_replace(['\\"', '\\\\', '\\$', '\\`'], ['"', '\\', '$', '`'], $val);
                $cfg[$m[1]] = $val;
            }
        }
    }
    return $cfg;
}

/** Escape a value to live safely inside bash double quotes. */
function bash_escape(string $v): string {
    return str_replace(['\\', '"', '$', '`'], ['\\\\', '\\"', '\\$', '\\`'], $v);
}

function write_config(string $file, array $cfg): bool {
    $logFile = $cfg['LOG_FILE'] !== '' ? $cfg['LOG_FILE'] : '$HOME/.config/xui-sync/sync.log';
    $lines = [];
    $lines[] = '# Generated by the xui-outbound-termux web panel';
    $lines[] = 'SITE_URL="' . bash_escape($cfg['SITE_URL']) . '"';
    $lines[] = 'MOBILE_TOKEN="' . bash_escape($cfg['MOBILE_TOKEN']) . '"';
    $lines[] = 'INTERVAL_MIN=' . (int) $cfg['INTERVAL_MIN'];
    $lines[] = 'SUB_USER_AGENT="' . bash_escape($cfg['SUB_USER_AGENT']) . '"';
    $lines[] = 'PROXY_URL="' . bash_escape($cfg['PROXY_URL']) . '"';
    $lines[] = 'FETCH_TIMEOUT=' . (int) $cfg['FETCH_TIMEOUT'];
    // LOG_FILE may legitimately contain $HOME — keep it unescaped on purpose.
    $lines[] = 'LOG_FILE="' . $logFile . '"';
    return file_put_contents($file, implode("\n", $lines) . "\n") !== false;
}

function tail_file(string $file, int $lines = 60, bool $newestFirst = true): string {
    if (!is_file($file)) {
        return '(هنوز لاگی ثبت نشده)';
    }
    $all = file($file, FILE_IGNORE_NEW_LINES);
    $all = array_slice($all, -$lines);
    if (!$all) {
        return '(لاگ خالی است)';
    }
    if ($newestFirst) {
        $all = array_reverse($all);
    }
    return implode("\n", $all);
}

/** Restart panel-relay so it picks up config.sh changes (systemd VPS or Termux). */
function restart_panel_relay(string $projectDir): bool {
    $systemctl = trim((string) shell_exec('command -v systemctl 2>/dev/null'));
    if ($systemctl !== '') {
        $active = trim((string) shell_exec('systemctl is-active xui-panel-relay 2>/dev/null'));
        if ($active === 'active' || $active === 'inactive' || $active === 'failed') {
            @shell_exec('systemctl restart xui-panel-relay 2>/dev/null');
            return trim((string) shell_exec('systemctl is-active xui-panel-relay 2>/dev/null')) === 'active';
        }
    }
    $svc = $projectDir . '/xui-services.sh';
    if (is_file($svc)) {
        @shell_exec('bash ' . escapeshellarg($svc) . ' restart-relay 2>/dev/null');
        return true;
    }
    return false;
}

function relay_service_status(): array {
    $systemctl = trim((string) shell_exec('command -v systemctl 2>/dev/null'));
    if ($systemctl !== '') {
        $active = trim((string) shell_exec('systemctl is-active xui-panel-relay 2>/dev/null'));
        if ($active === 'active') {
            return ['state' => 'running', 'label' => 'relay فعال'];
        }
        if ($active === 'inactive' || $active === 'failed') {
            return ['state' => 'stopped', 'label' => 'relay متوقف'];
        }
    }
    $pidFile = (getenv('HOME') ?: '/root') . '/.config/xui-sync/panel-relay.pid';
    if (is_file($pidFile)) {
        $pid = (int) trim((string) file_get_contents($pidFile));
        if ($pid > 0 && function_exists('posix_kill') && @posix_kill($pid, 0)) {
            return ['state' => 'running', 'label' => 'relay فعال'];
        }
    }
    return ['state' => 'unknown', 'label' => 'relay نامشخص'];
}

function append_log_line(string $file, string $line): void {
    $dir = dirname($file);
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
    @file_put_contents($file, $line . "\n", FILE_APPEND | LOCK_EX);
}

/** Summarize recent log health for the panel badge. */
function log_health_summary(string $file): array {
    if (!is_file($file)) {
        return ['state' => 'empty', 'label' => 'لاگی نیست', 'detail' => ''];
    }
    $lines = file($file, FILE_IGNORE_NEW_LINES);
    if (!$lines) {
        return ['state' => 'empty', 'label' => 'لاگ خالی', 'detail' => ''];
    }
    $last = end($lines);
    $detail = $last !== false ? $last : '';
    $recent = array_slice($lines, -30);
    $lastStartIdx = null;
    foreach (array_reverse($recent, true) as $idx => $line) {
        if (strpos($line, 'Panel relay loop started') !== false) {
            $lastStartIdx = $idx;
            break;
        }
    }
    if ($lastStartIdx !== null) {
        $afterStart = array_slice($recent, $lastStartIdx + 1);
        foreach ($afterStart as $line) {
            if (strpos($line, '[WARN]') !== false || strpos($line, '[ERROR]') !== false) {
                return ['state' => 'warn', 'label' => 'خطا بعد از آخرین start', 'detail' => $detail];
            }
        }
        return ['state' => 'ok', 'label' => 'سالم (بدون خطا بعد از start)', 'detail' => $detail];
    }
    foreach ($recent as $line) {
        if (strpos($line, '[WARN]') !== false || strpos($line, '[ERROR]') !== false) {
            return ['state' => 'warn', 'label' => 'خطا در لاگ‌های اخیر', 'detail' => $detail];
        }
    }
    return ['state' => 'ok', 'label' => 'بدون خطای اخیر', 'detail' => $detail];
}

$notice = '';
$notice_type = 'ok';
$run_output = '';

$cfg = read_config($CONFIG_FILE, $DEFAULTS);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? 'save';

    if ($action === 'save') {
        foreach (array_keys($FIELDS) as $key) {
            $cfg[$key] = trim((string) ($_POST[$key] ?? ''));
        }
        if ($cfg['SITE_URL'] === '' || $cfg['MOBILE_TOKEN'] === '') {
            $notice = 'آدرس سایت و توکن الزامی هستند.';
            $notice_type = 'err';
        } elseif (write_config($CONFIG_FILE, $cfg)) {
            $defaultLog = is_dir('/etc/xui-outbound')
                ? '/var/log/xui-outbound/sync.log'
                : ((getenv('HOME') ?: '/root') . '/.config/xui-sync/sync.log');
            $logForMarker = $cfg['LOG_FILE'] !== '' ? $cfg['LOG_FILE'] : $defaultLog;
            $logForMarker = str_replace('$HOME', getenv('HOME') ?: '/root', $logForMarker);
            $restarted = restart_panel_relay($PROJECT_DIR);
            $stamp = date('Y-m-d H:i:s');
            append_log_line(
                $logForMarker,
                "[$stamp] [panel] Config saved — SITE_URL={$cfg['SITE_URL']}"
                    . ($restarted ? ' — relay restarted' : ' — relay restart skipped')
            );
            $notice = $restarted
                ? 'تنظیمات ذخیره شد و relay دوباره start شد. ✓'
                : 'تنظیمات ذخیره شد. relay را دستی restart کنید. ✓';
        } else {
            $notice = 'ذخیره ناموفق بود (دسترسی نوشتن config.sh).';
            $notice_type = 'err';
        }
    } elseif ($action === 'run') {
        if (!is_file($CONFIG_FILE)) {
            $notice = 'ابتدا تنظیمات را ذخیره کنید.';
            $notice_type = 'err';
        } else {
            @chmod($SYNC_SCRIPT, 0755);
            $home = getenv('HOME') ?: '/root';
            $syncConfig = is_file('/etc/xui-outbound/config.sh')
                ? '/etc/xui-outbound/config.sh'
                : $CONFIG_FILE;
            $env = 'HOME=' . escapeshellarg($home)
                . ' XUI_SYNC_CONFIG=' . escapeshellarg($syncConfig)
                . ' XUI_STATE_DIR=/etc/xui-outbound';
            $cmd = $env . ' bash ' . escapeshellarg($SYNC_SCRIPT) . ' once 2>&1';
            $run_output = (string) shell_exec($cmd);
            $notice = 'همگام‌سازی اجرا شد.';
        }
    }

    $cfg = read_config($CONFIG_FILE, $DEFAULTS);
}

$defaultLog = is_dir('/etc/xui-outbound')
    ? '/var/log/xui-outbound/sync.log'
    : ((getenv('HOME') ?: '/root') . '/.config/xui-sync/sync.log');
$logPath = $cfg['LOG_FILE'] !== '' ? $cfg['LOG_FILE'] : $defaultLog;
$logPath = str_replace('$HOME', getenv('HOME') ?: '/root', $logPath);
$logTxt = tail_file($logPath);
$logHealth = log_health_summary($logPath);
$relayStatus = relay_service_status();
$configExists = is_file($CONFIG_FILE);

$syncVersion = '';
if (is_readable($SYNC_SCRIPT)) {
    $head = (string) file_get_contents($SYNC_SCRIPT, false, null, 0, 4096);
    if (preg_match('/^XUI_SYNC_VERSION="([^"]+)"/m', $head, $m)) {
        $syncVersion = $m[1];
    }
}

$panelPort = (int) ($_SERVER['SERVER_PORT'] ?? 8088);
$panelLocal = 'http://localhost:' . $panelPort;
$panelLan = '';
$lanIp = trim((string) shell_exec("ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print \$2}' | grep -vE '^127\\.' | head -n1"));
if ($lanIp !== '') {
    $panelLan = 'http://' . $lanIp . ':' . $panelPort;
}

function h($s) { return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8'); }
?>
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>XUI Outbound</title>
<style>
  :root {
    --bg: #f4f4f5;
    --card: #ffffff;
    --line: #e4e4e7;
    --txt: #18181b;
    --mut: #71717a;
    --acc: #2563eb;
    --ok: #16a34a;
    --err: #dc2626;
    --ok-bg: #f0fdf4;
    --err-bg: #fef2f2;
    --shadow: 0 1px 3px rgba(0,0,0,.04);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Vazirmatn, Tahoma, sans-serif;
    background: var(--bg);
    color: var(--txt);
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
  }
  .page { max-width: 640px; margin: 0 auto; padding: 32px 20px 48px; }
  .top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 24px;
  }
  .top h1 { font-size: 22px; font-weight: 600; letter-spacing: -.02em; }
  .top p { font-size: 13px; color: var(--mut); margin-top: 4px; }
  .link-muted { color: var(--mut); font-size: 13px; text-decoration: none; white-space: nowrap; }
  .link-muted:hover { color: var(--acc); }
  .notice {
    padding: 12px 14px;
    border-radius: 8px;
    margin-bottom: 16px;
    font-size: 14px;
    border: 1px solid var(--line);
  }
  .notice.ok { background: var(--ok-bg); border-color: #bbf7d0; color: #166534; }
  .notice.err { background: var(--err-bg); border-color: #fecaca; color: #991b1b; }
  .card {
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 20px;
    margin-bottom: 12px;
    box-shadow: var(--shadow);
  }
  .card-title {
    font-size: 13px;
    font-weight: 600;
    color: var(--mut);
    text-transform: uppercase;
    letter-spacing: .04em;
    margin-bottom: 14px;
  }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }
  .chip {
    display: inline-flex;
    align-items: center;
    font-size: 12px;
    padding: 4px 10px;
    border-radius: 999px;
    border: 1px solid var(--line);
    background: var(--bg);
    color: var(--mut);
  }
  .chip.ok { background: var(--ok-bg); border-color: #bbf7d0; color: #166534; }
  .chip.err { background: var(--err-bg); border-color: #fecaca; color: #991b1b; }
  .urls { direction: ltr; text-align: left; font-size: 13px; }
  .urls a { color: var(--acc); text-decoration: none; }
  .urls a:hover { text-decoration: underline; }
  .urls div + div { margin-top: 6px; }
  label {
    display: block;
    font-size: 13px;
    font-weight: 500;
    color: var(--txt);
    margin: 14px 0 6px;
  }
  label:first-of-type { margin-top: 0; }
  input[type=text], input[type=number], input[type=password] {
    width: 100%;
    padding: 10px 12px;
    border-radius: 8px;
    border: 1px solid var(--line);
    background: #fff;
    color: var(--txt);
    font-size: 14px;
    transition: border-color .15s, box-shadow .15s;
  }
  input:focus {
    outline: none;
    border-color: var(--acc);
    box-shadow: 0 0 0 3px rgba(37,99,235,.1);
  }
  .hint { font-size: 12px; color: var(--mut); margin-top: 8px; line-height: 1.6; }
  .actions { display: flex; gap: 8px; margin-top: 18px; }
  button {
    padding: 10px 18px;
    border: 0;
    border-radius: 8px;
    font-size: 14px;
    font-weight: 600;
    cursor: pointer;
    font-family: inherit;
    transition: background .15s;
  }
  .btn-primary { background: var(--acc); color: #fff; flex: 1; }
  .btn-primary:hover { background: #1d4ed8; }
  .btn-secondary {
    background: #fff;
    color: var(--txt);
    border: 1px solid var(--line);
    flex: 1;
  }
  .btn-secondary:hover { background: var(--bg); }
  pre {
    background: #fafafa;
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 14px;
    overflow: auto;
    max-height: 280px;
    font-size: 11.5px;
    line-height: 1.65;
    direction: ltr;
    text-align: left;
    color: #3f3f46;
    font-family: ui-monospace, "Cascadia Code", Consolas, monospace;
    margin-top: 12px;
  }
  .log-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
  }
  .log-head .card-title { margin-bottom: 0; }
  .refresh { color: var(--acc); font-size: 13px; text-decoration: none; }
  .refresh:hover { text-decoration: underline; }
  .last-line {
    direction: ltr;
    text-align: left;
    font-size: 11px;
    color: var(--mut);
    margin-top: 8px;
    word-break: break-all;
  }
  .split { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 520px) { .split { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<div class="page">

  <header class="top">
    <div>
      <h1>XUI Outbound</h1>
      <p>همگام‌سازی ساب با وردپرس</p>
    </div>
    <?php if ($AUTH_REQUIRED): ?>
      <a class="link-muted" href="?logout=1">خروج</a>
    <?php endif; ?>
  </header>

  <?php if ($notice): ?>
    <div class="notice <?= $notice_type === 'err' ? 'err' : 'ok' ?>"><?= h($notice) ?></div>
  <?php endif; ?>

  <section class="card">
    <div class="card-title">وضعیت</div>
    <div class="urls">
      <div><span style="color:var(--mut)">local</span> · <a href="<?= h($panelLocal) ?>"><?= h($panelLocal) ?></a></div>
      <?php if ($panelLan !== ''): ?>
      <div><span style="color:var(--mut)">lan</span> · <a href="<?= h($panelLan) ?>"><?= h($panelLan) ?></a></div>
      <?php endif; ?>
    </div>
    <div class="chips">
      <?php if ($configExists): ?>
        <span class="chip ok">کانفیگ ذخیره‌شده</span>
      <?php else: ?>
        <span class="chip err">کانفیگ تنظیم نشده</span>
      <?php endif; ?>
      <?php if ($syncVersion !== ''): ?>
        <span class="chip">sync <?= h($syncVersion) ?></span>
      <?php endif; ?>
      <?php if ($relayStatus['state'] === 'running'): ?>
        <span class="chip ok"><?= h($relayStatus['label']) ?></span>
      <?php elseif ($relayStatus['state'] === 'stopped'): ?>
        <span class="chip err"><?= h($relayStatus['label']) ?></span>
      <?php endif; ?>
      <?php if ($logHealth['state'] === 'ok'): ?>
        <span class="chip ok"><?= h($logHealth['label']) ?></span>
      <?php elseif ($logHealth['state'] === 'warn'): ?>
        <span class="chip err"><?= h($logHealth['label']) ?></span>
      <?php endif; ?>
    </div>
  </section>

  <form method="post" class="card">
    <input type="hidden" name="action" value="save">
    <div class="card-title">تنظیمات</div>
    <?php foreach ($FIELDS as $key => $f): ?>
      <label for="<?= h($key) ?>"><?= h($f['label']) ?></label>
      <input
        id="<?= h($key) ?>"
        name="<?= h($key) ?>"
        type="<?= h($f['type']) ?>"
        value="<?= h($cfg[$key] ?? '') ?>"
        placeholder="<?= h($f['placeholder']) ?>"
        <?= $f['type'] === 'text' ? 'dir="ltr" style="text-align:left"' : '' ?>>
    <?php endforeach; ?>
    <p class="hint">VPN (tun): پراکسی خالی · Proxy: socks5h://127.0.0.1:2334</p>
    <div class="actions">
      <button class="btn-primary" type="submit">ذخیره</button>
    </div>
  </form>

  <div class="split">
    <form method="post" class="card" style="margin-bottom:0">
      <input type="hidden" name="action" value="run">
      <div class="card-title">همگام‌سازی</div>
      <p class="hint">اجرای یک‌باره همین الان</p>
      <div class="actions" style="margin-top:12px">
        <button class="btn-secondary" type="submit">اجرا</button>
      </div>
    </form>

    <section class="card" style="margin-bottom:0">
      <div class="log-head">
        <div class="card-title">لاگ</div>
        <a class="refresh" href="">تازه‌سازی</a>
      </div>
      <p class="hint">جدیدترین خط بالاست</p>
      <?php if ($logHealth['detail'] !== ''): ?>
        <div class="last-line"><?= h($logHealth['detail']) ?></div>
      <?php endif; ?>
      <pre><?= h($logTxt) ?></pre>
    </section>
  </div>

  <?php if ($run_output !== ''): ?>
    <section class="card" style="margin-top:12px">
      <div class="card-title">خروجی همگام‌سازی</div>
      <pre><?= h($run_output) ?></pre>
    </section>
  <?php endif; ?>

</div>
</body>
</html>
