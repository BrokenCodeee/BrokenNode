# Changelog

Newest first. **Update both servers** of a tunnel to the same release: the
two ends now check each other's version and the menu warns when they differ.

## 2.8.10

From a full re-audit of the source; every fix comes with a test that failed
before it. Works with an older release on the other server in both
directions (tested against the published 2.8.4 and 2.8.6–2.8.9 over aead and
tls, and over reality from 2.8.6, the first published release with it); update
both servers to get every fix.

### Fixed
- **reality: the server that dials now requires the other to prove it holds
  the token** (the BN3 mutual-auth proof), as it already did over `none` and
  `tls` — the foreign server in reverse mode, the relay in direct mode. The
  reality client accepts any certificate, so someone in the middle could
  terminate the TLS and pose as the listening server. Every release with
  reality already sends the proof.
- **UDP ports of the relay** no longer freeze for every user while an idle
  session on a stalled link is being closed.
- **tcpnomux: after the relay restarts, the pool refills at once.** It used to
  wait out a one-second pause first, so users arriving right after the relay
  came back waited about a second each.
- **udp/icmp tunnels: a forwarded port another program holds is retried** and
  shown in red in the menu, as the other transports' ports are; IPv6 users get
  in too. It used to be tried once.
- **l2tp: a tunnel no longer deletes another running tunnel that uses the same
  tunnel id**; it says so and stops instead. (Two relays with the same id for
  one foreign server used to cut each other in a loop.)
- **The "other server runs an older release" warning** no longer appears when
  the link merely dropped during the version check.
- **pad**: the padding is random instead of zeros, which with encryption
  `none` was a pattern DPI could match.
- **Proxy (HTTP CONNECT)**: a destination that is not host:port is refused
  with 400 instead of being sent to the foreign server (found by fuzzing).
- The foreign server refuses streams it does not know instead of dialing
  them as TCP connections to the service.
- Diagnose reads at most 512 bytes of a port's answer.
- Manager: on a relay with the proxy on, *Port-forwards* can remove the last
  forwarded port (the proxy alone carries the users); elsewhere the refusal
  now points to proxy mode.
- Config check: the `socks` address is validated; the encryption error lists
  `reality`.

### Tests
- `scripts/menu_test.sh` drives the menu's create/edit flows with scripted
  answers and has the core check every config they write; it runs in CI.
- Fuzz targets for the proxy handshake, pad framing and the ClientHello
  parsers.
- The end-to-end mixed-version test required the "older than 2.8.6" warning,
  which cannot appear once the published release itself is 2.8.6 or newer;
  it now expects what the old binary's version calls for, covers tls and
  reality as well, and passes against 2.8.4 and 2.8.6–2.8.9 both ways round.

---

## فارسی — 2.8.10

حاصل بازبینی کامل دوبارهٔ سورس؛ هر رفع با تستی همراه است که پیش از آن شکست می‌خورد.
با نسخهٔ قدیمی‌تر روی سرور دیگر در هر دو جهت کار می‌کند (با نسخه‌های منتشرشدهٔ 2.8.4 و
2.8.6 تا 2.8.9 روی aead و tls، و روی reality از 2.8.6 که اولین نسخهٔ منتشرشدهٔ دارای آن است،
تست شد)؛ برای گرفتن همهٔ رفع‌ها هر دو سرور را به‌روز کن.

### رفع‌شده
- **reality: سروری که وصل می‌شود (dial می‌کند) حالا از سرور دیگر اثبات توکن را می‌خواهد**
  (اثبات mutual-auth در BN3)، همان‌طور که در `none` و `tls` می‌خواست — در حالت reverse
  سرور خارج و در حالت direct رله. کلاینت reality هر گواهی را می‌پذیرد، پس کسی در مسیر
  می‌توانست TLS را باز کند و خود را جای سرور مقابل جا بزند. همهٔ نسخه‌های دارای reality
  این اثبات را از قبل می‌فرستند.
- **پورت‌های UDP رله** دیگر هنگام بستن یک session بیکار روی لینک گیرکرده برای همهٔ
  کاربران قفل نمی‌شوند.
- **tcpnomux: بعد از ری‌استارت رله، pool فوراً پر می‌شود.** قبلاً اول یک ثانیه صبر می‌کرد
  و کاربرانی که درست بعد از برگشتن رله می‌آمدند هر کدام حدود یک ثانیه منتظر می‌ماندند.
- **تانل‌های udp/icmp: پورتی که برنامهٔ دیگری گرفته دوباره امتحان می‌شود** و در منو
  قرمز نشان داده می‌شود، مثل پورت‌های بقیهٔ ترنسپورت‌ها؛ کاربر IPv6 هم وصل می‌شود.
  قبلاً فقط یک بار امتحان می‌شد.
