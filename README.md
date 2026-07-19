# xui-outbound

سرویسی که هر یک ساعت یک‌بار لیست ساب‌های خارجی را دریافت می‌کند و به افزونه‌ی **X-UI VPN Manager** (وردپرس) می‌فرستد تا به‌صورت **Outbound** داخل بالانسر پنل ثنایی (3x-ui) ثبت شوند.

دو روش نصب: **سرور مجازی (VPS)** — پیشنهادی و پایدار — یا **گوشی اندروید (Termux)**.

---

## 🚀 نصب روی VPS (پیشنهادی)

روی یک سرور مجازی **خارج از ایران** (Debian/Ubuntu)، فقط یک دستور:

```bash
curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-vps.sh | bash
```

این دستور:
- پیش‌نیازها (`php`, `jq`, `curl`, `git`) را نصب می‌کند
- همگام‌سازی **ساعتی** را با systemd timer تنظیم می‌کند
- **relay پنل خارجی** را هر چند ثانیه اجرا می‌کند (`xui-panel-relay`) — برای ساخت/مدیریت اشتراک روی پنل X-UI خارج
- **پنل وب** را به‌صورت سرویس دائمی (systemd) بالا می‌آورد
- پورت فایروال را باز می‌کند
- یک **رمز ورود** برای پنل می‌سازد و در پایان آدرس و رمز را چاپ می‌کند

در پایان چیزی شبیه این می‌بینید:

```
پنل تنظیمات:  http://SERVER_IP:8088
رمز ورود پنل:  1895233171
```

> رمز پیش‌فرض پنل `1895233171` است. برای تغییر، قبل از نصب `PANEL_PASSWORD=...` بگذارید یا بعداً فایل `/etc/xui-outbound/panel-password.txt` را ویرایش و `systemctl restart xui-panel` کنید.

آدرس را در مرورگر باز کنید، با رمز وارد شوید، **آدرس سایت وردپرس و توکن** را ذخیره کنید و «اجرای همگام‌سازی الان» را بزنید.

> **مزیت VPS خارج:** چون سرور خارج از ایران است، مستقیم به ساب‌های خارجی دسترسی دارد و **اصلاً به VPN/هیدیفای نیاز نیست**. فیلد `PROXY_URL` را خالی بگذارید.

### دستورات مدیریت روی VPS

| کار | دستور |
|---|---|
| وضعیت پنل | `systemctl status xui-panel` |
| وضعیت relay پنل خارجی | `systemctl status xui-panel-relay` |
| وضعیت تست کانفیگ رایگان | `systemctl status xui-free-config-probe` |
| وضعیت زمان‌بندی | `systemctl status xui-sync.timer` |
| اجرای دستی همگام‌سازی | `systemctl start xui-sync --no-block` |
| لاگ همگام‌سازی (آخرین خطوط) | `journalctl -u xui-sync -n 50 --no-pager` |
| دنبال کردن لاگ sync زنده | `journalctl -u xui-sync -f` |
| لاگ تست کانفیگ | `journalctl -u xui-free-config-probe -n 50 --no-pager` |
| دنبال کردن لاگ probe | `journalctl -u xui-free-config-probe -f` |
| لاگ relay پنل | `journalctl -u xui-panel-relay -n 50 --no-pager` |
| دیدن/تغییر رمز پنل | `cat /etc/xui-outbound/panel-password.txt` |
| تغییر تنظیمات | `nano /etc/xui-outbound/config.sh` |
| بررسی SITE_URL و توکن | `grep SITE_URL /etc/xui-outbound/config.sh` |
| به‌روزرسانی از GitHub | `curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/update-vps.sh \| bash` |

### نصب / تعمیر Xray روی VPS

برای تست واقعی کانفیگ رایگان (`xray-real-delay`) باید باینری Xray روی همان VPS باشد.
نصب‌کننده اول از **میرور هاست** (`pronet24.ir` — همان فایلی که روی وردپرس آپلود شده) می‌گیرد، اگر نشد از GitHub.

**یک دستور (روی سرور، root):**

```bash
curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/install-xray.sh | bash
```

یا اگر پروژه از قبل در `/opt/xui-outbound` است:

```bash
bash /opt/xui-outbound/install-xray.sh
```

