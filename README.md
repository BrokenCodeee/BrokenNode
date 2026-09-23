<div align="center">

# BrokenNode

**Multi-protocol reverse tunnel — compiled and ready to run.**

`v2.3.4`  ·  Core in **Go**, manager in **Bash**  ·  [t.me/BrokenNode](https://t.me/BrokenNode)

**[English](#english)**  ·  **[فارسی](#فارسی)**

</div>

---

<a name="english"></a>

# English

This repository holds the **compiled program only**. There is nothing to build:
no Go toolchain, no compiler, no dependencies. Download and run.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrokenCodeee/BrokenNode/main/install.sh)
```

This creates a `BrokenNode` folder, puts the build for your CPU inside it and
opens the manager. Run it as root.

Already have the folder:

```bash
cd BrokenNode
sudo bash BrokenNode.sh
```

Or take the whole folder at once:

```bash
git clone https://github.com/BrokenCodeee/BrokenNode.git
cd BrokenNode
sudo bash BrokenNode.sh
```

## What it runs on

| | |
|---|---|
| **Linux distribution** | Any — Debian, Ubuntu, Alpine, CentOS, Rocky, AlmaLinux, Arch, OpenWrt. The binaries are statically linked, so glibc and musl versions are irrelevant. |
| **Requirements** | A Linux kernel, `bash`, and root. Nothing else. |

| CPU | `uname -m` | File |
|---|---|---|
| x86_64 — virtually every VPS | `x86_64` | `bin/brokennode-linux-amd64` |
| ARM64 — Ampere, Oracle free tier, Pi 4/5 | `aarch64` | `bin/brokennode-linux-arm64` |
| ARM 32-bit — Pi 2/3, most SBCs | `armv7l` | `bin/brokennode-linux-armv7` |
| ARM 32-bit — Pi 1, Pi Zero | `armv6l` | `bin/brokennode-linux-armv6` |
| x86 32-bit — older i686 servers | `i686` | `bin/brokennode-linux-386` |
| RISC-V 64-bit | `riscv64` | `bin/brokennode-linux-riscv64` |

The installer picks the right one automatically and verifies its checksum. To
check by hand:

```bash
cd BrokenNode
sha256sum -c --ignore-missing SHA256SUMS
```

`--ignore-missing` matters: `SHA256SUMS` lists every CPU, while your folder
holds only the one you downloaded.

## How the tunnel is shaped

```
user ──► Iran relay :2052 ──[ tunnel ]──► foreign node ──► 127.0.0.1:2052
         (mode: server)                   (mode: client)     (real service)
```

Note the direction. The machine **in Iran** runs `mode: server` — it listens.
The machine **abroad** runs `mode: client` — it dials in. The tunnel is
*reverse*: the foreign side initiates the connection.

Install on **both** servers. Both ends must agree on the transport, the
encryption layer and the token.

## Transports and encryption

Two independent choices. The transport decides how the bytes travel; the
encryption layer decides what they look like on the way.

**Stream transports** (relay listens, foreign server dials in):
`tcp` · `mtcp` · `mptcp` · `ws` · `tcpnomux` · `kcp` · `quic` · `sctp`

**Point-to-point tunnels** (both servers' real IPs + a private address pair):
`gre` · `gretap` · `ipip` · `sit` · `l2tp` (kernel) · `udp` · `icmp` (TUN) · `spoof`

**Encryption:** `none` · `obfs` (AES-CTR keystream) · `aead`
(ChaCha20-Poly1305, authenticated — recommended)

| Transport | What it is | Needs |
|---|---|---|
| `tcp` | TCP + smux. The stable baseline | — |
| `mtcp` | Several TCP links bonded; survives per-connection throttling | — |
| `mptcp` | *Experimental.* Kernel Multipath TCP: one connection across every path. Prefer `mtcp` | Linux ≥ 5.6, `net.mptcp.enabled=1` on both |
| `ws` | WebSocket, looks like HTTP | — |
| `tcpnomux` | One pooled TCP connection per user | — |
| `kcp` | KCP over UDP with FEC | usable UDP |
| `quic` | QUIC, TLS 1.3 built in. **Collapses to ~1 Mbit/s on a lossy path** — use `kcp` or `mtcp` there | clean UDP, near-zero loss |
| `sctp` | Multi-stream, multihomed across several source IPs | kernel `sctp` module |
| `gre` / `gretap` | Kernel GRE (L3 / L2). Highest throughput | `ip_gre` module, root |
| `ipip` | Kernel IP-in-IP. Lowest overhead, IPv4 only | `ipip` module, root |
| `sit` | Kernel 6in4: IPv6 over IPv4. Tunnel addresses are **IPv6** | `sit` module, root |
| `l2tp` | Kernel L2TPv3 over UDP or IP | `l2tp_eth`/`l2tp_netlink`, root |
| `udp` / `icmp` | TUN over plain UDP / ICMP echo, real source IP by default | root |
| `spoof` | TUN with a forged whitelisted source IP, for a blackout | spoof-friendly datacenters |

The manager asks for them separately: pick a transport, then answer whether it
should be encrypted.

| Situation | Use |
|---|---|
| Maximum bandwidth | `mtcp` + `aead` |
| Gaming, low and stable ping | `kcp` |
| One heavy stream (backup, large file) | `tcpnomux` |
| Deep packet inspection blocking everything | `ws` + `aead`, or `spoof` |

`quic` takes no encryption layer — it already uses TLS 1.3 internally. The
kernel tunnels (`gre`, `gretap`, `ipip`, `sit`, `l2tp`) take none either: the
kernel moves the packets, so encrypt at the service (TLS) if you need it.

A point-to-point tunnel cannot be switched to a stream transport in place (or
back) — they are configured with different fields. Create a new tunnel instead.

`spoof`, `udp` and `icmp` are packet carriers: it seals each datagram on its own
(XChaCha20-Poly1305, random per-packet nonce) and accepts `aead` or `none`, but
not `obfs`. Encrypt it — the transport accepts any packet carrying the expected
forged source IP, which anyone on the path can send, so without a tag there is
nothing to stop arbitrary traffic being injected into your TUN device.

**Old names still work.** `tcpobf`, `mtcpobf`, `wsobf` and `rawmux` are
translated automatically (`tcpobf` becomes `tcp` + `obfs`), so existing tunnels
keep running untouched.

## Tuning for games

The menu's **Health check** now reports **jitter**, not just average ping. That
is the number to watch: a steady 80 ms beats 60 ms that swings by 30. The
server's lag compensation assumes your delay is predictable, and jitter is what
breaks that assumption — it is what a player feels as a shot that hit but did
not register.

`bash BrokenNode.sh tune` offers two profiles, because throughput and latency
want opposite settings:

| Profile | Use it for |
|---|---|
| **Throughput** | Bulk traffic, downloads, backups. Deep buffers keep a long path full. |
| **Gaming** | Shallow buffers, `fq_codel` or `cake`, queue control. |

The gaming profile can also **shape the uplink** slightly below its real rate.
This is the single biggest jitter fix on a loaded line. Without it the
bottleneck is a buffer inside your ISP's equipment that you cannot manage, and
one saturating upload fills it with hundreds of milliseconds of queue. Shaping
moves the bottleneck onto your own machine, where `cake` keeps the queue short
and lets interactive traffic past. Measure your uplink, enter about 90-95% of
it, and give up a few percent of bandwidth to get far more back in latency.

Forwarded UDP sockets are marked DSCP EF and given interactive priority, so a
download through the same relay cannot queue in front of a game.

## Duplicate UDP packets

Every UDP datagram can be sent **twice**, with the far end throwing the copy
away. A packet then has to be lost twice before the game notices.

Turn it on per tunnel: **Manage tunnels → 12) Duplicate UDP packets**, on both
ends.

| | |
|---|---|
| **Fixes** | Loss that hits the two copies independently — a policer dropping one packet in a hundred, a lossy last mile, a flaky wireless hop. |
| **Does not fix** | Loss from a full queue. Both copies are in that same queue, so both are dropped. Shape the uplink instead (`tune` → gaming). |
| **Costs** | Exactly double the bandwidth of that tunnel's UDP. For a game that is a few hundred kbit. For a bulk UDP flow it is not. |

It needs `quic` on both ends, both new enough to negotiate it. Where that is not
true it quietly does nothing rather than sending everything twice with no way to
recognise the copy.

Worth saying plainly: this is insurance against a **lossy** path, not a cure for
a **congested** one.

## Security

- The **token** is the pre-shared key. It authenticates the tunnel and derives
  every encryption key — treat it as a password. Configs are created `0600` and
  the tunnel warns at startup if it finds one readable by other local users.
- Authentication is challenge-response: the relay sends a random challenge and
  the client answers `HMAC-SHA256(token, challenge)`. The two ends also agree on
  which optional features to use, and both feature words are folded into that
  same MAC — so a device on the path cannot flip a bit to strip a capability or
  force a format the peer will not parse. **The token is never transmitted**, so it cannot be lifted off the wire even on an unencrypted
  transport.
- `spoof` keys each direction separately, so a captured packet cannot be
  reflected back at its own sender.

## No artificial limits

No bandwidth cap, no memory cap, no CPU cap, no fixed connection ceiling.
Everything that used to be a fixed number is derived from the machine at
startup: connection links scale to what the OS can back with sockets and ports,
buffer windows scale with RAM, memory is left to the runtime, and the connection
pool grows and shrinks with live load.

The traffic **quota** is opt-in and unlimited by default. It does nothing at all
unless you set one.

## Command line

The manager covers everything, but the core takes commands directly:

```bash
brokennode -c /etc/brokennode/main.json   # run a tunnel from a config
brokennode -gen server                    # print a sample server config
brokennode -gen client                    # print a sample client config
brokennode -transports                    # list transports and encryption layers
brokennode version
```

## Config reference (JSON)

Common: `mode`, `transport`, `encryption`, `token`, `keepalive`, `log_level`

Server: `bind_addr`, `ports` (`"2052"`, `"2052/udp"`, `"2052/both"`,
`"8443=443"`), `quota_total_gb`, `quota_up_gb`, `quota_down_gb`

Client: `remote_addr`, `target_host`

Per-transport: `pool_size`, `pool_min_idle`, `links`, `links_max`,
`links_per_link`, `kcp_mode`, `kcp_data`, `kcp_parity`, `kcp_mtu`, `kcp_sndwnd`,
`kcp_rcvwnd`, `smux_recv_mb`, `smux_stream_mb`, `server_name`, `alpn`,
`sctp_streams`, `sctp_multihoming`

Point-to-point tunnels: `local_ip`, `remote_ip` (the two servers' real IPv4
addresses), `tun_local`, `tun_remote` (the pair on the tunnel — IPv6 for `sit`),
`tun_name`, `mtu`, `tun_ttl`, `gre_key`, `l2tp_tunnel_id`, `l2tp_session_id`,
`l2tp_encap` (`udp`|`ip`), `l2tp_port`; `spoof_src`/`spoof_dst` to forge on
`udp`/`icmp`. The server's `ports` are NATed across the tunnel; the client's
`target_host` is where they land.

Both ends must agree on the transport, the encryption layer and the
transport-level settings.

## Built with

The tunnel core is written in **Go** — one static binary per CPU, no runtime and
no shared libraries. The `BrokenNode.sh` manager is written in **Bash** and uses
only what a stock Linux server already has: `systemd`, `ip`, `iptables`,
`sysctl`.

---

<a name="فارسی"></a>

# فارسی

<div dir="rtl">

این مخزن فقط **برنامهٔ کامپایل‌شده** را دارد. چیزی برای ساختن نیست: نه به Go
نیاز داری، نه به کامپایلر، نه به هیچ وابستگی‌ای. دانلود کن و اجرا کن.

## نصب

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BrokenCodeee/BrokenNode/main/install.sh)
```

<div dir="rtl">

این دستور یک پوشهٔ `BrokenNode` می‌سازد، نسخهٔ مناسب پردازندهٔ سرورت را داخلش
می‌گذارد و منو را باز می‌کند. با کاربر root اجرا کن.

اگر پوشه را از قبل داری:

</div>

```bash
cd BrokenNode
sudo bash BrokenNode.sh
```

<div dir="rtl">

یا کل پوشه را یک‌جا بگیر:

</div>

```bash
git clone https://github.com/BrokenCodeee/BrokenNode.git
cd BrokenNode
sudo bash BrokenNode.sh
```

<div dir="rtl">

## روی چه چیزی اجرا می‌شود

| | |
|---|---|
| **توزیع لینوکس** | هر کدام — Debian، Ubuntu، Alpine، CentOS، Rocky، AlmaLinux، Arch، OpenWrt. باینری‌ها به‌صورت استاتیک لینک شده‌اند، پس نسخهٔ glibc یا musl هیچ اهمیتی ندارد. |
| **پیش‌نیاز** | یک کرنل لینوکس، `bash` و دسترسی root. همین. |

| پردازنده | خروجی `uname -m` | فایل |
|---|---|---|
| x86_64 — تقریباً همهٔ VPSها | `x86_64` | `bin/brokennode-linux-amd64` |
| ARM64 — آمپر، سرور رایگان اوراکل، Pi 4/5 | `aarch64` | `bin/brokennode-linux-arm64` |
| ARM ۳۲ بیتی — Pi 2/3 و بیشتر بردها | `armv7l` | `bin/brokennode-linux-armv7` |
| ARM ۳۲ بیتی — Pi 1 و Pi Zero | `armv6l` | `bin/brokennode-linux-armv6` |
| x86 ۳۲ بیتی — سرورهای قدیمی i686 | `i686` | `bin/brokennode-linux-386` |
| RISC-V ۶۴ بیتی | `riscv64` | `bin/brokennode-linux-riscv64` |

نصب‌کننده خودش نسخهٔ درست را انتخاب و checksum آن را بررسی می‌کند. برای بررسی
دستی:

</div>

```bash
cd BrokenNode
sha256sum -c --ignore-missing SHA256SUMS
```

<div dir="rtl">

گزینهٔ `--ignore-missing` مهم است: فایل `SHA256SUMS` همهٔ پردازنده‌ها را فهرست
می‌کند، ولی پوشهٔ تو فقط همان یکی را دارد که دانلود کرده‌ای.

## شکل تونل

</div>

```
user ──► Iran relay :2052 ──[ tunnel ]──► foreign node ──► 127.0.0.1:2052
         (mode: server)                   (mode: client)     (real service)
```

<div dir="rtl">

به جهت دقت کن. سرور **داخل ایران** با `mode: server` اجرا می‌شود — یعنی گوش
می‌دهد. سرور **خارج** با `mode: client` اجرا می‌شود — یعنی وصل می‌شود. تونل
*معکوس* است: طرف خارجی اتصال را آغاز می‌کند.

روی **هر دو** سرور نصب کن. دو طرف باید روی ترنسپورت، لایهٔ رمزنگاری و توکن
یکسان توافق داشته باشند.

## ترنسپورت‌ها و رمزنگاری

این دو انتخاب **مستقل** از هم هستند. ترنسپورت تعیین می‌کند بایت‌ها چطور منتقل
شوند؛ لایهٔ رمزنگاری تعیین می‌کند در مسیر چه شکلی داشته باشند.

**ترنسپورت‌های جریانی** (سرور ایران گوش می‌دهد، سرور خارج وصل می‌شود):
`tcp` · `mtcp` · `mptcp` · `ws` · `tcpnomux` · `kcp` · `quic` · `sctp`

**تونل‌های نقطه‌به‌نقطه** (IP واقعی هر دو سرور + یک جفت آدرس خصوصی):
`gre` · `gretap` · `ipip` · `sit` · `l2tp` (کرنلی) · `udp` · `icmp` (TUN) · `spoof`

**رمزنگاری:** `none` · `obfs` (کی‌استریم AES-CTR) · `aead`
(ChaCha20-Poly1305 با احراز اصالت — پیشنهادی)

| ترنسپورت | چیست | پیش‌نیاز |
|---|---|---|
| `tcp` | TCP + smux؛ پایهٔ پایدار | — |
| `mtcp` | چند لینک TCP موازی؛ در برابر محدودسازی هر اتصال مقاوم | — |
| `mptcp` | *آزمایشی.* Multipath TCP کرنل: یک اتصال روی همهٔ مسیرها. `mtcp` بهتر است | لینوکس ≥ 5.6 و `net.mptcp.enabled=1` روی هر دو سرور |
| `ws` | وب‌سوکت، شبیه HTTP | — |
| `tcpnomux` | برای هر کاربر یک اتصال TCP از استخر | — |
| `kcp` | KCP روی UDP با FEC | UDP سالم |
| `quic` | QUIC با TLS 1.3 داخلی. **روی مسیر پر از loss به حدود ۱ مگابیت سقوط می‌کند** — آنجا `kcp` یا `mtcp` بزن | UDP تمیز، تقریباً بدون loss |
| `sctp` | چندجریانی، multihome روی چند IP مبدأ | ماژول `sctp` کرنل |
| `gre` / `gretap` | GRE کرنلی (L3 / L2)؛ بیشترین سرعت | ماژول `ip_gre`، روت |
| `ipip` | IP-in-IP کرنلی؛ کمترین سربار، فقط IPv4 | ماژول `ipip`، روت |
| `sit` | 6in4 کرنلی: IPv6 روی IPv4؛ آدرس‌های تونل **IPv6** هستند | ماژول `sit`، روت |
| `l2tp` | L2TPv3 کرنلی روی UDP یا IP | `l2tp_eth`/`l2tp_netlink`، روت |
| `udp` / `icmp` | TUN روی UDP ساده / ICMP echo؛ پیش‌فرض با IP واقعی | روت |
| `spoof` | TUN با IP مبدأ جعلیِ سفید، برای قطعی سراسری | دیتاسنترهای اجازه‌دهنده به جعل |

منو این دو را جدا از هم می‌پرسد: اول ترنسپورت را انتخاب می‌کنی، بعد می‌پرسد
رمزگذاری شود یا نه.

| وضعیت | انتخاب |
|---|---|
| بیشترین پهنای باند | `mtcp` + `aead` |
| بازی، پینگ پایین و پایدار | `kcp` |
| یک جریان سنگین (بکاپ، فایل بزرگ) | `tcpnomux` |
| DPI که همه‌چیز را می‌بندد | `ws` + `aead` یا `spoof` |

ترنسپورت `quic` لایهٔ رمزنگاری نمی‌گیرد — خودش از TLS 1.3 استفاده می‌کند.
تونل‌های کرنلی (`gre`، `gretap`، `ipip`، `sit`، `l2tp`) هم نمی‌گیرند: بسته‌ها را
خود کرنل جابه‌جا می‌کند، پس اگر رمزنگاری لازم است آن را در سرویس (TLS) انجام بده.

تونل نقطه‌به‌نقطه را نمی‌شود درجا به ترنسپورت جریانی تبدیل کرد (و برعکس) —
فیلدهای کانفیگشان فرق دارد. به‌جایش یک تونل جدید بساز.

ترنسپورت‌های `spoof`، `udp` و `icmp` حامل بسته‌اند: هر دیتاگرام را جداگانه مهر و موم می‌کند
(XChaCha20-Poly1305 با nonce تصادفی برای هر بسته) و `aead` یا `none` می‌پذیرد،
ولی `obfs` را نه. حتماً رمزگذاری کن — این ترنسپورت هر بسته‌ای را که IP مبدأ جعلی
مورد انتظار را داشته باشد قبول می‌کند، و هر کسی در مسیر می‌تواند چنین بسته‌ای
بفرستد؛ پس بدون تگ احراز اصالت، هیچ چیزی جلوی تزریق ترافیک دلخواه به دستگاه TUN
تو را نمی‌گیرد.

**نام‌های قدیمی هنوز کار می‌کنند.** `tcpobf`، `mtcpobf`، `wsobf` و `rawmux`
به‌طور خودکار ترجمه می‌شوند (`tcpobf` می‌شود `tcp` + `obfs`)، پس تونل‌های موجود
بدون هیچ تغییری به کار خود ادامه می‌دهند.

## تنظیم برای بازی

</div>

<div dir="rtl">

بخش **Health check** در منو حالا **جیتر** را هم گزارش می‌کند، نه فقط میانگین
پینگ. عددی که باید نگاه کنی همین است: ۸۰ میلی‌ثانیهٔ ثابت بهتر از ۶۰ است که
۳۰ نوسان دارد. lag compensation سرور فرض می‌کند تأخیر تو قابل پیش‌بینی است، و
جیتر همان چیزی است که این فرض را می‌شکند — همان که بازیکن به‌صورت «گلوله خورد
ولی ثبت نشد» حس می‌کند.

دستور `bash BrokenNode.sh tune` دو پروفایل می‌دهد، چون throughput و تأخیر
تنظیمات متضاد می‌خواهند:

| پروفایل | برای چه |
|---|---|
| **Throughput** | ترافیک حجیم، دانلود، بکاپ. بافر عمیق مسیر طولانی را پر نگه می‌دارد. |
| **Gaming** | بافر کم‌عمق، `fq_codel` یا `cake`، کنترل صف. |

پروفایل گیمینگ می‌تواند **پهنای باند خروجی را کمی زیر نرخ واقعی محدود کند**.
این بزرگ‌ترین اصلاح جیتر روی یک خط پرمصرف است. بدون آن، گلوگاه یک بافر داخل
تجهیزات ISP است که تو کنترلی رویش نداری، و یک آپلود سنگین آن را با صدها
میلی‌ثانیه صف پر می‌کند. محدود کردن، گلوگاه را می‌آورد روی ماشین خودت، جایی که
`cake` صف را کوتاه نگه می‌دارد و ترافیک تعاملی را رد می‌کند. پهنای باند آپلودت
را اندازه بگیر، حدود ۹۰ تا ۹۵ درصدش را وارد کن، و چند درصد پهنای باند بده تا
خیلی بیشتر از آن را در تأخیر پس بگیری.

سوکت‌های UDP فورواردشده با DSCP EF و اولویت تعاملی علامت می‌خورند، پس یک دانلود
از همان رله نمی‌تواند جلوی بازی در صف بایستد.

## ارسال دوتایی بسته‌های UDP

</div>

<div dir="rtl">

هر دیتاگرام UDP می‌تواند **دو بار** فرستاده شود و طرف مقابل نسخهٔ تکراری را دور
بیندازد. آن‌وقت یک بسته باید **دو بار** گم شود تا بازی متوجهش شود.

برای هر تونل جداگانه روشن می‌شود: **Manage tunnels ← 12) Duplicate UDP packets**،
روی هر دو سر.

