# Changelog

Newest first. **Update both servers** of a tunnel to the same release: the
two ends now check each other's version and the menu warns when they differ.

## 2.8.7

### New
- **Every setting is asked in the menu, and can be changed later.** Creating a
  tunnel now also asks for:
  - `reality` as an encryption choice, with the real site it borrows
    (`reality_dest`);
  - on the end that connects: the browser fingerprint (`tls_fingerprint`) for
    tls, and splitting the ClientHello (`tls_fragment`) for tls and reality;
  - padding (`pad`);
  - on the Iran server, an optional SOCKS5/HTTP proxy (`socks`) with a login.
    Port forwards become optional when the proxy is on.
- **Manage → a tunnel → 14) Encryption & stealth:** change the encryption layer,
  the token, the tls name and ALPN, the reality site, the fingerprint, the
  fragment and padding.
- **Manage → a tunnel → 19) Proxy** (Iran server): turn the proxy on or off,
  change its port and login.
- **Tune settings** now also covers the ws path and headers, `links_max`,
  `links_per_link`, `pool_min_idle`, `smux_frame_kb`, and for point-to-point
  tunnels the two IPs, the tunnel addresses, the gre key, the l2tp ids, encap
  and port, and the carrier port.
- **Change peer IP** works for point-to-point tunnels too (`remote_ip`).

### Fixed
- Changing the transport away from ws no longer leaves its `ws_*` settings in
  the config. Switching the encryption layer drops the old layer's settings
  (tls, reality, fragment) and asks the new layer's questions.

### Note
- In the encryption menu `none` is now 5 (4 is `reality`).

---

## فارسی — 2.8.7

### جدید
- **همهٔ تنظیمات در منو پرسیده می‌شوند و بعداً قابل تغییرند.** ساخت تانل حالا این‌ها را
  هم می‌پرسد:
  - `reality` به‌عنوان یک گزینهٔ رمزنگاری، با سایت واقعی‌ای که از آن استفاده می‌کند
    (`reality_dest`)؛
  - روی طرفی که وصل می‌شود: اثرانگشت مرورگر (`tls_fingerprint`) برای tls، و
    تکه‌تکه کردن ClientHello (`tls_fragment`) برای tls و reality؛
  - padding (`pad`)؛
  - روی سرور ایران، پروکسی اختیاری SOCKS5/HTTP (`socks`) با نام کاربری و رمز. با
    روشن بودن پروکسی، فوروارد پورت اختیاری است.
- **Manage ← یک تانل ← 14) Encryption & stealth:** تغییر لایهٔ رمزنگاری، توکن، نام و
  ALPN در tls، سایت reality، اثرانگشت، fragment و padding.
- **Manage ← یک تانل ← 19) Proxy** (سرور ایران): روشن/خاموش کردن پروکسی و تغییر
  پورت و نام کاربری و رمز.
- **Tune settings** حالا این‌ها را هم دارد: مسیر و هدرهای ws، `links_max`،
  `links_per_link`، `pool_min_idle`، `smux_frame_kb`، و برای تانل‌های نقطه‌به‌نقطه دو
  IP، آدرس‌های تانل، کلید gre، شناسه‌ها و encap و پورت l2tp، و پورت حامل.
- **Change peer IP** حالا برای تانل‌های نقطه‌به‌نقطه هم کار می‌کند (`remote_ip`).

### رفع‌شده
- عوض کردن ترنسپورت از ws دیگر تنظیمات `ws_*` را در کانفیگ جا نمی‌گذارد. عوض کردن
  لایهٔ رمزنگاری تنظیمات لایهٔ قبلی (tls، reality، fragment) را پاک می‌کند و سؤال‌های
  لایهٔ جدید را می‌پرسد.

### توجه
- در منوی رمزنگاری، `none` حالا گزینهٔ 5 است (4 شده `reality`).

---

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
