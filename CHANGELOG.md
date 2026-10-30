# Changelog

Newest first. **Update both servers** of a tunnel to the same release: the
two ends now check each other's version and the menu warns when they differ.

## 2.8.16

### Fixed
- **UDP through a kernel tunnel (gre, gretap, ipip, l2tp).** On the foreign
  server every UDP service that ties its socket to the sender after the
  first packet — iperf3, many game and QUIC servers — got that first packet
  and nothing after it: each later one was answered with "port unreachable"
  (measured on a real GRE-inside-UDP tunnel: 0 bytes, while ping worked). A
  service listening on 0.0.0.0 now receives the tunnel's traffic directly;
  only one bound to 127.0.0.1 alone still goes through the address
  rewrite. Update the foreign server.

---

## فارسی — 2.8.16

### رفع اشکال
- **UDP داخل تانل‌های کرنل (gre، gretap، ipip، l2tp).** روی سرور خارج، هر سرویس UDP که بعد از اولین بسته
  سوکتش را به فرستنده وصل می‌کند (iperf3، خیلی از سرورهای بازی و QUIC) فقط همان بستهٔ اول را می‌گرفت و
  جواب بقیه "port unreachable" بود (روی یک تانل واقعی GRE داخل UDP اندازه‌گیری شد: ۰ بایت، در حالی که
  پینگ کار می‌کرد). حالا سرویسی که روی 0.0.0.0 گوش می‌دهد ترافیک تانل را مستقیم می‌گیرد و فقط سرویسی که
  تنها روی 127.0.0.1 است از مسیر تغییر آدرس می‌گذرد. سرور خارج را بروز کنید.

---

## 2.8.15

### New
- **GRE inside UDP (`fou_port`).** Many paths drop GRE's own protocol (IP
  protocol 47) while UDP passes: the tunnel came up on both servers, the
  servers pinged each other, and nothing went through. With `fou_port` the
  same kernel tunnel (gre, gretap, ipip, sit) travels inside UDP to that
  port, at the same speed. Asked when a tunnel is created; also in Tune; the
  share code carries it. The health check now says so when a tunnel's own
  protocol is the likely problem, and checks the firewall for the UDP port.

---

## فارسی — 2.8.15

### جدید
- **GRE داخل UDP (`fou_port`).** خیلی از مسیرها خود پروتکل GRE (شمارهٔ ۴۷) را می‌بندند ولی UDP را رد
  می‌کنند: تانل روی هر دو سرور بالا می‌آمد، سرورها همدیگر را پینگ می‌کردند، ولی چیزی از تانل رد نمی‌شد.
  با `fou_port` همان تانل کرنل (gre، gretap، ipip، sit) داخل UDP روی آن پورت می‌رود، با همان سرعت.
  موقع ساختن تانل پرسیده می‌شود، در Tune هم هست، و کد اشتراک منتقلش می‌کند. گزارش عیب‌یابی هم حالا
  وقتی مشکل از بسته بودن خود پروتکل تانل است این را می‌گوید، و فایروال را برای آن پورت UDP چک می‌کند.

---

## 2.8.14

### Changed
- **The share line asks nothing on the other server.** Pasted as printed
  (`BrokenNode import …` or the install line), every question it could raise
  takes its usual answer, shown on the screen: a tunnel name already taken
  there gets a free one, the same tunnel is updated, a point-to-point tunnel
  behind NAT uses that server's own address, and a line pasted back on the
  server that made it is refused. Still asked: the user ports when the line
  comes from the foreign server, and a backup that would open a proxy without
  a password. Pasted at the menu's prompt, the questions are asked as before.
- **An update is complete.** Rolling the core back (menu 7, `BrokenNode
  rollback`, `BrokenNode unpin`) is removed: no older core is kept, and a
  server that 2.8.13 left on an older core is brought up to date at the next
  start or update.

---

## فارسی — 2.8.14

### تغییرات
- **خط اشتراک روی سرور دوم هیچ سؤالی نمی‌پرسد.** وقتی همان‌طور که چاپ شده paste شود (`BrokenNode import …`
  یا خط نصب)، هر سؤالی که پیش بیاید جواب معمولش را می‌گیرد و روی صفحه نشان داده می‌شود: اسمی که آن‌جا
  گرفته شده یک اسم آزاد می‌گیرد، همان تانل به‌روز می‌شود، تانل نقطه‌به‌نقطه پشت NAT آدرس خود آن سرور را
  می‌گیرد، و خطی که روی همان سرور سازنده paste شود رد می‌شود. هنوز پرسیده می‌شود: پورت‌های کاربران وقتی
  خط از سرور خارج آمده، و پشتیبانی که پروکسی بدون رمز باز می‌کند. اگر کد در منو paste شود، سؤال‌ها مثل
  قبل پرسیده می‌شوند.
