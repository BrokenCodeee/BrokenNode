<div align="center">

# BrokenNode

**Multi-protocol tunnel, reverse or direct — compiled and ready to run.**

`v`  ·  Core in **Go**, manager in **Bash**  ·  [t.me/BrokenNode](https://t.me/BrokenNode)

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

**After the first run, open the menu from anywhere** — no `cd` needed:

```bash
BrokenNode
```

`brokennode` works too, in any mix of upper and lower case (`BROKENNODE`,
`Brokennode`...). The first run of the menu sets this up; a new SSH session
picks up the other spellings.

Or from the folder, as before:

```bash
cd BrokenNode
sudo bash BrokenNode.sh
```

**Updating:** menu option **5) Update BrokenNode**, or run the install command
again from inside the folder (`cd BrokenNode` first) — both update that folder
in place, and the menu then applies the new core and restarts the tunnels. The
menu never puts an older core over a newer one; an old folder only says so.

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

The machine **in Iran** runs `mode: server` (the relay: users connect to its
ports). The machine **abroad** runs `mode: client` (it delivers to the real
service). Which of the two opens the tunnel is a separate choice, the
**direction**:

| `direction` | Who connects to whom | Iran server | Foreign server |
|---|---|---|---|
| `reverse` (default) | foreign ➜ Iran | `bind_addr` (listens) | `remote_addr` = Iran IP:port |
| `direct` | Iran ➜ foreign | `remote_addr` = foreign IP:port | `bind_addr` (listens) |

Choose `direct` when connections **into** the Iran server are being blocked or
cut: the Iran server then only makes outgoing connections. Users, ports,
encryption and speed are the same either way. Both servers must use the same
direction. The manager asks for it when you create a tunnel, and
**Manage → Change direction** switches an existing one.

The same question has a third answer, **3) proxy**: instead of port forwards,
the Iran server runs a SOCKS5 + HTTP proxy (port, username and password are
asked) and users set it in their app or browser; every site they open goes out
from the foreign server. The manager then asks which server connects (reverse
or direct). On the foreign server pick 3) proxy too, with the same direction.
Not with `tcpnomux`. **Manage → 13) Change direction** offers the same three
choices later: switch to or from proxy, or pick 3 again to change the proxy's
port and login.

Direction applies to the stream transports (`tcp` `mtcp` `mptcp` `ws`
`tcpnomux` `kcp` `sctp`). The point-to-point tunnels (`gre`, `udp`,
`icmp`, ...) send from both ends at once and have no direction.

Install on **both** servers. Both ends must agree on the transport, the
encryption layer and the token.

### Every setting is asked, and can be changed later

Creating a tunnel asks for everything it can use, on the end it belongs to:
the encryption layer (`aead`, `obfs`, `tls`, `reality`, `none`), the tls
certificate, the site `reality` borrows, the browser fingerprint and the split
ClientHello (on the end that connects), padding, and — when *Connection
direction* is 3) proxy — the Iran server's SOCKS5/HTTP proxy with a login. Afterwards, under *Manage tunnels → a
tunnel*:

| Item | Changes |
|---|---|
| 9) Change transport | the transport and the encryption layer |
| 10) Change peer IP | the other server's IP (stream and point-to-point tunnels) |
| 11) Tune settings | keepalive, kcp, links, pool, ws path and headers, smux windows, addresses, quota, MTU, gre key, l2tp ids, carrier port, `target_host`, log level |
| 13) Change direction | reverse, direct or proxy (the SOCKS5/HTTP proxy on the Iran server: on/off, port, login) |
| 14) Encryption & stealth | encryption layer, token, tls name and ALPN, `reality_dest`, fingerprint, `tls_fragment`, `pad` |
| 17) Port-forwards | add, remove or replace the forwarded ports |

Every change is checked by the core before it replaces the config; a change it
refuses leaves the tunnel as it was. Settings marked "same on both ends" must be
changed on the other server too.

**Which transport under load?** On a path that loses packets, every user sharing
one TCP link waits behind each loss (head-of-line blocking). `mtcp` therefore
opens one link per concurrent user by default (measured with 40 users, 80 ms,
0.3 % loss: ping 135 ms instead of 320–410 ms — as good as no tunnel), and
`tcpnomux` does the same by design. `tcp` and `ws` use a single link.

## Transports and encryption

Two independent choices. The transport decides how the bytes travel; the
encryption layer decides what they look like on the way.

**Stream transports** (reverse or direct, see above):
`tcp` · `mtcp` · `mptcp` · `ws` · `tcpnomux` · `kcp` · `sctp`

