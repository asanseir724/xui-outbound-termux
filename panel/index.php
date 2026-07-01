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
  body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Tahoma,sans-serif;background:#0f1220;color:#e7e9f3;display:flex;min-height:100vh;align-items:center;justify-content:center;}
  .box{background:#191d31;border:1px solid #2b3150;border-radius:14px;padding:24px;width:320px;max-width:90vw;}
  h1{font-size:18px;margin:0 0 16px;}
  input{width:100%;padding:11px 12px;border-radius:10px;border:1px solid #2b3150;background:#0d1020;color:#e7e9f3;font-size:14px;box-sizing:border-box;}
  button{width:100%;margin-top:14px;padding:12px;border:0;border-radius:10px;background:#5b7cff;color:#fff;font-size:15px;font-weight:600;cursor:pointer;}
  .err{color:#ff8aa0;font-size:13px;margin-top:10px;}
</style></head><body>
  <form class="box" method="post">
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

function tail_file(string $file, int $lines = 60): string {
    if (!is_file($file)) {
        return '(هنوز لاگی ثبت نشده)';
    }
    $all = file($file, FILE_IGNORE_NEW_LINES);
    $all = array_slice($all, -$lines);
    return $all ? implode("\n", $all) : '(لاگ خالی است)';
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
            $notice = 'تنظیمات ذخیره شد. ✓';
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
<title>XUI Outbound — پنل تنظیمات</title>
<style>
  :root { --bg:#0f1220; --card:#191d31; --line:#2b3150; --txt:#e7e9f3; --mut:#9aa1c4; --acc:#5b7cff; --ok:#1f9d6b; --err:#d2425a; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,Segoe UI,Roboto,Vazirmatn,Tahoma,sans-serif; background:var(--bg); color:var(--txt); }
  .wrap { max-width:720px; margin:0 auto; padding:18px; }
  h1 { font-size:20px; margin:8px 0 2px; }
  .sub { color:var(--mut); font-size:13px; margin-bottom:16px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:16px; margin-bottom:16px; }
  label { display:block; font-size:13px; color:var(--mut); margin:12px 0 5px; }
  input[type=text], input[type=number] { width:100%; padding:11px 12px; border-radius:10px; border:1px solid var(--line); background:#0d1020; color:var(--txt); font-size:14px; }
  input:focus { outline:none; border-color:var(--acc); }
  .row-btns { display:flex; gap:10px; flex-wrap:wrap; margin-top:16px; }
  button { flex:1; min-width:130px; padding:12px 14px; border:0; border-radius:10px; font-size:15px; font-weight:600; cursor:pointer; }
  .primary { background:var(--acc); color:#fff; }
  .ghost { background:#262b45; color:var(--txt); }
  .notice { padding:11px 13px; border-radius:10px; margin-bottom:14px; font-size:14px; }
  .notice.ok { background:rgba(31,157,107,.16); border:1px solid var(--ok); }
  .notice.err { background:rgba(210,66,90,.16); border:1px solid var(--err); }
  pre { background:#0a0c18; border:1px solid var(--line); border-radius:10px; padding:12px; overflow:auto; max-height:300px; font-size:12px; line-height:1.6; direction:ltr; text-align:left; color:#c8cdf0; }
  .hint { font-size:12px; color:var(--mut); margin-top:4px; }
  .badge { display:inline-block; font-size:12px; padding:3px 8px; border-radius:20px; }
  .badge.on { background:rgba(31,157,107,.2); color:#5fe0a8; }
  .badge.off { background:rgba(210,66,90,.2); color:#ff8aa0; }
</style>
</head>
<body>
<div class="wrap">
  <h1>پنل تنظیمات XUI Outbound</h1>
  <div class="sub">
    دریافت ساب و ارسال به وردپرس — اجرای ساعتی خودکار
    <?php if ($AUTH_REQUIRED): ?>
      · <a href="?logout=1" style="color:var(--acc);text-decoration:none;">خروج</a>
    <?php endif; ?>
  </div>

  <?php if ($notice): ?>
    <div class="notice <?= $notice_type === 'err' ? 'err' : 'ok' ?>"><?= h($notice) ?></div>
  <?php endif; ?>

  <div class="card">
    <div style="font-size:14px;margin-bottom:8px;">آدرس این پنل</div>
    <div style="direction:ltr;text-align:left;font-size:13px;line-height:1.8;">
      <div><strong>روی همین گوشی:</strong> <a href="<?= h($panelLocal) ?>" style="color:var(--acc);"><?= h($panelLocal) ?></a></div>
      <?php if ($panelLan !== ''): ?>
      <div><strong>از وای‌فای (دستگاه دیگر):</strong> <a href="<?= h($panelLan) ?>" style="color:var(--acc);"><?= h($panelLan) ?></a></div>
      <?php endif; ?>
    </div>
    <div style="margin-top:10px;">
      وضعیت کانفیگ:
      <?php if ($configExists): ?>
        <span class="badge on">ذخیره‌شده</span>
      <?php else: ?>
        <span class="badge off">ذخیره نشده — فرم زیر را پر کنید</span>
      <?php endif; ?>
      <?php if ($syncVersion !== ''): ?>
        <span class="badge on" style="margin-right:6px;">نسخه sync: <?= h($syncVersion) ?></span>
      <?php elseif (is_readable($SYNC_SCRIPT)): ?>
        <span class="badge off" style="margin-right:6px;">نسخه sync: قدیمی — update-vps.sh را اجرا کنید</span>
      <?php endif; ?>
    </div>
  </div>

  <form method="post" class="card">
    <input type="hidden" name="action" value="save">
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
    <p class="hint">حالت VPN هیدیفای (tun): پراکسی را خالی بگذارید. حالت پراکسی: آدرس پراکسی محلی را وارد کنید.</p>
    <div class="row-btns">
      <button class="primary" type="submit">ذخیره تنظیمات</button>
    </div>
  </form>

  <form method="post" class="card">
    <input type="hidden" name="action" value="run">
    <div style="font-size:14px;margin-bottom:8px;">همگام‌سازی دستی</div>
    <div class="hint">یک‌بار همین حالا اجرا می‌کند و نتیجه را پایین نشان می‌دهد.</div>
    <div class="row-btns">
      <button class="ghost" type="submit">▶ اجرای همگام‌سازی الان</button>
    </div>
  </form>

  <?php if ($run_output !== ''): ?>
    <div class="card">
      <div style="font-size:14px;margin-bottom:8px;">خروجی اجرا</div>
      <pre><?= h($run_output) ?></pre>
    </div>
  <?php endif; ?>

  <div class="card">
    <div style="display:flex;justify-content:space-between;align-items:center;">
      <span style="font-size:14px;">آخرین لاگ‌ها</span>
      <a href="" style="color:var(--acc);font-size:13px;text-decoration:none;">↻ تازه‌سازی</a>
    </div>
    <pre><?= h($logTxt) ?></pre>
  </div>
</div>
</body>
</html>