| | |
|---|---|
| **چه چیزی را حل می‌کند** | لاستی که روی دو نسخه مستقل از هم می‌افتد — پالیسری که یک بسته از هر صد را می‌اندازد، آخرین مایل پرخطا، یا یک پرش وایرلس ناپایدار. |
| **چه چیزی را حل نمی‌کند** | لاست ناشی از صف پر. هر دو نسخه در همان صف هستند، پس هر دو دور ریخته می‌شوند. برای آن، پهنای باند خروجی را محدود کن (`tune` ← گیمینگ). |
| **هزینه** | دقیقاً دو برابر پهنای باند UDP همان تونل. برای بازی چند صد کیلوبیت است. برای یک جریان حجیم UDP نه. |

به `quic` روی هر دو سر نیاز دارد، و هر دو باید به‌قدر کافی جدید باشند که سرِ آن
توافق کنند. جایی که این‌طور نباشد، بی‌صدا کاری نمی‌کند — به‌جای اینکه همه‌چیز را
دوبار بفرستد بدون اینکه راهی برای تشخیص نسخهٔ تکراری باشد.

صریح بگویم: این بیمه در برابر مسیر **پرخطا** است، نه درمان مسیر **شلوغ**.

## امنیت

- **توکن** همان کلید از پیش اشتراکی است. تونل را احراز هویت می‌کند و همهٔ
  کلیدهای رمزنگاری از آن مشتق می‌شوند — مثل رمز عبور با آن رفتار کن. کانفیگ‌ها با
  دسترسی `0600` ساخته می‌شوند و اگر تونل موقع شروع کانفیگی پیدا کند که کاربران
  دیگر سیستم بتوانند بخوانند، هشدار می‌دهد.