**Point-to-point tunnels** (both servers' real IPs + a private address pair):
`gre` · `gretap` · `ipip` · `sit` · `l2tp` (kernel) · `udp` · `icmp` (TUN)

**Encryption:** `none` · `obfs` (AES-CTR keystream) · `aead`
(ChaCha20-Poly1305, authenticated — recommended) · `tls` (real HTTPS with a
certificate: self-signed, from files or Let's Encrypt) · `reality` (borrows a
real site's HTTPS, no domain or certificate; a prober is passed through to that
site). On top of any of them: `pad` (hides packet sizes and timing, both ends)
and, on the end that connects, `tls_fingerprint` and `tls_fragment`.

| Transport | What it is | Needs |
|---|---|---|
| `tcp` | TCP + smux. The stable baseline | — |
| `mtcp` | Several TCP links bonded; survives per-connection throttling | — |
| `mptcp` | *Experimental.* Kernel Multipath TCP: one connection across every path. Prefer `mtcp` | Linux ≥ 5.6, `net.mptcp.enabled=1` on both |
| `ws` | WebSocket, looks like HTTP | — |
| `tcpnomux` | One pooled TCP connection per user | — |
| `kcp` | KCP over UDP with FEC; 4 parallel sessions by default (`links`) | usable UDP |
| `sctp` | Multi-stream, multihomed across several source IPs | kernel `sctp` module |
| `gre` / `gretap` | Kernel GRE (L3 / L2). Highest throughput | `ip_gre` module, root |
| `ipip` | Kernel IP-in-IP. Lowest overhead, IPv4 only | `ipip` module, root |
| `sit` | Kernel 6in4: IPv6 over IPv4. Tunnel addresses are **IPv6** | `sit` module, root |
| `l2tp` | Kernel L2TPv3 over UDP or IP | `l2tp_eth`/`l2tp_netlink`, root |
| `udp` / `icmp` | TUN over plain UDP / ICMP echo between the two servers' real IPs | root; an `icmp` server stops answering normal pings while it runs |

The manager asks for them separately: pick a transport, then answer whether it
should be encrypted.

| Situation | Use |
|---|---|
| Maximum bandwidth | `udp`/`icmp` (if UDP or ping passes), else `mtcp` + `aead` |
| Gaming, low and stable ping | `kcp` with `kcp_mode` gaming, or `udp` |
| One heavy stream (backup, large file) | `tcpnomux` |
| Deep packet inspection blocking everything | `ws` + `aead` |

Measured in 2.3.9 on an emulated Iran-like path (80 ms, 0.3% loss, 500 Mbit/s)
with 300 users at once, 10 of them downloading and 5 uploading without pause:

| | ↓ Mbit/s | ↑ Mbit/s | ping, median | ping, 95% |
|---|---|---|---|---|
| no tunnel at all | 460 | 425 | 144 ms | 489 ms |
| `udp`, `icmp` | 453 | 402 | 145 ms | 490 ms |
| `mtcp` | 449 | 446 | 102 ms | 293 ms |
| `tcpnomux` | 458 | 399 | 142 ms | 495 ms |
| `kcp` (4 links) | 160 | 256 | 369 ms | 690 ms |
| `tcp`, `ws` (one link) | 140 | 136 | 240 ms | 340 ms |

Your path is not this one: run the **speed test** (below) on each candidate
and keep the one that does best on yours.

**`quic` was removed in 2.3.22.** It slowed to a few Mbit/s on lossy paths,
where `kcp` and `mtcp` carry hundreds. A tunnel still set to `quic` will not
start: switch it to `kcp` (UDP) or `mtcp` (TCP) on both servers with
**Manage tunnels → Change transport**. The manager lists such tunnels when it
opens. *Duplicate UDP packets*, which only `quic` could carry, went with it.

The kernel tunnels (`gre`, `gretap`, `ipip`, `sit`, `l2tp`) take no encryption
layer: the kernel moves the packets, so encrypt at the service (TLS) if you need it.

A point-to-point tunnel cannot be switched to a stream transport in place (or
back) — they are configured with different fields. Create a new tunnel instead.

On `udp` and `icmp` the foreign server delivers to `target_host` like the
kernel tunnels do (since 2.8.6). Before, a service had to listen on `0.0.0.0`
or on the tunnel address: one bound to `127.0.0.1` got nothing while the tunnel
showed connected.

`udp` and `icmp` are packet carriers: each datagram is sealed on its own
(XChaCha20-Poly1305, random per-packet nonce), so they accept `aead` or `none`,
but not `obfs`. Encrypt them — the carrier accepts any packet carrying the
peer's source IP, which anyone on the path can fake, so without a tag there is
nothing to stop arbitrary traffic being injected into your TUN device.
With `aead`, both servers need 2.3.12 or newer (its keys changed in 2.3.12);
unencrypted `udp`/`icmp` still work with older releases.

**Update both servers together.** Since 2.3.20 a stream tunnel with
encryption `none` connects only when the other server proves it
holds the token too, which needs 2.3.14 or newer on both ends. Against an older
server the log says so and the tunnel stays down. The same proof is required
over `tls`, and since 2.8.10 over `reality` (its client accepts any
certificate); every release that has reality already sends it.

**Old names still work.** `tcpobf`, `mtcpobf`, `wsobf` and `rawmux` are
translated automatically (`tcpobf` becomes `tcp` + `obfs`), so existing tunnels
keep running untouched.

## Share codes: one paste sets up the other server

Every tunnel has two ends, and setting up the second one meant typing again
what the first one was given. Now the first server gives you **one line**;
paste it into the other server's terminal and its end is set up and started:
transport, encryption, token, direction, tunnel addresses, keys and ports,
mirrored for that side.

- After you create a tunnel the line is printed for you. Later: **Manage
  tunnels → the tunnel → 19) Share code**, or **6) Share codes → 1**.
- It works from either end: made on the Iran server, it sets up the foreign
  one, and the other way round (the Iran server then asks only for the user
  ports, which the foreign server does not know).
- On a server that does not have BrokenNode yet the same line installs it
  first.
- Pasted on a server that already has that tunnel, it **updates it in place**
  — handy after you change the transport or the encryption on one end.

**Moving to a new server when one gets filtered:** **6) Share codes → 2)
Backup code** gives one line with **every** tunnel on the server. Copy it
while you can still reach the server and keep it somewhere safe. On the new
server paste it: all the tunnels come back as they were, and it prints a line
for each other server that has to learn the new IP — paste each one there.

You can also paste a code into the menu: **6) Share codes → 3) Paste a code**
(useful when a terminal breaks a long line up). A code contains the tunnels'
secret tokens: share it only with yourself.

## Several tunnels between the same two servers

Different types run side by side between the same pair of servers — `gre`,
`gretap`, `ipip`, `sit`, `l2tp`, `udp`, `icmp` and the stream transports — each
with its own tunnel subnet and its own user ports (the manager picks free ones
on the Iran server). Two of the **same** type:

| Type | A second one to the same server | What keeps them apart |
|---|---|---|
| `gre`, `gretap` | yes | a different `gre_key` each (the manager offers one) |
| `ipip`, `sit` | **no** — the kernel allows one per pair of IPs | — |
| `l2tp` | yes | its own tunnel/session id, and over udp its own `l2tp_port` |
| `udp`, `icmp` | yes | its own `carrier_port` (for icmp: the echo identifier) |
| stream transports | yes | its own port |

