# Changelog

Newest first. **Update both servers** of a tunnel to the same release: the
two ends now check each other's version and the menu warns when they differ.

## 2.8.6

### Fixed
- **Tunnel connected, speed test fine, but users get nothing.** A deleted
  `gre`/`ipip`/`l2tp` tunnel could leave its NAT rules behind (its stop was
  killed, or another program held the firewall lock at that moment), and they
  kept sending its ports to a tunnel that no longer existed. Now every
  firewall call waits for the lock, a stop removes every rule carrying the
  tunnel's tag (whatever form an older release wrote it in) and reports any
  it cannot, and the rules of tunnels that no longer run are swept after
  every stop (even a crash or `kill -9`), by the health check, at every
  start, when a tunnel is deleted, and by `brokennode cleanup` by hand.
  Uninstall removes every BrokenNode rule. A NAT rule another program added
  is reported with the command that removes it.
- **Two tunnels could forward the same port**; the second one's rule never
  saw a packet. A tunnel is now refused when a running one already forwards
  its port.
- **mtcp dropped about one user in five** when a burst arrived after an idle
  spell (the client closed idle links while the relay was still sending new
  users onto them). Measured over an 80 ms path: 149/200 before, 1600/1600
  after.
- **kcp took 18–20 s to recover after a relay restart**; now about 10 s.
- **udp/icmp tunnels ignored `target_host`**: a service listening on
  127.0.0.1 got nothing. They now deliver to `target_host` like the kernel
  tunnels.
- **`pad` cut throughput to a quarter** (391 Mbit/s on a 1.4 Gbit/s link);
  now 1154 Mbit/s, with the timing jitter kept for light traffic.
- A forwarded port that another program held at start was given up for good;
  it is now retried every 10 s and served as soon as it is free.
- A reality handshake that stalled had no time limit.

### New
- **Diagnose** (Manage tunnels → a tunnel → 18, or `brokennode doctor -c
  CONFIG`): checks every port end to end — served here, not taken by a NAT
  rule, open in the firewall, and reachable by the other server at
  `target_host` — and prints the command that fixes each problem.
- The menu shows in red a port that is not being served, and in yellow when
  the two servers run different releases.
- Forwarded ports accept IPv6 users as well as IPv4.
- Proxy mode on the relay: `socks` (SOCKS5 + HTTP CONNECT), with
  `socks_user` + `socks_pass` for a login.
- `tls_fragment` now works with `encryption: "reality"` too.

### Check your config
- `socks_user` and `socks_pass` are set together or not at all, and a proxy
  with no login on a public address needs `"socks_open": true`.

---

## فارسی — 2.8.6

**هر دو سرور** یک تانل را به یک نسخه آپدیت کنید: حالا دو طرف نسخهٔ هم را چک
می‌کنند و منو اگر متفاوت باشند هشدار می‌دهد.

### رفع‌شده
- **تانل وصل است و تست سرعت خوب، ولی کاربر هیچ.** تانل `gre`/`ipip`/`l2tp`
  حذف‌شده ممکن بود قوانین NAT خود را جا بگذارد و پورت‌هایش را به تانلی که دیگر
  نبود بفرستد. حالا هر فراخوانی فایروال منتظر قفل می‌ماند، توقف تانل همهٔ
  قوانینِ با برچسب آن را (به هر شکلی که نسخه‌های قبلی نوشته باشند) پاک می‌کند و
  اگر نتواند گزارش می‌دهد، و قوانین تانل‌هایی که دیگر اجرا نمی‌شوند بعد از هر
  توقف (حتی crash یا `kill -9`)، در بررسی سلامت، در هر اجرا، هنگام حذف تانل و
  با `brokennode cleanup` جارو می‌شوند. حذف کامل BrokenNode همهٔ قوانینش را پاک
  می‌کند. قانونی که برنامهٔ دیگری گذاشته با دستور حذفش گزارش می‌شود.
- **دو تانل می‌توانستند یک پورت را فوروارد کنند** و قانون دومی هیچ بسته‌ای
  نمی‌دید. حالا اگر تانلِ در حال اجرایی همان پورت را دارد، تانل جدید رد می‌شود.
- **mtcp از هر پنج کاربر یکی را می‌انداخت** وقتی بعد از مدتی بیکاری موجی از
  کاربرها می‌رسید. روی مسیر ۸۰ میلی‌ثانیه: قبلاً ۱۴۹ از ۲۰۰، حالا ۱۶۰۰ از ۱۶۰۰.
- **kcp بعد از ری‌استارت رله ۱۸ تا ۲۰ ثانیه طول می‌کشید**؛ حالا حدود ۱۰ ثانیه.
- **تانل‌های udp/icmp به `target_host` تحویل نمی‌دادند**: سرویسی که روی
  127.0.0.1 گوش می‌داد چیزی نمی‌گرفت. حالا مثل تانل‌های کرنلی تحویل می‌دهند.
- **`pad` سرعت را یک‌چهارم می‌کرد**؛ حالا تقریباً کامل (۳۹۱ ← ۱۱۵۴ مگابیت).
- پورتی که موقع شروع دست برنامهٔ دیگری بود برای همیشه رها می‌شد؛ حالا هر ۱۰ ثانیه
  دوباره امتحان می‌شود و به محض آزاد شدن سرویس می‌دهد.
- handshake گیرکردهٔ reality محدودیت زمانی نداشت.

### جدید
- **Diagnose** (مدیریت تانل‌ها ← یک تانل ← ۱۸، یا `brokennode doctor -c CONFIG`):
  هر پورت را در کل مسیر چک می‌کند و برای هر مشکل دستور رفعش را می‌دهد.
- منو پورتی را که سرویس نمی‌دهد قرمز، و نسخه‌های متفاوت دو سرور را زرد نشان می‌دهد.
- پورت‌های فوروارد حالا کاربر IPv6 را هم می‌پذیرند.
- حالت پروکسی روی رله: `socks` (SOCKS5 و HTTP CONNECT)، با `socks_user` و
  `socks_pass` برای ورود با رمز.
- `tls_fragment` حالا با `encryption: "reality"` هم کار می‌کند.

### کانفیگ خود را چک کنید
- `socks_user` و `socks_pass` باید با هم باشند یا هیچ‌کدام، و پروکسی بدون رمز روی
  آدرس عمومی `"socks_open": true` لازم دارد.