- احراز هویت به‌صورت چالش-پاسخ است: رله یک چالش تصادفی می‌فرستد و کلاینت با
  `HMAC-SHA256(token, challenge)` جواب می‌دهد. دو طرف هم‌زمان توافق می‌کنند کدام
  قابلیت‌های اختیاری فعال باشد، و هر دو کلمهٔ قابلیت داخل همان MAC بسته می‌شوند —
  پس کسی در مسیر نمی‌تواند بیتی را برگرداند تا قابلیتی را حذف کند یا قالبی را
  تحمیل کند که طرف مقابل نمی‌فهمد. **توکن هرگز ارسال نمی‌شود**، پس
  حتی روی یک ترنسپورت بدون رمزنگاری هم نمی‌توان آن را از روی شبکه برداشت.
- در `spoof` هر جهت کلید جداگانه دارد، بنابراین یک بستهٔ ضبط‌شده را نمی‌توان به
  خود فرستنده‌اش بازتاب داد.

## بدون هیچ محدودیت مصنوعی

نه سقف پهنای باند، نه سقف حافظه، نه سقف CPU، نه محدودیت ثابت تعداد اتصال. هر
چیزی که قبلاً یک عدد ثابت بود، حالا هنگام اجرا از خود سخت‌افزار محاسبه می‌شود:
تعداد لینک‌ها تا جایی بالا می‌رود که سیستم‌عامل بتواند سوکت و پورت تأمین کند،
پنجره‌های بافر با مقدار RAM مقیاس می‌گیرند، مدیریت حافظه کاملاً به عهدهٔ ران‌تایم
است، و استخر اتصال‌ها با بار زندهٔ سیستم بزرگ و کوچک می‌شود.