- **به‌روزرسانی کامل است.** برگرداندن هسته (گزینهٔ 7 منو، `BrokenNode rollback`، `BrokenNode unpin`) حذف
  شد: هیچ هستهٔ قدیمی‌ای نگه داشته نمی‌شود، و سروری که 2.8.13 روی هستهٔ قدیمی گذاشته بود در اجرای بعدی
  منو یا به‌روزرسانی بعدی به نسخهٔ جدید می‌رسد.

---

## 2.8.13

**Update both servers.** The security fix and the half-close fix take effect
only when both ends run 2.8.13; an updated end still works with an older one.

### Security
- **tls (self-signed) and reality: an attacker on the path between the two
  servers could read and change the tunnel.** The dialing end cannot verify a
  self-signed (or reality's) certificate, and the token check did not cover
  the TLS session, so a device that ended the TLS on both sides and passed the
  token check along was trusted by both servers and saw every connection in
  the clear. The token check is now bound to the TLS session itself: such a
  device gets nothing, and both servers log that the token differs or the TLS
  is being intercepted. Until the other server is updated too, the updated one
  logs once that the tunnel is still exposed. aead was not affected.
- **The installer never installs files it could not verify.** Without a
  SHA-256 tool it used to install unchecked; it now stops and says which tool
  to install. Downloads stay on https (a redirect to http is refused).
- Built with Go 1.26.10 (crypto/x509 fix, GO-2026-6809).

### Fixed
- **Cut-off replies on every multiplexed transport** (tcp, mtcp, ws, kcp, …).
  A user program that finishes sending and closes its sending side before the
  reply arrives (common for scripted HTTP, uploads, rsync, `nc -N`) got only
  part of the reply. Three causes, including a bug in the smux library (fixed
  in a bundled copy). Both ends must be updated.
- **kcp comes back in about a second after the link between the servers
  drops**, instead of about 20 seconds: a failed send now ends the dead link
  at once.
- **After an outage, users are no longer sent down links the other server has
  already given up** (mtcp, kcp): the relay prefers links it still hears from.
- **A tunnel never deletes a network interface it did not create.** Starting a
  kernel or packet tunnel deleted any device with its name (tun_name), taken
  for a leftover — wg0, docker0, another VPN's tun0, or another running
  tunnel's device. Now only a leftover of BrokenNode's own is removed; anything
  else stops the start with the reason.
- Settings a config has that this release does not know are named in a
  warning (a typo used to be ignored silently). A point-to-point tunnel whose
  local_ip and remote_ip are the same address is refused.
- A backup code shows each proxy it would open (and whether it has a
  password) before restoring; one with an open proxy asks with "No" as the
  default. A setting stored as null in a backup survives the round trip.
- The menu run from a script whose input has ended no longer asks for the
  user ports for ever when the default list clashes with another tunnel.
- A tunnel started right after another tunnel on its ports was killed is no
  longer refused as if that one still ran.
- The SOCKS5 proxy refuses a destination name that cannot be dialed (such as
  `]`) at once, as the HTTP proxy already did, instead of sending it through
  the tunnel to fail there.

### New
- **Roll back the core:** `BrokenNode rollback` (or menu 7) puts the previous
  core back, keeps it there across menu starts and restarts the tunnels;
  `BrokenNode unpin` or Update ends that.

---

## فارسی — 2.8.13

**هر دو سرور را به‌روز کن.** رفع مشکل امنیتی و رفع قطع‌شدن پاسخ‌ها فقط وقتی اثر دارد که هر دو طرف
2.8.13 باشند؛ طرف به‌روزشده با طرف قدیمی هم کار می‌کند.

### امنیتی
- **tls (خودامضا) و reality: کسی که روی مسیر بین دو سرور است می‌توانست تانل را بخواند و تغییر دهد.**
  طرفی که وصل می‌شود گواهی خودامضا (و گواهی reality) را نمی‌تواند بررسی کند، و بررسی توکن به خود
  نشست TLS گره نخورده بود؛ دستگاهی که TLS را از هر دو طرف باز می‌کرد و بررسی توکن را دست‌نخورده
  رد می‌کرد، مورد اعتماد هر دو سرور بود و همهٔ اتصال‌ها را بدون رمز می‌دید. حالا بررسی توکن به خود
  نشست TLS گره خورده است: چنین دستگاهی هیچ چیز به دست نمی‌آورد و هر دو سرور در لاگ می‌نویسند که
  توکن فرق دارد یا TLS در مسیر شنود می‌شود. تا وقتی سرور دیگر هم به‌روز نشده، سرور به‌روزشده یک بار
  می‌نویسد که تانل هنوز در معرض است. aead تحت تأثیر نبود.
- **نصب‌کننده هیچ‌وقت فایل تأییدنشده نصب نمی‌کند.** بدون ابزار SHA-256 قبلاً بدون بررسی نصب می‌کرد؛
  حالا متوقف می‌شود و می‌گوید چه چیزی نصب شود. دانلودها روی https می‌مانند (ریدایرکت به http رد می‌شود).
- ساخته‌شده با Go 1.26.10 (رفع مشکل crypto/x509، GO-2026-6809).

### رفع‌شده
- **پاسخ‌های نصفه روی همهٔ ترنسپورت‌های مالتی‌پلکس** (tcp، mtcp، ws، kcp، …). برنامه‌ای که ارسالش
  تمام می‌شود و قبل از رسیدن پاسخ سمت ارسالش را می‌بندد (رایج در HTTP اسکریپتی، آپلود، rsync،
  `nc -N`) فقط بخشی از پاسخ را می‌گرفت. سه علت داشت، از جمله یک باگ در کتابخانهٔ smux (در یک نسخهٔ
  همراه رفع شده). هر دو طرف باید به‌روز شوند.
- **kcp بعد از قطع‌شدن ارتباط بین دو سرور حدود یک ثانیه‌ای برمی‌گردد**، نه حدود ۲۰ ثانیه: ارسالِ
  ناموفق حالا لینک مرده را فوراً می‌بندد.
- **بعد از قطعی، کاربرها دیگر به لینک‌هایی که سرور دیگر رهایشان کرده فرستاده نمی‌شوند** (mtcp،
  kcp): رله لینک‌هایی را ترجیح می‌دهد که هنوز از آن‌ها چیزی می‌شنود.
- **تانل هیچ‌وقت اینترفیس شبکه‌ای را که خودش نساخته پاک نمی‌کند.** روشن‌کردن تانل کرنلی یا پکتی هر
  دستگاهی با همان نام (tun_name) را به‌عنوان باقی‌مانده پاک می‌کرد — wg0، docker0، tun0 یک VPN
  دیگر، یا دستگاه تانلی که در حال کار است. حالا فقط باقی‌ماندهٔ خود BrokenNode پاک می‌شود؛ هر چیز
  دیگری روشن‌شدن را با ذکر دلیل متوقف می‌کند.
- تنظیماتی در کانفیگ که این نسخه نمی‌شناسد در یک هشدار نام برده می‌شوند (غلط تایپی قبلاً بی‌صدا
  نادیده گرفته می‌شد). تانل نقطه‌به‌نقطه‌ای که local_ip و remote_ip آن یکی است رد می‌شود.
- کد پشتیبان قبل از بازگردانی هر پروکسی‌ای را که باز می‌کند (و این‌که رمز دارد یا نه) نشان می‌دهد؛
  اگر پروکسی باز بدون رمز داشته باشد، پیش‌فرض سؤال «نه» است. تنظیمی که در پشتیبان null ذخیره شده
  سالم برمی‌گردد.
- منو وقتی از اسکریپتی اجرا شود که ورودی‌اش تمام شده، اگر پورت‌های پیش‌فرض با تانل دیگری تداخل داشته
  باشند دیگر سؤال پورت‌ها را بی‌پایان تکرار نمی‌کند.
- تانلی که درست بعد از kill شدن تانل دیگری روی همان پورت‌ها روشن شود، دیگر طوری رد نمی‌شود که انگار
  آن تانل هنوز در حال کار است.
- پروکسی SOCKS5 مقصدی را که نمی‌شود به آن وصل شد (مثل `]`) همان اول رد می‌کند، همان‌طور که پروکسی
  HTTP از قبل می‌کرد، به‌جای این‌که آن را از تانل بفرستد تا آن‌جا شکست بخورد.

### جدید
- **برگرداندن هسته:** `BrokenNode rollback` (یا گزینهٔ 7 منو) هستهٔ قبلی را برمی‌گرداند، با شروع
  دوبارهٔ منو هم همان می‌ماند و تانل‌ها را ری‌استارت می‌کند؛ `BrokenNode unpin` یا Update این را تمام می‌کند.

---

## 2.8.12

### New
- **Share codes.** After you create a tunnel the manager prints one line to
  paste into the other server's terminal: it sets up that end — transport,
  encryption, token, direction, tunnel addresses, keys, the address to dial —
  mirrored for that side, and starts it. Works from either end; on a server
  without BrokenNode the same line installs it first; pasted where the tunnel
  already exists it updates it in place. Also under Manage tunnels → 19) Share
  code, and the new main menu item 6) Share codes.
