# WaterWall Proto51 Tunnel

اسکریپت نصب تانل **WaterWall** با پروتکل IP سفارشی (پیش‌فرض `51`)، فوروارد پورت از ایران به خارج، و رمزنگاری اختیاری `AesGcm`.

## نصب یک‌خطی

روی **هر دو سرور** (اول خارج، بعد ایران):

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash
```

If the menu appears but keyboard input does not work (classic `curl | bash` stdin issue), use one of these instead:

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh)
```

or:

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh -o install.sh
sudo bash install.sh
```

بعد از نصب، منو با دستور `ww51` هم در دسترس است.

## منوی `ww51`

| گزینه | کار |
|------|-----|
| **1) Install / Reinstall** | نصب کامل / نصب مجدد |
| **2) Status** | وضعیت سرویس، `wtun0`، watchdog، و مقادیر `tunnel.env` |
| **3) Restart** | ری‌استارت سرویس |
| **4) Edit tunnel** | ویرایش IP ایران/خارج، پروتکل، پورت‌ها (ایران)، رمزنگاری، old-cpu — بدون نصب کامل |
| **5) Change Iran ports** | فقط تغییر پورت‌های فوروارد ایران |
| **6) Uninstall** | حذف سرویس، watchdog و فایل‌ها |
| **0) Exit** | خروج |

تنظیمات ذخیره‌شده در `/opt/waterwall-proto51/tunnel.env` هستند. گزینه Edit همان مقادیر را به‌عنوان پیش‌فرض نشان می‌دهد.

## کارهایی که اسکریپت می‌کند

| مورد | توضیح |
|------|--------|
| پروتکل | پیش‌فرض `51` (قابل تغییر) |
| ایران | `TcpListener` روی `0.0.0.0` برای پورت‌های انتخابی → فوروارد به `10.10.0.2` |
| خارج | endpoint تانل؛ پنل/Xray باید همان پورت‌ها را گوش بدهد |
| رمزنگاری | **پیش‌فرض خاموش**؛ `AesGcm` اختیاری است ولی در باینری‌های رسمی WaterWall 1.46.x معمولاً پلاگین `libs/AesGcm` وجود ندارد و سرویس کرش می‌کند |
| سرویس | `systemd` با نام `waterwall-proto51` — `enable` شده تا بعد از ریبوت خودکار بالا بیاید (`Restart=always`) |
| Watchdog | تایمر `waterwall-proto51-watchdog.timer` هر ~۲ دقیقه سرویس/`wtun0` را چک می‌کند و در صورت down بودن ری‌استارت می‌کند |
| باینری | دانلود از [radkesvat/WaterWall](https://github.com/radkesvat/WaterWall/releases) |

## پورت‌های پیش‌فرض ایران

`80 443 2053 2083 2087 2096 8080 8443 8880`

در منو می‌توانی عوضشان کنی (گزینه 4 یا 5)، یا:

```bash
sudo ww51
# 4) Edit tunnel   یا   5) Change Iran ports
```

## به‌روزرسانی روی سرورهای قبلی

روی **هر دو** سرور دوباره اسکریپت را اجرا کن (منوی جدید + watchdog):

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash
```

سپس:

- برای نصب/نصب مجدد: گزینه **1**
- فقط ویرایش IP/پورت/پروتکل: گزینه **4** (بعد از اینکه یک‌بار منوی جدید لود شد)
- تأیید بقا بعد از ریبوت و watchdog: گزینه **2) Status** — باید `enabled` برای سرویس و تایمر watchdog را ببینی

CLI مستقیم:

```bash
sudo ww51 edit
sudo ww51 status
```

## دستورات مفید

```bash
sudo ww51                                   # منو
systemctl status waterwall-proto51
systemctl status waterwall-proto51-watchdog.timer
systemctl list-timers waterwall-proto51-watchdog.timer
journalctl -u waterwall-proto51 -f
journalctl -t waterwall-proto51-watchdog -n 20
ip addr show wtun0
cat /opt/waterwall-proto51/tunnel.env
```

## نکات

1. اول سرور **خارج** را نصب/استارت کن، بعد **ایران**.
2. روی خارج، سرویس (Xray/پنل) باید روی همان پورت‌ها روی `0.0.0.0` یا `10.10.0.1` گوش بدهد.
3. رمزنگاری `AesGcm` را مگر اینکه مطمئن باشی پلاگین در `libs/` هست روشن نکن (پیش‌فرض: خاموش).
4. برای CPU قدیمی، هنگام نصب/Edit گزینه `old-cpu` را انتخاب کن.
5. مسیر نصب: `/opt/waterwall-proto51`
6. اگر سرویس بالا نیامد: `journalctl -u waterwall-proto51 -n 50 --no-pager` و فایل‌های `log/` زیر `/opt/waterwall-proto51`.
7. بعد از ریبوت، سرویس و watchdog باید خودکار برگردند؛ Status را چک کن.

## حذف

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash
# گزینه 6) Uninstall
```

یا:

```bash
sudo bash /opt/waterwall-proto51/install.sh uninstall
```

## Disclaimer

این ابزار فقط برای تانل‌سازی و مدیریت شبکهٔ مجاز است. مسئولیت استفاده بر عهدهٔ کاربر است.