فعال‌سازی کامل سرویس probe (نصب Xray + systemd):

```bash
curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/update-vps.sh | bash
# یا فقط probe:
bash /opt/xui-outbound/enable-free-config-probe.sh
```

بررسی نصب:

```bash
/etc/xui-outbound/xray/xray version
# یا
cat /etc/xui-outbound/xray-path.txt
systemctl restart xui-free-config-probe
```

اگر دانلود از GitHub روی سرور محدود بود، دستی از میرور هاست:

```bash
mkdir -p /etc/xui-outbound/xray
curl -fSL "https://pronet24.ir/wp-content/plugins/xui-vpn-manager/bin/xray/xui-xray-download.php?key=xui-pronet-diag-2026" \
  -o /etc/xui-outbound/xray/xray
chmod +x /etc/xui-outbound/xray/xray
ln -sf /etc/xui-outbound/xray/xray /usr/local/bin/xray
echo /etc/xui-outbound/xray/xray > /etc/xui-outbound/xray-path.txt
systemctl restart xui-free-config-probe
```

---

## نصب روی گوشی (Termux)

سرویس سبک **Termux** برای اندروید — مناسب وقتی VPS ندارید و گوشی به هیدیفای وصل است.

---

## چرا گوشی؟

هاست وردپرس معمولاً به ساب‌های خارجی دسترسی ندارد. گوشی شما که به **هیدیفای** وصل است، ساب را می‌گیرد و فقط نتیجه را به سایت می‌فرستد.

### آیا با روشن بودن VPN مشکل پیش می‌آید؟

نه. دو حالت دارید:

| حالت هیدیفای | تنظیم لازم |
|---|---|
| **VPN / tun** (پیش‌فرض، آیکن کلید بالای صفحه) | هیچ — همه‌ی ترافیک Termux خودکار از تونل رد می‌شود. `PROXY_URL` را خالی بگذارید. |
| **فقط پراکسی** (Proxy only) | در `config.sh` مقدار `PROXY_URL` را به پراکسی محلی هیدیفای بدهید، مثلاً `socks5h://127.0.0.1:2334`. |

دریافت ساب از تونل رد می‌شود (که خوب است، سانسور را رد می‌کند) و ارسال به سایت هم بدون مشکل انجام می‌شود.

---

## پنل X-UI خارجی (Panel Relay)

علاوه بر همگام‌سازی ساب → اوتباند، همان VPS می‌تواند **API پنل‌های X-UI خارج** را هم اجرا کند (ساخت کلاینت، sync حجم، حذف و …) چون هاست ایران مستقیم به آن پنل‌ها دسترسی ندارد.

### تنظیم در وردپرس

1. **مدیریت → Panel Management** — پنل خارج را اضافه کنید.
2. فیلد **«دسترسی از هاست»** را روی **از طریق واسط (VPS/اندروید)** بگذارید.
3. پلن/نماینده مثل قبل کار می‌کند.

### روی VPS

سرویس `xui-panel-relay` هر چند ثانیه jobهای API را از وردپرس می‌گیرد و روی پنل خارج اجرا می‌کند. با نصب جدید خودکار فعال است؛ برای به‌روزرسانی:

```bash
curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/update-vps.sh | bash
```

---

## پیش‌نیاز در وردپرس

1. وارد **مدیریت → Outbound Sync** شوید.
2. **توکن اپ** را کپی کنید (یا یک توکن ذخیره کنید).
3. منبع ساب را با حالت **«اپ اندروید»** بسازید و پنل مقصد + تگ بالانسر را تنظیم کنید.

---

## نصب با یک دستور 🚀