Use the same values on both servers; the Iran server's manager prints them.

## Speed test and live stats

**Speed test** (Manage tunnels → a tunnel → 15) measures ping, jitter,
download and upload *through the tunnel*, with its own transport and
encryption, so the numbers are what your users get. It first pings the other
server outside the tunnel, so you see what the tunnel adds, and it keeps every
result: the table at the end lists the last runs of all tunnels side by side,
which is how you compare transports on your own path. Stream transports run it
on the Iran server; `gre`, `ipip`, `l2tp`, `udp` and `icmp` on either.
Both servers need 2.3.9 or newer.

**Live stats** (→ 8) shows the speed right now, the peak, a 40-second
history, the links that are up and the users connected, on both servers and for
every transport. It updates in place once a second; any key goes back.

**Tunnel connected and speed test fine, but users get nothing?** The speed
test does not pass through your forwarded ports, so it cannot see this. Run
**Diagnose** (Manage tunnels → a tunnel → 18) on the Iran server. It checks
every port the whole way — served on this server, not taken by a NAT rule,
open in the firewall (ufw/iptables), and reachable by the foreign server at
`target_host` — and prints the command that fixes each problem. The tunnel
list also shows in red a port that is not being served (another program holds
it); the tunnel keeps retrying such a port and serves it as soon as it is free.

A common cause is an old NAT rule, left by a deleted `gre`/`ipip`/`l2tp`
tunnel, that sends the port somewhere else before the tunnel ever sees it.
Since 2.8.6 every start removes such leftovers and deleting a tunnel sweeps
them; `brokennode cleanup` does it by hand. A rule another program added is not
removed: Diagnose and the tunnel's log name it, with the command that removes
it. For the exact answer about the foreign side, both servers need 2.8.6.

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

**Games next to busy users (2.3.10).** On the stream transports a game's UDP
packets used to wait behind everyone else's downloads inside the tunnel;
with 100 people browsing over one tcp link, games lost 72% of their packets
and the rest arrived 11-20 seconds late. Each UDP session now has its own
queue that is sent in one piece whenever its turn comes, and a packet that is
already half a second late is dropped instead of delivered: measured with the
same load, loss under 1% and ping 250 ms on tcp, 140 ms on mtcp, 97 ms on
udp (80 ms path).

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
- `udp` and `icmp` key each direction separately, so a captured packet cannot be
  reflected back at its own sender.

## No artificial limits

No bandwidth cap, no memory cap, no CPU cap, no fixed connection ceiling.
Everything that used to be a fixed number is derived from the machine at
startup: connection links scale to what the OS can back with sockets and ports,
buffer windows scale with RAM, memory is left to the runtime, and the connection
pool grows and shrinks with live load.

The traffic **quota** is opt-in and unlimited by default. It does nothing at all
unless you set one.

Tested in 2.3.9: 18,000 users at once on one tunnel, 80 of them moving data
flat out (about 6 Gbit/s down and 5 Gbit/s up on a 4-core machine), for 5
minutes without a single dropped user and with steady latency; memory settled
near 1 GB and fell back when the users left. What decides how many users one
server holds is its RAM (about 30 KB per idle user, more while they move data)
and its file limit, which the service raises. On the foreign server, when every
source port toward a local service (`127.0.0.1:port`) is taken — about 64,000
users — new users are dialed from another `127.x` address instead of failing.

## Command line

The manager covers everything, but the core takes commands directly:

```bash
brokennode -c /etc/brokennode/main.json   # run a tunnel from a config
brokennode -gen server                    # print a sample server config
brokennode -gen client                    # print a sample client config
brokennode -transports                    # list transports and encryption layers
brokennode speedtest -c /etc/brokennode/main.json [-t 10] [-p 4]
brokennode doctor -c /etc/brokennode/main.json   # why does a tunnel carry no users?
brokennode cleanup                        # remove NAT rules left by deleted tunnels
brokennode version
BrokenNode share <tunnel>                 # the share code of a tunnel (its other end)
BrokenNode backup                         # one code with every tunnel on this server
BrokenNode import <code>                  # set up / restore from a share or backup code
```

## Config reference (JSON)

Common: `mode`, `transport`, `encryption`, `token`, `keepalive`, `log_level`

Server: `ports` (`"2052"`, `"2052/udp"`, `"2052/both"`,
`"8443=443"`), `quota_total_gb`, `quota_up_gb`, `quota_down_gb`; `socks`
(a SOCKS5 + HTTP CONNECT proxy on this address, e.g. `"127.0.0.1:1080"`),
`socks_user` + `socks_pass` (both, to require a login), `socks_open` (allow a
proxy with no login on a public address)

Client: `target_host`

Stream transports: `direction` (`reverse` default, or `direct`); the end that
listens sets `bind_addr`, the end that connects sets `remote_addr` — the relay
listens in reverse mode, the foreign server in direct mode.

Per-transport: `pool_size`, `pool_min_idle`, `links` (mtcp; for kcp the
number of parallel sessions, default 4, 1 in gaming mode), `links_max`,
`links_per_link`, `kcp_mode`, `kcp_data`, `kcp_parity`, `kcp_mtu`, `kcp_sndwnd`,
`kcp_rcvwnd`, `smux_recv_mb`, `smux_stream_mb`, `smux_frame_kb`, `server_name`, `alpn`,
`sctp_streams`, `sctp_multihoming`, `ws_path`, `ws_host`, `ws_user_agent`

The smux windows are what each link may buffer for users who read slower than
the tunnel delivers. One session carries every user on `tcp`, `ws` and `kcp`
(16 MB or more by default); `mtcp` has a session per link, so its default
scales with RAM — 1 MB per stream on a server of less than 4 GB, up to 4 MB — and
a stream carries about window ÷ ping (1 MB: ~70 Mbit/s at 120 ms).