- **Backup codes.** 6) Share codes → 2) gives one line with every tunnel on
  the server. Pasted on a new server (when the old one's IP is filtered) it
  rebuilds them all — stopped ones stay stopped — and prints a line for each
  other server that has to learn the new IP.
- A code is a short line such as `2XTQE9-7Ry49o-HcbpAz-…` (about 60
  characters for a tunnel), with a checksum: a mistyped or half-copied code
  is refused, never half-imported. New tunnels get 16-character tokens, which
  keeps their codes short.
- Command line: `BrokenNode share <tunnel>`, `BrokenNode backup`,
  `BrokenNode import <code>`; the installer passes its arguments on, so
  `bash <(curl ... install.sh) import <code>` installs and imports.

### Fixed
- **A kernel tunnel on a server without iptables** no longer comes up
  "connected" while forwarding nothing: it stops with "iptables is not
  installed … apt install -y iptables", and Diagnose says the same instead of
  "restart it".

---

## فارسی — 2.8.12

### جدید
- **کد اشتراک.** بعد از ساختن هر تانل، منو یک خط چاپ می‌کند که در ترمینال سرور دوم paste می‌شود و
  طرف دیگر تانل را می‌سازد — ترنسپورت، رمزنگاری، توکن، جهت، آدرس‌های تانل، کلیدها و آدرسی که باید
  به آن وصل شود — برای آن طرف برعکس‌شده، و روشنش می‌کند. از هر دو طرف کار می‌کند؛ روی سروری که
  BrokenNode ندارد همان خط اول نصبش می‌کند؛ اگر تانل از قبل باشد همان را به‌روز می‌کند. در Manage
  tunnels ← 19) Share code و گزینهٔ جدید 6) Share codes در منوی اصلی هم هست.