- **l2tp: تانل دیگر تانل در حال اجرای دیگری با همان tunnel id را پاک نمی‌کند**؛ پیام
  می‌دهد و متوقف می‌شود. (دو رله با id یکسان برای یک سرور خارج همدیگر را در حلقه قطع
  می‌کردند.)
- **هشدار «سرور دیگر نسخهٔ قدیمی‌تر دارد»** دیگر وقتی فقط لینک وسط بررسی نسخه قطع شده
  ظاهر نمی‌شود.
- **pad**: padding تصادفی است نه صفر، که با رمزنگاری `none` الگویی قابل تشخیص برای DPI بود.
- **پروکسی (HTTP CONNECT)**: مقصدی که host:port نیست با 400 رد می‌شود و به سرور خارج
  فرستاده نمی‌شود (با fuzzing پیدا شد).
- سرور خارج stream ناشناخته را رد می‌کند و آن را به‌عنوان اتصال TCP به سرویس dial نمی‌کند.
- Diagnose حداکثر ۵۱۲ بایت از پاسخ یک پورت را می‌خواند.
- منیجر: روی رله‌ای که پروکسی‌اش روشن است، *Port-forwards* می‌تواند آخرین پورت فوروارد را هم
  حذف کند (کاربران فقط از پروکسی رد می‌شوند)؛ در بقیهٔ حالت‌ها پیام رد، حالت پروکسی را پیشنهاد می‌دهد.
- بررسی کانفیگ: آدرس `socks` اعتبارسنجی می‌شود؛ پیام خطای رمزنگاری `reality` را هم نام می‌برد.

### تست‌ها
- `scripts/menu_test.sh` مسیرهای ساخت و ویرایش منو را با پاسخ‌های از پیش نوشته اجرا
  می‌کند و هسته هر کانفیگی را که می‌نویسند چک می‌کند؛ در CI اجرا می‌شود.
- fuzz برای handshake پروکسی، قاب‌بندی pad و پارسرهای ClientHello.
- تست end-to-end نسخه‌های مختلط هشدار «older than 2.8.6» را می‌خواست که وقتی خود نسخهٔ
  منتشرشده 2.8.6 یا جدیدتر است دیگر ظاهر نمی‌شود؛ حالا همان پیامی را انتظار دارد که نسخهٔ
  باینری قدیمی ایجاب می‌کند، tls و reality را هم پوشش می‌دهد، و با 2.8.4 و 2.8.6 تا 2.8.9 در هر
  دو جهت قبول می‌شود.

---

## 2.8.9

### Changed
- **The proxy lives only under *Connection direction*.** The separate
  *Manage → 19) Proxy* item is gone. *Manage → 13) Change direction* now offers
  the same three choices as creating a tunnel — reverse, direct, proxy — so the
  proxy is switched on or off there, and picking 3) proxy again changes its port
  and login. Switching to proxy removes the port forwards (proxy mode has
  none); switching back asks for them.

---

## فارسی — 2.8.9

### تغییر
- **پروکسی فقط در بخش *Connection direction* است.** گزینهٔ جداگانهٔ *Manage ← 19) Proxy*
  حذف شد. *Manage ← 13) Change direction* حالا همان سه گزینهٔ ساخت تانل را دارد (reverse،
  direct، proxy): پروکسی همان‌جا روشن یا خاموش می‌شود و انتخاب دوبارهٔ 3) proxy پورت و رمز
  آن را عوض می‌کند. رفتن به حالت پروکسی فوروارد پورت‌ها را حذف می‌کند (حالت پروکسی فوروارد
  ندارد)؛ برگشتن از آن دوباره پورت‌ها را می‌پرسد.

---

## 2.8.8

### Changed
- **The proxy is now chosen under *Connection direction*, as 3) proxy**, next to
  reverse and direct, instead of a separate yes/no question later. It asks the
  proxy port, username and password, then which server connects (reverse or
  direct), and sets up no port forwards. Pick 3) proxy on the foreign server
  too. *Manage → 19) Proxy* still changes it later.
- The transport menu's first group was labelled "proxy (users connect to a
  port)", which read like the SOCKS proxy. It is now "stream transports (users
  connect to a forwarded port)".

---

## فارسی — 2.8.8

### تغییر
- **پروکسی حالا در بخش *Connection direction* به‌عنوان گزینهٔ 3) proxy** کنار reverse و
  direct انتخاب می‌شود، نه با یک سؤال بله/خیر جداگانه در ادامه. پورت، نام کاربری و رمز
  پروکسی را می‌پرسد، بعد اینکه کدام سرور وصل شود (ریورس یا دایرکت)، و فوروارد پورت
  نمی‌سازد. روی سرور خارج هم 3) proxy را انتخاب کنید. *Manage ← 19) Proxy* همچنان برای
  تغییر بعدی است.
- عنوان گروه اول منوی ترنسپورت «proxy (users connect to a port)» بود که با پروکسی SOCKS
  اشتباه گرفته می‌شد. حالا «stream transports (users connect to a forwarded port)» است.

---

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