Encryption extras: `tls_selfsigned`, `tls_cert` + `tls_key`, `tls_auto_email`,
`tls_insecure`, `tls_fingerprint` (`chrome` `firefox` `safari` `edge` `ios`
`random`), `tls_fragment`, `reality_dest` (`host:443`, same on both ends),
`reality_server_name`, `pad` (same on both ends)

Point-to-point tunnels: `local_ip`, `remote_ip` (the two servers' real IPv4
addresses), `tun_local`, `tun_remote` (the pair on the tunnel — IPv6 for `sit`),
`tun_name`, `mtu`, `tun_ttl`, `gre_key`, `l2tp_tunnel_id`, `l2tp_session_id`,
`l2tp_encap` (`udp`|`ip`), `l2tp_port`, `carrier_port` (`udp`/`icmp`). The server's `ports` are NATed across the tunnel; the client's
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

**به‌روزرسانی:** گزینهٔ **5) Update BrokenNode** در منو، یا اجرای دوبارهٔ دستور نصب
از **داخل** همان پوشه (اول `cd BrokenNode`) — هر دو همان پوشه را به‌روز می‌کنند و
منو هستهٔ جدید را اعمال و تانل‌ها را ری‌استارت می‌کند. منو هیچ‌وقت هستهٔ قدیمی‌تر
را روی جدیدتر نمی‌گذارد؛ پوشهٔ قدیمی فقط هشدار می‌دهد.

**بعد از اولین اجرا، منو را از هر جایی باز کن** (بدون `cd`):

</div>

```bash
BrokenNode
```

<div dir="rtl">

`brokennode` هم کار می‌کند، و بزرگ یا کوچک بودن حروف فرقی ندارد (`BROKENNODE`، `Brokennode` و...). این میانبر در اولین اجرای منو ساخته می‌شود. برای حالت‌های دیگر حروف، یک بار SSH را از نو باز کن.

یا مثل قبل از داخل پوشه:

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

سرور **داخل ایران** با `mode: server` اجرا می‌شود (کاربران به پورت‌های آن وصل
می‌شوند). سرور **خارج** با `mode: client` اجرا می‌شود (ترافیک را به سرویس اصلی
می‌رساند). این‌که کدام طرف تونل را باز کند انتخاب جداگانه‌ای است به نام
**جهت** (`direction`):

| `direction` | چه کسی به چه کسی وصل می‌شود | سرور ایران | سرور خارج |
|---|---|---|---|
| `reverse` (پیش‌فرض، ریورس) | خارج ⬅ به ایران | `bind_addr` (گوش می‌دهد) | `remote_addr` = آی‌پی:پورت ایران |
| `direct` (دایرکت) | ایران ⬅ به خارج | `remote_addr` = آی‌پی:پورت خارج | `bind_addr` (گوش می‌دهد) |

وقتی اتصال‌های **ورودی** به سرور ایران بسته یا قطع می‌شوند `direct` را انتخاب
کن: در این حالت سرور ایران فقط اتصال خروجی می‌سازد. کاربران، پورت‌ها،
رمزنگاری و سرعت در هر دو حالت یکسان است. هر دو سرور باید جهت یکسان داشته
باشند. منیجر هنگام ساخت تانل این را می‌پرسد و با
**Manage → Change direction** می‌توان جهت یک تانل موجود را عوض کرد.

همین سؤال گزینهٔ سومی هم دارد، **3) proxy**: به جای فوروارد پورت، سرور ایران یک
پروکسی SOCKS5 و HTTP اجرا می‌کند (پورت، نام کاربری و رمز پرسیده می‌شود) و کاربر آن را
در برنامه یا مرورگرش تنظیم می‌کند؛ هر سایتی که باز کند از سرور خارج باز می‌شود. بعد
منیجر می‌پرسد کدام سرور وصل شود (ریورس یا دایرکت). روی سرور خارج هم 3) proxy را با
همان جهت انتخاب کن. با `tcpnomux` نمی‌شود. بعداً **Manage → 13) Change direction** همین سه گزینه را دارد:
رفتن به حالت پروکسی یا برگشتن از آن، یا انتخاب دوبارهٔ ۳ برای تغییر پورت و رمز پروکسی.

جهت فقط برای ترنسپورت‌های جریانی است (`tcp` `mtcp` `mptcp` `ws` `tcpnomux`
`kcp` `sctp`). تونل‌های نقطه‌به‌نقطه (`gre`، `udp`، `icmp` و ...) از هر
دو طرف هم‌زمان ارسال می‌کنند و جهت ندارند.

روی **هر دو** سرور نصب کن. دو طرف باید روی ترنسپورت، لایهٔ رمزنگاری و توکن
یکسان توافق داشته باشند.

### همهٔ تنظیمات پرسیده می‌شوند و بعداً قابل تغییرند

ساخت تانل هر تنظیمی را که به کار می‌آید، روی همان طرفی که لازم است می‌پرسد: لایهٔ
رمزنگاری (`aead`، `obfs`، `tls`، `reality`، `none`)، گواهی tls، سایتی که `reality`
از آن استفاده می‌کند، اثرانگشت مرورگر و تکه‌تکه کردن ClientHello (روی طرفی که وصل
می‌شود)، padding، و وقتی *Connection direction* روی 3) proxy باشد، پروکسی SOCKS5/HTTP
سرور ایران با نام کاربری و رمز.
بعداً در *Manage tunnels ← یک تانل*:

| گزینه | چه چیزی را عوض می‌کند |
|---|---|
| 9) Change transport | ترنسپورت و لایهٔ رمزنگاری |
| 10) Change peer IP | IP سرور مقابل (تانل‌های استریم و نقطه‌به‌نقطه) |
| 11) Tune settings | keepalive، kcp، links، pool، مسیر و هدرهای ws، پنجره‌های smux، آدرس‌ها، سهمیه، MTU، کلید gre، شناسه‌های l2tp، پورت حامل، `target_host`، سطح لاگ |
| 13) Change direction | ریورس، دایرکت یا پروکسی (پروکسی SOCKS5/HTTP سرور ایران: روشن/خاموش، پورت، رمز) |
| 14) Encryption & stealth | لایهٔ رمزنگاری، توکن، نام و ALPN در tls، `reality_dest`، اثرانگشت، `tls_fragment`، `pad` |
| 17) Port-forwards | افزودن، حذف یا جایگزینی پورت‌ها |