۱. اپ **Termux** را از [F-Droid](https://f-droid.org/packages/com.termux/) نصب کنید (نسخه‌ی Play Store قدیمی است).

۲. این **یک دستور** را در Termux اجرا کنید (به‌جای `USERNAME` نام گیت‌هاب خودتان):

```bash
curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/setup.sh | bash
```

اگر خطای `$'\r': command not found` دیدید (فایل با خط‌پایان ویندوزی):

```bash
curl -fsSL https://raw.githubusercontent.com/asanseir724/xui-outbound-termux/main/setup.sh | sed 's/\r$//' | bash
```

همین! این دستور همه‌ی پیش‌نیازها را نصب می‌کند، پروژه را می‌گیرد، سرویس همگام‌سازی ساعتی و **پنل وب محلی** را راه می‌اندازد، قفل بیداری را روشن می‌کند و در پایان **آدرس پنل** را چاپ می‌کند.

### تنظیم از طریق پنل وب

بعد از نصب، آدرسی شبیه این چاپ می‌شود:

```
روی همین گوشی:   http://localhost:8088
از دستگاه دیگر در همان وای‌فای:  http://192.168.x.x:8088
```

این آدرس را در **مرورگر** باز کنید، سپس:

1. **آدرس سایت** و **توکن** را وارد و **ذخیره** کنید.
2. دکمه‌ی **«اجرای همگام‌سازی الان»** را بزنید تا تست شود.
3. لاگ‌ها و نتیجه را در همان صفحه می‌بینید.

پنل همیشه بالا می‌ماند و سرویس هر ساعت خودکار اجرا می‌شود.

---

## همیشه‌آنلاین ماندن (بعد از بستن Termux / ریبوت)

نصب‌کننده سرویس‌ها را در پس‌زمینه بالا می‌آورد (`crond` + پنل وب) و `termux-wake-lock` را روشن می‌کند تا با بستن پنجره‌ی Termux خاموش نشوند. برای پایداری کامل بعد از ریبوت:

1. اپ **Termux:Boot** را از F-Droid نصب کنید و یک‌بار بازش کنید.
2. اسکریپت بوت را کپی کنید:

   ```bash
   mkdir -p ~/.termux/boot
   cp termux-boot/start-xui-sync.sh ~/.termux/boot/
   chmod +x ~/.termux/boot/start-xui-sync.sh
   ```

3. در تنظیمات اندروید، **بهینه‌سازی باتری** را برای Termux **خاموش** کنید.
4. (اختیاری ولی توصیه‌شده) قفل بیداری را فعال کنید: `termux-wake-lock`

### روش جایگزین بدون کرون (حالت حلقه)

اگر نخواستید با کرون کار کنید، می‌توانید سرویس را در یک حلقه نگه دارید:

```bash
termux-wake-lock
./xui-sync.sh loop
```

این هر `INTERVAL_MIN` دقیقه (پیش‌فرض ۶۰) همگام‌سازی می‌کند تا وقتی Termux باز است.

---

## مشاهده‌ی لاگ

```bash
tail -f ~/.config/xui-sync/sync.log
```

---

## دستورات مفید

| کار | دستور |
|---|---|
| همگام‌سازی یک‌باره | `./xui-sync.sh once` |
| حالت حلقه | `./xui-sync.sh loop` |
| حذف زمان‌بندی کرون | `bash uninstall.sh` |
| توقف سرویس‌ها | `./xui-services.sh stop` |
| شروع مجدد سرویس‌ها | `./xui-services.sh restart` |
| وضعیت سرویس‌ها | `./xui-services.sh status` |
| دیدن کرون فعلی | `crontab -l` |
| باز کردن پنل وب | مرورگر → `http://localhost:8088` |
| دیدن IP گوشی برای دسترسی LAN | `ip -4 addr` |

---

## API مورد استفاده (سمت وردپرس)

- `GET  /wp-json/xui/v1/outbound-mobile/sources` — شامل منابع **Outbound** و **استخر کانفیگ رایگان** (`pool: outbound` | `free_config`)
- `POST /wp-json/xui/v1/outbound-mobile/push` — یکی از این روش‌ها:
  - **پیشنهادی (ساب بزرگ):** `?source_id=1&pool=outbound` در URL + بدنه خام ساب به‌صورت `text/plain`
  - **JSON کوچک:** `{ "source_id": 1, "pool": "free_config", "body": "<raw sub body>" }`
  - برای استخر رایگان: `pool=free_config`
- هدر احراز هویت: `X-XUI-Mobile-Token: YOUR_TOKEN`

سرور خودش بدنه‌ی ساب (base64 یا متن) را پارس می‌کند:
- `pool=outbound` → لینک‌ها به اوتباند پنل ثنایی می‌روند
- `pool=free_config` → لینک‌ها در استخر کانفیگ رایگان ثبت و تست می‌شوند
- `GET  /wp-json/xui/v1/outbound-mobile/probe-jobs` — وقتی `exec` روی هاست غیرفعال است، jobهای تست Xray
- `POST /wp-json/xui/v1/outbound-mobile/probe-result` — برگرداندن نتیجه تست از VPS

`xui-sync.sh` بعد از هر sync، probe jobها را هم (مثل panel relay) پردازش می‌کند.

### تست Xray روی VPS (وقتی هاست exec ندارد)

1. Xray را نصب کنید — بخش **«نصب / تعمیر Xray روی VPS»** بالاتر (یک دستور `install-xray.sh`).
2. سرویس `xui-free-config-probe` باید فعال باشد (`systemctl status xui-free-config-probe`).
3. در لاگ باید `xray-real-delay` و گاهی `ALIVE` ببینید — نه فقط `tcp`.

بدون Xray فقط تست TCP انجام می‌شود (بهتر از TCP هاست ایرانی، ولی بدون Real Delay).

---

## رفع اشکال

| مشکل | راه‌حل |
|---|---|
| `Could not resolve host: your-wp-site.com` | هنوز placeholder است — در پنل آدرس واقعی وردپرس + توکن را **ذخیره** کنید، بعد `systemctl start xui-sync --no-block` |
| `Empty response from host` | `SITE_URL` اشتباه است یا سرور به سایت دسترسی ندارد. |
| `Host rejected request: Invalid token` | `MOBILE_TOKEN` با توکن پنل وردپرس یکی نیست. |
| `empty subscription body` | ساب باز نمی‌شود — هیدیفای را وصل کنید یا `PROXY_URL` را تنظیم کنید. |
| `Operation timed out` هنگام fetch ساب | آن منبع ساب کند/مرده است؛ بقیه منابع ادامه می‌یابند — طبیعی برای ساب رایگان. |
| فقط `tcp` / بدون `xray-real-delay` | Xray روی VPS نیست — `install-xray.sh` را اجرا کنید. |
| `parse outbound` | لینک کانفیگ خراب/ناقص است (مشکل نصب Xray نیست). |
| `host rejected result` | وردپرس نتیجه را نپذیرفت — توکن/آدرس سایت یا REST API را چک کنید. |
| `panel-jobs: empty response (HTTP=000)` | قطعی لحظه‌ای شبکه تا هاست؛ معمولاً خودبه‌خود درست می‌شود. |
| `systemctl start xui-sync` گیر می‌کند / Ctrl+C | طبیعی است تا sync تمام شود — با `--no-block` بزنید و لاگ را با `-f` ببینید. |
| بعد از ریبوت دیگر کار نمی‌کند | Termux:Boot نصب نشده یا بهینه‌سازی باتری روشن است. |

### چک‌لیست سریع روی VPS (وقتی «خطا در لاگ» می‌بینید)

```bash
# 1) کانفیگ ذخیره‌شده
grep -E 'SITE_URL|MOBILE_TOKEN' /etc/xui-outbound/config.sh

# 2) وضعیت سرویس‌ها
systemctl is-active xui-panel xui-panel-relay xui-free-config-probe xui-sync.timer

# 3) Xray
/etc/xui-outbound/xray/xray version

# 4) sync تازه (بلاک نمی‌کند)
systemctl start xui-sync --no-block
journalctl -u xui-sync -n 40 --no-pager

# 5) probe
journalctl -u xui-free-config-probe -n 40 --no-pager

# 6) دسترسی به وردپرس از خود VPS
curl -sI "https://YOUR-SITE/" | head -n 5
curl -sS -H "X-XUI-Mobile-Token: YOUR_TOKEN" \
  "https://YOUR-SITE/index.php?rest_route=/xui/v1/outbound-mobile/sources" | head -c 200
echo
```

اگر مرحله ۱ هنوز `your-wp-site.com` بود → پنل `:8088` → ذخیره تنظیمات → دوباره مرحله ۴.

اگر مرحله ۳ fail بود → بخش **نصب / تعمیر Xray** بالاتر.

اگر sync نوشت `Got N source(s)` ولی بعضی ساب‌ها `FAILED` / timeout → مشکل آن منبع است، نه کل سیستم.

### ری‌استارت سرویس‌ها

```bash
systemctl restart xui-panel xui-panel-relay xui-free-config-probe
systemctl start xui-sync --no-block
```

## مجوز

MIT
