# =============================================================================
# xui-outbound-termux configuration
# Copy this file to "config.sh" and fill in your values:
#     cp config.example.sh config.sh
#     nano config.sh
# =============================================================================

# آدرس سایت وردپرس شما (بدون / در انتها)
SITE_URL="https://your-wp-site.com"

# توکن اپ موبایل — از پنل وردپرس:
# مدیریت → Outbound Sync → «توکن اپ»
MOBILE_TOKEN="paste-your-token-here"

# فاصله‌ی همگام‌سازی در حالت loop (دقیقه)
INTERVAL_MIN=60

# User-Agent برای دریافت ساب (بعضی ساب‌ها به UA حساس‌اند)
SUB_USER_AGENT="HiddifyNext/4.1.0 (Android) v2rayNG/1.8.0"

# پراکسی فقط برای دریافت ساب خارجی.
# - اگر هیدیفای را در حالت VPN/tun وصل کرده‌اید: این را خالی بگذارید
#   (همه‌ی ترافیک Termux خودکار از تونل رد می‌شود).
# - اگر هیدیفای را در حالت «پراکسی» اجرا می‌کنید: آدرس پراکسی محلی را بگذارید،
#   مثلاً:
#       PROXY_URL="socks5h://127.0.0.1:2334"
#   یا
#       PROXY_URL="http://127.0.0.1:2334"
PROXY_URL=""

# حداکثر زمان دریافت هر ساب (ثانیه)
FETCH_TIMEOUT=45

# مسیر فایل لاگ
LOG_FILE="$HOME/.config/xui-sync/sync.log"