هر تغییر قبل از جایگزین شدن توسط هسته چک می‌شود؛ تغییری که رد شود تانل را دست‌نخورده
می‌گذارد. تنظیماتی که «در هر دو طرف یکسان» هستند را روی سرور دیگر هم عوض کن.

**زیر بار کدام ترنسپورت؟** در مسیری که بسته گم می‌کند، هر کاربری که روی یک لینک TCP
مشترک است پشت هر بستهٔ گم‌شده منتظر می‌ماند. برای همین `mtcp` حالا به‌طور پیش‌فرض
برای هر کاربر هم‌زمان یک لینک باز می‌کند (با ۴۰ کاربر، ۸۰ms و ۰٫۳٪ گم‌شدن: پینگ
۱۳۵ms به‌جای ۳۲۰ تا ۴۱۰ms — هم‌اندازهٔ حالت بدون تانل) و `tcpnomux` هم ذاتاً همین‌طور
است. `tcp` و `ws` یک لینک دارند.

## ترنسپورت‌ها و رمزنگاری

این دو انتخاب **مستقل** از هم هستند. ترنسپورت تعیین می‌کند بایت‌ها چطور منتقل
شوند؛ لایهٔ رمزنگاری تعیین می‌کند در مسیر چه شکلی داشته باشند.

**ترنسپورت‌های جریانی** (ریورس یا دایرکت، بالا را ببین):
`tcp` · `mtcp` · `mptcp` · `ws` · `tcpnomux` · `kcp` · `sctp`

**تونل‌های نقطه‌به‌نقطه** (IP واقعی هر دو سرور + یک جفت آدرس خصوصی):
`gre` · `gretap` · `ipip` · `sit` · `l2tp` (کرنلی) · `udp` · `icmp` (TUN)

**رمزنگاری:** `none` · `obfs` (کی‌استریم AES-CTR) · `aead`
(ChaCha20-Poly1305 با احراز اصالت — پیشنهادی) · `tls` (HTTPS واقعی با گواهی:
self-signed، فایل یا Let's Encrypt) · `reality` (HTTPS یک سایت واقعی را قرض می‌گیرد،
بدون دامنه و گواهی؛ کسی که پورت را بررسی کند به همان سایت فرستاده می‌شود). روی هر
کدام: `pad` (اندازه و زمان‌بندی بسته‌ها را پنهان می‌کند، هر دو طرف) و روی طرفی که وصل
می‌شود `tls_fingerprint` و `tls_fragment`.

| ترنسپورت | چیست | پیش‌نیاز |
|---|---|---|
| `tcp` | TCP + smux؛ پایهٔ پایدار | — |
| `mtcp` | چند لینک TCP موازی؛ در برابر محدودسازی هر اتصال مقاوم | — |
| `mptcp` | *آزمایشی.* Multipath TCP کرنل: یک اتصال روی همهٔ مسیرها. `mtcp` بهتر است | لینوکس ≥ 5.6 و `net.mptcp.enabled=1` روی هر دو سرور |
| `ws` | وب‌سوکت، شبیه HTTP | — |
| `tcpnomux` | برای هر کاربر یک اتصال TCP از استخر | — |
| `kcp` | KCP روی UDP با FEC؛ به‌طور پیش‌فرض ۴ نشست موازی (`links`) | UDP سالم |
| `sctp` | چندجریانی، multihome روی چند IP مبدأ | ماژول `sctp` کرنل |
| `gre` / `gretap` | GRE کرنلی (L3 / L2)؛ بیشترین سرعت | ماژول `ip_gre`، روت |
| `ipip` | IP-in-IP کرنلی؛ کمترین سربار، فقط IPv4 | ماژول `ipip`، روت |
| `sit` | 6in4 کرنلی: IPv6 روی IPv4؛ آدرس‌های تونل **IPv6** هستند | ماژول `sit`، روت |
| `l2tp` | L2TPv3 کرنلی روی UDP یا IP | `l2tp_eth`/`l2tp_netlink`، روت |
| `udp` / `icmp` | TUN روی UDP ساده / ICMP echo بین IP واقعی دو سرور | روت؛ سرورِ `icmp` تا وقتی بالاست به پینگ معمولی جواب نمی‌دهد |

منو این دو را جدا از هم می‌پرسد: اول ترنسپورت را انتخاب می‌کنی، بعد می‌پرسد
رمزگذاری شود یا نه.

| وضعیت | انتخاب |
|---|---|
| بیشترین پهنای باند | `udp`/`icmp` (اگر UDP یا پینگ رد می‌شود)، وگرنه `mtcp` + `aead` |
| بازی، پینگ پایین و پایدار | `kcp` با `kcp_mode` gaming، یا `udp` |
| یک جریان سنگین (بکاپ، فایل بزرگ) | `tcpnomux` |
| DPI که همه‌چیز را می‌بندد | `ws` + `aead` |

اندازه‌گیری نسخهٔ 2.3.9 روی مسیر شبیه‌سازی‌شدهٔ ایران (۸۰ میلی‌ثانیه، ۰٫۳٪ loss،
۵۰۰ مگابیت) با ۳۰۰ کاربر هم‌زمان که ۱۰ نفرشان بی‌وقفه دانلود و ۵ نفر آپلود می‌کنند:

| | ↓ مگابیت | ↑ مگابیت | پینگ میانه | پینگ ۹۵٪ |
|---|---|---|---|---|
| بدون تانل | 460 | 425 | 144 ms | 489 ms |
| `udp`، `icmp` | 453 | 402 | 145 ms | 490 ms |
| `mtcp` | 449 | 446 | 102 ms | 293 ms |
| `tcpnomux` | 458 | 399 | 142 ms | 495 ms |
| `kcp` (۴ لینک) | 160 | 256 | 369 ms | 690 ms |
| `tcp`، `ws` (یک لینک) | 140 | 136 | 240 ms | 340 ms |

