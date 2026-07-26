<div align="center">

# 🚀 Linux Server Optimizer

**اسکریپت راه‌اندازی و بهینه‌سازی خودکار سرور لینوکس**  
برای محیط‌های VPN / Proxy / Xray

[![Version](https://img.shields.io/badge/version-1.2.0-blue?style=for-the-badge)](https://github.com/MNSH-Nexo/linux-server-optimizer)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-orange?style=for-the-badge)](https://github.com/MNSH-Nexo/linux-server-optimizer)
[![Arch](https://img.shields.io/badge/arch-x86__64-green?style=for-the-badge)](https://github.com/MNSH-Nexo/linux-server-optimizer)
[![License](https://img.shields.io/badge/license-MIT-purple?style=for-the-badge)](LICENSE)

</div>

---

## ⚡ اجرای سریع (یک دستور)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/linux-server-optimizer/main/server-setup.sh)
```

> نیاز به دسترسی **root** دارد — اگر با کاربر معمولی هستید:
> ```bash
> sudo bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/linux-server-optimizer/main/server-setup.sh)
> ```

---

## 📋 فهرست محتوا

- [ویژگی‌ها](#-ویژگیها)
- [پیش‌نیازها](#-پیشنیازها)
- [نحوه اجرا](#-نحوه-اجرا)
- [مراحل اجرا](#-مراحل-اجرا)
- [تنظیمات بهینه‌شده](#-تنظیمات-بهینهشده)
- [بعد از اجرا](#-بعد-از-اجرا)
- [سوالات متداول](#-سوالات-متداول)

---

## ✨ ویژگی‌ها

| ویژگی | توضیح |
|-------|--------|
| 🌀 **XanMod Kernel** | نصب خودکار کرنل XanMod با BBRv3 |
| 🧠 **Smart Scaling** | تنظیمات sysctl هوشمند بر اساس RAM/CPU سرور |
| 📡 **MTU = 1360** | تنظیم دائمی MTU روی تمام اینترفیس‌ها |
| 🛡 **iptables TCPMSS** | اعمال MSS=1360 برای جلوگیری از fragmentation |
| 🔁 **Idempotent** | اجرای مجدد بدون مشکل |
| 🎨 **Professional UI** | نمایشگر پیشرفت، spinner، banner ASCII |
| 📝 **Full Log** | لاگ کامل در `/var/log/server-setup.log` |
| ✅ **Auto-detect** | تشخیص خودکار IPv4/IPv6 و CPU level |

---

## 📦 پیش‌نیازها

- **سیستم‌عامل**: Debian یا Ubuntu (هر نسخه‌ای)
- **معماری**: x86_64
- **دسترسی**: root
- **اینترنت**: اتصال به اینترنت (برای دریافت XanMod)
- **ابزارها**: `curl`, `gpg` (در صورت نبود، خودکار نصب می‌شوند)

---

## 🚀 نحوه اجرا

### روش ۱ — مستقیم (توصیه‌شده)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MNSH-Nexo/linux-server-optimizer/main/server-setup.sh)
```

### روش ۲ — دانلود و اجرا

```bash
curl -O https://raw.githubusercontent.com/MNSH-Nexo/linux-server-optimizer/main/server-setup.sh
chmod +x server-setup.sh
sudo bash server-setup.sh
```

### روش ۳ — با wget

```bash
wget -qO server-setup.sh https://raw.githubusercontent.com/MNSH-Nexo/linux-server-optimizer/main/server-setup.sh
sudo bash server-setup.sh
```

---

## 🔄 مراحل اجرا

```
╔══════════════════════════════════════════════════════╗
║  فاز 0  —  بررسی محیط و پیش‌نیازها                  ║
║  فاز 1  —  تشخیص منابع سیستم (RAM / CPU)            ║
║  فاز 2  —  نصب کرنل XanMod (BBRv3)                   ║
║  فاز 3  —  تنظیمات sysctl هوشمند                     ║
║  فاز 4  —  تنظیم MTU = 1360                           ║
║  فاز 5  —  پیکربندی iptables / TCPMSS                ║
║  فاز 6  —  خلاصه نهایی                               ║
╚══════════════════════════════════════════════════════╝
```

---

## ⚙️ تنظیمات بهینه‌شده

### 🔧 sysctl (`/etc/sysctl.conf`)

تمام مقادیر **به صورت هوشمند** بر اساس منابع سرور شما محاسبه می‌شوند:

| پارامتر | توضیح | مثال (1GB RAM) |
|---------|--------|----------------|
| `net.core.rmem_max` | حداکثر بافر دریافت | 32MB |
| `net.core.wmem_max` | حداکثر بافر ارسال | 32MB |
| `net.ipv4.tcp_congestion_control` | الگوریتم کنترل ازدحام | `bbr` |
| `net.core.default_qdisc` | صف پیش‌فرض | `fq` |
| `net.core.somaxconn` | حداکثر صف اتصالات | 16384 |
| `net.ipv4.tcp_max_tw_buckets` | TIME_WAIT buckets | ~675K |
| `net.netfilter.nf_conntrack_max` | حداکثر ردیابی اتصال | ~123K |
| `fs.file-max` | حداکثر فایل‌های باز | ~492K |
| `net.ipv4.tcp_fastopen` | TCP Fast Open | `3` |
| `net.ipv4.tcp_tw_reuse` | استفاده مجدد TIME_WAIT | `1` |

### 📡 MTU & MSS

```
MTU  = 1360  →  تنظیم روی تمام اینترفیس‌های شبکه
MSS  = 1360  →  iptables mangle TCPMSS
```

ماندگاری MTU از طریق:
- **Netplan** (Ubuntu): تغییر در فایل YAML
- **NetworkManager**: `nmcli con mod`
- **systemd unit**: `set-mtu.service` (fallback همیشگی)

---

## ✅ بعد از اجرا

پس از اتمام اسکریپت، برای فعال شدن **XanMod + BBRv3** سرور را ریبوت کنید:

```bash
sudo reboot
```

### تأیید بعد از ریبوت

```bash
# بررسی کرنل XanMod
uname -r
# خروجی مورد انتظار: 6.x.x-x-xanmod1 یا مشابه

# بررسی BBR
sysctl net.ipv4.tcp_congestion_control
# خروجی مورد انتظار: net.ipv4.tcp_congestion_control = bbr

# بررسی الگوریتم‌های موجود
cat /proc/sys/net/ipv4/tcp_available_congestion_control
# باید شامل bbr باشد

# بررسی MTU
ip link show
# باید mtu 1360 نشان دهد

# بررسی iptables
iptables -t mangle -L POSTROUTING -n -v | grep TCPMSS
```

---

## ❓ سوالات متداول

**Q: آیا روی Ubuntu 22.04 / 24.04 کار می‌کند؟**  
A: بله، کاملاً تست شده روی Ubuntu 24.04 Noble Numbat.

**Q: آیا اجرای دوباره مشکلی ایجاد می‌کند؟**  
A: خیر، اسکریپت idempotent است — اجرای مجدد امن است.

**Q: آیا XanMod روی ARM/VPS ارزان نصب می‌شود؟**  
A: XanMod فقط x86_64 دارد. روی ARM، فاز نصب کرنل رد می‌شود اما بقیه تنظیمات اعمال می‌شوند.

**Q: بعد از reboot کرنل تغییر نکرد؟**  
A: مطمئن شوید GRUB بوت لودر روی کرنل جدید تنظیم شده: `sudo update-grub`

**Q: لاگ کجاست؟**  
A: `/var/log/server-setup.log` — با `cat /var/log/server-setup.log` مشاهده کنید.

---

## 📊 نتایج تست

| محیط | وضعیت |
|------|--------|
| Ubuntu 24.04 Noble — 1GB RAM — 1 vCPU | ✅ تأیید شده |
| Ubuntu 22.04 Jammy — 2GB RAM — 2 vCPU | ✅ تأیید شده |
| Debian 12 Bookworm — 1GB RAM — 1 vCPU | ✅ تأیید شده |

---

## 📄 لایسنس

MIT License — آزادانه استفاده و تغییر کنید.

---

<div align="center">

**ساخته‌شده با ❤️ برای بهینه‌سازی سرورهای لینوکس**

</div>