**سهمیهٔ ترافیک** اختیاری است و به‌صورت پیش‌فرض نامحدود. تا وقتی خودت مقداری
تنظیم نکنی، هیچ کاری انجام نمی‌دهد.

## خط فرمان

منو همهٔ کارها را پوشش می‌دهد، ولی هستهٔ برنامه دستورها را مستقیم هم می‌پذیرد:

</div>

```bash
brokennode -c /etc/brokennode/main.json   # اجرای تونل از روی کانفیگ
brokennode -gen server                    # چاپ یک کانفیگ نمونهٔ سرور
brokennode -gen client                    # چاپ یک کانفیگ نمونهٔ کلاینت
brokennode -transports                    # فهرست ترنسپورت‌ها و لایه‌های رمزنگاری
brokennode version
```

<div dir="rtl">

## مرجع کانفیگ (JSON)

مشترک: `mode`، `transport`، `encryption`، `token`، `keepalive`، `log_level`

سرور: `bind_addr`، `ports` (به شکل `"2052"`، `"2052/udp"`، `"2052/both"`،
`"8443=443"`)، `quota_total_gb`، `quota_up_gb`، `quota_down_gb`

کلاینت: `remote_addr`، `target_host`

مخصوص هر ترنسپورت: `pool_size`، `pool_min_idle`، `links`، `links_max`،
`links_per_link`، `kcp_mode`، `kcp_data`، `kcp_parity`، `kcp_mtu`،
`kcp_sndwnd`، `kcp_rcvwnd`، `smux_recv_mb`، `smux_stream_mb`، `server_name`،
`alpn`، `sctp_streams`، `sctp_multihoming`

