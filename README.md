# WaterWall Proto51 Tunnel

اسکریپت نصب تانل **WaterWall** با پروتکل IP سفارشی (پیش‌فرض `51`)، فوروارد پورت از ایران به خارج، و رمزنگاری اختیاری با نودهای رسمی `EncryptionClient` / `EncryptionServer`.

مستندات رسمی WaterWall: [Intro](https://radkesvat.github.io/WaterWall-Docs/docs/intro) · [EncryptionClient](https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionClient) · [EncryptionServer](https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/EncryptionServer) · [IpManipulator](https://radkesvat.github.io/WaterWall-Docs/docs/noderefs/IpManipulator)

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
| **1) Install / Reinstall** | نصب کامل / نصب مجدد (شامل انتخاب `PROTO` و رمزنگاری) |
| **2) Status** | IP عمومی این سرور، وضعیت سرویس، `wtun0`، watchdog، و مقادیر `tunnel.env` |
| **3) Restart** | ری‌استارت سرویس |
| **4) Edit tunnel** | ویرایش IP ایران/خارج، **شماره پروتکل (PROTO)**، پورت‌ها، رمزنگاری، old-cpu — بدون نصب کامل |
| **5) Change ports** | تغییر پورت‌ها (ایران؛ یا خارج وقتی رمزنگاری روشن است) |
| **6) Show tunnel logs** | آخرین لاگ‌های `journalctl -u waterwall-proto51` و فایل‌های `/opt/waterwall-proto51/log/` |
| **7) Uninstall** | حذف سرویس، watchdog و فایل‌ها |
| **0) Exit** | خروج |

بالای منو و در Status، **IP عمومی این سرور** با `curl` (مثل ifconfig.me / api.ipify.org) یا IP اینترفیس اصلی تشخیص داده می‌شود تا بتوانید کپی کنید؛ در Install/Edit هم به‌عنوان پیش‌فرض سمتِ همین سرور پر می‌شود (قابل تغییر).

تنظیمات ذخیره‌شده در `/opt/waterwall-proto51/tunnel.env` هستند. گزینه Edit همان مقادیر را به‌عنوان پیش‌فرض نشان می‌دهد.

CLI لاگ:

```bash
sudo ww51 logs
```

### تغییر شماره پروتکل (PROTO)

1. روی **هر دو** سرور: `sudo ww51` → گزینه **4) Edit tunnel**
2. مقدار `Protocol` را عوض کن (مثلاً `51` → `58`) — بازه معتبر `0..255`
3. اسکریپت کانفیگ را از نو می‌نویسد، `PROTO=` را در `tunnel.env` ذخیره می‌کند و سرویس را ری‌استارت می‌کند
4. **همان عدد** باید روی ایران و خارج تنظیم شود

CLI:

```bash
sudo ww51 edit
# سپس Protocol را وارد کن
grep ^PROTO= /opt/waterwall-proto51/tunnel.env
```

## کارهایی که اسکریپت می‌کند

