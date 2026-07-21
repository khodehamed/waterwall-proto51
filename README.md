# WaterWall Proto51 Tunnel

اسکریپت نصب تانل **WaterWall** با پروتکل IP سفارشی (پیش‌فرض `51`)، فوروارد پورت از ایران به خارج، و رمزنگاری اختیاری `AesGcm`.

## نصب یک‌خطی

روی **هر دو سرور** (اول خارج، بعد ایران):

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash
```

بعد از نصب، منو با دستور `ww51` هم در دسترس است.

## کارهایی که اسکریپت می‌کند

| مورد | توضیح |
|------|--------|
| پروتکل | پیش‌فرض `51` (قابل تغییر) |
| ایران | `TcpListener` روی `0.0.0.0` برای پورت‌های انتخابی → فوروارد به `10.10.0.2` |
| خارج | endpoint تانل؛ پنل/Xray باید همان پورت‌ها را گوش بدهد |
| رمزنگاری | اختیاری با `AesGcm` (کلید دقیقاً ۳۲ کاراکتر، یکسان در دو طرف) |
| سرویس | `systemd` با نام `waterwall-proto51` |
| باینری | دانلود از [radkesvat/WaterWall](https://github.com/radkesvat/WaterWall/releases) |

## پورت‌های پیش‌فرض ایران

`80 443 2053 2083 2087 2096 8080 8443 8880`

در منو می‌توانی عوضشان کنی، یا بعداً:

```bash
sudo ww51
# گزینه 4) Change Iran ports
```

## دستورات مفید

```bash
sudo ww51                 # منو
systemctl status waterwall-proto51
journalctl -u waterwall-proto51 -f
ip addr show wtun0
```

## نکات

1. اول سرور **خارج** را نصب/استارت کن، بعد **ایران**.
2. روی خارج، سرویس (Xray/پنل) باید روی همان پورت‌ها روی `0.0.0.0` یا `10.10.0.1` گوش بدهد.
3. اگر رمزنگاری روشن است، **همان کلید AES** را در هر دو طرف وارد کن.
4. برای CPU قدیمی، هنگام نصب گزینه `old-cpu` را انتخاب کن.
5. مسیر نصب: `/opt/waterwall-proto51`

## حذف

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51/master/install.sh | sudo bash
# گزینه 5) Uninstall
```

یا:

```bash
sudo bash /opt/waterwall-proto51/install.sh uninstall
```

## Disclaimer

این ابزار فقط برای تانل‌سازی و مدیریت شبکهٔ مجاز است. مسئولیت استفاده بر عهدهٔ کاربر است.