مسیر تو همین نیست: روی هر گزینه **تست سرعت** (پایین‌تر) را بزن و بهترینش روی
مسیر خودت را نگه دار.

**ترنسپورت `quic` در 2.3.22 حذف شد.** روی مسیرهای پرافت به چند مگابیت سقوط
می‌کرد، در حالی که `kcp` و `mtcp` صدها مگابیت می‌برند. تونلی که هنوز روی `quic`
است اجرا نمی‌شود: روی هر دو سرور با **Manage tunnels ← Change transport** آن را
به `kcp` (UDP) یا `mtcp` (TCP) تغییر بده. منیجر هنگام باز شدن این تونل‌ها را نام
می‌برد. قابلیت *ارسال دوتایی بسته‌های UDP* هم که فقط با `quic` کار می‌کرد، همراهش
حذف شد.

تونل‌های کرنلی (`gre`، `gretap`، `ipip`، `sit`، `l2tp`) لایهٔ رمزنگاری نمی‌گیرند: بسته‌ها را
خود کرنل جابه‌جا می‌کند، پس اگر رمزنگاری لازم است آن را در سرویس (TLS) انجام بده.

تونل نقطه‌به‌نقطه را نمی‌شود درجا به ترنسپورت جریانی تبدیل کرد (و برعکس) —
فیلدهای کانفیگشان فرق دارد. به‌جایش یک تونل جدید بساز.

ترنسپورت‌های `udp` و `icmp` حامل بسته‌اند: هر دیتاگرام جداگانه مهر و موم می‌شود
(XChaCha20-Poly1305 با nonce تصادفی برای هر بسته)، پس `aead` یا `none` می‌پذیرند،
ولی `obfs` را نه. حتماً رمزگذاری کن — حامل هر بسته‌ای را که IP مبدأ طرف مقابل
را داشته باشد قبول می‌کند، و هر کسی در مسیر می‌تواند چنین بسته‌ای جعل کند و
بفرستد؛ پس بدون تگ احراز اصالت، هیچ چیزی جلوی تزریق ترافیک دلخواه به دستگاه TUN
تو را نمی‌گیرد.
با `aead` هر دو سرور باید 2.3.12 یا جدیدتر باشند (کلیدهایش در 2.3.12 عوض شد)؛
`udp`/`icmp` بدون رمزنگاری هنوز با نسخه‌های قدیمی‌تر کار می‌کند.

**هر دو سرور را با هم به‌روز کن.** از 2.3.20 تانل جریانی با رمزنگاری `none`
فقط وقتی وصل می‌شود که سرور مقابل هم ثابت کند توکن را دارد؛ این
یعنی هر دو طرف باید 2.3.14 یا جدیدتر باشند. با سرور قدیمی‌تر، لاگ همین را می‌گوید
و تانل وصل نمی‌شود. همین اثبات روی `tls`، و از 2.8.10 روی `reality` هم لازم است (کلاینت
reality هر گواهی را می‌پذیرد)؛ همهٔ نسخه‌هایی که reality دارند این اثبات را از قبل می‌فرستند.

**نام‌های قدیمی هنوز کار می‌کنند.** `tcpobf`، `mtcpobf`، `wsobf` و `rawmux`
به‌طور خودکار ترجمه می‌شوند (`tcpobf` می‌شود `tcp` + `obfs`)، پس تونل‌های موجود
بدون هیچ تغییری به کار خود ادامه می‌دهند.

## کد اشتراک: یک paste و سرور دوم آماده است

هر تانل دو طرف دارد و برای طرف دوم باید همه‌چیزهایی را که به طرف اول داده بودی دوباره تایپ می‌کردی.
حالا سرور اول **یک خط** به تو می‌دهد؛ آن را در ترمینال سرور دوم paste کن و طرف دوم تانل ساخته و
روشن می‌شود: ترنسپورت، رمزنگاری، توکن، جهت اتصال، آدرس‌های تانل، کلیدها و پورت‌ها، همه برای آن طرف
برعکس و تنظیم‌شده.

- بعد از ساختن هر تانل، این خط خودش چاپ می‌شود. بعداً هم: **Manage tunnels ← تانل ← 19) Share code**
  یا **6) Share codes ← 1**.
- از هر دو طرف کار می‌کند: اگر روی سرور ایران ساخته شود سرور خارج را تنظیم می‌کند، و برعکس (در این
  حالت سرور ایران فقط پورت‌های کاربران را می‌پرسد، چون سرور خارج آن‌ها را نمی‌داند).
- روی سروری که هنوز BrokenNode ندارد، همان خط اول نصبش می‌کند.
- اگر روی سروری paste شود که همین تانل را دارد، **همان را به‌روز می‌کند** — مثلاً بعد از عوض کردن
  ترنسپورت یا رمزنگاری روی یک طرف.

**انتقال به سرور جدید وقتی یکی فیلتر می‌شود:** **6) Share codes ← 2) Backup code** یک خط می‌دهد که
**همهٔ** تانل‌های سرور در آن است. تا وقتی به سرور دسترسی داری کپی‌اش کن و جای امنی نگه دار. روی سرور
جدید paste کن: همهٔ تانل‌ها همان‌طور که بودند برمی‌گردند، و برای هر سرور دیگری که باید آی‌پی جدید را
بداند یک خط چاپ می‌کند — هر کدام را روی همان سرور paste کن.

کد را در منو هم می‌شود paste کرد: **6) Share codes ← 3) Paste a code** (وقتی ترمینال یک خط بلند را
می‌شکند به کار می‌آید). کد شامل توکن‌های مخفی تانل‌هاست: فقط برای خودت نگهش دار.

## چند تانل بین همان دو سرور