- **کد پشتیبان.** 6) Share codes ← 2) یک خط با همهٔ تانل‌های سرور می‌دهد. روی سرور جدید (وقتی آی‌پی
  قبلی فیلتر شد) paste کن: همه دوباره ساخته می‌شوند — تانل‌های خاموش خاموش می‌مانند — و برای هر سرور
  دیگری که باید آی‌پی جدید را بداند یک خط چاپ می‌شود.
- کد یک خط کوتاه است مثل `2XTQE9-7Ry49o-HcbpAz-…` (برای یک تانل حدود ۶۰ کاراکتر) با checksum:
  کدی که اشتباه تایپ یا نصفه کپی شود رد می‌شود و هیچ‌وقت نصفه import نمی‌شود. تانل‌های جدید توکن
  ۱۶ کاراکتری می‌گیرند تا کدشان کوتاه بماند.
- خط فرمان: `BrokenNode share <tunnel>`، `BrokenNode backup`، `BrokenNode import <code>`؛ نصب‌کننده
  آرگومان‌ها را به منو می‌دهد، پس `bash <(curl ... install.sh) import <code>` نصب و import را یک‌جا انجام می‌دهد.

### رفع‌شده
- **تانل کرنلی روی سروری که iptables ندارد** دیگر «وصل» نشان داده نمی‌شود در حالی که هیچ پورتی را
  رد نمی‌کند: با پیام «iptables is not installed … apt install -y iptables» متوقف می‌شود و Diagnose
  هم همین را می‌گوید، نه «ری‌استارت کن».

---

## 2.8.11

### Fixed
- **mtcp uses far less memory.** Every mtcp link is its own smux session, one
  per concurrent user connection, and each got the full 16/8 MB windows (more
  on large servers). Users who read slower than the tunnel delivers — a weak
  mobile link — fill them: 60 such users held 310-342 MB on the relay where
  tcp held 52 MB and tcpnomux 35 MB, and a relay of 1-2 GB with a few hundred
  users runs out of memory and stalls. Unless `smux_recv_mb` / `smux_stream_mb`
  are set, mtcp's windows now scale with RAM, 1 MB per stream on a server of
  less than 4 GB and at most 4 MB: the same 60 users hold 43 MB. A connection carries
  about window ÷ ping (1 MB: ~70 Mbit/s at 120 ms); each has a link of its own.
  Update both servers: each end buffers with its own windows.