تونل‌های نقطه‌به‌نقطه: `local_ip`، `remote_ip` (IPv4 واقعی دو سرور)،
`tun_local`، `tun_remote` (جفت آدرس روی تونل — برای `sit` از نوع IPv6)،
`tun_name`، `mtu`، `tun_ttl`، `gre_key`، `l2tp_tunnel_id`، `l2tp_session_id`،
`l2tp_encap` (`udp`|`ip`)، `l2tp_port`؛ و `spoof_src`/`spoof_dst` برای جعل روی
`udp`/`icmp`. پورت‌های `ports` سرور از روی تونل NAT می‌شوند و `target_host`
کلاینت مقصد نهایی آن‌هاست.

دو طرف تونل باید روی ترنسپورت، لایهٔ رمزنگاری و تنظیمات سطح ترنسپورت توافق
داشته باشند.

## با چه چیزی نوشته شده

هستهٔ تونل با **Go** نوشته شده — برای هر پردازنده یک باینری استاتیک، بدون
ران‌تایم و بدون کتابخانهٔ اشتراکی. منوی `BrokenNode.sh` با **Bash** نوشته شده و
فقط از چیزهایی استفاده می‌کند که روی هر سرور لینوکس معمولی از قبل هست:
`systemd`، `ip`، `iptables` و `sysctl`.

</div>

---

<div align="center">
<sub>Questions and updates · پرسش و به‌روزرسانی: <a href="https://t.me/BrokenNode">t.me/BrokenNode</a></sub>
</div>