انواع مختلف کنار هم بین یک جفت سرور کار می‌کنند — `gre`، `gretap`، `ipip`، `sit`،
`l2tp`، `udp`، `icmp` و ترنسپورت‌های جریانی — هر کدام با زیرشبکهٔ تانل و
پورت‌های کاربر جداگانه (منیجر روی سرور ایران مقادیر آزاد را پیشنهاد می‌دهد). دو
تانل از **یک** نوع:

| نوع | دومی به همان سرور | چه چیزی جدایشان می‌کند |
|---|---|---|
| `gre`، `gretap` | بله | هر کدام `gre_key` جدا (منیجر پیشنهاد می‌دهد) |
| `ipip`، `sit` | **نه** — کرنل برای هر جفت IP فقط یکی را اجازه می‌دهد | — |
| `l2tp` | بله | tunnel/session id جدا و روی udp یک `l2tp_port` جدا |
| `udp`، `icmp` | بله | `carrier_port` جدا (در icmp همان شناسهٔ echo) |
| ترنسپورت‌های جریانی | بله | پورت جدا |

روی هر دو سرور همان مقادیر را وارد کن؛ منیجر سرور ایران آن‌ها را نشان می‌دهد.

## تست سرعت و آمار زنده

**تست سرعت** (مدیریت تانل‌ها ← یک تانل ← ۱۵) پینگ، جیتر، دانلود و آپلود را
*از داخل خود تانل* و با همان ترنسپورت و رمزنگاری می‌سنجد؛ پس عددها همان چیزی است
که کاربرهایت می‌گیرند. اول سرور مقابل را بیرون از تانل پینگ می‌کند تا ببینی
تانل چقدر اضافه می‌کند، و هر نتیجه را نگه می‌دارد: جدول آخر، آخرین اجراهای همهٔ
تانل‌ها را کنار هم نشان می‌دهد — این‌طوری ترنسپورت‌ها را روی مسیر خودت مقایسه
می‌کنی. برای ترنسپورت‌های جریانی روی سرور ایران اجرا کن؛ برای `gre`، `ipip`،
`l2tp`، `udp` و `icmp` روی هر کدام. هر دو سرور باید 2.3.9 یا جدیدتر باشند.

**آمار زنده** (← ۸) سرعت همین لحظه، بیشینه، تاریخچهٔ ۴۰ ثانیه، لینک‌های وصل و
کاربرهای متصل را روی هر دو سرور و برای همهٔ ترنسپورت‌ها نشان می‌دهد. هر ثانیه
درجا به‌روز می‌شود (بدون پرش صفحه)؛ با زدن هر کلیدی برمی‌گردی.

**تانل وصل است و تست سرعت خوب است، ولی کانفیگ کار نمی‌کند؟** تست سرعت از پورت‌های
فوروارد عبور نمی‌کند، پس این مشکل را نمی‌بیند. روی سرور ایران **Diagnose** را بزن
(مدیریت تانل‌ها ← یک تانل ← ۱۸). هر پورت را در کل مسیر چک می‌کند — روی این سرور باز
شده، قانون NAT آن را نگرفته، فایروال (ufw/iptables) بازش گذاشته، و سرور خارج به
`target_host` می‌رسد — و برای هر مشکل دستور رفعش را چاپ می‌کند. فهرست تانل‌ها هم
پورتی را که باز نشده (برنامهٔ دیگری گرفته) قرمز نشان می‌دهد؛ تانل مدام دوباره امتحان
می‌کند و به محض آزاد شدن پورت، سرویسش را شروع می‌کند.

یک علت رایج، قانون NAT قدیمی است که از یک تانل `gre`/`ipip`/`l2tp` حذف‌شده مانده و
پورت را قبل از رسیدن به تانل به جای دیگری می‌فرستد. از 2.8.6 هر بار اجرا این
باقی‌مانده‌ها را پاک می‌کند و حذف تانل هم آن‌ها را جارو می‌کند؛ `brokennode cleanup`
همین کار را دستی انجام می‌دهد. قانونی که برنامهٔ دیگری گذاشته پاک نمی‌شود: Diagnose
و لاگ تانل آن را با دستور حذفش نشان می‌دهند. برای جواب دقیقِ سمت سرور خارج، هر دو
سرور باید 2.8.6 باشند.

## تنظیم برای بازی

</div>

<div dir="rtl">

**بازی کنار کاربرهای پرمصرف (2.3.10).** روی ترنسپورت‌های جریانی، بسته‌های UDP
بازی داخل تانل پشت دانلود بقیه منتظر می‌ماندند؛ با ۱۰۰ نفر در حال وب‌گردی روی یک
لینک tcp، بازی‌ها ۷۲٪ بسته‌ها را از دست می‌دادند و بقیه ۱۱ تا ۲۰ ثانیه دیر
می‌رسید. حالا هر نشست UDP صف خودش را دارد که هر نوبت یک‌جا فرستاده می‌شود، و بسته‌ای
که نیم ثانیه دیر شده به‌جای رسیدن دیرهنگام دور ریخته می‌شود: با همان بار، loss زیر
۱٪ و پینگ ۲۵۰ میلی‌ثانیه روی tcp، ۱۴۰ روی mtcp و ۹۷ روی udp (مسیر ۸۰ میلی‌ثانیه).

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
- در `udp` و `icmp` هر جهت کلید جداگانه دارد، بنابراین یک بستهٔ ضبط‌شده را نمی‌توان به
  خود فرستنده‌اش بازتاب داد.

## بدون هیچ محدودیت مصنوعی

نه سقف پهنای باند، نه سقف حافظه، نه سقف CPU، نه محدودیت ثابت تعداد اتصال. هر
چیزی که قبلاً یک عدد ثابت بود، حالا هنگام اجرا از خود سخت‌افزار محاسبه می‌شود:
تعداد لینک‌ها تا جایی بالا می‌رود که سیستم‌عامل بتواند سوکت و پورت تأمین کند،
پنجره‌های بافر با مقدار RAM مقیاس می‌گیرند، مدیریت حافظه کاملاً به عهدهٔ ران‌تایم
است، و استخر اتصال‌ها با بار زندهٔ سیستم بزرگ و کوچک می‌شود.