- **A path that goes silent is reported as such.** When nothing arrives from
  the other end for the keepalive window (a filter dropping the traffic, a
  dead route), the disconnect line said "session closed locally (restart or
  reconfiguration)"; it now says "keepalive timeout — no data from the peer".
  Same for kcp's silence watchdog.
- **A dial that times out after the tunnel had been up** no longer tells you to
  open the port in the firewall (it was open — the tunnel used it): it says
  the server answered earlier and packets between the servers are being
  dropped on the way, and that it reconnects by itself when that clears.
- **mtcp: one dial-error line per 10 s** instead of one per link — a dropped
  tunnel redials every link at once, which wrote dozens of identical lines a
  second; the line now counts the ones held back.

### Tests
- `TestMtcpWindowsAreSmallByDefault`; `TestSlowReadersMemory` (end-to-end,
  `BN_SLOWREAD=1`) measures what slow-reading users cost each transport.
- `TestPathGoesDark` (end-to-end): an mtcp tunnel whose path is cut for 40 s
  comes back by itself within a second of the path, and the log says what
  happened.

---

## فارسی — 2.8.11

### رفع‌شده
- **mtcp خیلی کمتر حافظه مصرف می‌کند.** هر لینک mtcp یک session جداگانهٔ smux است، یکی برای هر
  اتصال همزمان کاربر، و هر کدام پنجرهٔ کامل ۱۶/۸ مگابایت می‌گرفت (روی سرورهای بزرگ بیشتر). کاربرانی که
  کندتر از تانل داده را می‌خوانند — اینترنت ضعیف موبایل — این پنجره‌ها را پر می‌کنند: ۶۰ کاربر این‌چنینی
  روی رله ۳۱۰ تا ۳۴۲ مگابایت گرفتند، در حالی که tcp ۵۲ و tcpnomux ۳۵ مگابایت؛ و رلهٔ ۱ تا ۲ گیگابایتی
  با چند صد کاربر حافظه کم می‌آورد و قفل می‌شود. اگر `smux_recv_mb` / `smux_stream_mb` تنظیم نشده
  باشند، پنجره‌های mtcp حالا با RAM تغییر می‌کنند، ۱ مگابایت برای هر stream روی سرور کمتر از ۴ گیگابایت و
  حداکثر ۴ مگابایت: همان ۶۰ کاربر ۴۳ مگابایت می‌گیرند. هر اتصال حدود پنجره ÷ پینگ سرعت دارد
  (۱ مگابایت: حدود ۷۰ مگابیت با پینگ ۱۲۰ میلی‌ثانیه)؛ هر اتصال لینک خودش را دارد. هر دو سرور را
  به‌روز کن: هر طرف با پنجره‌های خودش بافر می‌کند.
- **مسیری که ساکت می‌شود درست گزارش می‌شود.** وقتی در بازهٔ keepalive هیچ چیز از سرور مقابل
  نمی‌رسد (فیلتری که ترافیک را دور می‌ریزد، مسیر قطع)، پیام قطع می‌گفت «session closed locally
  (restart or reconfiguration)»؛ حالا می‌گوید «keepalive timeout — no data from the peer».
  برای ناظر سکوت kcp هم همین‌طور.
- **dial ای که بعد از وصل بودن تانل timeout می‌خورد** دیگر نمی‌گوید پورت را در فایروال باز کن
  (باز بود — تانل از آن استفاده می‌کرد): می‌گوید سرور قبلاً جواب داده و بسته‌ها بین دو سرور در
  مسیر دور ریخته می‌شوند، و خودش وقتی برطرف شد دوباره وصل می‌شود.
- **mtcp: هر ۱۰ ثانیه یک خط خطای dial** به جای یک خط برای هر لینک — تانلی که قطع می‌شود همهٔ
  لینک‌ها را با هم دوباره dial می‌کند و ده‌ها خط یکسان در ثانیه می‌نوشت؛ حالا خط، تعداد خط‌های
  نوشته‌نشده را می‌گوید.

### تست‌ها
- `TestMtcpWindowsAreSmallByDefault`؛ `TestSlowReadersMemory` (end-to-end، با `BN_SLOWREAD=1`)
  هزینهٔ کاربران کندخوان را برای هر ترنسپورت اندازه می‌گیرد.
- `TestPathGoesDark` (end-to-end): تانل mtcp که مسیرش ۴۰ ثانیه قطع می‌شود، کمتر از یک ثانیه بعد
  از برگشتن مسیر خودش برمی‌گردد، و لاگ درست می‌گوید چه شد.

---

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