| مورد | توضیح |
|------|--------|
| پروتکل | پیش‌فرض `51`؛ در Install و Edit قابل تغییر؛ ذخیره در `tunnel.env` به‌صورت `PROTO=` و اعمال در `IpManipulator.protoswap` |
| ایران | `TcpListener` روی `0.0.0.0` برای پورت‌های PUBLIC → فوروارد به `10.10.0.2` |
| خارج | endpoint تانل؛ بدون رمزنگاری پنل روی همان پورت‌های PUBLIC گوش می‌دهد (`0.0.0.0` OK) |
| رمزنگاری | **پیش‌فرض خاموش**؛ با `EncryptionClient`/`EncryptionServer` روی پورت‌های **داخلی تانل** (`INTERNAL = PUBLIC + PORT_OFFSET`) |
| سرویس | `systemd` با نام `waterwall-proto51` — `enable` شده تا بعد از ریبوت خودکار بالا بیاید (`Restart=always`) |
| Watchdog | تایمر `waterwall-proto51-watchdog.timer` هر ~۲ دقیقه سرویس/`wtun0` را چک می‌کند |
| باینری | دانلود از [radkesvat/WaterWall](https://github.com/radkesvat/WaterWall/releases) |

### مسیر تانل بسته‌ای (همیشه)

```text
TunDevice -> IpOverrider -> IpOverrider -> IpManipulator(protoswap=PROTO) -> IpOverrider -> IpOverrider -> RawSocket
```

### رمزنگاری وقتی روشن است (روی استریم TCP فوروارد)

```text
Iran:   TcpListener(0.0.0.0:PUBLIC) -> EncryptionClient -> TcpConnector(10.10.0.2:INTERNAL)
Kharej: TcpListener(10.10.0.1:INTERNAL) -> EncryptionServer -> TcpConnector(127.0.0.1:PUBLIC)
```

**INTERNAL_PORT = PUBLIC_PORT + PORT_OFFSET** (پیش‌فرض `PORT_OFFSET=10000`)

مثال: `443 → 10443`، `2053 → 12053`، `8443 → 18443`، `2083 → 12083`

ذخیره در `tunnel.env`:

```bash
PORT_OFFSET=10000
PORTS="443 2053 8443 2083"
```

#### نکات مهم (UX)

- **ایران می‌تواند روی `0.0.0.0` با رمزنگاری گوش بدهد** — این مشکلی ندارد.
- تداخل قبلی فقط وقتی بود که روی خارج `EncryptionServer` همان **PUBLIC** پورت پنل را روی `*:PORT` بایند می‌کرد.
- حالا WaterWall روی خارج فقط **INTERNAL** را روی `10.10.0.1` بایند می‌کند؛ پنل می‌تواند روی `0.0.0.0:PUBLIC` بماند.
- اتصال به `127.0.0.1:PUBLIC` روی خارج OK است حتی اگر پنل روی `0.0.0.0:PUBLIC` گوش بدهد.
- این نصب‌کننده **هرگز** x-ui / xray / nginx / listen پنل را عوض نمی‌کند و از شما نمی‌خواهد پورت پنل را آزاد کنید.

#### چک اشغال بودن پورت

| سمت | چه چیزی چک می‌شود |
|------|-------------------|
| ایران | پورت‌های **PUBLIC** روی `0.0.0.0` (مثل قبل) |
| خارج + encrypt | فقط پورت‌های **INTERNAL** آزاد باشند — **نه** پورت‌های PUBLIC پنل |

اگر INTERNAL اشغال بود: هشدار + `ENCRYPT=0` (تانل بالا می‌ماند). پنل را جابه‌جا نکنید.

#### الگوریتم و کلید

- الگوریتم: بعد از دانلود باینری **پروب** می‌شود و در `tunnel.env` به‌صورت `ENC_ALGO=` ذخیره می‌گردد
  - ترجیح: `chacha20-poly1305` (پیش‌فرض مستندات رسمی؛ بدون AES-NI کار می‌کند)
  - جایگزین: `aes-gcm` فقط وقتی باینری/CPU پشتیبانی کند
  - باینری **old-cpu**: معمولاً AES-GCM در crypto backend نیست → اسکریپت `chacha20-poly1305` می‌نویسد
  - اگر هیچ AEAD در دسترس نباشد: هشدار واضح + نصب **بدون** رمزنگاری
- salt ثابت: `waterwall-proto51`
- کلید/پسورد مشترک: دقیقاً **۳۲ کاراکتر**؛ اگر خالی بگذاری خودکار ساخته و چاپ می‌شود
- هر دو طرف باید همان کلید، همان پورت‌های PUBLIC، همان `PORT_OFFSET`، همان `PROTO` و همان `ENC_ALGO` را داشته باشند

### چرا دیگر `AesGcm` نیست؟

نود `AesGcm` در WaterWall 1.46.x و سورس فعلی وجود ندارد. زیپ‌های رسمی فقط یک باینری دارند و پلاگین `libs/AesGcm` ندارند؛ در نتیجه کانفیگ‌های قدیمی با خطای زیر کرش می‌کردند:

```text
library "AesGcm" (hash: ...) could not be loaded
```

راه‌حل درست: نودهای رسمی و استاتیک `EncryptionClient` / `EncryptionServer` (نیازی به دانلود `libs/` نیست).

## پورت‌های پیش‌فرض ایران

`443 2053 2083 2087 2096 8443`

```bash
sudo ww51
# 4) Edit tunnel   یا   5) Change ports
```

## به‌روزرسانی روی سرورهای قبلی

روی **هر دو** سرور:

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh -o /tmp/ww51-install.sh
sudo bash /tmp/ww51-install.sh
```

سپس:

- نصب/نصب مجدد: گزینه **1**
- فقط ویرایش IP / **PROTO** / پورت / رمزنگاری: گزینه **4**
- تأیید بقا بعد از ریبوت و watchdog: گزینه **2) Status**

CLI مستقیم:

```bash
sudo ww51 edit
sudo ww51 status
```

### روشن کردن رمزنگاری روی هر دو سرور

1. اول **خارج** (`sudo ww51` → Edit یا Install):
   - `Enable EncryptionClient/Server?` → `y`
   - همان پورت‌های PUBLIC ایران + همان `PORT_OFFSET` (پیش‌فرض `10000`)
   - کلید ۳۲ کاراکتری را بساز/کپی کن
   - **پنل را جابه‌جا نکن** — می‌تواند روی `0.0.0.0` بماند
2. بعد **ایران**:
   - رمزنگاری `y` + **همان کلید** + همان پورت‌ها + همان `PORT_OFFSET` + همان `PROTO`
   - ایران روی `0.0.0.0:PUBLIC` گوش می‌دهد (با رمز هم OK)
3. Status را روی هر دو چک کن؛ اگر سرویس down بود: `journalctl -u waterwall-proto51 -n 50 --no-pager`

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
2. بدون رمزنگاری: روی خارج سرویس (Xray/پنل) روی همان پورت‌ها روی `0.0.0.0` یا `10.10.0.1` گوش بدهد.
3. با رمزنگاری: پنل خارج می‌تواند روی `0.0.0.0:PUBLIC` بماند؛ WaterWall فقط `10.10.0.1:INTERNAL` را بایند می‌کند.
4. `PROTO` و `PORT_OFFSET` روی هر دو طرف یکسان باشد (Install یا Edit).
5. برای CPU قدیمی، هنگام نصب/Edit گزینه `old-cpu` را انتخاب کن. با رمزنگاری، الگوریتم باید `chacha20-poly1305` باشد (نه `aes-gcm`).
6. مسیر نصب: `/opt/waterwall-proto51`
7. بعد از ریبوت، سرویس و watchdog باید خودکار برگردند؛ Status را چک کن.
8. اگر قبلاً با `aes-gcm` + old-cpu کرش کرده‌ای: روی هر دو سرور اسکریپت را آپدیت کن و Install/Edit را با همان کلید دوباره اعمال کن.

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