**سهمیهٔ ترافیک** اختیاری است و به‌صورت پیش‌فرض نامحدود. تا وقتی خودت مقداری
تنظیم نکنی، هیچ کاری انجام نمی‌دهد.

تست‌شده در 2.3.9: ۱۸٬۰۰۰ کاربر هم‌زمان روی یک تانل، ۸۰ نفرشان با تمام سرعت در
حال جابه‌جایی داده (حدود ۶ گیگابیت دانلود و ۵ گیگابیت آپلود روی یک ماشین ۴ هسته‌ای)،
۵ دقیقه بدون قطع شدن حتی یک کاربر و با تأخیر ثابت؛ حافظه حدود ۱ گیگابایت ماند و
بعد از رفتن کاربرها پایین آمد. تعداد کاربری که یک سرور نگه می‌دارد را RAM آن
(حدود ۳۰ کیلوبایت برای هر کاربر بیکار، بیشتر وقتی داده جابه‌جا می‌کند) و سقف
فایل‌های باز تعیین می‌کند که سرویس بالا می‌برد. روی سرور خارج، وقتی همهٔ پورت‌های
مبدأ به سمت سرویس محلی (`127.0.0.1:port`) پر شود — حدود ۶۴٬۰۰۰ کاربر — کاربر
جدید از یک آدرس دیگر `127.x` وصل می‌شود به‌جای اینکه قطع شود.

## خط فرمان

منو همهٔ کارها را پوشش می‌دهد، ولی هستهٔ برنامه دستورها را مستقیم هم می‌پذیرد:

</div>

```bash
brokennode -c /etc/brokennode/main.json   # اجرای تونل از روی کانفیگ
brokennode -gen server                    # چاپ یک کانفیگ نمونهٔ سرور
brokennode -gen client                    # چاپ یک کانفیگ نمونهٔ کلاینت
brokennode -transports                    # فهرست ترنسپورت‌ها و لایه‌های رمزنگاری
brokennode speedtest -c /etc/brokennode/main.json [-t 10] [-p 4]   # تست سرعت از داخل تانل
brokennode doctor -c /etc/brokennode/main.json   # چرا تانل کاربر رد نمی‌کند؟
brokennode cleanup                        # پاک کردن قوانین NAT تانل‌های حذف‌شده
brokennode version
BrokenNode share <tunnel>                 # کد اشتراک یک تانل (برای طرف دیگرش)
BrokenNode backup                         # یک کد با همهٔ تانل‌های این سرور
BrokenNode import <code>                  # ساختن / بازگرداندن از روی کد اشتراک یا پشتیبان
```

<div dir="rtl">

## مرجع کانفیگ (JSON)

مشترک: `mode`، `transport`، `encryption`، `token`، `keepalive`، `log_level`

سرور: `ports` (به شکل `"2052"`، `"2052/udp"`، `"2052/both"`،
`"8443=443"`)، `quota_total_gb`، `quota_up_gb`، `quota_down_gb`؛ `socks`
(پروکسی SOCKS5 و HTTP CONNECT روی این آدرس، مثلاً `"127.0.0.1:1080"`)،
`socks_user` و `socks_pass` (هر دو، برای اجباری کردن ورود با رمز)، `socks_open`
(اجازهٔ پروکسی بدون رمز روی آدرس عمومی)

کلاینت: `target_host`

ترنسپورت‌های جریانی: `direction` (پیش‌فرض `reverse`، یا `direct`)؛ طرفی که گوش
می‌دهد `bind_addr` و طرفی که وصل می‌شود `remote_addr` می‌گیرد — در ریورس سرور
ایران گوش می‌دهد و در دایرکت سرور خارج.

مخصوص هر ترنسپورت: `pool_size`، `pool_min_idle`، `links`، `links_max`،
`links_per_link`، `kcp_mode`، `kcp_data`، `kcp_parity`، `kcp_mtu`،
`kcp_sndwnd`، `kcp_rcvwnd`، `smux_recv_mb`، `smux_stream_mb`، `smux_frame_kb`، `server_name`،
`alpn`، `sctp_streams`، `sctp_multihoming`، `ws_path`، `ws_host`، `ws_user_agent`

پنجره‌های smux مقداری است که هر لینک می‌تواند برای کاربرانی که کندتر از تانل داده را می‌خوانند
نگه دارد. در `tcp`، `ws` و `kcp` یک session همهٔ کاربران را می‌برد (پیش‌فرض ۱۶ مگابایت یا بیشتر)؛
`mtcp` برای هر لینک یک session دارد، پس پیش‌فرضش با RAM تغییر می‌کند — روی سرور کمتر از ۴ گیگابایت
۱ مگابایت برای هر stream، و حداکثر ۴ — و هر stream حدود پنجره ÷ پینگ سرعت دارد (۱ مگابایت: حدود
۷۰ مگابیت با پینگ ۱۲۰ میلی‌ثانیه).

رمزنگاری: `tls_selfsigned`، `tls_cert` + `tls_key`، `tls_auto_email`،
`tls_insecure`، `tls_fingerprint` (`chrome` `firefox` `safari` `edge` `ios`
`random`)، `tls_fragment`، `reality_dest` (`host:443`، در هر دو طرف یکسان)،
`reality_server_name`، `pad` (در هر دو طرف یکسان)

تونل‌های نقطه‌به‌نقطه: `local_ip`، `remote_ip` (IPv4 واقعی دو سرور)،
`tun_local`، `tun_remote` (جفت آدرس روی تونل — برای `sit` از نوع IPv6)،
`tun_name`، `mtu`، `tun_ttl`، `gre_key`، `l2tp_tunnel_id`، `l2tp_session_id`،
`l2tp_encap` (`udp`|`ip`)، `l2tp_port`، `carrier_port` (`udp`/`icmp`). پورت‌های `ports` سرور از روی تونل NAT می‌شوند و `target_host`
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
