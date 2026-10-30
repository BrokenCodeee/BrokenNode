#!/usr/bin/env bash
# ============================================================================
#  BrokenNode Tunnel - Manager (prebuilt core, no build / no internet)
#  Multi-instance | presets | per-port tcp/udp/both | systemd
#  Transport and encryption are chosen separately (see pick_transport /
#  pick_encryption).
# ============================================================================
set -uo pipefail

VERSION="2.8.17"
# Bump when the sysctl tuning changes: hosts tuned by an older release pick
# the new values up automatically (see auto_tune_once).
TUNE_VERSION=3
BIN="/usr/local/bin/brokennode"
CFG_DIR="/etc/brokennode"
TPL="/etc/systemd/system/brokennode@.service"
AU_SVC="/etc/systemd/system/brokennode-autoupdate.service"
AU_TIMER="/etc/systemd/system/brokennode-autoupdate.timer"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repository root when running from a source checkout (this script lives in
# scripts/). Harmless when the script is deployed on its own to a server.
REPO_DIR="$(cd "$SRC_DIR/.." && pwd)"
# How the operator actually invoked us, so usage/hint text stays correct whether
# this is run as "scripts/BrokenNode.sh" from a checkout or as "BrokenNode.sh"
# from a release directory.
SELF="${BASH_SOURCE[0]}"
INSTALL_URL="https://raw.githubusercontent.com/BrokenCodeee/BrokenNode/main/install.sh"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_M='\033[0;35m'; C_D='\033[0;90m'; C_N='\033[0m'
info(){ echo -e "${C_G}  [+]${C_N} $*"; }
warn(){ echo -e "${C_Y}  [!]${C_N} $*"; }
err(){ echo -e "${C_R}  [x]${C_N} $*" >&2; }
# ask PROMPT [DEFAULT] — one answer. When input has ended (Ctrl+D, a dropped
# SSH session, a script that ran out of answers) a question WITH a default takes
# it, as before; one without a default stops the manager instead. Those are the
# questions that must be answered (the other server's IP, say), and their
# "ask again" loops otherwise spun for ever at full CPU once stdin was closed.
ask(){
  local p="$1" d="${2:-}" a
  # A code given on the command line (the line printed for the other server)
  # is imported without questions: each one with a default takes it, shown.
  if [ -n "$d" ] && [ "${IMPORT_AUTO:-0}" = 1 ]; then
    echo -e "${C_B}  ?${C_N} $p: ${C_Y}$d${C_N} ${C_D}(chosen automatically)${C_N}" >&2
    echo "$d"; return 0
  fi
  if [ -n "$d" ]; then read -rp "$(echo -e "${C_B}  ?${C_N} $p [${C_D}$d${C_N}]: ")" a; echo "${a:-$d}"; return 0; fi
  if ! read -rp "$(echo -e "${C_B}  ?${C_N} $p: ")" a && [ -z "$a" ]; then
    echo >&2; err "Input ended — stopped (nothing was saved from this question on)."
    kill -TERM "$$" 2>/dev/null; exit 1
  fi
  echo "$a"
}
# menu_ask PROMPT — a menu choice; "__eof__" once input has ended. The menus
# loop until a choice exits them, and ask() cannot tell end of input from an
# empty answer, so a closed stdin (a script feeding the menu, a dropped SSH
# session) spun them forever printing "Invalid.".
menu_ask(){ local a; if read -rp "$(echo -e "${C_B}  ?${C_N} $1: ")" a; then echo "$a"; else echo "__eof__"; fi; }
# is_ipv4 ADDR — a dotted quad, each part 0-255 without leading zeros (the
# core's parser refuses "01.2.3.4").
is_ipv4(){ local q='(0|[1-9][0-9]{0,2})'; [[ "$1" =~ ^$q\.$q\.$q\.$q$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done; }
# is_ipv6 ADDR — an IPv6 address, without brackets.
is_ipv6(){ case "$1" in *%*) return 1 ;; *:*) python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$1" 2>/dev/null ;; *) return 1 ;; esac; }
# hostport HOST PORT — "HOST:PORT", with an IPv6 host in brackets ([2001:db8::1]:443).
hostport(){ case "$1" in *:*) printf '[%s]:%s' "$1" "$2" ;; *) printf '%s:%s' "$1" "$2" ;; esac; }
need_root(){ [ "$(id -u)" -eq 0 ] || { err "Run as root: sudo bash $SELF"; exit 1; }; }
detect_ip(){ ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || true; }
# detect_ip6 — this server's global IPv6 address, empty when it has none.
detect_ip6(){ ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || true; }
default_iface(){ ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1; }

core_ver(){ if [ -x "$BIN" ]; then "$BIN" version 2>/dev/null | awk '{print $NF}'; else echo "v$VERSION"; fi; }
banner(){
  clear 2>/dev/null || true
  local v; v="$(core_ver)"
  echo -e "${C_M}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║           B R O K E N   N O D E              ║"
  printf "  ║      Multi-Protocol Tunnel  ·  %-14s║\n" "$v"
  echo "  ╠══════════════════════════════════════════════╣"
  printf "  ║%-46s║\n" "      Telegram:  @BrokenNode"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${C_N}${C_D}  arch: $(uname -m)   manager: v$VERSION   core: $([ -x "$BIN" ] && core_ver || echo 'not installed')${C_N}"
  echo -e "${C_G}  Free & open-source · t.me/BrokenNode${C_N}"
}

# arch_sfx maps this machine to the binary suffix built by scripts/build.sh.
# The names come from `uname -m`, which is what every Linux distribution
# reports regardless of packaging: Debian, Ubuntu, Alpine, CentOS and OpenWrt
# all agree here. An unknown CPU prints nothing rather than guessing amd64 —
# installing an x86 binary on a MIPS router produces "cannot execute binary
# file", which tells the operator far less than ensure_core's message does.
arch_sfx(){
  case "$(uname -m)" in
    x86_64|amd64)             echo amd64   ;;
    aarch64|arm64)            echo arm64   ;;
    armv8l|armv7l|armv7|armhf) echo armv7  ;;
    armv6l|armv6|arm)         echo armv6   ;;
    i386|i486|i586|i686|x86)  echo 386     ;;
    riscv64)                  echo riscv64 ;;
    *)                        echo ""      ;;
  esac
}
# detect_bin looks for the core binary in the places it can legitimately be.
# The script's OWN directory comes first: a release ships this script and the
# binary side by side, and that deployment must keep working untouched. The
# published BrokenNode folder keeps its binaries in bin/, so that is checked
# first of all. The repository layout (dist/, and the repo root for a plain
# "go build") is checked afterwards so the menu is also usable straight from a
# source checkout, where the script lives in scripts/ rather than next to the
# build output.
detect_bin(){
  local sfx; sfx="$(arch_sfx)"
  local c
  for c in \
    "$SRC_DIR/bin/brokennode-linux-$sfx" \
    "$SRC_DIR/brokennode-linux-$sfx" \
    "$SRC_DIR/brokennode" \
    "$REPO_DIR/bin/brokennode-linux-$sfx" \
    "$REPO_DIR/dist/brokennode-linux-$sfx" \
    "$REPO_DIR/dist/brokennode" \
    "$REPO_DIR/brokennode-linux-$sfx" \
    "$REPO_DIR/brokennode"
  do
    # An unknown CPU leaves $sfx empty; skip the arch-specific candidates so a
    # bare "brokennode" beside the script is still found.
    case "$c" in *-linux-) continue ;; esac
    [ -f "$c" ] && { echo "$c"; return; }
  done
}
# core_version BINARY — "2.3.7" from "BrokenNode Tunnel v2.3.7"; empty if the
# binary does not run.
core_version(){ "$1" version 2>/dev/null | sed -n 's/.* v\{0,1\}\([0-9][0-9.]*\)$/\1/p' | head -n 1; }

# version_lt A B — true when version A is older than B.
version_lt(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]; }

# bundled_is_older SRC — the core in this folder is OLDER than the one already
# installed. Installing it would be a downgrade: that is what happened when an
# update landed in a second, nested BrokenNode folder and the old folder, opened
# later, put its old core back ("updated, and then it is 2.3.5 again").
bundled_is_older(){
  [ -x "$BIN" ] || return 1
  local have new; have="$(core_version "$BIN")"; new="$(core_version "$1")"
  [ -n "$have" ] && [ -n "$new" ] && version_lt "$new" "$have"
}

# install_core SRC — put the core SRC in place as $BIN, only if it actually
# runs here and reports a version: a truncated download or a build for another
# CPU used to replace a working core, and every tunnel was then restarted onto
# it. The copy is renamed into place, so a running tunnel's binary is never
# rewritten underneath it and an interrupted copy leaves the old core.
install_core(){
  if [ -z "$(core_version "$1")" ]; then
    err "The core in this folder ($1) does not run on this machine — not installed; the current one stays."
    return 1
  fi
  install -m0755 "$1" "$BIN.new" && mv -f "$BIN.new" "$BIN" || { rm -f "$BIN.new"; err "Could not install the core to $BIN."; return 1; }
  forget_old_core
}

# forget_old_core — an update is complete: no older core is kept, and nothing
# holds a server on one. 2.8.13 kept the replaced core as $BIN.prev and let a
# rollback pin it ($CFG_DIR/.core-pin), which then stopped every update from
# applying; both are removed wherever the core is checked.
forget_old_core(){ rm -f "$BIN.prev" "$CFG_DIR/.core-pin"; }

warn_old_folder(){
  warn "This folder ($SRC_DIR) holds an OLDER BrokenNode (core v$(core_version "$1")) than the one installed (v$(core_version "$BIN")) — not downgrading."
  echo -e "  ${C_D}Update this folder: menu option 5, or  cd \"$SRC_DIR\" && bash <(curl -fsSL $INSTALL_URL)${C_N}"
}

ensure_core(){
  local src; src="$(detect_bin)"
  if [ -n "$src" ] && [ -f "$src" ]; then
    if bundled_is_older "$src"; then warn_old_folder "$src"; return 0; fi
    forget_old_core
    if [ ! -x "$BIN" ] || ! cmp -s "$src" "$BIN"; then
      install_core "$src" || { [ -x "$BIN" ] && return 0; return 1; }
      info "Core updated: $("$BIN" version)"
    fi
    return 0
  fi
  [ -x "$BIN" ] && return 0
  if [ -z "$(arch_sfx)" ]; then
    err "Unsupported CPU: $(uname -m). BrokenNode ships amd64, arm64, armv7, armv6, 386 and riscv64."
    return 1
  fi
  err "No core binary for $(arch_sfx) (looked in bin/, next to this script, in dist/ and in the repo root) and none installed."
  err "Get the build for your CPU:  bash <(curl -fsSL https://raw.githubusercontent.com/BrokenCodeee/BrokenNode/main/install.sh)"; return 1
}

write_template(){
  cat > "$TPL" <<EOF
[Unit]
Description=BrokenNode Tunnel (%i)
After=network-online.target
Wants=network-online.target
# Never stop retrying. systemd's default start-limit gives up after a few
# restarts in a short window and parks the unit in "failed" — which is how a
# tunnel ends up stopped "for no reason" until someone restarts it by hand.
# With the limit off, a crashing or flapping tunnel is retried forever.
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=$BIN -c $CFG_DIR/%i.json
# After EVERY stop — a clean one, a crash, a kill -9, the stop timeout — sweep
# the NAT rules no running tunnel owns. A rule a stop failed to remove kept
# its port pointed at a tunnel that was gone. "-": a failure here is not a
# failure of the unit.
ExecStopPost=-$BIN cleanup
Restart=always
RestartSec=2
# No resource ceilings: the tunnel may use as much CPU / RAM / sockets as the
# box has. Raise nothing artificially; the OS hard limits are the only cap.
LimitNOFILE=infinity
LimitNPROC=infinity
LimitMEMLOCK=infinity
TasksMax=infinity
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
# 16 letters and digits: about 95 random bits, and short in a share code.
gen_token(){ ( head -c 24 /dev/urandom | base64 2>/dev/null | tr -d '/+=' | head -c 16 ) || echo "bn$(date +%s)$RANDOM"; }

# new_cfg_file creates an EMPTY config at 0600 before anything is written into
# it. Configs hold the shared token, so they must never be world-readable. The
# file is created restricted FIRST because "cat >" keeps the permissions of an
# existing file but creates a new one at the umask default (0644 for root) —
# which would leave the token readable by every local user for the moment
# between creation and the chmod.
new_cfg_file(){ install -m 600 /dev/null "$1"; }

# harden_cfg_dir tightens the config directory and any file already in it, so an
# install created by an older build stops exposing its token.
harden_cfg_dir(){
  chmod 700 "$CFG_DIR" 2>/dev/null
  local f
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue
    chmod 600 "$f" 2>/dev/null
  done
}

# pick_transport lists only the BASE transports. Encryption used to double this
# menu (tcp vs tcpobf, mtcp vs mtcpobf, ws vs wsobf, kcp vs rawmux) even though
# those pairs are the same transport with a layer on top. Encryption is now a
# separate question — see pick_encryption — which keeps this list short and lets
# every transport be combined with every layer.
# is_tunnel_transport is true for the point-to-point tunnels that need address
# fields rather than a bind port: the kernel tunnels and the raw udp/icmp carriers.
is_tunnel_transport(){
  case "$1" in gre|gretap|ipip|sit|l2tp|udp|icmp) return 0 ;; *) return 1 ;; esac
}

# transport_family groups transports by the config fields they need, which is
# what decides whether one can replace another in place:
#   stream  bind_addr / remote_addr         tcp mtcp mptcp ws tcpnomux kcp sctp
#   p2p4    local_ip / remote_ip / tun_* v4 gre gretap ipip l2tp udp icmp
#   sit     the same fields, but an IPv6 tunnel pair
transport_family(){
  case "$1" in
    sit) echo sit ;;
    *) if is_tunnel_transport "$1"; then echo p2p4; else echo stream; fi ;;
  esac
}

# Direction (stream transports only). "reverse": the foreign server dials the
# Iran relay. "direct": the Iran relay dials the foreign server, which listens.
# Both servers must use the same one. The config keeps both addresses when a
# tunnel is flipped, so flipping back needs no re-entry; which one is used
# follows from the mode and the direction.
tunnel_direction(){ # CFG -> reverse|direct
  local d; d="$(jget "$1" direction | tr -d ' ' | tr 'A-Z' 'a-z')"
  [ "$d" = direct ] && [ "$(transport_family "$(jget "$1" transport)")" = stream ] && echo direct || echo reverse
}

# tunnel_listens CFG: this end waits for the other (relay in reverse mode,
# foreign server in direct mode). The other case dials.
tunnel_listens(){
  local m d; m="$(jget "$1" mode)"; d="$(tunnel_direction "$1")"
  { [ "$m" = server ] && [ "$d" = reverse ]; } || { [ "$m" = client ] && [ "$d" = direct ]; }
}

# pick_direction [TRANSPORT] — reverse, direct, or proxy-reverse /
# proxy-direct: a SOCKS5/HTTP proxy on the Iran server in place of port
# forwards. The proxy still rides a tunnel, so it asks which server connects.
# tcpnomux does not multiplex and cannot carry the proxy.
pick_direction(){
  local tr="${1:-}" max=3
  [ "$tr" = tcpnomux ] && max=2
  echo -e "${C_B}  Connection direction:${C_N}" >&2
  echo -e "   1) reverse  the FOREIGN server connects to the Iran server  ${C_D}(classic)${C_N}" >&2
  echo -e "   2) direct   the IRAN server connects to the foreign server" >&2
  [ "$max" = 3 ] && echo -e "   3) proxy    a SOCKS5/HTTP proxy on the Iran server  ${C_D}(no port forwards: users set it in their app or browser)${C_N}" >&2
  echo -e "  ${C_D}Pick direct when connections INTO the Iran server are being cut.${C_N}" >&2
  echo -e "  ${C_D}Both servers must use the SAME choice.${C_N}" >&2
  local d; d=$(ask "Choice [1-$max]" "1")
  case "$d" in
    2|d|direct) echo direct ;;
    3|p|proxy)
      if [ "$max" = 2 ]; then echo reverse; return; fi
      echo -e "  ${C_D}The proxy runs over the tunnel. Which server connects to the other?${C_N}" >&2
      local w; w=$(ask "1) the FOREIGN server connects to Iran (reverse)   2) IRAN connects to the foreign server (direct)" "1")
      [ "$w" = 2 ] && echo proxy-direct || echo proxy-reverse ;;
    *) echo reverse ;;
  esac
}

# ask_hostport PROMPT DEFAULT_PORT [DEFAULT] — a host:port, with the port
# added when only a host is typed. Empty stays empty (the caller decides).
# An IPv6 address works typed bare (2001:db8::1) or as [2001:db8::1]:443.
ask_hostport(){
  local a; a=$(ask "$1" "${3:-}")
  a="$(echo "$a" | tr -d ' ')"
  [ -z "$a" ] && { echo ""; return; }
  case "$a" in
    \[*\]:*) echo "$a" ;;
    \[*\])   echo "$a:$2" ;;
    *:*:*)   echo "[$a]:$2" ;;   # a bare IPv6 address: its colons are not a port
    *:*)     echo "$a" ;;
    *)       echo "$a:$2" ;;
  esac
}

# ---------------------------------------------------------------------------
# Several tunnels on one server
#
# One Iran relay commonly serves several foreign servers, one tunnel each.
# Anything two tunnels share by accident breaks one of them: the same tunnel
# addresses (routes collide), the same l2tp id or udp carrier port, or the same
# user port on the relay. These helpers read the OTHER tunnels' configs so a new
# one is offered free values and warned about clashes.
# ---------------------------------------------------------------------------

# cfg_scan MODE EXCLUDE [KEY]
#   values KEY : every value of KEY in the other configs, one per line
#   ports      : every port the other configs listen on (user ports + bind port)
#   carriers [P]: carrier ports in use for protocol P (udp by default; icmp's is
#                its echo identifier), 6262 when a tunnel leaves it unset
cfg_scan(){
  python3 - "$CFG_DIR" "$1" "$2" "${3:-}" <<'PYEOF2'
import json, os, sys, glob
d, mode, excl, key = sys.argv[1:5]
P2P = ("gre", "gretap", "ipip", "sit", "l2tp", "udp", "icmp")
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    if os.path.basename(f)[:-5] == excl:
        continue
    try:
        c = json.load(open(f))
    except Exception:
        continue
    if mode == "values":
        v = c.get(key)
        if v not in (None, ""):
            print(v)
    elif mode == "ports":
        # "port/proto" lines: a tcp and a udp listener on one number coexist.
        for spec in c.get("ports") or []:
            spec = str(spec).strip()
            port = spec.split("=")[0].split("/")[0].strip()
            proto = spec.rsplit("/", 1)[1] if "/" in spec else "tcp"
            for pr in (("tcp", "udp") if proto == "both" else (proto,)):
                print(port + "/" + pr)
        # A tunnel's own port is taken only where it listens: the relay in
        # reverse mode, the foreign server in direct mode.
        # Same rule as the core (Config.Direct): direction counts only for
        # the stream transports, read case- and space-insensitively.
        stream = c.get("transport") not in P2P
        direct = stream and str(c.get("direction") or "").strip().lower() == "direct"
        listens = (c.get("mode") == "server") != direct
        b = (c.get("bind_addr") or "") if listens else ""
        if ":" in b:
            pr = "udp" if c.get("transport") == "kcp" else "tcp"
            print(b.rsplit(":", 1)[1] + "/" + pr)
    elif mode == "carriers":
        # key = carrier protocol (udp, icmp, tcp). A carrier port — the echo
        # identifier for icmp — has to be unique per protocol on a server.
        t = c.get("transport")
        key = key or "udp"
        # A udp carrier and an l2tp-over-udp tunnel bind in the same UDP port
        # space on this server, so for either one both kinds are taken.
        if key in ("udp", "l2tp") and t == "l2tp" and (c.get("l2tp_encap") or "udp") == "udp":
            print(c.get("l2tp_port") or 1701)
            continue
        cp = t if t in ("udp", "icmp") else None
        if cp == key or (key == "l2tp" and cp == "udp"):
            print(c.get("carrier_port") or 6262)
PYEOF2
}

# next_free_int KEY START EXCLUDE — smallest integer >= START no other tunnel uses for KEY.
next_free_int(){
  local key="$1" v="$2" used
  used=" $( { case "$key" in
      carrier_port)        cfg_scan carriers "$3" udp ;;
      carrier_port:*)      cfg_scan carriers "$3" "${key#carrier_port:}" ;;
      *)                   cfg_scan values "$3" "$key" ;;
    esac; } | tr '\n' ' ') "
  while [[ "$used" == *" $v "* ]]; do v=$((v+1)); done
  echo "$v"
}

# auto_or_ask ROLE PROMPT VALUE — on the relay a value that must not clash
# with anything else on this server is chosen, not asked (the operator asked
# not to have to pick them); it is shown so the other end can be set up by hand.
# The foreign server, set up by hand, is still asked.
auto_or_ask(){
  if [ "$1" = server ]; then
    echo -e "  ${C_D}  $2: ${C_N}${C_Y}$3${C_N}${C_D} (chosen automatically)${C_N}" >&2
    echo "$3"
  else
    ask "$2" "$3"
  fi
}

# bnpy SUBCOMMAND ... — the config-aware helpers that need more than sed:
#
#   alloc net EXCL            a free N for 10.10.N.x: no other tunnel here uses
#                             it and no address or route on this machine does
#   alloc port PROTO EXCL     a free port (tcp|udp) in 20000-40000: not in any
#                             tunnel config here and nothing listening on it
#   alloc l2tpid EXCL         a free l2tp tunnel/session id (1000-60000)
#
# Values are picked at RANDOM among the free ones, not the lowest: a foreign
# server may carry tunnels from several Iran relays, and relays that all chose
# "the first free" would all choose the same subnet, id and port.
bnpy(){
  python3 - "$CFG_DIR" "$@" <<'PYEOF'
import glob, json, os, random, re, subprocess, sys

cfgdir, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]

def configs(excl=""):
    out = []
    for f in sorted(glob.glob(os.path.join(cfgdir, "*.json"))):
        n = os.path.basename(f)[:-5]
        if n == excl:
            continue
        try:
            out.append((n, json.load(open(f))))
        except Exception:
            pass
    return out

def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""

def used_nets(excl):
    used = set()
    for _, c in configs(excl):
        for k in ("tun_local", "tun_remote"):
            m = re.match(r"10\.10\.(\d+)\.", str(c.get(k) or "")) or re.match(r"fd00:10:(\d+)::", str(c.get(k) or ""))
            if m:
                used.add(int(m.group(1)))
    for line in (sh("ip", "-o", "addr") + sh("ip", "route")).splitlines():
        for m in re.finditer(r"\b10\.10\.(\d+)\.", line):
            used.add(int(m.group(1)))
    return used

def used_ports(proto, excl):
    used = set()
    for _, c in configs(excl):
        t = c.get("transport")
        for spec in c.get("ports") or []:
            spec = str(spec)
            p = spec.split("=")[0].split("/")[0]
            pr = spec.rsplit("/", 1)[1] if "/" in spec else "tcp"
            if p.isdigit() and pr in (proto, "both"):
                used.add(int(p))
        for k in ("bind_addr", "remote_addr"):
            v = str(c.get(k) or "")
            if ":" in v and v.rsplit(":", 1)[1].isdigit():
                used.add(int(v.rsplit(":", 1)[1]))
        if t == "l2tp":
            used.add(int(c.get("l2tp_port") or 1701))
        if t in ("udp", "icmp"):
            used.add(int(c.get("carrier_port") or 6262))
    flag = "-Hlnu" if proto == "udp" else "-Hlnt"
    for line in sh("ss", flag).splitlines():
        f = line.split()
        if len(f) >= 4 and ":" in f[3]:
            p = f[3].rsplit(":", 1)[1]
            if p.isdigit():
                used.add(int(p))
    return used

def used_l2tp(excl):
    used = set()
    for _, c in configs(excl):
        for k in ("l2tp_tunnel_id", "l2tp_session_id"):
            if c.get(k):
                used.add(int(c[k]))
    for m in re.finditer(r"(?:Tunnel|Session) (\d+)", sh("ip", "l2tp", "show", "tunnel") + sh("ip", "l2tp", "show", "session")):
        used.add(int(m.group(1)))
    return used

def pick(lo, hi, used):
    free = [v for v in range(lo, hi + 1) if v not in used]
    return random.choice(free) if free else lo

if cmd == "alloc":
    what = args[0]
    if what == "net":
        print(pick(30, 250, used_nets(args[1])))
    elif what == "port":
        print(pick(20000, 40000, used_ports(args[1], args[2])))
    elif what == "l2tpid":
        print(pick(1000, 60000, used_l2tp(args[1])))
PYEOF
}

# peer_tunnels TRANSPORTS RIP EXCLUDE — for every other tunnel on this server
# whose transport is in TRANSPORTS (comma-separated) and whose peer is RIP, one
# line: its gre_key (0 = none; meaningful for gre/gretap only).
peer_tunnels(){
  python3 - "$CFG_DIR" "$1" "$2" "$3" <<'PYEOF'
import json, os, sys, glob
d, trs, rip, excl = sys.argv[1:5]
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    if os.path.basename(f)[:-5] == excl:
        continue
    try:
        c = json.load(open(f))
    except Exception:
        continue
    if c.get("transport") in trs.split(",") and c.get("remote_ip") == rip:
        print(int(c.get("gre_key") or 0))
PYEOF
}

# gre_peer_keys TR RIP EXCLUDE — the gre_key (0 = none) of every other tunnel
# of transport TR (gre or gretap: the kernel keeps the two apart) on this
# server to the peer RIP, one per line.
gre_peer_keys(){ peer_tunnels "$1" "$2" "$3"; }

# next_free_port START PROTO EXCLUDE — the first port >= START that no other
# tunnel on this server listens on for PROTO. A foreign server in direct mode
# can carry tunnels from several Iran relays, each on its own port.
next_free_port(){
  local p="$1" used; used=" $(cfg_scan ports "$3" | tr '\n' ' ') "
  while [[ "$used" == *" $p/$2 "* ]] && [ "$p" -lt 65535 ]; do p=$((p+1)); done
  echo "$p"
}

# warn_port_clash "PORTSJSON" EXCLUDE [BINDPORT] — tell the operator when a
# port this tunnel will listen on is already taken by another tunnel. Two
# tunnels on one user port cannot both work: only one listener (or DNAT rule)
# can ever receive the traffic.
warn_port_clash(){
  local specs="$1" excl="$2" bport="${3:-}" bproto="${4:-tcp}" used spec p pr clash=""
  used=" $(cfg_scan ports "$excl" | tr '\n' ' ') "
  local want=()
  for spec in $(printf '%s' "$specs" | tr -d '"' | tr ',' ' '); do
    p="${spec%%=*}"; p="${p%%/*}"
    case "$spec" in */both) want+=("$p/tcp" "$p/udp") ;; */udp) want+=("$p/udp") ;; *) want+=("$p/tcp") ;; esac
  done
  [ -n "$bport" ] && want+=("$bport/$bproto")
  for pr in "${want[@]}"; do
    [[ "$used" == *" $pr "* ]] && clash="$clash $pr"
  done
  if [ -n "$clash" ]; then
    warn "Port(s)${C_Y}$clash${C_N} already belong to another tunnel on this server."
    echo -e "  ${C_D}Only one tunnel can receive a given port. Use a different port for this one.${C_N}"
    return 1
  fi
  return 0
}

# ask_ports EXCLUDE — build_ports until none of the user ports is already taken
# by another tunnel here. Two tunnels on one port cannot both work: the second
# fails to bind at every start and systemd restarts it for ever.
ask_ports(){
  local p last=""
  while :; do
    p=$(build_ports)
    warn_port_clash "$p" "$1" >&2 && break
    input_ended "$p" "$last" && return 1
    last="$p"
    echo -e "  ${C_D}Enter the port list again.${C_N}" >&2
  done
  echo "$p"
}

# input_ended ANSWER PREVIOUS — stops a question that is asked again until the
# answer changes, once input has ended: with no terminal, the same answer
# twice is the default an ended input gives every time. ask() stops the script
# itself on end of input, but not when the shell ignores SIGTERM (as some
# supervisors run it), and the question then came back for ever.
input_ended(){
  [ -t 0 ] && return 1
  [ -n "$2" ] && [ "$1" = "$2" ] || return 1
  err "The same answer again and no more input — stopped."
  kill -TERM "$$" 2>/dev/null
  return 0
}

# cfg_begin CFG / cfg_commit CFG — bracket an edit of a tunnel's config: the
# core checks the edited file, and a change it refuses is rolled back to the
# copy cfg_begin kept, so the tunnel is never restarted onto a config it
# cannot run (a transport switch onto a port a user port already has, a typo
# in an address, a word where a number goes).
cfg_begin(){ cp -p "$1" "$(dirname "$1")/.undo-$(basename "$1")"; }
cfg_commit(){
  local cfg="$1" undo out rc=0; undo="$(dirname "$1")/.undo-$(basename "$1")"
  out="$("$BIN" -check -c "$cfg" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q 'flag provided but not defined' <<<"$out"; then
    [ -f "$undo" ] && mv -f "$undo" "$cfg"
    err "Not applied — the core refuses the change: $(check_reason "$out")"
    info "The previous settings are kept; the tunnel was not restarted."
    return 1
  fi
  rm -f "$undo"
}

# check_reason OUTPUT — the one line of "$BIN -check" output that says what is
# wrong: its "config error:" line, else (a file that is not valid JSON, say)
# the last line that is not a log line.
check_reason(){
  local r; r="$(printf '%s\n' "$1" | sed -n 's/^config error: //p' | tail -n 1)"
  [ -n "$r" ] || r="$(printf '%s\n' "$1" | grep -v '\[ERR\]\|\[INF\]\|\[WRN\]' | grep -v '^$' | tail -n 1)"
  printf '%s' "${r:-unknown error}"
}

# core_check CFG — have the core validate a config it is about to run. On a
# refusal: say why, delete the config (nothing was started from it) and fail.
# A core too old to know -check is not held against the config.
core_check(){
  local out
  out="$("$BIN" -check -c "$1" 2>&1)" && return 0
  grep -q 'flag provided but not defined' <<<"$out" && return 0
  err "Not saved — the core refuses this config: $(check_reason "$out")"
  rm -f "$1"
  return 1
}

pick_transport(){
  # Numbers 1-7 are exactly what 2.2.0 and earlier used. Operators pick these by
  # habit on both servers, so renumbering them (2.3.0 inserted the new ones in
  # the middle) silently put the two ends on different transports and the
  # tunnel never connected. New transports only ever get appended.
  echo >&2
  echo -e "${C_B}  Select transport:${C_N}" >&2
  echo -e "  ${C_D}── stream transports (users connect to a forwarded port) ──${C_N}" >&2
  echo -e "   1) tcp       Plain TCP + smux         ${C_G}(stable baseline)${C_N}" >&2
  echo -e "   2) mtcp      Multi-link TCP           ${C_G}(beats throttling, best for Iran)${C_N}" >&2
  echo    "   3) ws        WebSocket/HTTP + smux    (HTTP mimicry)" >&2
  echo    "   4) tcpnomux  TCP pool, no HoL         (heavy single-flow)" >&2
  echo -e "   5) kcp       KCP/UDP + FEC            ${C_Y}(only if UDP works)${C_N}" >&2
  echo -e "   8) mptcp     Multipath TCP (kernel)   ${C_G}(link aggregation, kernel >= 5.6)${C_N}" >&2
  echo -e "   9) sctp      Multi-stream + multihome ${C_Y}(needs kernel sctp module)${C_N}" >&2
  echo -e "  ${C_D}── kernel tunnels (point-to-point, root on both ends) ──${C_N}" >&2
  echo    "  10) gre       GRE, L3, offload" >&2
  echo    "  11) gretap    GRETAP, L2/ethernet" >&2
  echo    "  12) ipip      IP-in-IP, lowest overhead" >&2
  echo    "  13) sit       6in4 (IPv6 over IPv4)" >&2
  echo    "  14) l2tp      L2TPv3 tunnel+session" >&2
  echo -e "  ${C_D}── raw carriers (TUN over a protocol) ────────${C_N}" >&2
  echo    "  15) udp       TUN over UDP" >&2
  echo    "  16) icmp      TUN over ICMP echo" >&2
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}" >&2
  echo -e "  ${C_D}Type a number or a name (e.g. mtcp). 0 = cancel.${C_N}" >&2
  local n
  while :; do
    n=$(ask "Choice [1-16]" "1")
    case "$n" in
      0) echo ""; return ;;
      1|tcp) echo tcp; return ;;        2|mtcp) echo mtcp; return ;;
      3|ws) echo ws; return ;;          4|tcpnomux) echo tcpnomux; return ;;
      5|kcp) echo kcp; return ;;
      6|quic)
        # 6 was quic, removed in 2.3.22 (it slowed to a few Mbit/s on lossy
        # paths). The number stays taken so an old habit never lands on
        # another transport by accident.
        err "quic was removed in 2.3.22 — it slowed to a few Mbit/s on lossy paths. Use 5) kcp (UDP) or 2) mtcp (TCP)." ;;
      8|mptcp) echo mptcp; return ;;    9|sctp) echo sctp; return ;;
      10|gre) echo gre; return ;;       11|gretap) echo gretap; return ;;
      12|ipip) echo ipip; return ;;     13|sit) echo sit; return ;;
      14|l2tp) echo l2tp; return ;;     15|udp) echo udp; return ;;
      16|icmp) echo icmp; return ;;
      *) err "'$n' is not one of the choices." ;;
    esac
  done
}

# pick_encryption asks whether the chosen transport should be encrypted. The
# kernel tunnels carry plain IP and take no layer, so they are not asked.
pick_encryption(){
  local tr="$1"
  # The kernel tunnels (encrypt at the service) take no encryption layer.
  case "$tr" in
    gre|gretap|ipip|sit|l2tp) echo none; return ;;
  esac
  # udp/icmp seal each datagram: offer aead/none (a stream cipher cannot key
  # packets that may be lost or reordered).
  case "$tr" in
    udp|icmp)
      echo >&2
      echo -e "${C_B}  Encrypt this '$tr' tunnel?${C_N}" >&2
      echo -e "   1) aead   ChaCha20-Poly1305   ${C_G}(encrypted + tamper-proof, Recommended)${C_N}" >&2
      echo    "   2) none   No encryption" >&2
      local nn; nn=$(ask "Choice [1-2]" "1")
      case "$nn" in 2) echo none ;; *) echo aead ;; esac
      return ;;
  esac
  echo >&2
  echo -e "${C_B}  Encrypt this '$tr' tunnel?${C_N}" >&2
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}" >&2
  echo -e "   1) aead   ChaCha20-Poly1305   ${C_G}(encrypted + tamper-proof, Recommended)${C_N}" >&2
  echo -e "   2) obfs   AES-CTR obfuscation ${C_G}(anti-DPI, matches older builds)${C_N}" >&2
  echo -e "   3) tls    Real HTTPS + certificate ${C_G}(looks like HTTPS to DPI, works on any port)${C_N}" >&2
  echo -e "   4) reality Borrow a real site's HTTPS ${C_G}(no domain/certificate; probers see the real site)${C_N}" >&2
  echo    "   5) none   No encryption layer (lowest overhead)" >&2
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}" >&2
  echo -e "  ${C_D}Both ends of the tunnel must use the SAME choice.${C_N}" >&2
  local n; n=$(ask "Choice [1-5]" "1")
  case "$n" in 2) echo obfs ;; 3) echo tls ;; 4) echo reality ;; 5) echo none ;; *) echo aead ;; esac
}

# tls_extra collects the tls encryption layer's fields into TLSJSON (the config
# blocks splice it in). server_name is the SNI the client sends and the name on
# the certificate; the same value on both ends makes the handshake look like
# ordinary HTTPS. Only the automatic Let's Encrypt mode needs a reachable
# :80/:443 — self-signed and cert-file modes run on ANY port.
tls_extra(){
  local listens="$1" dom alpn
  if [ "$listens" = 1 ]; then
    echo >&2
    echo -e "${C_B}  TLS certificate — how should this (listening) end get one?${C_N}" >&2
    echo -e "   1) Self-signed        ${C_G}(ANY port, no domain needed — easiest)${C_N}" >&2
    echo    "   2) Let's Encrypt auto (real CA; needs a domain + port 80/443 reachable)" >&2
    echo    "   3) Certificate files  (e.g. from certbot; any port)" >&2
    local cs; cs=$(ask 'Choice [1-3]' '1')
    case "$cs" in
      2)
        dom=$(ask 'Domain (SNI + certificate, e.g. tunnel.example.com)' '')
        while [ -z "$dom" ]; do warn "Let's Encrypt auto needs a domain." >&2; dom=$(ask 'Domain' ''); done
        TLSJSON="\"server_name\":\"$(jstr "$dom")\","
        local em; em=$(ask "Email for the Let's Encrypt account (blank = none)" '')
        [ -n "$em" ] && TLSJSON="$TLSJSON\"tls_auto_email\":\"$(jstr "$em")\","
        warn "Automatic certificate: '$dom' must resolve to THIS server and this tunnel must listen on port 443." >&2
        ;;
      3)
        dom=$(ask 'Domain on the certificate (SNI; blank = none)' '')
        [ -n "$dom" ] && TLSJSON="\"server_name\":\"$(jstr "$dom")\","
        local cert key
        cert=$(ask 'Path to certificate (full chain)' "/etc/letsencrypt/live/${dom:-example.com}/fullchain.pem")
        key=$(ask 'Path to private key' "/etc/letsencrypt/live/${dom:-example.com}/privkey.pem")
        TLSJSON="$TLSJSON\"tls_cert\":\"$(jstr "$cert")\",\"tls_key\":\"$(jstr "$key")\","
        ;;
      *)
        dom=$(ask 'SNI name to present (blank = default; a real-looking name blends in)' '')
        [ -n "$dom" ] && TLSJSON="\"server_name\":\"$(jstr "$dom")\","
        TLSJSON="$TLSJSON\"tls_selfsigned\":true,"
        info "Self-signed: this tunnel works on ANY port. On the OTHER end (the one that dials), keep the self-signed answer as yes." >&2
        ;;
    esac
  else
    dom=$(ask 'TLS SNI / domain (same as the other end; blank = none)' '')
    [ -n "$dom" ] && TLSJSON="\"server_name\":\"$(jstr "$dom")\","
    local si; si=$(ask 'Is the server certificate self-signed (not a public CA)? Y/n' 'Y')
    case "$si" in n|N) : ;; *) TLSJSON="$TLSJSON\"tls_insecure\":true," ;; esac
  fi
  alpn=$(ask 'ALPN (blank = h2,http/1.1, looks like a browser)' '')
  [ -n "$alpn" ] && TLSJSON="$TLSJSON\"alpn\":\"$(jstr "$alpn")\","
}

# yes_no QUESTION DEFAULT — true for a yes; Enter takes DEFAULT (y or n).
yes_no(){
  local a; a=$(ask "$1" "$2")
  case "$a" in y|Y|yes|YES|Yes) return 0 ;; n|N|no|NO|No) return 1 ;; esac
  case "$2" in y|Y) return 0 ;; *) return 1 ;; esac
}

# pick_fingerprint [CURRENT] — the browser the tls ClientHello imitates
# (tls_fingerprint). Enter keeps CURRENT (chrome when there is none).
pick_fingerprint(){
  local cur="${1:-chrome}" n d=1
  echo -e "  ${C_D}Which browser should the TLS handshake look like? (DPI fingerprints it)${C_N}" >&2
  echo    "   1) chrome   2) firefox   3) safari   4) edge   5) ios   6) random" >&2
  case "$cur" in firefox) d=2 ;; safari) d=3 ;; edge) d=4 ;; ios) d=5 ;; random|randomized) d=6 ;; esac
  n=$(ask "Fingerprint [1-6]" "$d")
  case "$n" in 2) echo firefox ;; 3) echo safari ;; 4) echo edge ;; 5) echo ios ;; 6) echo random ;; *) echo chrome ;; esac
}

# ask_reality_dest [CURRENT] — the real site reality borrows, as host:port.
# A bare host gets :443. Both ends must name the same site.
ask_reality_dest(){
  local v; v=$(ask "Real site to borrow (host:port, the SAME on both ends)" "${1:-www.microsoft.com:443}"); v="${v// /}"
  case "$v" in
    *:*[!0-9]*|*:) v="${v%%:*}:443" ;;   # "host:" or a non-numeric port
    *:*) : ;;
    *) v="$v:443" ;;
  esac
  echo "$v"
}

# stealth_extra ENC DIALS — the anti-DPI options of a stream tunnel, appended
# to TLSJSON: the site reality borrows; on the end that DIALS the browser
# fingerprint (tls) and the split ClientHello (tls, reality); and padding,
# which both ends must set alike.
stealth_extra(){
  local enc="$1" dials="$2"
  if [ "$enc" = reality ]; then
    echo -e "  ${C_D}reality shows a real site's HTTPS: no domain or certificate of your own. Anyone${C_N}" >&2
    echo -e "  ${C_D}probing the port is passed through to that real site.${C_N}" >&2
    TLSJSON="$TLSJSON\"reality_dest\":\"$(jstr "$(ask_reality_dest)")\","
  fi
  if [ "$dials" = 1 ]; then
    if [ "$enc" = tls ]; then
      TLSJSON="$TLSJSON\"tls_fingerprint\":\"$(pick_fingerprint)\","
    fi
    if [ "$enc" = tls ] || [ "$enc" = reality ]; then
      echo -e "  ${C_D}Fragment: split the TLS ClientHello so a DPI box cannot read the server name. Only this end.${C_N}" >&2
      yes_no "Fragment the ClientHello (tls_fragment)? y/N" n && TLSJSON="$TLSJSON\"tls_fragment\":true,"
    fi
  fi
  echo -e "  ${C_D}Padding: hides packet sizes and timing from pattern-based DPI. Costs a little bandwidth.${C_N}" >&2
  echo -e "  ${C_D}It MUST be the same on both ends.${C_N}" >&2
  yes_no "Add padding (pad)? y/N" n && TLSJSON="$TLSJSON\"pad\":true,"
  return 0
}

# socks_extra TRANSPORT NAME [CFG] — the relay's SOCKS5 + HTTP proxy, into
# SOCKSJSON. Each proxied connection names its own destination and is opened
# from the foreign server. A proxy without a login is offered only on
# localhost, unless the operator insists (strangers find open proxies fast).
socks_extra(){
  local tr="$1" name="$2" from="${3:-}"; SOCKSJSON=""
  [ "$tr" = tcpnomux ] && return 0
  local cport="" cuser="bn" cpass=""
  if [ -n "$from" ] && [ -n "$(jget "$from" socks)" ]; then
    cport="$(jget "$from" socks)"; cport="${cport##*:}"
    cuser="$(jget "$from" socks_user)"; cpass="$(jget "$from" socks_pass)"
  fi
  echo >&2
  echo -e "  ${C_D}Proxy mode: a SOCKS5 + HTTP proxy on this server; every site it opens goes out from the${C_N}" >&2
  echo -e "  ${C_D}foreign server. Users set it in their app or browser.${C_N}" >&2
  local port host=0.0.0.0 user pass
  while :; do
    port=$(ask "Proxy port" "${cport:-$(next_free_port 1080 tcp "$name")}"); port="${port// /}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && break
    warn "'$port' is not a port (1-65535)." >&2
  done
  user=$(ask "Proxy username ('-' = no login)" "${cuser:--}"); user="${user// /}"; [ "$user" = - ] && user=""
  if [ -n "$user" ]; then
    local tk; tk="$(gen_token)"; pass=$(ask "Proxy password" "${cpass:-${tk:0:12}}")
    SOCKSJSON="\"socks_user\":\"$(jstr "$user")\",\"socks_pass\":\"$(jstr "$pass")\","
  else
    echo -e "  ${C_D}Without a login, anyone who finds a public proxy port can use it.${C_N}" >&2
    local o; o=$(ask "Listen on  1) localhost only (safe)   2) every address, open to anyone" "1")
    if [ "$o" = 2 ]; then SOCKSJSON="\"socks_open\":true,"; else host=127.0.0.1; fi
  fi
  SOCKSJSON="\"socks\":\"$host:$port\",$SOCKSJSON"
}

pick_preset(){
  echo >&2
  echo -e "${C_B}  Connection preset:${C_N}" >&2
  echo    "   1) Optimized    balanced (Recommended)" >&2
  echo    "   2) High-Speed   max throughput" >&2
  echo    "   3) Stable       tolerate high packet loss" >&2
  echo    "   4) Low-Latency  gaming / VoIP" >&2
  echo    "   5) Eco          low CPU/RAM, weak VPS" >&2
  # "cancel" as $1 (a running tunnel): offer 0) Cancel as the default and print
  # nothing for it, so Enter never silently overwrites the current settings.
  local n
  if [ "${1:-}" = cancel ]; then
    echo    "   0) Cancel       keep the current settings" >&2
    n=$(ask "Choice [0-5]" "0")
    case "$n" in 1|2|3|4|5) : ;; *) return 0 ;; esac
  else
    n=$(ask "Choice [1-5]" "1")
  fi
  case "$n" in 2) echo "15 turbo 10 2";; 3) echo "8 fast 10 4";; 4) echo "5 gaming 10 4";; 5) echo "20 normal 10 1";; *) echo "10 fast 10 3";; esac
}

build_ports(){
  local arr=() spec proto sfx
  echo -e "${C_B}  Port mappings${C_N} ${C_D}(formats: 443 | 8443=443 ; empty to finish)${C_N}" >&2
  while true; do
    spec=$(ask "Port(s) (empty=done)" ""); spec="${spec// /}"; [ -z "$spec" ] && break
    # N or N=M, each 1-65535: anything else would be written into the config
    # and stop the tunnel from starting.
    local okp=1 part
    if [[ "$spec" =~ ^[0-9]+(=[0-9]+)?$ ]]; then
      for part in ${spec//=/ }; do [ "$part" -ge 1 ] && [ "$part" -le 65535 ] || okp=0; done
    else okp=0; fi
    if [ "$okp" = 0 ]; then warn "'$spec' is not a port mapping — use 443 or 8443=443 (1-65535)." >&2; continue; fi
    proto=$(ask "Protocol  1)tcp 2)udp 3)both" "3")
    case "$proto" in 1) sfx="";; 2) sfx="/udp";; *) sfx="/both";; esac
    arr+=("\"${spec}${sfx}\""); echo -e "${C_G}    added ${spec}${sfx}${C_N}" >&2
  done
  [ ${#arr[@]} -eq 0 ] && arr+=("\"443/both\""); ( IFS=,; echo "${arr[*]}" )
}

# jstr TEXT — TEXT escaped for use inside a JSON string. Typed answers
# (a token with a quote or a backslash in it, a header value) used to go into
# the config as they were, which left JSON the core could not parse.
jstr(){ local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v" | tr -d '\000-\037'; }
# jint VALUE DEFAULT — VALUE if it is a whole number, else DEFAULT (an answer
# like "auto" used to be written into the config as-is).
jint(){ case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac; }

# build_extra ROLE TRANSPORT [DIRECTION] asks the transport's own settings.
# Those that belong to the end that DIALS (ws request headers, the mtcp link
# count) go to the client in reverse mode and to the relay in direct mode.
build_extra(){ local role="$1" tr="$2" dir="${3:-reverse}" enc="${4:-}"; EXTRA=""; TLSJSON=""
  # Who dials vs. listens depends on BOTH mode and direction. The TLS certificate
  # belongs to the end that LISTENS (it presents it); the dialing end verifies it.
  # In reverse mode the server listens; in direct mode the client listens — so the
  # cert questions must follow who-listens, not the mode (this was the direct-mode
  # "tunnel won't connect" bug: the listening end got no certificate).
  local dials=0
  { [ "$role" = client ] && [ "$dir" = reverse ]; } || { [ "$role" = server ] && [ "$dir" = direct ]; } && dials=1
  if [ "$enc" = tls ]; then local lis=1; [ "$dials" = 1 ] && lis=0; tls_extra "$lis"; fi
  stealth_extra "$enc" "$dials"
  case "$tr" in
    ws)
      EXTRA="\"ws_path\":\"$(jstr "$(ask 'WebSocket path' '/')")\","
      if [ "$dials" = 1 ]; then
        local h u; h=$(ask 'Fake Host header (domain fronting, empty=none)' '')
        u=$(ask 'User-Agent (empty=default)' '')
        [ -n "$h" ] && EXTRA="$EXTRA\"ws_host\":\"$(jstr "$h")\","
        [ -n "$u" ] && EXTRA="$EXTRA\"ws_user_agent\":\"$(jstr "$u")\","
      fi ;;
    tcpnomux) EXTRA="\"pool_size\":$(jint "$(ask 'Connection pool size (0 = AUTO, scales with load — recommended)' '0')" 0),";;
    kcp)
      local w; w=$(ask 'KCP window for the whole tunnel, split across its links (packets, empty=1024)' '')
      w=$(jint "$w" ""); [ -n "$w" ] && EXTRA="\"kcp_sndwnd\":$w,\"kcp_rcvwnd\":$w," ;;
    mtcp) [ "$dials" = 1 ] && EXTRA="\"links\":$(jint "$(ask 'Parallel links (0 = AUTO, scales with load — recommended)' '0')" 0),";;
    sctp)
      local mh; mh=$(ask 'Extra local IPs for multihoming (comma-separated, blank = none)' '')
      local st; st=$(ask 'Outbound streams' '8')
      EXTRA="\"sctp_streams\":$(jint "$st" 8),"
      [ -n "$mh" ] && EXTRA="$EXTRA\"sctp_multihoming\":\"$(jstr "$mh")\","
      ;;
  esac
}

# check_bind warns when bind_addr names an address this machine does not have.
#
# This is the mistake operators actually make: bind_addr reads like "the address
# of my relay", so the server's PUBLIC ip goes in — and on a NAT'd VPS, which is
# most of them, that address lives on the provider's gateway and not here. The
# tunnel then dies at startup with the kernel's "cannot assign requested
# address", which says what failed and nothing about what to change.
#
# Returns the address to actually use: the operator's, or 0.0.0.0 when they take
# the offer. Never blocks — the operator may know something we do not, such as
# an address that appears later.
check_bind(){
  local addr="$1" host port
  host="${addr%:*}"; port="${addr##*:}"
  case "$host" in
    ""|"0.0.0.0"|"::"|"[::]"|"*") echo "$addr"; return ;;
  esac
  host="${host#[}"; host="${host%]}"
  command -v ip >/dev/null 2>&1 || { echo "$addr"; return; }
  if ip -o addr show 2>/dev/null | grep -qw "$host"; then
    echo "$addr"; return
  fi
  {
    echo
    warn "This machine has no interface holding $host."
    echo -e "  ${C_D}bind_addr is where this server LISTENS, so it must be an address it${C_N}"
    echo -e "  ${C_D}actually has. On a VPS behind NAT the public ip lives on the${C_N}"
    echo -e "  ${C_D}provider's gateway, not here, and the tunnel will fail to start.${C_N}"
    echo -e "  ${C_D}The public ip belongs in the OTHER end's remote_addr.${C_N}"
    echo
    echo -e "  ${C_D}addresses this machine does have:${C_N}"
    ip -o -4 addr show 2>/dev/null | awk '{print "    " $2 "  " $4}'
    ip -o -6 addr show scope global 2>/dev/null | awk '{print "    " $2 "  " $4}'
  } >&2
  local c; c=$(ask "Use 0.0.0.0:$port instead? Y/n" "Y") 
  case "$c" in n|N) echo "$addr" ;; *) echo "0.0.0.0:$port" ;; esac
}

# server_summary spells out which port is which after a relay is created.
#
# The two ports do completely different jobs and nothing on screen used to say
# so. An operator who reads bind_addr as "my relay's address" puts users on it,
# and nothing works — the tunnel is up, the service is up, and the traffic never
# meets either. That is a support cycle this prints away.
server_summary(){
  local bind="$1" portspec="$2" ip
  ip="$(detect_ip)"; ip="${ip:-YOUR-RELAY-IP}"
  local bport="${bind##*:}"
  echo
  if [ -z "$portspec" ]; then
    echo -e "  ${C_D}No port forwards. The FOREIGN server connects to ${C_N}$ip:$bport${C_D} — that is its remote_addr.${C_N}"
    return 0
  fi
  echo -e "  ${C_B}These two ports do different jobs — do not mix them up.${C_N}"
  echo
  echo -e "  ${C_G}Users / client configs connect to:${C_N}"
  local spec p
  # portspec is the JSON array body: "443/both","8443=443/udp"
  # printf with a trailing newline, and the '|| [ -n ]' guard: without both, the
  # LAST mapping is silently dropped, because read returns non-zero on a final
  # line that has no newline after it. A summary that quietly omits a port is
  # worse than no summary.
  printf '%s\n' "$portspec" | tr ',' '\n' | while read -r spec || [ -n "$spec" ]; do
    spec="${spec//\"/}"
    p="${spec%%=*}"; p="${p%%/*}"
    [ -n "$p" ] && echo -e "      ${C_Y}$ip:$p${C_N}"
  done
  echo
  echo -e "  ${C_D}The FOREIGN server connects to ${C_N}$ip:$bport${C_D} — that is its remote_addr.${C_N}"
  local ip6; ip6="$(detect_ip6)"
  [ -n "$ip6" ] && echo -e "  ${C_D}Over IPv6 (when IPv4 is filtered or unreliable) it can use ${C_N}[$ip6]:$bport${C_D} instead.${C_N}"
  echo -e "  ${C_D}Never point a user config at $bport: it is the tunnel itself, not your service.${C_N}"
  echo
  echo -e "  ${C_D}And on the FOREIGN server, your real service (xray, v2ray, ...) must be${C_N}"
  echo -e "  ${C_D}listening on the port each mapping delivers to — the right-hand side of${C_N}"
  echo -e "  ${C_D}\"8443=443\", or the same number when there is no \"=\".${C_N}"
}

# server_summary_direct is server_summary for a relay in direct mode: users
# still connect here, but the tunnel is dialed OUT to the foreign server, so
# no tunnel port is open on this machine.
server_summary_direct(){
  local remote="$1" portspec="$2" bproto="${3:-tcp}" ip spec p
  ip="$(detect_ip)"; ip="${ip:-YOUR-RELAY-IP}"
  echo
  echo -e "  ${C_G}Users / client configs connect to:${C_N}"
  printf '%s\n' "$portspec" | tr ',' '\n' | while read -r spec || [ -n "$spec" ]; do
    spec="${spec//\"/}"
    p="${spec%%=*}"; p="${p%%/*}"
    [ -n "$p" ] && echo -e "      ${C_Y}$ip:$p${C_N}"
  done
  echo
  echo -e "  ${C_D}Direct mode: this server CONNECTS to ${C_N}$remote${C_D} (${bproto^^}); no tunnel port is open here.${C_N}"
  echo -e "  ${C_D}On the FOREIGN server create the tunnel with direction ${C_N}direct${C_D}, listening on port ${C_N}${remote##*:}${C_D},${C_N}"
  echo -e "  ${C_D}and allow ${bproto^^} ${remote##*:} inbound in its firewall.${C_N}"
}

# socks_summary CFG — where to point a browser or an app at the relay's proxy.
socks_summary(){
  local s u pw ip; s="$(jget "$1" socks)"; [ -n "$s" ] || return 0
  u="$(jget "$1" socks_user)"; pw="$(jget "$1" socks_pass)"
  ip="$(detect_ip)"; ip="${ip:-YOUR-RELAY-IP}"
  echo
  echo -e "  ${C_G}Proxy (SOCKS5 and HTTP on the same port):${C_N}"
  case "$s" in
    127.0.0.1:*|localhost:*) echo -e "      ${C_Y}$s${C_N}  ${C_D}(this server only: apps on it, or an SSH tunnel)${C_N}" ;;
    *) echo -e "      ${C_Y}$ip:${s##*:}${C_N}"
       [ -n "$u" ] && echo -e "  ${C_D}  user:${C_N} $u   ${C_D}password:${C_N} $pw"
       echo -e "  ${C_D}  e.g. socks5://${u:+$u:$pw@}$ip:${s##*:}   — allow TCP ${s##*:} in this server's firewall.${C_N}" ;;
  esac
}

# write_tunnel_cfg writes the config for a point-to-point tunnel: the kernel
# tunnels (gre/gretap/ipip/sit/l2tp) and the raw carriers (udp/icmp). These do
# not bind a listen port like tcp — they need the two servers' real addresses
# and the addresses on the tunnel itself. The server also maps user ports across
# the tunnel; the client names the local backend.
write_tunnel_cfg(){
  # Two statements: in one 'local', $name would expand before it is assigned.
  local role="$1" name="$2" tr="$3" enc="$4"
  local cfg="$CFG_DIR/$name.json"
  echo
  echo -e "  ${C_D}$tr is a point-to-point tunnel. Give the two servers' real IPs and${C_N}"
  echo -e "  ${C_D}the private addresses to use on the tunnel (any unused /30 works).${C_N}"
  echo
  # The most common reason these "connect" and then carry almost nothing: the
  # foreign IP is filtered in Iran. A point-to-point tunnel needs the relay to
  # send straight to that IP, so it cannot work; the proxy transports (mtcp,
  # tcp, ws, kcp) have the FOREIGN server dial in, which often still does.
  warn "$tr needs the two servers to reach each other DIRECTLY, in both directions."
  echo -e "  ${C_D}If the foreign server's IP is filtered in Iran, $tr will not work (it may${C_N}"
  echo -e "  ${C_D}come up and then carry almost nothing). Check first, from the Iran server:${C_N}"
  echo -e "  ${C_D}    ping -c 5 <foreign-ip>     — 100% loss means filtered.${C_N}"
  echo -e "  ${C_D}In that case use ${C_N}mtcp${C_D} instead: the foreign server dials in to Iran.${C_N}"
  local go_on; go_on=$(ask "Continue with $tr? Y/n" "Y")
  case "$go_on" in n|N) warn "Cancelled."; return ;; esac
  local lip rip tl trr
  # The two servers reach each other over IPv4, or over IPv6 when IPv4 between
  # them is filtered or unreliable (gre, gretap, ipip, sit and l2tp run over
  # either; both ends must use the same). udp and icmp are IPv4 only.
  local fam=4 isfam=is_ipv4 myip
  case "$tr" in gre|gretap|ipip|sit|l2tp)
    local f6; f6=$(ask "Connect the two servers over  1) IPv4   2) IPv6 (when IPv4 is filtered or unreliable)" "1")
    if [ "$f6" = 2 ]; then
      fam=6; isfam=is_ipv6
      [ -z "$(detect_ip6)" ] && warn "This server has no global IPv6 address — IPv6 needs one on BOTH servers."
      info "Choose IPv6 on the other server too."
    fi ;;
  esac
  [ "$fam" = 6 ] && myip="$(detect_ip6)" || myip="$(detect_ip)"
  # Both are required addresses of that family (the core refuses anything
  # else): an empty or mistyped one used to be saved, and the tunnel then
  # failed at start.
  while :; do
    lip=$(ask "This server's real (public) IPv$fam" "$myip"); lip="${lip// /}"; lip="${lip#[}"; lip="${lip%]}"
    $isfam "$lip" && break; warn "'$lip' is not an IPv$fam address."
  done
  while :; do
    rip=$(ask "The OTHER server's real IPv$fam" ""); rip="${rip// /}"; rip="${rip#[}"; rip="${rip%]}"
    if ! $isfam "$rip"; then warn "'$rip' is not an IPv$fam address."
    elif [ "$rip" = "$lip" ]; then warn "That is this server's own IP — give the OTHER server's."
    else break; fi
  done
  # ipip and sit carry nothing that tells two tunnels between the same two
  # servers apart, so the kernel allows one of each per pair of IPs; a second
  # fails to start ("File exists"). Say so now rather than after the fact.
  case "$tr" in ipip|sit)
    if [ -n "$(peer_tunnels "$tr" "$rip" "$name")" ]; then
      warn "This server already has a $tr tunnel to $rip — the kernel allows only one."
      echo -e "  ${C_D}For another tunnel to the same server use gre (each with its own key), l2tp or udp.${C_N}"
    fi ;;
  esac
  # sit carries IPv6, so its tunnel addresses are IPv6 (a ULA pair); every
  # other point-to-point tunnel here uses an IPv4 pair.
  # A free pair: every tunnel on this server needs its own tunnel addresses,
  # or their routes collide and one tunnel takes the other's traffic.
  # Only the relay picks free values: it is the side that carries several
  # tunnels. The foreign server usually has one and cannot know what the relay
  # picked, so it offers the base values; the relay prints what to enter.
  local nn=30; [ "$role" = server ] && nn="$(bnpy alloc net "$name")"
  local a1=10.10.$nn.1 a2=10.10.$nn.2
  if [ "$tr" = sit ]; then
    a1=fd00:10:$nn::1 a2=fd00:10:$nn::2
    echo -e "  ${C_D}sit carries IPv6: the tunnel addresses below must be IPv6.${C_N}"
  fi
  tl=$(auto_or_ask "$role" "This end's tunnel address" "$([ "$role" = server ] && echo $a1 || echo $a2)")
  trr=$(auto_or_ask "$role" "The OTHER end's tunnel address" "$([ "$role" = server ] && echo $a2 || echo $a1)")
  local mtu; mtu=$(ask "MTU (blank = auto)" "")
  case "$mtu" in ""|*[!0-9]*) mtu=0 ;; esac

  # transport-specific extras
  local extra=""
  case "$tr" in
    gre|gretap)
      # The kernel tells gre tunnels between the same two IPs apart only by
      # their key: a second keyless one fails with "File exists". When this
      # server already has a gre/gretap tunnel to the same peer, offer a key
      # no other one uses (the other end must enter the same).
      local dk=0 k keys; keys=" $(gre_peer_keys "$tr" "$rip" "$name" | tr '\n' ' ') "
      if [ "$keys" != "  " ]; then
        dk=1; while [[ "$keys" == *" $dk "* ]]; do dk=$((dk+1)); done
        echo -e "  ${C_D}Another $tr tunnel to $rip exists here: this one needs its own key.${C_N}"
      fi
      k=$(auto_or_ask "$role" "GRE key (0 = none, same on both ends)" "$dk"); case "$k" in ''|*[!0-9]*) k=$dk ;; esac
      if [ "$k" != 0 ]; then
        extra="\"gre_key\": $k,"
      elif [[ "$keys" == *" 0 "* ]]; then
        warn "Another keyless $tr tunnel to $rip exists — this one will not start without a key."
      fi
      ;;
    l2tp)
      local tid sid en
      local dt=1000 ds=1000
      [ "$role" = server ] && { dt=$(bnpy alloc l2tpid "$name"); ds=$dt; }
      tid=$(auto_or_ask "$role" "Tunnel id (same on both ends)" "$dt")
      sid=$(auto_or_ask "$role" "Session id (same on both ends)" "$ds")
      en=$(ask "Encap  1)udp 2)ip" "1"); [ "$en" = 2 ] && en=ip || en=udp
      extra="\"l2tp_tunnel_id\": ${tid:-1000}, \"l2tp_session_id\": ${sid:-1000}, \"l2tp_encap\": \"$en\","
      if [ "$en" = udp ]; then
        # Over udp each l2tp tunnel on a server binds its own port: a second
        # one on a taken port fails with "Address already in use".
        local dlp=1701 lp; [ "$role" = server ] && dlp=$(bnpy alloc port udp "$name")
        lp=$(auto_or_ask "$role" "L2TP UDP port (same on both ends)" "$dlp"); case "$lp" in ''|*[!0-9]*) lp=$dlp ;; esac
        if [ "$lp" -lt 1 ] || [ "$lp" -gt 65535 ]; then warn "Port must be 1-65535; using $dlp"; lp=$dlp; fi
        extra="$extra \"l2tp_port\": $lp,"
      fi
      ;;
    udp|icmp)
      # Each tunnel on this server needs its own carrier port: a second udp
      # tunnel on a taken one cannot bind and will not start, and two icmp
      # tunnels with one identifier would receive each other's packets.
      local dcp=6262
      if [ "$role" = server ]; then
        if [ "$tr" = udp ]; then dcp=$(bnpy alloc port udp "$name"); else dcp=$(next_free_int "carrier_port:$tr" 6262 "$name"); fi
      fi
      local cport what="Carrier UDP port"; [ "$tr" = icmp ] && what="ICMP tunnel id"
      cport=$(auto_or_ask "$role" "$what (same on both ends)" "$dcp")
      case "$cport" in ''|*[!0-9]*) cport=$dcp ;; esac
      if [ "$cport" -lt 1 ] || [ "$cport" -gt 65535 ]; then warn "$what must be 1-65535; using $dcp"; cport=$dcp; fi
      extra="$extra\"carrier_port\": $cport,"
      ;;
  esac
  # Many paths drop GRE's own IP protocol (47; ipip 4, sit 41) while UDP
  # passes: the kernel can carry the same tunnel inside UDP (fou_port).
  case "$tr" in
    gre|gretap|ipip|sit)
      if is_ipv4 "$rip"; then
        echo -e "  ${C_D}Many paths (often inside Iran) drop $tr's own protocol but pass UDP.${C_N}"
        if yes_no "Carry the tunnel inside UDP (the same kernel $tr, in UDP packets)? y/N" n; then
          local dfp=5555 fp; [ "$role" = server ] && dfp=$(bnpy alloc port udp "$name")
          fp=$(auto_or_ask "$role" "UDP port for the tunnel (same on both ends)" "$dfp")
          case "$fp" in ''|*[!0-9]*) fp=$dfp ;; esac
          if [ "$fp" -lt 1 ] || [ "$fp" -gt 65535 ]; then warn "Port must be 1-65535; using $dfp"; fp=$dfp; fi
          extra="$extra \"fou_port\": $fp,"
        fi
      fi
      ;;
  esac

  local tokline=""; local token
  token=$(ask "Shared token (same on both ends)" "$(gen_token)")
  tokline="\"token\": \"$(jstr "$token")\","

  local portsjson=""
  if [ "$role" = server ]; then portsjson=$(ask_ports "$name") || return 1; fi

  new_cfg_file "$cfg"
  if [ "$role" = server ]; then
    cat > "$cfg" <<EOF
{
  "mode": "server",
  "transport": "$tr",
  "encryption": "$enc",
  $tokline
  "local_ip": "$lip",
  "remote_ip": "$rip",
  "tun_local": "$tl",
  "tun_remote": "$trr",
  "mtu": $mtu,
  $extra
  "ports": [$portsjson],
  "log_level": "info"
}
EOF
    core_check "$cfg" || return 1
    info "Saved $cfg"
  else
    local target tdef=127.0.0.1
    # sit delivers IPv6 straight to this host; the service must listen on [::].
    [ "$tr" = sit ] && tdef=::1
    target=$(ask "Local backend host" "$tdef")
    cat > "$cfg" <<EOF
{
  "mode": "client",
  "transport": "$tr",
  "encryption": "$enc",
  $tokline
  "local_ip": "$lip",
  "remote_ip": "$rip",
  "tun_local": "$tl",
  "tun_remote": "$trr",
  "target_host": "$(jstr "$target")",
  "mtu": $mtu,
  $extra
  "log_level": "info"
}
EOF
    info "Saved $cfg"
  fi
  core_check "$cfg" || return 1
  install_health
  start_tunnel_unit "$name"
  # The other end, as one paste: nothing to retype on the other server.
  show_pair_code "$name" 0
}

create_tunnel(){
  need_root; ensure_core || return; mkdir -p "$CFG_DIR"; harden_cfg_dir; write_template
  local role="$1" name tr enc ka kmode kdata kparity
  echo; info "Create ${role^^} tunnel"
  name=$(ask "Instance name" "main"); name="$(echo "$name" | tr -cd 'A-Za-z0-9_-')"; [ -z "$name" ] && name=main
  if [ -f "$CFG_DIR/$name.json" ]; then local o; o=$(ask "'$name' exists. Overwrite? y/N" "N"); case "$o" in y|Y) :;; *) warn "Cancelled."; return;; esac; fi
  tr=$(pick_transport)
  [ -z "$tr" ] && { warn "Cancelled."; return; }
  enc=$(pick_encryption "$tr")

  if is_tunnel_transport "$tr"; then
    write_tunnel_cfg "$role" "$name" "$tr" "$enc"
  else
    local dsel dir proxy=0; dsel=$(pick_direction "$tr"); dir="${dsel#proxy-}"; [ "$dsel" != "$dir" ] && proxy=1
    read -r ka kmode kdata kparity <<< "$(pick_preset)"; build_extra "$role" "$tr" "$dir" "$enc"
    local cfg="$CFG_DIR/$name.json"
    local bproto=tcp; [ "$tr" = kcp ] && bproto=udp
    if [ "$role" = server ]; then
      local bind="" remote="" addrline ports token qtotal qup qdown
      if [ "$dir" = direct ]; then
        # This relay dials out; nothing listens here but the user ports. The
        # foreign server's listen port is picked at random from a quiet range
        # so tunnels from several relays to one foreign server do not collide.
        local dport; dport=$(bnpy alloc port "$bproto" "$name")
        while [ -z "$remote" ]; do
          remote=$(ask_hostport "Foreign server IP (it will listen on port $dport)" "$dport")
          [ -z "$remote" ] && warn "Required: the foreign server's real IP (and the port it will listen on)."
        done
        addrline="\"remote_addr\": \"$remote\","
      else
        bind=$(ask "Tunnel listen address (host:port)" "0.0.0.0:$(next_free_port 8443 "$bproto" "$name")")
        bind="$(check_bind "$bind")"
        addrline="\"bind_addr\": \"$bind\","
      fi
      SOCKSJSON=""
      if [ "$proxy" = 1 ]; then
        socks_extra "$tr" "$name"
        ports=""
        echo -e "  ${C_D}No port forwards in proxy mode (add some later with 17 Port-forwards if you want both).${C_N}"
      else
        ports=$(ask_ports "$name") || return 1
      fi
      [ "$dir" = direct ] || warn_port_clash "" "$name" "${bind##*:}" "$bproto"
      token=$(ask "Shared token" "$(gen_token)")
      echo -e "  ${C_D}Traffic quota (optional) — leave blank for unlimited. Once reached, the${C_N}"
      echo -e "  ${C_D}tunnel refuses new connections and drops active ones until you raise it.${C_N}"
      qtotal=$(ask "  Total quota in GB (up+down combined, e.g. 1000 for 1TB)" "")
      qup=$(ask "  Upload quota in GB (leave blank if using total)" "")
      qdown=$(ask "  Download quota in GB (leave blank if using total)" "")
      # Keep only digits/decimal point so a stray non-numeric answer can never
      # produce invalid JSON; anything empty or not a plain number becomes 0
      # (unlimited).
      sanitize_gb(){ local v; v=$(printf '%s' "$1" | tr -cd '0-9.'); [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$v" || echo 0; }
      qtotal=$(sanitize_gb "$qtotal"); qup=$(sanitize_gb "$qup"); qdown=$(sanitize_gb "$qdown")
      new_cfg_file "$cfg"
    cat > "$cfg" <<EOF
{
  "mode": "server",
  "transport": "$tr",
  "encryption": "$enc",
  "token": "$(jstr "$token")",
  "direction": "$dir",
  $addrline
  "ports": [$ports],
  $TLSJSON$EXTRA$SOCKSJSON
  "keepalive": $ka,
  "kcp_mode": "$kmode", "kcp_data": $kdata, "kcp_parity": $kparity,
  "quota_total_gb": $qtotal, "quota_up_gb": $qup, "quota_down_gb": $qdown,
  "log_level": "info"
}
EOF
      core_check "$cfg" || return 1
      info "Saved $cfg"
      if [ "$dir" = direct ]; then server_summary_direct "$remote" "$ports" "$bproto"
      else server_summary "$bind" "$ports"; fi
      [ -n "$SOCKSJSON" ] && socks_summary "$cfg"
    else
      local remote="" bind="" addrline token target
      [ "$proxy" = 1 ] && info "Proxy mode: the proxy itself is set up on the Iran server; this server only needs the same direction ($dir)."
      if [ "$dir" = direct ]; then
        bind=$(ask "Listen address for the Iran server to connect to (host:port)" "0.0.0.0:$(next_free_port 8443 "$bproto" "$name")")
        bind="$(check_bind "$bind")"
        warn_port_clash "" "$name" "${bind##*:}" "$bproto"
        addrline="\"bind_addr\": \"$bind\","
      else
        while [ -z "$remote" ]; do
          remote=$(ask_hostport "Tunnel server address (Iran relay IP:port)" 8443)
          [ -z "$remote" ] && warn "Required: the Iran relay's real IP and its tunnel port."
        done
        addrline="\"remote_addr\": \"$remote\","
      fi
      token=$(ask "Shared token (same as server)" ""); target=$(ask "Local services host" "127.0.0.1")
      new_cfg_file "$cfg"
    cat > "$cfg" <<EOF
{
  "mode": "client",
  "transport": "$tr",
  "encryption": "$enc",
  "token": "$(jstr "$token")",
  "direction": "$dir",
  $addrline
  "target_host": "$(jstr "$target")",
  $TLSJSON$EXTRA
  "keepalive": $ka,
  "kcp_mode": "$kmode", "kcp_data": $kdata, "kcp_parity": $kparity,
  "log_level": "info"
}
EOF
      core_check "$cfg" || return 1
      info "Saved $cfg"
      if [ "$dir" = direct ]; then
        echo
        echo -e "  ${C_B}Direct mode:${C_N} the Iran server connects to this one on ${C_Y}${bproto^^} ${bind##*:}${C_N}."
        echo -e "  ${C_D}This server's firewall must allow that port inbound, e.g.${C_N}"
        echo -e "  ${C_D}  ufw allow ${bind##*:}/$bproto   or   iptables -I INPUT -p $bproto --dport ${bind##*:} -j ACCEPT${C_N}"
        echo -e "  ${C_D}On the Iran server enter:${C_N} ${C_Y}$(detect_ip):${bind##*:}${C_N}"
        [ -n "$(detect_ip6)" ] && echo -e "  ${C_D}or over IPv6:${C_N} ${C_Y}[$(detect_ip6)]:${bind##*:}${C_N}"
      fi
    fi
  fi

  install_health
  start_tunnel_unit "$name"
  # The other end, as one paste: nothing to retype on the other server.
  show_pair_code "$name" 0
}

# link_state reports the REAL connection state by looking at the most recent
# connect/disconnect event in the journal, rather than trusting systemd's notion
# of "active" (which only means the process is alive).
# diagnose runs the core's end-to-end check of one tunnel on this server
# (brokennode doctor): service, link, every port from the user's side to the
# service behind it, the firewall and NAT rules, with the fix for each problem.
diagnose(){
  local n="$1"
  echo
  "$BIN" doctor -c "$CFG_DIR/$n.json" 2>&1 | sed \
    -e "s/\[FAIL\]/$(printf '%b' "$C_R")[FAIL]$(printf '%b' "$C_N")/" \
    -e "s/\[WARN\]/$(printf '%b' "$C_Y")[WARN]$(printf '%b' "$C_N")/" \
    -e "s/\[OK\]/$(printf '%b' "$C_G")[OK]$(printf '%b' "$C_N")/"
  echo
  read -t 300 -rp "  ▶ press ENTER to continue... " _
}

# version_note prints a warning when the two ends of a running tunnel run
# different releases (the core swaps versions on every new link), else
# nothing. Fixes that need both ends are not in effect until they match.
version_note(){
  local lf="/run/brokennode/$1.live" ts now mine peer
  [ -f "$lf" ] || return
  ts=$(sed -n 's/^ts=//p' "$lf"); now=$(date +%s)
  case "$ts" in ""|*[!0-9]*) return;; esac
  [ $((now - ts)) -le 5 ] || return
  mine=$(sed -n 's/^version=//p' "$lf"); peer=$(sed -n 's/^peer_version=//p' "$lf")
  [ -n "$peer" ] && [ -n "$mine" ] && [ "$peer" != "$mine" ] || return
  [ "$peer" = older ] && peer="a release older than 2.8.6"
  echo -e "${C_Y}⚠ the other server runs ${peer}, this one ${mine} — update both to the same release${C_N}"
}

# ports_failed prints how many of a running relay's user ports are NOT being
# served (another program holds the port, ...), from the core's live
# snapshot; 0 when it cannot tell. The tunnel shows connected and passes its
# speed test regardless, so this is the only place that shows it.
ports_failed(){
  local lf="/run/brokennode/$1.live" ts now v
  [ -f "$lf" ] || { echo 0; return; }
  ts=$(sed -n 's/^ts=//p' "$lf"); now=$(date +%s)
  case "$ts" in ""|*[!0-9]*) echo 0; return;; esac
  [ $((now - ts)) -le 5 ] || { echo 0; return; }
  v=$(sed -n 's/^ports_failed=//p' "$lf")
  case "$v" in ""|*[!0-9]*) echo 0;; *) echo "$v";; esac
}

link_state(){
  local n="$1" last
  last="$(journalctl -u "brokennode@$n" -n 200 --no-pager -o cat 2>/dev/null \
          | grep -E '🟢 Connected|🔴 Disconnected|TUNNEL IS DOWN' | tail -1)"
  case "$last" in
    "")                 printf "%b" "${C_D}no events yet${C_N}" ;;
    *"TUNNEL IS DOWN"*) printf "%b" "${C_R}● no peer${C_N}" ;;
    *"🟢 Connected"*)   printf "%b" "${C_G}● connected${C_N}" ;;
    # mtcp closes links it no longer needs; the relay logs each one, with how
    # many are left. Links left means the tunnel is up.
    *"🔴 Disconnected"*" link(s) left"*)
      if [[ "$last" =~ ·\ ([0-9]+)\ link\(s\)\ left ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
        printf "%b" "${C_G}● connected${C_N}"
      else printf "%b" "${C_Y}● disconnected${C_N}"; fi ;;
    *"🔴 Disconnected"*) printf "%b" "${C_Y}● disconnected${C_N}" ;;
    *)                  printf "%b" "${C_D}unknown${C_N}" ;;
  esac
}

list_tunnels(){
  TUNNELS=()
  local f n st any=0 i=0
  echo; echo -e "${C_B}  Tunnels:${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue
    any=1; n="$(basename "$f" .json)"; i=$((i+1)); TUNNELS+=("$n")
    st="$(systemctl is-active "brokennode@$n" 2>/dev/null)"
    local m tr; m=$(grep -o '"mode"[^,]*' "$f" | sed 's/.*: *"//;s/".*//'); tr=$(grep -o '"transport"[^,]*' "$f" | sed 's/.*: *"//;s/".*//')
    local col="$C_R"; [ "$st" = active ] && col="$C_G"
    # "active" only means the SERVICE is running. It says nothing about whether
    # the tunnel actually has a peer — we lost hours to a tunnel that was
    # "active" while carrying no traffic at all. link_state reads the log to
    # report what really happened last.
    local link; link="$(link_state "$n")"
    # One read of the config for everything the two lines show.
    local dir listens addr ports
    IFS=$'\t' read -r dir listens addr ports < <(tunnel_summary "$f")
    [ "$dir" = direct ] && tr="$tr (direct)"
    printf "  %2d) %-14s ${col}%-8s${C_N} %-22s ${C_D}%s/%s${C_N}\n" "$i" "$n" "$st" "$link" "$m" "$tr"
    local pf; pf=$(ports_failed "$n")
    [ "$pf" -gt 0 ] && echo -e "      ${C_R}⚠ ${pf} port(s) NOT served — users of them get nothing. Open the tunnel → 18) Diagnose${C_N}"
    local vn; vn=$(version_note "$n"); [ -n "$vn" ] && echo -e "      $vn"
    # second line: address/port + psk (token), so both sides can be re-checked
    # against each other at a glance without opening the config file.
    local psk
    psk="$(sed -n 's/.*"token"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$f")"
    # Where this end listens or what it dials depends on the direction.
    local how="listen:"
    [ "$listens" = 0 ] && how="dials: "
    if [ "$m" = server ]; then
      printf "      ${C_D}%s %-22s ports: %-18s psk: %s${C_N}\n" "$how" "${addr:-?}" "${ports:-?}" "${psk:-?}"
    else
      printf "      ${C_D}%s %-22s psk: %s${C_N}\n" "$how" "${addr:-?}" "${psk:-?}"
    fi
  done
  [ "$any" = 0 ] && echo -e "   ${C_D}(no tunnels yet)${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
}

hb(){ # humanize bytes -> KB/MB/GB/TB
  local b="${1:-0}"; awk -v b="$b" 'BEGIN{
    u="B"; x=b+0;
    if(x>=1024){x/=1024;u="KB"} if(x>=1024){x/=1024;u="MB"} if(x>=1024){x/=1024;u="GB"} if(x>=1024){x/=1024;u="TB"}
    if(u=="B")printf "%d%s",x,u; else printf "%.2f%s",x,u }'
}

# live_logs: follow ONLY the current run (since last start), live, and let Ctrl+C
# return to the menu instead of killing the whole script.
live_logs(){
  local n="$1" unit="brokennode@$1"
  echo -e "${C_B}  Live logs: $n${C_N}   ${C_D}(Ctrl+C = back to menu)${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
  local since; since="$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)"
  trap ':' INT   # catch Ctrl+C here so the script is NOT terminated
  if [ -n "$since" ] && [ "$since" != "n/a" ]; then
    journalctl -u "$unit" -f --since "$since" -o short-precise 2>/dev/null
  else
    journalctl -u "$unit" -f -n 0 -o short-precise 2>/dev/null
  fi
  trap - INT     # restore
  echo -e "\n${C_G}  ← back to menu${C_N}"; sleep 0.3
}

# hr_rate BYTES_PER_SEC -> "12.4 Mbit/s" (network speeds are quoted in bits).
hr_rate(){
  awk -v b="${1:-0}" 'BEGIN{ x=b*8; u="bit/s";
    if(x>=1000){x/=1000;u="Kbit/s"} if(x>=1000){x/=1000;u="Mbit/s"} if(x>=1000){x/=1000;u="Gbit/s"}
    if(u=="bit/s")printf "%d %s",x,u; else printf "%.1f %s",x,u }'
}

# stats_page: live traffic for one tunnel, redrawn IN PLACE once a second.
#
# It used to clear the screen and redraw every 2 seconds from the 30-second
# lifetime file, which only the Iran relay writes: on the foreign server, and
# for gre/ipip/l2tp/udp/icmp whose traffic never passes a user socket, that file
# never existed, so the page flashed "No stats yet" for ever. The core (2.3.9+)
# now writes /run/brokennode/<name>.live every second on BOTH ends for EVERY
# transport; this page turns two samples into a speed. Any key or Ctrl+C
# returns to the menu.
stats_page(){
  local n="$1" unit="brokennode@$1" lf="/run/brokennode/$1.live" sf="/var/lib/brokennode/$1.stats"
  local leave=0 key k
  local pts=0 pup=0 pdown=0 rup=0 rdown=0 mup=0 mdown=0 hist=()
  trap 'leave=1' INT
  # The header is drawn once; each frame is then drawn from a fixed row
  # below it. (Saving and restoring the cursor broke on a short terminal:
  # the first frame scrolled the screen and every later one landed higher.)
  local hdr
  hdr="$(banner; echo -e "${C_B}  Live stats: $n${C_N}   ${C_D}(any key or Ctrl+C = back)${C_N}"; echo -e "  ${C_D}──────────────────────────────────────────────${C_N}")"
  clear 2>/dev/null || true
  printf '%s\n' "$hdr"
  local top; top=$(printf '%s\n' "$hdr" | wc -l)
  tput civis 2>/dev/null   # no blinking cursor jumping around
  while [ "$leave" -eq 0 ]; do
    local out="" st; st=$(systemctl is-active "$unit" 2>/dev/null); [ -z "$st" ] && st=unknown
    local now; now=$(date +%s)
    declare -A L=()
    if [ -f "$lf" ]; then
      # Every key but these few is a counter used in $(( )), where bash would
      # evaluate anything else as an expression: keep only plain numbers.
      while IFS='=' read -r k v; do
        [[ "$k" =~ ^[a-z_]+$ ]] || continue
        case "$k" in dev|role|src|transport) : ;; *) [[ "$v" =~ ^[0-9]+$ ]] || v=0 ;; esac
        L[$k]="$v"
      done < "$lf"
    fi
    local ts="${L[ts]:-0}"; case "$ts" in ""|*[!0-9]*) ts=0 ;; esac; local age=$(( now - ts ))
    if [ "$st" != active ]; then
      out+="    Service: ${C_R}${st}${C_N} — the tunnel is not running. Start it from this menu.\n"
      pts=0
    elif [ ! -f "$lf" ] || [ "$age" -gt 5 ]; then
      out+="    Service: ${C_G}active${C_N}\n"
      if [ ! -f "$lf" ] && [ -f "$sf" ]; then
        out+="    ${C_Y}The running core is older than this manager and has no live counters.${C_N}\n"
        out+="    ${C_D}Update (main menu → Update) and restart the tunnel for live speeds.${C_N}\n"
        out+="    Lifetime traffic: $(hb "$(sed -n 's/^life_total=//p' "$sf")")\n"
      else
        out+="    ${C_Y}Waiting for the core's first counters…${C_N}\n"
        out+="    ${C_D}(If this stays, the core is older than 2.3.9: update, then restart.)${C_N}\n"
      fi
    else
      local up="${L[up]:-0}" down="${L[down]:-0}"
      if [ "$pts" -gt 0 ] && [ "$ts" -gt "$pts" ]; then
        local dt=$(( ts - pts ))
        rup=$(( (up - pup) / dt )); rdown=$(( (down - pdown) / dt ))
        [ "$rup" -lt 0 ] && rup=0; [ "$rdown" -lt 0 ] && rdown=0
        [ "$rup" -gt "$mup" ] && mup=$rup; [ "$rdown" -gt "$mdown" ] && mdown=$rdown
        # a 40-second picture of the download speed, scaled to its own peak
        local bars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █) lvl=0
        [ "$mdown" -gt 0 ] && lvl=$(( rdown * 7 / mdown ))
        hist+=("${bars[$lvl]}"); [ "${#hist[@]}" -gt 40 ] && hist=("${hist[@]: -40}")
      fi
      if [ "$ts" -gt "$pts" ]; then pts=$ts; pup=$up; pdown=$down; fi
      local role="foreign server"; [ "${L[role]:-}" = server ] && role="Iran relay"
      local upt=$(( now - ${L[started]:-$now} ))
      out+="    Service: ${C_G}active${C_N}   ${role} · ${L[transport]:-}   up $(printf '%dh%02dm%02ds' $((upt/3600)) $((upt%3600/60)) $((upt%60)))\n"
      if [ "${L[src]:-}" = dev ]; then
        local dst="gone"; [ -n "${L[dev]:-}" ] && dst=$(cat "/sys/class/net/${L[dev]:-}/operstate" 2>/dev/null || echo gone)
        # Tunnel devices have no carrier to report and say "unknown" while up.
        if [ "$dst" = unknown ]; then
          local fl; fl=$(cat "/sys/class/net/${L[dev]:-}/flags" 2>/dev/null)
          [ -n "$fl" ] && [ $(( fl & 1 )) -eq 1 ] && dst=up
        fi
        out+="    Device : ${L[dev]:-none yet} (${dst})\n"
      else
        local lk="${L[links]:--1}"
        if [ "$lk" -gt 0 ]; then out+="    Links  : ${C_G}${lk} up${C_N}\n"
        elif [ "$lk" -eq 0 ]; then out+="    Links  : ${C_R}0 up — not connected to the other server${C_N}\n"; fi
      fi
      out+="  ${C_D}──────────────────────────────────────────────${C_N}\n"
      out+="    ${C_B}Speed now${C_N}    ↓ download $(hr_rate "$rdown")   ↑ upload $(hr_rate "$rup")\n"
      out+="    ${C_D}Peak here${C_N}    ↓ $(hr_rate "$mdown")   ↑ $(hr_rate "$mup")\n"
      out+="    ${C_D}↓ history${C_N}    $(printf '%s' "${hist[@]}")\n"
      out+="    ${C_B}This run${C_N}     ↓ $(hb "$down")   ↑ $(hb "$up")   total $(hb $(( up + down )))\n"
      if [ -n "${L[life_up]:-}" ]; then
        out+="    ${C_B}Lifetime${C_N}     ↓ $(hb "${L[life_down]:-}")   ↑ $(hb "${L[life_up]:-}")   ${C_D}(survives restarts)${C_N}\n"
      fi
      if [ "${L[src]:-}" != dev ]; then
        out+="    Users now    $(( ${L[active_tcp]:-0} + ${L[active_udp]:-0} ))  (tcp ${L[active_tcp]:-0}, udp ${L[active_udp]:-0})   peak ${L[peak]:-0} · total ${L[conns]:-0}\n"
      else
        out+="    ${C_D}Kernel/packet tunnel: speeds are the tunnel device's own counters.${C_N}\n"
      fi
    fi
    # Redraw over the previous frame instead of clearing: no flashing. Only
    # as many lines as the terminal has room for, so nothing ever scrolls.
    local rows; rows=$(tput lines 2>/dev/null || echo 40)
    local room=$(( rows - top - 1 )); [ "$room" -lt 3 ] && room=3
    tput cup "$top" 0 2>/dev/null || printf '\033[%d;1H' $(( top + 1 ))
    printf '%b' "$out" | head -n "$room" | sed 's/$/\x1b[K/'
    printf '\033[J'
    unset L
    # Waits one second, or returns at once on a key press.
    if [ -t 0 ]; then
      if read -rsn1 -t 1 key 2>/dev/null; then
        leave=1
        # An arrow or function key is several bytes: take the rest too, or
        # the menu reads them next and answers "Invalid."
        while read -rsn1 -t 0.05 key 2>/dev/null; do :; done
      fi
    else
      leave=1   # no terminal to watch or to press a key on: one frame
    fi
  done
  tput cnorm 2>/dev/null
  trap - INT
  echo -e "\n${C_G}  ← back to menu${C_N}"; sleep 0.3
}

# speed_test NAME: ping, jitter, download and upload THROUGH the tunnel, with
# its own transport (core: `brokennode speedtest`). The numbers are what the
# users get, so running it on each transport shows which one suits this path.
# Every result is kept in $CFG_DIR/.speedtests, and the last ones are listed
# side by side for comparison.
speed_test(){
  local n="$1" cfg="$CFG_DIR/$1.json" histf="$CFG_DIR/.speedtests"
  local tr role; tr="$(jget "$cfg" transport)"; role="$(jget "$cfg" mode)"
  echo
  echo -e "${C_B}  Speed test: $n  (${tr})${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
  local cv; cv="$(core_version "$BIN")"
  if [ -n "$cv" ] && version_lt "$cv" 2.3.9; then
    warn "The installed core ($cv) has no speed test — update (main menu → Update) first."
    return
  fi
  if [ "$(systemctl is-active "brokennode@$n" 2>/dev/null)" != active ]; then
    warn "The tunnel is not running — start it first (option 1)."
    return
  fi
  case "$tr" in
    gre|gretap|ipip|sit|l2tp|udp|icmp) : ;;
    *) if [ "$role" != server ]; then
         warn "For $tr the test runs on the Iran relay (the server that forwards the users' ports)."
         echo -e "  ${C_D}Its tunnel opens the test streams and this server answers them. Open this menu there.${C_N}"
         return
       fi ;;
  esac
  # The path itself, outside the tunnel: the floor the tunnel is measured against.
  local peer; peer="$(jget "$cfg" remote_ip)"
  [ -z "$peer" ] && { peer="$(jget "$cfg" remote_addr)"; peer="${peer%:*}"; peer="${peer#[}"; peer="${peer%]}"; }
  local pavg="" ploss=""
  if [ -n "$peer" ] && command -v ping >/dev/null 2>&1; then
    echo -e "  ${C_D}Path to $peer outside the tunnel (10 pings)…${C_N}"
    local pres; pres="$(ping -c 10 -i 0.2 -w 6 "$peer" 2>/dev/null | tail -2)"
    ploss="$(printf '%s' "$pres" | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')"
    pavg="$(printf '%s' "$pres" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')"
    if [ -n "$pavg" ]; then echo "  path   ping ${pavg}ms   loss ${ploss}%"
    else echo -e "  ${C_D}  (the other server does not answer ping — fine, the test below does not need it)${C_N}"; fi
  fi
  local secs streams
  secs=$(ask "Seconds per direction (3-30)" "10"); case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  streams=$(ask "Parallel streams (1 = one user, 8 = many users)" "4"); case "$streams" in ''|*[!0-9]*) streams=4 ;; esac
  echo
  local out ttyf=""
  [ -t 2 ] && ttyf=-tty
  out="$("$BIN" speedtest -c "$cfg" -t "$secs" -p "$streams" $ttyf 2>&1 | tee /dev/stderr)"
  local res; res="$(printf '%s\n' "$out" | sed -n 's/.*RESULT //p' | tail -n 1)"
  if [ -z "$res" ]; then
    echo; warn "No result — see the message above."
    return
  fi
  local tping tjit down up
  tping="$(printf '%s' "$res" | sed -n 's/.*ping=\([0-9.]*\)ms.*/\1/p')"
  tjit="$(printf '%s' "$res" | sed -n 's/.*jitter=\([0-9.]*\)ms.*/\1/p')"
  down="$(printf '%s' "$res" | sed -n 's/.*down=\([0-9.]*\)Mbit.*/\1/p')"
  up="$(printf '%s' "$res" | sed -n 's/.*up=\([0-9.]*\)Mbit.*/\1/p')"
  echo
  echo -e "  ${C_B}Result${C_N}  ↓ ${C_G}${down} Mbit/s${C_N}   ↑ ${C_G}${up} Mbit/s${C_N}   ping ${tping}ms   jitter ${tjit}ms"
  # What the numbers say.
  if [ -n "$pavg" ]; then
    local extra; extra=$(awk -v a="$tping" -v b="$pavg" 'BEGIN{printf "%.0f", a-b}')
    if [ "$extra" -gt 30 ]; then warnln "The tunnel adds ${extra}ms over the bare path — the tunnel or its links are queueing. Try mtcp or tcpnomux."
    else okln "The tunnel adds ${extra}ms over the bare path."; fi
    if awk -v l="${ploss:-0}" 'BEGIN{exit !(l > 2)}'; then warnln "The path loses ${ploss}% of packets: kcp or udp copes with loss best."; fi
  fi
  if awk -v d="$down" 'BEGIN{exit !(d < 20)}'; then
    warnln "Low speed: run the test again with another transport (option 9) and compare below."
  fi
  if awk -v j="$tjit" 'BEGIN{exit !(j > 20)}'; then warnln "High jitter: games and calls will feel it. Try the udp transport or the gaming profile."; fi
  local dir; dir="$(jget "$cfg" direction)"
  printf '%s %s %s %s down=%s up=%s ping=%s jitter=%s streams=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$n" "$tr" "${dir:-reverse}" \
    "$down" "$up" "$tping" "$tjit" "$streams" >> "$histf" 2>/dev/null
  tail -n 200 "$histf" > "$histf.tmp" 2>/dev/null && mv "$histf.tmp" "$histf"
  echo
  echo -e "  ${C_B}Recent results${C_N} ${C_D}(all tunnels on this server — compare transports)${C_N}"
  printf "  %-16s %-12s %-9s %9s %9s %8s %7s\n" "when" "tunnel" "transport" "↓ Mbit" "↑ Mbit" "ping" "jitter"
  tail -n 8 "$histf" | while read -r d t nm tt dir dn u p j st; do
    printf "  %-16s %-12s %-9s %9s %9s %8s %7s\n" "$d $t" "$nm" "$tt" "${dn#down=}" "${u#up=}" "${p#ping=}" "${j#jitter=}"
  done
}

okln(){   echo -e "  ${C_G}✔${C_N} $*"; }
warnln(){ echo -e "  ${C_Y}▲${C_N} $*"; }
badln(){  echo -e "  ${C_R}✗${C_N} $*"; }

# doctor_dial REMOTE TRANSPORT — for the end that dials: can the other end be
# reached, and how good is the path (loss, RTT, jitter)? Adds to the caller's
# warns count.
doctor_dial(){
  local remote="$1" trans="$2" host port=""
  case "$remote" in
    *:*) host="${remote%:*}"; port="${remote##*:}" ;;
    *)   host="$remote" ;;   # no port given: only the path can be checked
  esac
  host="${host#[}"; host="${host%]}"
  [ -z "$host" ] && { warnln "  no remote_addr to check"; warns=$((warns+1)); return; }
  # A TCP carrier can be probed directly; kcp runs over UDP and sctp
  # over its own protocol, where a TCP probe says nothing, so for them only
  # the ping below speaks.
  case "$trans" in
  kcp|sctp) : ;;
  *)
    if [ -n "$port" ] && command -v timeout >/dev/null 2>&1; then
      if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        okln "  $host:$port accepts connections"
      else
        badln "  cannot connect to $host:$port — is the other end running and listening, and is the port open in its firewall?"
        warns=$((warns+1))
      fi
    fi ;;
  esac
  # 20 probes, not 5: jitter is the number that decides whether hit
  # registration feels right, and five samples cannot show a distribution.
  local pres; pres="$(ping -c 20 -i 0.2 -w 10 "$host" 2>/dev/null | tail -2)"
  local loss rtt jit
  loss="$(printf '%s' "$pres" | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')"
  rtt="$(printf '%s' "$pres" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')"
  # mdev, the last field of ping's rtt summary, is the jitter.
  jit="$(printf '%s' "$pres" | sed -n 's#.*= [0-9.]*/[0-9.]*/[0-9.]*/\([0-9.]*\) ms#\1#p')"
  if [ -n "$loss" ]; then
    if awk "BEGIN{exit !(${loss:-0} > 3)}"; then warnln "  packet loss to $host: ${loss}% (high — hurts speed/latency)"; warns=$((warns+1));
    else okln "  packet loss to $host: ${loss}%"; fi
    [ -n "$rtt" ] && echo -e "  ${C_D}    avg RTT: ${rtt} ms${C_N}"
    if [ -n "$jit" ]; then
      # A steady 80ms beats 60ms that swings by 30. The server's lag
      # compensation assumes your delay is predictable; jitter is what
      # breaks that assumption, and it is what players feel as a shot
      # that hit but did not register.
      if awk "BEGIN{exit !(${jit:-0} > 15)}"; then
        warnln "  jitter to $host: ${jit} ms (high — this is what breaks hit registration)"; warns=$((warns+1))
      elif awk "BEGIN{exit !(${jit:-0} > 5)}"; then
        echo -e "  ${C_Y}    jitter: ${jit} ms (noticeable in fast games)${C_N}"
      else
        echo -e "  ${C_D}    jitter: ${jit} ms (steady)${C_N}"
      fi
    fi
  else warnln "  could not ping $host (ICMP blocked?)"; fi
}

# doctor: one-shot self-diagnosis of the things that actually break tunnels
# (BBR, ports, UDP reachability, public IP, packet loss, MTU, services).
doctor(){
  banner
  echo -e "${C_B}  BrokenNode Doctor${C_N}   ${C_D}(read-only checks)${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
  local warns=0

  # Congestion control (BBR)
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [ "$cc" = bbr ]; then okln "Congestion control: bbr"
  else warnln "Congestion control: ${cc:-unknown} — run 'sudo bash $SELF tune' for BBR"; warns=$((warns+1)); fi
  # qdisc
  local qd; qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  [ "$qd" = fq ] && okln "Queue discipline: fq" || { warnln "Queue discipline: ${qd:-unknown} (fq recommended)"; warns=$((warns+1)); }

  # Public IP
  local ip; ip="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)"
  [ -z "$ip" ] && ip="$(curl -s --max-time 6 https://ipinfo.io/ip 2>/dev/null)"
  if printf '%s' "$ip" | grep -qE '^[0-9a-fA-F:.]+$' && printf '%s' "$ip" | grep -qE '[0-9]'; then
    okln "Public IP: $ip"
  else
    warnln "Public IP: could not determine (network/DNS?)"; warns=$((warns+1))
  fi

  # FD limit
  local fd; fd="$(ulimit -n)"
  okln "Open-file limit (ulimit -n): $fd"

  # Leftover ICMP-echo suppression. An icmp tunnel turns the kernel's ping
  # responder off while it runs; a release before 2.3.13 (or a hard kill) could
  # leave it off for good, so the server answers no pings even after the tunnel
  # is gone or switched to another transport. If it is off here but NO configured
  # tunnel is icmp, that is a leftover — turn it back on so the host pings again.
  local echoOff; echoOff="$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)"
  if [ "$echoOff" = 1 ]; then
    local hasICMP=0
    for cf in "$CFG_DIR"/*.json; do
      [ -e "$cf" ] || continue
      [ "$(jget "$cf" transport)" = icmp ] && hasICMP=1 && break
    done
    if [ "$hasICMP" = 1 ]; then
      okln "ICMP echo responder off (an icmp tunnel is running — expected)"
    else
      sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
      warnln "ICMP echo was disabled with no icmp tunnel configured — a leftover from an older run. Re-enabled it, so this server answers pings again."
      warns=$((warns+1))
    fi
  fi

  echo -e "  ${C_D}── per-tunnel ─────────────────────────────────${C_N}"
  shopt -s nullglob
  local found=0
  for cf in "$CFG_DIR"/*.json; do
    found=1
    local n; n="$(basename "$cf" .json)"
    local mode trans bind remote ports
    mode="$(sed -n 's/.*"mode"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$cf")"
    trans="$(sed -n 's/.*"transport"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$cf")"
    bind="$(sed -n 's/.*"bind_addr"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$cf")"
    remote="$(sed -n 's/.*"remote_addr"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$cf")"
    echo -e "  ${C_B}• $n${C_N} ${C_D}($mode/$trans)${C_N}"
    # service state
    local st; st="$(systemctl is-active "brokennode@$n" 2>/dev/null)"
    [ "$st" = active ] && okln "  service: active" || { badln "  service: $st"; warns=$((warns+1)); }

    # Point-to-point tunnels (gre, ipip, udp, icmp ...) have no bind/remote
    # address to check. What decides whether they work is whether the two real
    # IPs reach each other at all — the case that fails silently when the
    # foreign IP is filtered in Iran — and then whether the peer answers on the
    # tunnel itself. Test both, and say which one broke.
    if is_tunnel_transport "$trans"; then
      local rip tr_ip dev
      rip="$(jget "$cf" remote_ip)"; tr_ip="$(jget "$cf" tun_remote)"
      # The running core records the device it created; read that rather than
      # re-deriving the name (per-tunnel, hashed when long). Without a record
      # (an older core, or /run wiped) find the interface holding this
      # tunnel's own address; if none does, the tunnel is not running.
      dev="$(head -n 1 "/run/brokennode/$n.dev" 2>/dev/null)"  # device, then PID
      [ -z "$dev" ] && dev="$(jget "$cf" tun_name)"
      if [ -z "$dev" ]; then
        local tl; tl="$(jget "$cf" tun_local)"
        [ -n "$tl" ] && dev="$(ip -o addr show 2>/dev/null | awk -v a="$tl/" 'index($4,a)==1{print $2; exit}')"
        dev="${dev%%@*}"
      fi
      [ -z "$dev" ] && dev="(not running)"
      if ip link show "$dev" >/dev/null 2>&1; then okln "  interface $dev: up"
      else badln "  interface $dev: missing (tunnel not running?)"; warns=$((warns+1)); fi
      if ! command -v ping >/dev/null 2>&1; then
        # Without ping there is no measurement. Reporting that as "100% loss"
        # would tell the operator their peer is filtered when nothing was tested.
        warnln "  ping is not installed — cannot test the peer (apt install iputils-ping)"
        warns=$((warns+1)); continue
      fi
      # An icmp tunnel IS ping: its server end turns off the kernel's echo
      # responder while it runs (otherwise the kernel would answer the tunnel's
      # own packets), so that server does not reply to a normal ping. A failed
      # ping to it is expected, not a fault, so skip the ping asserts for icmp.
      if [ "$trans" = icmp ]; then
        echo -e "  ${C_D}icmp carries traffic inside ping; the server end does not answer normal${C_N}"
        echo -e "  ${C_D}ICMP echo while running, so a failed ping to it here is expected.${C_N}"
        continue
      fi
      local l1 l2
      l1="$(ping -c 10 -i 0.2 -W 2 "$rip" 2>/dev/null | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')"
      l2="$(ping -c 10 -i 0.2 -W 2 "$tr_ip" 2>/dev/null | sed -n 's/.*, \([0-9.]*\)% packet loss.*/\1/p')"
      if [ -z "$l1" ]; then
        warnln "  peer $rip: ping failed to run (no route to it?)"; warns=$((warns+1))
      elif [ "$l1" = 100 ]; then
        badln "  peer $rip: NOT reachable directly (100% loss)"
        echo -e "  ${C_Y}    The other server's IP does not answer at all — most often it is filtered.${C_N}"
        echo -e "  ${C_Y}    $trans cannot work like that. Use mtcp instead (the foreign server dials in).${C_N}"
        warns=$((warns+1))
      elif awk "BEGIN{exit !(${l1:-0} > 3)}"; then
        warnln "  peer $rip: ${l1}% loss directly (high)"; warns=$((warns+1))
      else okln "  peer $rip: reachable directly (${l1}% loss)"; fi
      if [ -z "$l2" ]; then
        warnln "  tunnel peer $tr_ip: ping failed to run (no route to it?)"; warns=$((warns+1))
      elif [ "$l2" = 100 ]; then
        badln "  tunnel peer $tr_ip: no answer through the tunnel"; warns=$((warns+1))
        if [ -n "$l1" ] && [ "$l1" != 100 ]; then
          echo -e "  ${C_Y}    The IP answers but the tunnel does not: is the other side running, with the addresses swapped?${C_N}"
          case "$trans" in gre|gretap|ipip|sit)
            if [ "$(jget "$cf" fou_port)" = "" ] || [ "$(jget "$cf" fou_port)" = 0 ]; then
              echo -e "  ${C_Y}    If both sides are right, the path drops $trans's own protocol (gre is IP protocol 47): many do,${C_N}"
              echo -e "  ${C_Y}    while UDP passes. Carry the tunnel inside UDP: Manage tunnels → $n → tune → fou_port.${C_N}"
            fi ;;
          esac
        fi
      else okln "  tunnel peer $tr_ip: answers through the tunnel (${l2}% loss)"; fi
      continue
    fi

    # The end that listens checks its port; the end that dials checks the
    # path to the other end. Which is which depends on the direction.
    local dir; dir="$(tunnel_direction "$cf")"
    [ "$dir" = direct ] && echo -e "  ${C_D}  direction: direct (the Iran server dials the foreign server)${C_N}"
    if [ "$(transport_family "$trans")" != stream ]; then
      : # no listen port and no dial address to check
    elif tunnel_listens "$cf"; then
      local port; port="${bind##*:}"
      if [ -n "$port" ]; then
        ss -ltnup 2>/dev/null | grep -q ":$port " && okln "  listening on port $port" || { warnln "  port $port not listening"; warns=$((warns+1)); }
      fi
    else
      doctor_dial "$remote" "$trans"
    fi
    if [ "$mode" = server ]; then
      # Traffic quota status.
      local qtot qup qdown
      qtot="$(sed -n 's/.*"quota_total_gb"[ ]*:[ ]*\([0-9.]*\).*/\1/p' "$cf")"
      qup="$(sed -n 's/.*"quota_up_gb"[ ]*:[ ]*\([0-9.]*\).*/\1/p' "$cf")"
      qdown="$(sed -n 's/.*"quota_down_gb"[ ]*:[ ]*\([0-9.]*\).*/\1/p' "$cf")"
      if awk "BEGIN{exit !(${qtot:-0}>0 || ${qup:-0}>0 || ${qdown:-0}>0)}"; then
        local sf="/var/lib/brokennode/$n.stats" lu ld
        lu="$(sed -n 's/^life_up=//p' "$sf" 2>/dev/null)"; ld="$(sed -n 's/^life_down=//p' "$sf" 2>/dev/null)"
        lu="${lu:-0}"; ld="${ld:-0}"
        # gb_to_bytes converts a possibly-FRACTIONAL GB value to whole bytes via
        # awk. Bash integer arithmetic cannot do this: "${q%.*}" truncated 0.5 to
        # 0 (making every tunnel look over quota) and 1.5 to 1, and blew up on an
        # empty value. The core enforces fractional quotas correctly, so the
        # report has to agree with it.
        gb_to_bytes(){ awk -v g="${1:-0}" 'BEGIN{printf "%d", g*1073741824}'; }
        if awk "BEGIN{exit !(${qtot:-0}>0)}"; then
          local cap; cap=$(gb_to_bytes "$qtot")
          if [ "$((lu+ld))" -ge "$cap" ]; then badln "  QUOTA REACHED: $(hb $((lu+ld))) / $(hb "$cap") total — refusing traffic"; warns=$((warns+1));
          else okln "  quota: $(hb $((lu+ld))) / $(hb "$cap") total"; fi
        fi
        if awk "BEGIN{exit !(${qup:-0}>0)}"; then
          local capu; capu=$(gb_to_bytes "$qup")
          if [ "$lu" -ge "$capu" ]; then badln "  UPLOAD QUOTA REACHED: $(hb "$lu") / $(hb "$capu")"; warns=$((warns+1));
          else okln "  upload quota: $(hb "$lu") / $(hb "$capu")"; fi
        fi
        if awk "BEGIN{exit !(${qdown:-0}>0)}"; then
          local capd; capd=$(gb_to_bytes "$qdown")
          if [ "$ld" -ge "$capd" ]; then badln "  DOWNLOAD QUOTA REACHED: $(hb "$ld") / $(hb "$capd")"; warns=$((warns+1));
          else okln "  download quota: $(hb "$ld") / $(hb "$capd")"; fi
        fi
      fi
    fi
  done
  [ "$found" = 0 ] && echo "  (no tunnels configured yet)"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
  if [ "$warns" -eq 0 ]; then echo -e "  ${C_G}All checks passed.${C_N}"
  else echo -e "  ${C_Y}$warns warning(s) above.${C_N}"; fi
  echo -e "  ${C_D}Note: kcp (a UDP transport) also needs UDP open end-to-end;${C_N}"
  echo -e "  ${C_D}test with:  nc -u <relay-ip> <port>  (both sides).${C_N}"
}

# ---------------------------------------------------------------------------
# In-place tunnel editing. These exist so a tunnel never has to be deleted and
# recreated just to change one field — with several tunnels on one relay,
# recreating each time is slow and easy to get wrong.
# ---------------------------------------------------------------------------

# jset writes key=value into a tunnel's JSON without disturbing anything else.
# Values are typed: strings are quoted, numbers are not. Python is used because
# sed-based JSON editing silently corrupts files the moment a value contains a
# character you did not anticipate.
jset(){
  local file="$1" key="$2" val="$3" kind="${4:-string}"
  python3 - "$file" "$key" "$val" "$kind" <<'PYEOF'
import json,sys
f,k,v,kind=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
import os
d=json.load(open(f))
try:
    if kind=="int": d[k]=int(v)
    elif kind=="float": d[k]=float(v)
    elif kind=="bool": d[k]=(v.lower() in ("1","true","yes","on"))
    elif kind=="del": d.pop(k,None)
    else: d[k]=v
except ValueError:
    sys.stderr.write("  [x] %s: %r is not a number — left unchanged\n" % (k, v)); sys.exit(1)
# Written beside and renamed over the config, keeping its mode: truncating it
# in place left an empty config if anything failed half-way.
t=f+".tmp"
fd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,os.stat(f).st_mode&0o777)
with os.fdopen(fd,"w") as o:
    json.dump(d,o,indent=2); o.write("\n")
os.replace(t,f)
PYEOF
}

# jmerge FILE JSON — merge a JSON object's keys into the config (the fields
# tls_extra collects as a fragment), written the same safe way as jset.
jmerge(){
  python3 - "$1" "$2" <<'PYEOF'
import json,os,sys
f=sys.argv[1]; d=json.load(open(f)); d.update(json.loads(sys.argv[2]))
t=f+".tmp"
fd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,os.stat(f).st_mode&0o777)
with os.fdopen(fd,"w") as o:
    json.dump(d,o,indent=2); o.write("\n")
os.replace(t,f)
PYEOF
}

# jget reads one value back (empty string when the key is absent).
jget(){
  python3 - "$1" "$2" <<'PYEOF'
import json,sys
try:
    d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2],"")
    print("" if v is None else v)
except Exception:
    print("")
PYEOF
}


# is_udp_transport: carried over UDP, so the relay's firewall must allow UDP.
is_udp_transport(){ [ "$1" = kcp ]; }

# service_check restarts a tunnel and reports whether it actually came up,
# with the reason from its log when it did not. "restarted" alone told the
# operator nothing: a config the core rejects exits at once, and the menu used
# to report success anyway.
service_check(){
  local n="$1"
  systemctl restart "brokennode@$n" >/dev/null 2>&1
  sleep 2
  if [ "$(systemctl is-active "brokennode@$n" 2>/dev/null)" = active ]; then
    info "'$n' is ${C_G}running${C_N}."
    return 0
  fi
  err "'$n' did not start. Recent log:"
  journalctl -u "brokennode@$n" -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

# change_transport swaps a tunnel's transport in place, keeping token, ports and
# addresses. It also clears settings that belong to the OLD transport so a
# leftover field cannot confuse the new one.
change_transport(){
  local n="$1"; local cfg="$CFG_DIR/$n.json" k
  local cur curenc mode; cur="$(jget "$cfg" transport)"; curenc="$(jget "$cfg" encryption)"; mode="$(jget "$cfg" mode)"
  # A config written by an older build may still carry a retired combined name.
  # The core reads "tcpobf" as tcp+obfs; show and compare it the same way, or
  # the menu reports the wrong encryption and "nothing to do" checks misfire.
  case "$cur" in
    tcpobf)  cur=tcp;  [ -z "$curenc" ] && curenc=obfs ;;
    mtcpobf) cur=mtcp; [ -z "$curenc" ] && curenc=obfs ;;
    wsobf)   cur=ws;   [ -z "$curenc" ] && curenc=obfs ;;
    rawmux)  cur=kcp;  [ -z "$curenc" ] && curenc=obfs ;;
  esac
  [ -z "$curenc" ] && curenc=none
  echo; echo -e "${C_B}  Change transport for '$n'${C_N}  ${C_D}(current: $cur, encryption: $curenc)${C_N}"
  local new; new=$(pick_transport)
  [ -z "$new" ] && { warn "cancelled"; return; }
  # A transport from another family needs different fields entirely (a relay
  # address vs. two real IPs and a tunnel pair). Swapping the name in place
  # left a config the new transport could not start from.
  local curfam newfam; curfam=$(transport_family "$cur"); newfam=$(transport_family "$new")
  if [ "$curfam" != "$newfam" ]; then
    err "'$cur' and '$new' are configured differently ($curfam vs $newfam) — they cannot be swapped in place."
    warn "Create a new tunnel with '$new' instead, then delete '$n'."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  local newenc; newenc=$(pick_encryption "$new")
  if [ "$new" = "$cur" ] && [ "$newenc" = "$curenc" ]; then info "already $cur/$curenc — nothing to do"; return; fi
  cfg_begin "$cfg"
  jset "$cfg" transport "$new"
  jset "$cfg" encryption "$newenc"
  # Drop transport-specific leftovers.
  case "$new" in
    tcpnomux) jset "$cfg" links "" del ;;
    mtcp)     jset "$cfg" pool_size "" del ;;
    *)        jset "$cfg" pool_size "" del; jset "$cfg" links "" del ;;
  esac
  [ "$new" != sctp ] && { jset "$cfg" sctp_streams "" del; jset "$cfg" sctp_multihoming "" del; }
  [ "$new" != ws ] && for k in ws_path ws_host ws_user_agent; do jset "$cfg" "$k" "" del; done
  # Settings only quic had (removed in 2.3.22). alpn and server_name now
  # belong to the tls layer, so they stay while the tunnel keeps tls.
  jset "$cfg" udp_duplicate "" del
  enc_switch "$cfg" "$curenc" "$newenc"
  # tcpnomux does not multiplex, so it cannot carry the proxy.
  [ "$new" = tcpnomux ] && for k in socks socks_user socks_pass socks_open; do jset "$cfg" "$k" "" del; done
  cfg_commit "$cfg" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
  info "transport: $cur/$curenc -> $new/$newenc"
  if tunnel_listens "$cfg" && is_udp_transport "$new" && ! is_udp_transport "$cur"; then
    local port; port="$(jget "$cfg" bind_addr)"; port="${port##*:}"
    warn "$new runs over UDP: this server's firewall must allow ${C_Y}UDP $port${C_N} (TCP alone is not enough)."
    warn "e.g.  ufw allow $port/udp   or   iptables -I INPUT -p udp --dport $port -j ACCEPT"
  fi
  warn "Do the SAME on the other server: '$new' with encryption '$newenc', or they will not connect."
  service_check "$n"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# enc_switch CFG FROM TO — move a config from one encryption layer to another:
# drop the settings of the old layer and ask the ones the new layer needs for
# this end's role (the listening end presents a certificate or the borrowed
# site, the dialing end verifies it and shapes the ClientHello). Without the
# questions a switch to tls left a config with no certificate that never ran.
enc_switch(){
  local cfg="$1" from="$2" to="$3" k
  if [ "$to" != tls ]; then
    for k in alpn server_name tls_cert tls_key tls_selfsigned tls_insecure tls_auto_email tls_auto_cache tls_fingerprint; do jset "$cfg" "$k" "" del; done
  fi
  [ "$to" != reality ] && for k in reality_dest reality_server_name; do jset "$cfg" "$k" "" del; done
  case "$to" in tls|reality) : ;; *) jset "$cfg" tls_fragment "" del ;; esac
  [ "$to" = "$from" ] && return 0
  local lis=0 dials=1; tunnel_listens "$cfg" && { lis=1; dials=0; }
  TLSJSON=""
  case "$to" in
    tls)
      tls_extra "$lis"
      [ "$dials" = 1 ] && TLSJSON="$TLSJSON\"tls_fingerprint\":\"$(pick_fingerprint)\","
      [ "$dials" = 1 ] && yes_no "Fragment the ClientHello (tls_fragment)? y/N" n && TLSJSON="$TLSJSON\"tls_fragment\":true,"
      ;;
    reality)
      TLSJSON="\"reality_dest\":\"$(jstr "$(ask_reality_dest)")\","
      [ "$dials" = 1 ] && yes_no "Fragment the ClientHello (tls_fragment)? y/N" n && TLSJSON="$TLSJSON\"tls_fragment\":true,"
      ;;
  esac
  [ -n "$TLSJSON" ] && jmerge "$cfg" "{${TLSJSON%,}}"
  return 0
}

# onoff CFG KEY — "on" or "off" for a true/false setting.
onoff(){ case "$(jget "$1" "$2")" in True|true|1) echo on ;; *) echo off ;; esac; }

# toggle WORK KEY QUESTION CURRENT(on|off) — ask, keeping CURRENT on Enter,
# and write the answer (an "off" setting is removed, not written as false).
toggle(){
  local work="$1" key="$2" q="$3" cur="$4"
  if [ "$cur" = on ]; then
    if yes_no "$q (now on) Y/n" y; then jset "$work" "$key" true bool; else jset "$work" "$key" "" del; fi
  else
    if yes_no "$q (now off) y/N" n; then jset "$work" "$key" true bool; else jset "$work" "$key" "" del; fi
  fi
}

# edit_security NAME — the encryption layer and everything that goes with it:
# the token, the tls certificate and name, the reality site, the browser
# fingerprint, the split ClientHello and padding. Edited on a copy that the
# core checks before it replaces the config, like Tune settings.
edit_security(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local tr enc fam v cur; tr="$(jget "$cfg" transport)"; enc="$(jget "$cfg" encryption)"; enc="${enc:-none}"
  fam=$(transport_family "$tr")
  local work="$CFG_DIR/.tune-$n.json"
  cp -p "$cfg" "$work" || { err "Could not prepare the edit."; return; }
  trap 'rm -f "$work"' RETURN
  echo; echo -e "${C_B}  Encryption & stealth of '$n'${C_N}  ${C_D}($tr, encryption: $enc) — blank keeps the current value${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
  if [ "$fam" = stream ] || [ "$tr" = udp ] || [ "$tr" = icmp ]; then
    if yes_no "Change the encryption layer (now $enc)? y/N" n; then
      local newenc; newenc=$(pick_encryption "$tr")
      jset "$work" encryption "$newenc"
      enc_switch "$work" "$enc" "$newenc"
      enc="$newenc"
    fi
  else
    echo -e "  ${C_D}$tr is a kernel tunnel: it has no encryption layer (encrypt in the service, e.g. xray).${C_N}"
  fi
  v=$(ask "Shared token (same on both ends; blank keeps the current one)" "")
  [ -n "$v" ] && jset "$work" token "$v"
  if [ "$fam" = stream ]; then
    local dials=1; tunnel_listens "$cfg" && dials=0
    case "$enc" in
      tls)
        cur="$(jget "$work" server_name)"
        v=$(ask "  server_name / SNI (same on both ends; '-' clears) [${cur:-none}]" "")
        if [ "$v" = - ]; then jset "$work" server_name "" del; elif [ -n "$v" ]; then jset "$work" server_name "$v"; fi
        cur="$(jget "$work" alpn)"
        v=$(ask "  alpn ('-' = default h2,http/1.1) [${cur:-default}]" "")
        if [ "$v" = - ]; then jset "$work" alpn "" del; elif [ -n "$v" ]; then jset "$work" alpn "$v"; fi
        if [ "$dials" = 1 ]; then
          jset "$work" tls_fingerprint "$(pick_fingerprint "$(jget "$work" tls_fingerprint)")"
          toggle "$work" tls_fragment "  Fragment the ClientHello (tls_fragment)?" "$(onoff "$work" tls_fragment)"
        fi ;;
      reality)
        jset "$work" reality_dest "$(ask_reality_dest "$(jget "$work" reality_dest)")"
        if [ "$dials" = 1 ]; then
          cur="$(jget "$work" reality_server_name)"
          v=$(ask "  SNI to show ('-' = the site name) [${cur:-same as the site}]" "")
          if [ "$v" = - ]; then jset "$work" reality_server_name "" del; elif [ -n "$v" ]; then jset "$work" reality_server_name "$v"; fi
          toggle "$work" tls_fragment "  Fragment the ClientHello (tls_fragment)?" "$(onoff "$work" tls_fragment)"
        fi ;;
    esac
    toggle "$work" pad "  Padding (pad; must match the other end)?" "$(onoff "$work" pad)"
  fi
  tune_apply "$n" "$cfg" "$work" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
  info "saved, '$n' restarted"
  warn "Make the SAME change on the other server (encryption, token, reality site, padding), or they will not connect."
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# change_relay_ip updates the IP this end dials, keeping the port: the Iran
# relay's IP on a foreign server in reverse mode (needed every time the relay's
# IP changes), or the foreign server's IP on the relay in direct mode.
change_relay_ip(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local fam; fam="$(transport_family "$(jget "$cfg" transport)")"
  if [ "$fam" != stream ]; then
    # A point-to-point tunnel names the other server by remote_ip, in the
    # family (IPv4 or IPv6) local_ip already uses.
    local cur newip isfam=is_ipv4; cur="$(jget "$cfg" remote_ip)"
    case "$(jget "$cfg" local_ip)" in *:*) isfam=is_ipv6 ;; esac
    echo; echo -e "${C_B}  Change the other server's IP for '$n'${C_N}  ${C_D}(current: $cur)${C_N}"
    newip=$(ask "New IP of the other server" ""); newip="${newip// /}"; newip="${newip#[}"; newip="${newip%]}"
    [ -z "$newip" ] && { warn "cancelled"; return; }
    $isfam "$newip" || { err "'$newip' is not an address of the same family as local_ip ($(jget "$cfg" local_ip))."; return; }
    cfg_begin "$cfg"
    jset "$cfg" remote_ip "$newip"
    cfg_commit "$cfg" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
    info "remote_ip: $cur -> $newip"
    warn "On the other server, set local_ip to $newip too (11 Tune settings)."
    service_check "$n"
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  if tunnel_listens "$cfg"; then
    warn "'$n' LISTENS for the other end in this direction, so it has no peer IP to change."
    warn "Change its listen address with 'Tune settings' instead."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  local what="relay"; [ "$(jget "$cfg" mode)" = server ] && what="foreign server"
  local cur port newip; cur="$(jget "$cfg" remote_addr)"; port="${cur##*:}"
  echo; echo -e "${C_B}  Change $what IP for '$n'${C_N}  ${C_D}(current: $cur)${C_N}"
  newip=$(ask "New $what IP — IPv4 or IPv6 (port $port kept)" "")
  [ -z "$newip" ] && { warn "cancelled"; return; }
  newip="${newip// /}"; newip="${newip#[}"; newip="${newip%]}"
  is_ipv4 "$newip" || is_ipv6 "$newip" || { err "'$newip' is not an IPv4 or IPv6 address."; return; }
  cfg_begin "$cfg"
  jset "$cfg" remote_addr "$(hostport "$newip" "$port")"
  cfg_commit "$cfg" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
  info "$what: $cur -> $(hostport "$newip" "$port")"
  systemctl restart "brokennode@$n" >/dev/null 2>&1
  info "restarted '$n'"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# direction_label CFG — reverse, direct, or "proxy (reverse)" / "proxy (direct)"
# when the relay runs the SOCKS5/HTTP proxy.
direction_label(){
  local d; d="$(tunnel_direction "$1")"
  if [ -n "$(jget "$1" socks)" ]; then echo "proxy ($d)"; else echo "$d"; fi
}

# change_direction — the same three choices as at creation: reverse (the
# foreign server dials the relay), direct (the relay dials the foreign server)
# or proxy (a SOCKS5/HTTP proxy on the relay instead of port forwards, over
# either). Each end needs the address for its new role; choosing proxy again
# changes the proxy's port and login. The old address stays in the config,
# so flipping back later offers it as the default.
change_direction(){
  local n="$1"; local cfg="$CFG_DIR/$n.json" k
  local tr mode cur new; tr="$(jget "$cfg" transport)"; mode="$(jget "$cfg" mode)"
  if [ "$(transport_family "$tr")" != stream ]; then
    warn "$tr has no direction: both ends send to each other, so it already works either way."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  cur="$(tunnel_direction "$cfg")"
  local hadproxy=0 before; [ -n "$(jget "$cfg" socks)" ] && hadproxy=1
  before="$(direction_label "$cfg")"
  echo; echo -e "${C_B}  Direction of '$n'${C_N}  ${C_D}(now: $before)${C_N}"
  local dsel proxy=0; dsel=$(pick_direction "$tr"); new="${dsel#proxy-}"; [ "$dsel" != "$new" ] && proxy=1
  if [ "$new" = "$cur" ] && [ "$proxy" = 0 ] && { [ "$hadproxy" = 0 ] || [ "$mode" = client ]; }; then
    info "already $cur — nothing to do"; return
  fi
  local bproto=tcp; [ "$tr" = kcp ] && bproto=udp
  local bind remote port
  bind="$(jget "$cfg" bind_addr)"; remote="$(jget "$cfg" remote_addr)"
  cfg_begin "$cfg"
  if [ "$new" != "$cur" ]; then
    # The side that will listen needs bind_addr; the side that will dial needs
    # remote_addr. The tunnel port is the same number either way.
    if { [ "$mode" = server ] && [ "$new" = reverse ]; } || { [ "$mode" = client ] && [ "$new" = direct ]; }; then
      port="${bind##*:}"; [ -z "$bind" ] && port="${remote##*:}"; [ -z "$port" ] && port=8443
      local v; v=$(ask "Listen address (host:port)" "${bind:-0.0.0.0:$port}")
      jset "$cfg" bind_addr "$(check_bind "$v")"
      jset "$cfg" remote_addr "" del   # this end no longer dials
      port="$(jget "$cfg" bind_addr)"; port="${port##*:}"
      warn_port_clash "$(jq_ports "$cfg")" "$n" "$port" "$bproto"
      warn "This server must now accept ${bproto^^} $port inbound (firewall)."
    else
      local who="Iran relay"; [ "$mode" = server ] && who="foreign server"
      port="${remote##*:}"; [ -z "$remote" ] && port="${bind##*:}"; [ -z "$port" ] && port=8443
      local v=""
      while [ -z "$v" ]; do
        v=$(ask_hostport "$who address (IP:port)" "$port" "$remote")
        [ -z "$v" ] && warn "Required: the $who's real IP and the port it listens on."
      done
      jset "$cfg" remote_addr "$v"
      jset "$cfg" bind_addr "" del     # this end no longer listens
    fi
    jset "$cfg" direction "$new"
  fi
  if [ "$mode" = server ]; then
    if [ "$proxy" = 1 ]; then
      # Proxy mode carries no port forwards, as at creation.
      socks_extra "$tr" "$n" "$cfg"
      for k in socks socks_user socks_pass socks_open; do jset "$cfg" "$k" "" del; done
      jmerge "$cfg" "{${SOCKSJSON%,}}"
      if [ -n "$(jq_ports "$cfg")" ]; then
        warn "Proxy mode has no port forwards: removing this tunnel's ports ($(jq_ports "$cfg" | tr -d '"'))."
        jmerge "$cfg" '{"ports":[]}'
      fi
    elif [ "$hadproxy" = 1 ]; then
      # Leaving proxy mode: the tunnel carries port forwards again.
      for k in socks socks_user socks_pass socks_open; do jset "$cfg" "$k" "" del; done
      if [ -z "$(jq_ports "$cfg")" ]; then
        info "Without the proxy this tunnel needs port forwards:"
        jmerge "$cfg" "{\"ports\":[$(ask_ports "$n")]}"
      fi
    fi
  elif [ "$proxy" = 1 ]; then
    info "The proxy itself is set up on the Iran server; this server only needs the same direction ($new)."
  fi
  cfg_commit "$cfg" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
  info "direction: $before -> $(direction_label "$cfg")"
  # The certificate belongs to the end that LISTENS, and the flip moves that
  # role. Self-signed carries over by itself (either tls flag works on either
  # end); a certificate from files or Let's Encrypt lives on the OTHER server.
  if [ "$new" != "$cur" ] && [ "$(jget "$cfg" encryption)" = tls ] && [ "$(jget "$cfg" tls_selfsigned)" != True ] && [ "$(jget "$cfg" tls_insecure)" != True ]; then
    warn "This tunnel uses tls with a real certificate, and the flip moved the listening role to the other end."
    warn "That end now needs the certificate (tls_cert/tls_key, or Let's Encrypt on :443) — or switch both ends to self-signed."
  fi
  [ "$new" != "$cur" ] && warn "Switch the OTHER server to ${C_Y}$new${C_N} too, or the two will not connect."
  [ "$mode" = server ] && socks_summary "$cfg"
  service_check "$n"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# tunnel_summary CFG — "direction<TAB>listens(1|0)<TAB>address<TAB>ports" in one
# python start, for the tunnel list (it runs once per tunnel on every redraw).
# The address is bind_addr where this end listens, remote_addr where it dials.
tunnel_summary(){
  python3 - "$1" <<'PYEOF'
import json,sys
P2P = ("gre", "gretap", "ipip", "sit", "l2tp", "udp", "icmp")
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    c = {}
stream = c.get("transport") not in P2P
direct = stream and str(c.get("direction") or "").strip().lower() == "direct"
listens = (c.get("mode") == "server") != direct
addr = c.get("bind_addr" if listens else "remote_addr") or ""
ports = ",".join(str(p) for p in (c.get("ports") or []))
print("\t".join(["direct" if direct else "reverse", "1" if listens else "0", addr or "?", ports or "?"]))
PYEOF
}

# jq_ports CFG — the config's "ports" list as the JSON array body build_ports
# returns, for warn_port_clash.
jq_ports(){
  python3 - "$1" <<'PYEOF'
import json,sys
try:
    print(",".join(json.dumps(str(p)) for p in json.load(open(sys.argv[1])).get("ports") or []))
except Exception:
    print("")
PYEOF
}

# apply_preset re-applies one of the create-time presets (Optimized, High-Speed,
# Stable, Low-Latency, Eco) to a RUNNING tunnel, so the operator can retune with
# one choice instead of typing keepalive / kcp_* by hand. Stream transports only:
# the point-to-point tunnels (gre/udp/icmp/...) have none of these knobs.
apply_preset(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local tr; tr="$(jget "$cfg" transport)"
  if [ "$(transport_family "$tr")" != stream ]; then
    warn "'$tr' is a point-to-point tunnel — it has no preset-tunable settings (try 'Tune settings' for its MTU)."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  echo; echo -e "${C_B}  Apply a preset to '$n'${C_N}  ${C_D}($tr) — sets keepalive and the kcp profile${C_N}"
  local ka kmode kdata kparity choice
  choice="$(pick_preset cancel)"
  if [ -z "$choice" ]; then info "cancelled — nothing changed"; return; fi
  read -r ka kmode kdata kparity <<< "$choice"
  jset "$cfg" keepalive "$ka" int
  jset "$cfg" kcp_mode "$kmode"
  jset "$cfg" kcp_data "$kdata" int
  jset "$cfg" kcp_parity "$kparity" int
  info "preset applied: keepalive=$ka kcp_mode=$kmode kcp_data=$kdata kcp_parity=$kparity"
  [ "$tr" = kcp ] && warn "kcp settings must MATCH on both ends — apply the same preset there."
  service_check "$n"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# ports_set CFG SPEC... writes the config's "ports" array from the given specs
# (already validated), or empties it when none are given. Keeps the file valid
# JSON with a trailing newline, like jset.
ports_set(){
  local file="$1"; shift
  python3 - "$file" "$@" <<'PYEOF'
import json,sys
f=sys.argv[1]; specs=sys.argv[2:]
d=json.load(open(f))
d["ports"]=specs
json.dump(d,open(f,"w"),indent=2); open(f,"a").write("\n")
PYEOF
}

# ports_apply CFG NAME SPEC... writes the new list to a copy of the config and
# has the core validate it (brokennode -check) before putting it in place. A
# list the core would refuse — a port listed twice, the tunnel's own listen
# port — is rejected with the core's reason and the running tunnel is left
# untouched; written straight to the config it made the relay crash-loop.
ports_apply(){
  local cfg="$1" n="$2"; shift 2
  local tmp out rc
  tmp="$(dirname "$cfg")/.check-$n.json"
  install -m 600 "$cfg" "$tmp" || return 1
  ports_set "$tmp" "$@"
  out="$("$BIN" -check -c "$tmp" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q 'flag provided but not defined' <<<"$out"; then
    rm -f "$tmp"
    err "Not applied: $(check_reason "$out")"
    return 1
  fi
  mv -f "$tmp" "$cfg"
}

# manage_ports adds and removes user port-forwards on a RUNNING relay without
# hand-editing the config: add one, remove several by number (or a range), or
# clear them all. Server side only — the client has no port list.
manage_ports(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  if [ "$(jget "$cfg" mode)" != server ]; then
    warn "Port-forwards live on the relay (server) side; '$n' is a client."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  while true; do
    # Read the current list into a bash array, one spec per line.
    local ports=() line
    while IFS= read -r line; do [ -n "$line" ] && ports+=("$line"); done < <(
      python3 - "$cfg" <<'PYEOF'
import json,sys
try:
    for p in json.load(open(sys.argv[1])).get("ports") or []: print(p)
except Exception: pass
PYEOF
)
    echo; echo -e "${C_B}  Port-forwards for '$n'${C_N}"
    echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
    if [ "${#ports[@]}" -eq 0 ]; then
      echo -e "  ${C_D}(none)${C_N}"
    else
      local i; for i in "${!ports[@]}"; do printf "   %2d) %s\n" "$((i+1))" "${ports[$i]}"; done
    fi
    echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
    echo "   a) add a port     r) remove by number(s)     c) replace the whole list     0) done"
    local act; act=$(menu_ask 'Choice')
    case "$act" in
      a|A)
        local spec; spec=$(ask "Port(s)  (443 or 8443=443)" ""); spec="${spec// /}"; [ -z "$spec" ] && continue
        local okp=1 part
        if [[ "$spec" =~ ^[0-9]+(=[0-9]+)?$ ]]; then
          for part in ${spec//=/ }; do [ "$part" -ge 1 ] && [ "$part" -le 65535 ] || okp=0; done
        else okp=0; fi
        [ "$okp" = 0 ] && { warn "'$spec' is not a port mapping — use 443 or 8443=443 (1-65535)."; continue; }
        local proto sfx; proto=$(ask "Protocol  1)tcp 2)udp 3)both" "3")
        case "$proto" in 1) sfx="";; 2) sfx="/udp";; *) sfx="/both";; esac
        warn_port_clash "\"${spec}${sfx}\"" "$n" || continue
        if ports_apply "$cfg" "$n" "${ports[@]}" "${spec}${sfx}"; then
          info "added ${spec}${sfx}"; service_check "$n"
        fi
        ;;
      r|R)
        [ "${#ports[@]}" -eq 0 ] && { warn "nothing to remove"; continue; }
        echo -e "  ${C_D}Enter numbers to remove: e.g. 1 3, or a range 2-4.${C_N}"
        local rsel; rsel=$(ask "Remove which" ""); [ -z "$rsel" ] && continue
        # Expand numbers and N-M ranges into a set of 1-based indices.
        local drop=() tok a b j
        for tok in $rsel; do
          if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
            a="${tok%-*}"; b="${tok#*-}"
            [ "$a" -le "$b" ] || { local t=$a; a=$b; b=$t; }
            for ((j=a;j<=b;j++)); do drop+=("$j"); done
          elif [[ "$tok" =~ ^[0-9]+$ ]]; then drop+=("$tok")
          else warn "ignored '$tok' (not a number or range)"; fi
        done
        local keep=() removed=0
        for i in "${!ports[@]}"; do
          local idx=$((i+1)) hit=0 d
          for d in "${drop[@]}"; do [ "$d" = "$idx" ] && hit=1 && break; done
          if [ "$hit" = 1 ]; then removed=$((removed+1)); else keep+=("${ports[$i]}"); fi
        done
        [ "$removed" = 0 ] && { warn "no matching entries"; continue; }
        if [ "${#keep[@]}" -eq 0 ] && [ -z "$(jget "$cfg" socks)" ]; then
          warn "A relay needs at least one port (or proxy mode: 13 Change direction → 3). Use c) to replace the whole list instead."
          continue
        fi
        if ports_apply "$cfg" "$n" "${keep[@]}"; then
          info "removed $removed port-forward(s)"; service_check "$n"
        fi
        ;;
      c|C)
        # Replace the whole list. The old list stays until at least one new
        # port has been entered — an empty list would stop the relay.
        echo -e "  ${C_D}Enter the new ports; the old list is replaced only when you add at least one.${C_N}"
        local newl=() s2 okp2 pr2 sfx2 part2
        while true; do
          s2=$(ask "Port (443 or 8443=443, blank = done)" ""); s2="${s2// /}"
          [ -z "$s2" ] && break
          okp2=1
          if [[ "$s2" =~ ^[0-9]+(=[0-9]+)?$ ]]; then
            for part2 in ${s2//=/ }; do [ "$part2" -ge 1 ] && [ "$part2" -le 65535 ] || okp2=0; done
          else okp2=0; fi
          [ "$okp2" = 0 ] && { warn "'$s2' is not a port mapping — use 443 or 8443=443 (1-65535)."; continue; }
          pr2=$(ask "Protocol  1)tcp 2)udp 3)both" "3")
          case "$pr2" in 1) sfx2="";; 2) sfx2="/udp";; *) sfx2="/both";; esac
          newl+=("${s2}${sfx2}"); echo -e "  ${C_G}  + ${s2}${sfx2}${C_N}"
        done
        if [ "${#newl[@]}" -eq 0 ]; then info "cancelled — the list is unchanged"; continue; fi
        warn_port_clash "$(printf '"%s",' "${newl[@]}")" "$n" || continue
        if ports_apply "$cfg" "$n" "${newl[@]}"; then
          info "port list replaced (${#newl[@]} port(s))"; service_check "$n"
        fi
        ;;
      0|"") return ;;
      __eof__) return ;;
      *) warn "Invalid." ;;
    esac
  done
}

# tune_tunnel exposes the per-tunnel network knobs. Blank input keeps the current
# value, so it doubles as a way to review settings without changing them.
# tune_apply NAME LIVE WORK — the core checks the edited WORK copy; if it passes
# it replaces LIVE and the tunnel restarts, otherwise LIVE is left untouched.
tune_apply(){
  local n="$1" live="$2" work="$3" out
  if cmp -s "$live" "$work"; then info "no changes"; return 1; fi
  out="$("$BIN" -check -c "$work" 2>&1)" || {
    if ! grep -q 'flag provided but not defined' <<<"$out"; then
      err "Not applied — the core refuses the change: $(check_reason "$out")"
      info "The previous settings are kept; the tunnel was not restarted."
      return 1
    fi
  }
  chmod 600 "$work" 2>/dev/null
  mv -f "$work" "$live"
  systemctl restart "brokennode@$n" >/dev/null 2>&1
}

tune_tunnel(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local tr mode; tr="$(jget "$cfg" transport)"; mode="$(jget "$cfg" mode)"
  echo; echo -e "${C_B}  Tune '$n'${C_N}  ${C_D}($mode/$tr) — blank keeps the current value${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"

  local v cur
  local fam; fam=$(transport_family "$tr")
  # Every edit goes to a working COPY, not the live config. Only at the very
  # end, if the core accepts it, does it replace the live config. So an input
  # that ends half-way through the questions (ask stops the manager) leaves the
  # running tunnel exactly as it was, rather than saving a half-set of changes
  # that would apply at the next restart.
  local work; work="$CFG_DIR/.tune-$n.json"
  cp -p "$cfg" "$work" || { err "Could not prepare the edit."; return; }
  trap 'rm -f "$work"' RETURN
  if [ "$fam" != stream ]; then
    # Point-to-point tunnels have no smux, bind port or keepalive; what can be
    # tuned is the MTU and the addresses, which live in the config itself.
    cur="$(jget "$cfg" mtu)"
    v=$(ask "  mtu (0 = default) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" mtu "$v" int
    if [ "$tr" = gre ] || [ "$tr" = gretap ] || [ "$tr" = ipip ] || [ "$tr" = sit ]; then
      cur="$(jget "$cfg" tun_ttl)"
      v=$(ask "  tun_ttl (outer TTL, 0 = kernel default) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" tun_ttl "$v" int
    fi
    echo -e "  ${C_D}The values below must match the other end (its local is your remote).${C_N}"
    cur="$(jget "$cfg" local_ip)"
    v=$(ask "  local_ip (this server's real IP) [$cur]" ""); [ -n "$v" ] && jset "$work" local_ip "${v// /}"
    cur="$(jget "$cfg" remote_ip)"
    v=$(ask "  remote_ip (the other server's real IP) [$cur]" ""); [ -n "$v" ] && jset "$work" remote_ip "${v// /}"
    cur="$(jget "$cfg" tun_local)"
    v=$(ask "  tun_local (this end's tunnel address) [$cur]" ""); [ -n "$v" ] && jset "$work" tun_local "${v// /}"
    cur="$(jget "$cfg" tun_remote)"
    v=$(ask "  tun_remote (the other end's tunnel address) [$cur]" ""); [ -n "$v" ] && jset "$work" tun_remote "${v// /}"
    case "$tr" in
      gre|gretap)
        cur="$(jget "$cfg" gre_key)"
        v=$(ask "  gre_key (0 = none, same on both ends) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" gre_key "$v" int ;;
    esac
    case "$tr" in
      gre|gretap|ipip|sit)
        cur="$(jget "$cfg" fou_port)"
        v=$(ask "  fou_port (carry the tunnel inside UDP to this port, for paths that drop $tr; 0 = off; same on both ends) [${cur:-0}]" "")
        [ -n "$v" ] && jset "$work" fou_port "$v" int ;;
    esac
    case "$tr" in
      l2tp)
        cur="$(jget "$cfg" l2tp_tunnel_id)"
        v=$(ask "  l2tp_tunnel_id (same on both ends) [${cur:-1000}]" ""); [ -n "$v" ] && jset "$work" l2tp_tunnel_id "$v" int
        cur="$(jget "$cfg" l2tp_session_id)"
        v=$(ask "  l2tp_session_id (same on both ends) [${cur:-1000}]" ""); [ -n "$v" ] && jset "$work" l2tp_session_id "$v" int
        cur="$(jget "$cfg" l2tp_encap)"
        v=$(ask "  l2tp_encap (udp/ip) [${cur:-udp}]" ""); [ -n "$v" ] && jset "$work" l2tp_encap "$v"
        cur="$(jget "$cfg" l2tp_port)"
        v=$(ask "  l2tp_port (udp encap, same on both ends) [${cur:-1701}]" ""); [ -n "$v" ] && jset "$work" l2tp_port "$v" int ;;
      udp|icmp)
        cur="$(jget "$cfg" carrier_port)"
        v=$(ask "  carrier_port ($([ "$tr" = icmp ] && echo 'icmp tunnel id' || echo 'udp port'), same on both ends) [${cur:-6262}]" "")
        [ -n "$v" ] && jset "$work" carrier_port "$v" int ;;
    esac
    if [ "$mode" = client ]; then
      cur="$(jget "$cfg" target_host)"
      v=$(ask "  target_host (where traffic is delivered locally) [$cur]" ""); [ -n "$v" ] && jset "$work" target_host "$v"
    fi
    cur="$(jget "$cfg" log_level)"
    v=$(ask "  log_level (info/debug/error) [$cur]" ""); [ -n "$v" ] && jset "$work" log_level "$v"
    tune_apply "$n" "$cfg" "$work" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
    info "settings saved, '$n' restarted"
    warn "mtu should match on both ends."
    read -t 30 -rp "  ▶ press ENTER to continue... " _
    return
  fi

  cur="$(jget "$cfg" keepalive)"
  v=$(ask "  keepalive seconds (lower = faster dead-peer detection) [$cur]" ""); [ -n "$v" ] && jset "$work" keepalive "$v" int

  # Both the current and the legacy transport names are matched here on purpose:
  # this reads whatever is already in the config file, and a tunnel created by an
  # older build still says "rawmux" or "mtcpobf" on disk (the core translates
  # those at load time, but the file itself is untouched).
  case "$tr" in
    kcp|rawmux)
      cur="$(jget "$cfg" kcp_mode)"
      echo -e "  ${C_D}kcp_mode: gaming = lowest/steadiest latency · fast · turbo = throughput · normal = low CPU (slows sharply under packet loss)${C_N}"
      v=$(ask "  kcp_mode [$cur]" ""); [ -n "$v" ] && jset "$work" kcp_mode "$v"
      cur="$(jget "$cfg" kcp_data)"
      v=$(ask "  kcp_data  (FEC data shards, e.g. 10) [$cur]" ""); [ -n "$v" ] && jset "$work" kcp_data "$v" int
      cur="$(jget "$cfg" kcp_parity)"
      echo -e "  ${C_D}Higher parity repairs more loss without retransmits (steadier ping) but uses more bandwidth.${C_N}"
      v=$(ask "  kcp_parity (FEC parity shards, e.g. 4) [$cur]" ""); [ -n "$v" ] && jset "$work" kcp_parity "$v" int
      cur="$(jget "$cfg" kcp_mtu)"
      echo -e "  ${C_D}MTU: 1200 is safe for gaming; raise only if the path has no fragmentation.${C_N}"
      v=$(ask "  kcp_mtu [${cur:-auto}]" ""); [ -n "$v" ] && jset "$work" kcp_mtu "$v" int
      cur="$(jget "$cfg" kcp_sndwnd)"
      v=$(ask "  kcp_sndwnd (send window, packets) [${cur:-auto}]" ""); [ -n "$v" ] && jset "$work" kcp_sndwnd "$v" int
      cur="$(jget "$cfg" kcp_rcvwnd)"
      v=$(ask "  kcp_rcvwnd (recv window, packets) [${cur:-auto}]" ""); [ -n "$v" ] && jset "$work" kcp_rcvwnd "$v" int
      cur="$(jget "$cfg" links)"
      echo -e "  ${C_D}Parallel kcp links (0 = auto: 4). One kcp link tops out near 120 Mbit/s for all users;${C_N}"
      echo -e "  ${C_D}4 carry about twice as much. 1 gives the steadiest ping under heavy load (gaming).${C_N}"
      echo -e "  ${C_D}Set it on the end that dials (the foreign server, or the relay in direct mode).${C_N}"
      v=$(ask "  links [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" links "$v" int
      ;;
    mtcp|mtcpobf)
      cur="$(jget "$cfg" links)"
      echo -e "  ${C_D}links: 0 = auto-scale with load (recommended)${C_N}"
      v=$(ask "  links [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" links "$v" int
      cur="$(jget "$cfg" links_max)"
      v=$(ask "  links_max (auto: most links, 0 = no cap) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" links_max "$v" int
      cur="$(jget "$cfg" links_per_link)"
      v=$(ask "  links_per_link (auto: users per link before another opens) [${cur:-1}]" ""); [ -n "$v" ] && jset "$work" links_per_link "$v" int
      ;;
    tcpnomux)
      cur="$(jget "$cfg" pool_size)"
      echo -e "  ${C_D}pool_size: 0 = auto-scale with load (recommended)${C_N}"
      v=$(ask "  pool_size [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" pool_size "$v" int
      cur="$(jget "$cfg" pool_min_idle)"
      v=$(ask "  pool_min_idle (auto: idle connections kept ready) [${cur:-16}]" ""); [ -n "$v" ] && jset "$work" pool_min_idle "$v" int
      ;;
    ws)
      cur="$(jget "$cfg" ws_path)"
      v=$(ask "  ws_path (same on both ends) [${cur:-/}]" ""); [ -n "$v" ] && jset "$work" ws_path "$v"
      if ! tunnel_listens "$cfg"; then
        cur="$(jget "$cfg" ws_host)"
        v=$(ask "  ws_host (fake Host header; '-' clears) [${cur:-none}]" "")
        if [ "$v" = - ]; then jset "$work" ws_host "" del; elif [ -n "$v" ]; then jset "$work" ws_host "$v"; fi
        cur="$(jget "$cfg" ws_user_agent)"
        v=$(ask "  ws_user_agent ('-' = default) [${cur:-default}]" "")
        if [ "$v" = - ]; then jset "$work" ws_user_agent "" del; elif [ -n "$v" ]; then jset "$work" ws_user_agent "$v"; fi
      fi
      ;;
    sctp)
      cur="$(jget "$cfg" sctp_streams)"
      v=$(ask "  sctp_streams (1-65535) [${cur:-8}]" ""); [ -n "$v" ] && jset "$work" sctp_streams "$v" int
      cur="$(jget "$cfg" sctp_multihoming)"
      echo -e "  ${C_D}Extra local IPs for multihoming, comma-separated (blank keeps; '-' clears).${C_N}"
      v=$(ask "  sctp_multihoming [${cur:-none}]" "")
      if [ "$v" = "-" ]; then jset "$work" sctp_multihoming "" del; elif [ -n "$v" ]; then jset "$work" sctp_multihoming "$v"; fi
      ;;
  esac

  cur="$(jget "$cfg" smux_recv_mb)"
  v=$(ask "  smux_recv_mb (session window MB; larger = more throughput on long links, more memory; 0 = auto: 16+, mtcp 2-8 by RAM) [${cur:-auto}]" ""); [ -n "$v" ] && jset "$work" smux_recv_mb "$v" int
  cur="$(jget "$cfg" smux_stream_mb)"
  v=$(ask "  smux_stream_mb (per-stream window MB; 0 = auto: half the session's) [${cur:-auto}]" ""); [ -n "$v" ] && jset "$work" smux_stream_mb "$v" int
  cur="$(jget "$cfg" smux_frame_kb)"
  v=$(ask "  smux_frame_kb (largest frame KB; 0 = default) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" smux_frame_kb "$v" int

  if [ "$(transport_family "$tr")" = stream ]; then
    if tunnel_listens "$cfg"; then
      cur="$(jget "$cfg" bind_addr)"
      v=$(ask "  bind_addr (listen host:port) [$cur]" "")
      [ -n "$v" ] && jset "$work" bind_addr "$(check_bind "$v")"
    else
      cur="$(jget "$cfg" remote_addr)"
      v=$(ask "  remote_addr (the other end, IP:port) [$cur]" ""); v="${v// /}"
      if [ -n "$v" ]; then
        case "$v" in *:*) : ;; *) v="$v:${cur##*:}" ;; esac  # IP only: keep the port
        jset "$work" remote_addr "$v"
      fi
    fi
  fi
  if [ "$mode" = server ]; then
    cur="$(jget "$cfg" quota_total_gb)"
    v=$(ask "  quota_total_gb (0 = unlimited) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" quota_total_gb "$v" float
    cur="$(jget "$cfg" quota_up_gb)"
    v=$(ask "  quota_up_gb   (0 = unlimited) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" quota_up_gb "$v" float
    cur="$(jget "$cfg" quota_down_gb)"
    v=$(ask "  quota_down_gb (0 = unlimited) [${cur:-0}]" ""); [ -n "$v" ] && jset "$work" quota_down_gb "$v" float
  else
    cur="$(jget "$cfg" target_host)"
    v=$(ask "  target_host (where traffic is delivered locally) [$cur]" ""); [ -n "$v" ] && jset "$work" target_host "$v"
  fi

  cur="$(jget "$cfg" log_level)"
  v=$(ask "  log_level (info/debug/error) [$cur]" ""); [ -n "$v" ] && jset "$work" log_level "$v"

  tune_apply "$n" "$cfg" "$work" || { read -t 30 -rp "  ▶ press ENTER to continue... " _; return; }
  info "settings saved, '$n' restarted"
  warn "Transport-level settings (kcp_*, links, smux_*) must MATCH on both sides."
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# delete_all_tunnels removes every configured tunnel in one step.
delete_all_tunnels(){
  local names=() f
  for f in "$CFG_DIR"/*.json; do [ -e "$f" ] || continue; names+=("$(basename "$f" .json)"); done
  if [ "${#names[@]}" -eq 0 ]; then warn "No tunnels to delete."; sleep 1; return; fi
  echo; echo -e "${C_R}  This will delete ALL ${#names[@]} tunnel(s):${C_N} ${names[*]}"
  echo -e "  ${C_D}Configs and services are removed. Traffic stats are kept.${C_N}"
  local c; c=$(ask "Type DELETE-ALL to confirm" "")
  [ "$c" = "DELETE-ALL" ] || { warn "cancelled"; sleep 1; return; }
  local n
  for n in "${names[@]}"; do
    systemctl disable --now "brokennode@$n" >/dev/null 2>&1
    rm -f "$CFG_DIR/$n.json"
    echo "  removed $n"
  done
  "$BIN" cleanup 2>/dev/null | sed 's/^/  /'   # NAT rules a stop failed to remove
  info "all tunnels deleted"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# edit_config NAME EDITOR — hand-edit a tunnel's config. The result is checked
# by the core before the tunnel is restarted onto it: a typo used to restart
# the tunnel straight into a failure. A refused edit can be fixed again or
# thrown away (the previous config back).
edit_config(){
  local n="$1" ed="$2" cfg="$CFG_DIR/$1.json" undo out a
  [ -n "$ed" ] || { err "No editor found (install nano, or set EDITOR)."; return; }
  undo="$CFG_DIR/.undo-$n.json"; cp -p "$cfg" "$undo"
  while :; do
    "$ed" "$cfg"
    if cmp -s "$cfg" "$undo"; then rm -f "$undo"; info "no changes"; return; fi
    out="$("$BIN" -check -c "$cfg" 2>&1)" && break
    grep -q 'flag provided but not defined' <<<"$out" && break
    err "The core refuses this config: $(check_reason "$out")"
    # Discard is the default: with no one at the keyboard (input ended) "edit
    # again" would reopen the editor for ever.
    a=$(ask "e = edit again, d = discard the changes" "d")
    case "$a" in d|D) mv -f "$undo" "$cfg"; info "changes discarded — the tunnel was not restarted"; return ;; esac
  done
  rm -f "$undo"; chmod 600 "$cfg" 2>/dev/null
  systemctl restart "brokennode@$n"; info "saved & restarted"
}

manage_tunnels(){
  while true; do
    banner; list_tunnels
    if [ "${#TUNNELS[@]}" -eq 0 ]; then read -t 30 -rp "  ▶ press ENTER to continue... " _; return; fi
    echo -e "  ${C_D}Enter a number to manage one tunnel, 'D' to delete ALL, or blank to go back.${C_N}"
    local sel; sel=$(ask "Select tunnel number (empty=back, D=delete all)" ""); [ -z "$sel" ] && return
    case "$sel" in
      d|D) delete_all_tunnels; continue;;
      *[!0-9]*) err "Enter a number, or D to delete all."; sleep 1; continue;;
    esac
    if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#TUNNELS[@]}" ]; then err "Out of range."; sleep 1; continue; fi
    local n="${TUNNELS[$((sel-1))]}"
    local ED; ED="$(command -v nano || command -v vi)"
    while true; do
      echo; echo -e "${C_B}  Manage '$n'${C_N}  ${C_D}[$(systemctl is-active "brokennode@$n" 2>/dev/null)]${C_N}"
      local pfn; pfn=$(ports_failed "$n")
      [ "$pfn" -gt 0 ] && echo -e "  ${C_R}⚠ ${pfn} port(s) of this tunnel are NOT served (another program may hold them). Run 18) Diagnose.${C_N}"
      local vnn; vnn=$(version_note "$n"); [ -n "$vnn" ] && echo -e "  $vnn"
      echo "   1) Start    2) Stop    3) Restart"
      echo "   4) Live logs   5) Show config   6) Edit config (nano)"
      echo "   7) Delete   8) Live stats"
      echo -e "   ${C_G}9) Change transport${C_N}   ${C_G}10) Change peer IP${C_N}   ${C_G}11) Tune settings (MTU/FEC/window...)${C_N}"
      echo -e "   ${C_G}13) Change direction${C_N}  ${C_D}(reverse / direct / proxy) [$(direction_label "$CFG_DIR/$n.json")]${C_N}   ${C_G}14) Encryption & stealth${C_N}  ${C_D}(token, tls, reality, fingerprint, fragment, pad)${C_N}"
      echo -e "   ${C_G}15) Speed test${C_N}  ${C_D}(download/upload/ping through this tunnel)${C_N}"
      echo -e "   ${C_G}16) Apply preset${C_N}  ${C_D}(Optimized/High-Speed/Stable/Low-Latency/Eco)${C_N}   ${C_G}17) Port-forwards${C_N}  ${C_D}(add / remove / replace)${C_N}"
      echo -e "   ${C_G}18) Diagnose${C_N}  ${C_D}(connected but users get nothing? checks every port end to end, firewall, NAT rules)${C_N}"
      echo -e "   ${C_G}19) Share code${C_N}  ${C_D}(one line to paste on the other server: it sets up its end of this tunnel)${C_N}"
      echo "   0) Back"
      case "$(menu_ask 'Choice')" in
        1) systemctl enable --now "brokennode@$n" >/dev/null 2>&1; systemctl start "brokennode@$n"; info "started";;
        2) systemctl disable --now "brokennode@$n" >/dev/null 2>&1; info "stopped — stays down until you start it (the health check leaves it alone)";;
        3) systemctl enable "brokennode@$n" >/dev/null 2>&1; systemctl restart "brokennode@$n"; info "restarted";;
        4) live_logs "$n";;
        5) echo; cat "$CFG_DIR/$n.json"; echo; read -t 30 -rp "  ▶ press ENTER to continue... " _;;
        6) edit_config "$n" "${EDITOR:-$ED}";;
        7) local c; c=$(ask "Delete '$n' permanently? yes/no" "no")
           if [ "$c" = yes ]; then
             systemctl disable --now "brokennode@$n" >/dev/null 2>&1
             rm -f "$CFG_DIR/$n.json" "$CFG_DIR/.undo-$n.json" "/var/lib/brokennode/$n.stats" "/run/brokennode/$n".*
             # A NAT rule the stop failed to remove would keep sending the
             # port to this deleted tunnel; sweep whatever is left.
             "$BIN" cleanup 2>/dev/null | sed 's/^/  /'
             info "deleted '$n'"; break
           fi;;
        8) stats_page "$n";;
        9) change_transport "$n";;
        10) change_relay_ip "$n";;
        11) tune_tunnel "$n";;
        12) warn "Duplicate UDP packets was removed with quic in 2.3.22 (only quic could carry it).";;
        13) change_direction "$n";;
        14) edit_security "$n";;
        15) speed_test "$n"; read -t 120 -rp "  ▶ press ENTER to continue... " _;;
        16) apply_preset "$n";;
        17) manage_ports "$n";;
        18) diagnose "$n";;
        19) SHARE_PUB=""; show_pair_code "$n" 1; read -rp "  ▶ press ENTER to continue... " _;;
        __eof__) return;;
        0) break;;
        *) warn "Invalid.";;
      esac
    done
  done
}


# --- Share codes ---------------------------------------------------------------
#
# Setting up the second server of a tunnel used to mean retyping everything the
# first one was given (transport, encryption, token, tunnel addresses, ports,
# keys) and one typo kept the tunnel down. And when a server's IP got filtered,
# every tunnel on it had to be built again on the new one by hand.
#
# A share code carries that instead, as one line to paste into the other
# server's terminal:
#   pair    the OTHER end of one tunnel, already mirrored for that server:
#           mode swapped, addresses swapped, the address it must dial filled
#           in. Made on either end. Pasted on a server that already has this
#           tunnel (same token), it updates it in place.
#   backup  every tunnel on this server, as they are. Pasted on a new server
#           it rebuilds them all, and prints a pair code for every other
#           server that has to learn the new address.
# A code is a short line of letters and digits in groups of six (the format is
# described at encode() below). It holds the tunnels' tokens: it is a secret.

# bnshare SUBCOMMAND ... — the share code helpers:
#   pair CFG NAME PUBIP        the pair code of tunnel NAME (PUBIP: this
#                              server's public IP, for the end that dials it)
#   backup CFGDIR IP4 IP6 HOST OFF
#                              the backup code of every tunnel in CFGDIR;
#                              OFF: the stopped ones, comma-separated
#   probe TEXT                 succeeds when TEXT holds a whole, valid code
#   encode FILE                the code of the body in FILE (for the tests)
#   unpack TEXT DIR            one config per tunnel into DIR/<i>.json; prints
#                              "kind count ip4 ip6 host", then "i name on|off"
#   match CFGDIR TOKEN         "name mode" of every tunnel with TOKEN
#   merge CFG NEW OUT          CFG updated from the pair code's NEW into OUT
bnshare(){
  python3 - "$@" <<'PYEOF'
import glob, ipaddress, json, os, re, sys, zlib

P2P = ("gre", "gretap", "ipip", "sit", "l2tp", "udp", "icmp")
# What belongs to ONE server and never travels to the other: its user ports,
# quotas and proxy, where it delivers, its device name, its extra local
# addresses and its certificate files.
LOCAL = {"ports", "quota_total_gb", "quota_up_gb", "quota_down_gb", "socks",
         "socks_user", "socks_pass", "socks_open", "target_host", "tun_name",
         "sctp_multihoming", "tls_cert", "tls_key", "tls_auto_email",
         "tls_auto_cache"}
# What the two ends must agree on. The code speaks for the other end: one of
# these it does not carry is unset there, so an update removes it here too
# (padding left on at one end alone would keep the tunnel down).
MATCH = {"transport", "encryption", "token", "direction", "pad", "ws_path",
         "server_name", "alpn", "reality_dest", "reality_server_name",
         "kcp_mode", "kcp_data", "kcp_parity", "kcp_mtu", "keepalive", "mtu",
         "carrier_port", "gre_key", "fou_port", "l2tp_tunnel_id", "l2tp_session_id",
         "l2tp_encap", "l2tp_port", "tls_selfsigned", "tls_insecure"}
SWAP = {"local_ip": "remote_ip", "remote_ip": "local_ip",
        "tun_local": "tun_remote", "tun_remote": "tun_local"}
WILD = ("", "0.0.0.0", "::", "*")


def fail(msg):
    sys.stderr.write("\033[0;31m  [x]\033[0m %s\n" % msg)
    sys.exit(1)


def load(path):
    with open(path) as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise ValueError("not a JSON object")
    return d


def save(path, d):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as o:
        json.dump(d, o, indent=2)
        o.write("\n")


def split_hp(addr):
    addr = str(addr or "").strip()
    if ":" not in addr:
        return None, None
    host, port = addr.rsplit(":", 1)
    return host.strip("[]"), port


def hostport(host, port):
    return ("[%s]:%s" if ":" in host else "%s:%s") % (host, port)


def private(host):
    """An address other servers cannot dial (a VPS behind NAT listens on one)."""
    try:
        a = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(a in ipaddress.ip_network(n) for n in (
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8",
        "169.254.0.0/16", "fc00::/7", "fe80::/10", "::1/128"))


def mirror(src, pubip):
    """The other end of tunnel src, as that server must run it."""
    out = {}
    for k, v in src.items():
        if k in LOCAL or k in SWAP or k in ("mode", "bind_addr", "remote_addr", "tls_selfsigned", "tls_insecure"):
            continue
        out[k] = v
    out["mode"] = "client" if src.get("mode") == "server" else "server"
    for k, other in SWAP.items():
        if src.get(k) not in (None, ""):
            out[other] = src[k]
    if src.get("transport") not in P2P:
        # Where this end listens, the other dials; where this end dials, the
        # other listens. Both addresses are kept when a tunnel is flipped, so
        # both are mirrored, and flipping back works on either server.
        stream_direct = str(src.get("direction") or "").strip().lower() == "direct"
        listens = (src.get("mode") == "server") != stream_direct
        host, port = split_hp(src.get("bind_addr"))
        if port:
            if host in WILD or private(host):
                host = pubip
            if host:
                out["remote_addr"] = hostport(host, port)
            elif listens:
                fail("the other server dials this one: this server's public IP is needed")
        host, port = split_hp(src.get("remote_addr"))
        if port:
            out["bind_addr"] = ("[::]:%s" if host and ":" in host else "0.0.0.0:%s") % port
    # tls_selfsigned (the listening end) and tls_insecure (the dialing end)
    # both mean "a self-signed pair" and the core honours either on either
    # end, so the mirror carries both: it stays right after a direction flip.
    if src.get("tls_selfsigned") or src.get("tls_insecure"):
        out["tls_selfsigned"] = True
        out["tls_insecure"] = True
    # Nothing that says nothing, so the code stays short: kcp's settings on
    # another transport, the default log level, tuning left at 0 (= auto).
    if out.get("transport") != "kcp":
        for k in ("kcp_mode", "kcp_data", "kcp_parity", "kcp_sndwnd", "kcp_rcvwnd", "kcp_mtu"):
            out.pop(k, None)
    # The core's defaults: unset at the other end means the same.
    for k, d in (("log_level", "info"), ("keepalive", 10), ("mtu", 0)):
        if out.get(k) == d:
            del out[k]
    for k in list(out):
        if k not in MATCH and k not in SWAP and out[k] in (0, "", False, None) and out[k] is not True:
            del out[k]
    return out


def clean(v):
    """v without control characters: values from a pasted code are printed
    on the terminal, and an escape sequence in one would act on it."""
    if isinstance(v, str):
        return re.sub(r"[\x00-\x1f\x7f]", "", v)
    if isinstance(v, list):
        return [clean(x) for x in v]
    if isinstance(v, dict):
        return dict((clean(k), clean(x)) for k, x in v.items())
    return v


# --- the code format ----------------------------------------------------------
# A code is short enough to read: the body (a dict) packed into bytes — every
# known key and common value a single byte, addresses as their bytes, a
# token as 6 bits a character — deflated when that is shorter, a 3-byte
# checksum after it, written in base58 (no 0 O I l to confuse) in groups of 6.
# KEYS and WORDS are append-only: a code names keys and words by position.
KEYS = ["v", "k", "m", "t", "n", "c", "off", "from", "ip4", "ip6", "host",
        "mode", "transport", "encryption", "token", "log_level", "direction",
        "bind_addr", "ports", "remote_addr", "target_host", "ws_path",
        "keepalive", "server_name", "alpn", "tls_cert", "tls_key",
        "tls_selfsigned", "tls_auto_email", "tls_auto_cache", "tls_insecure",
        "tls_fingerprint", "tls_fragment", "reality_dest", "reality_server_name",
        "socks", "socks_user", "socks_pass", "socks_open", "pad", "pool_size",
        "pool_min_idle", "links", "links_max", "links_per_link", "quota_total_gb",
        "quota_up_gb", "quota_down_gb", "smux_recv_mb", "smux_stream_mb",
        "smux_frame_kb", "kcp_mode", "kcp_data", "kcp_parity", "carrier_port",
        "tun_name", "tun_local", "tun_remote", "mtu", "local_ip", "remote_ip",
        "gre_key", "tun_ttl", "sctp_streams", "sctp_multihoming",
        "l2tp_tunnel_id", "l2tp_session_id", "l2tp_encap", "l2tp_port",
        "ws_host", "ws_user_agent", "kcp_sndwnd", "kcp_rcvwnd", "kcp_mtu",
        "fou_port"]
WORDS = ["pair", "backup", "server", "client", "reverse", "direct", "tcp", "mtcp",
         "mptcp", "ws", "tcpnomux", "kcp", "sctp", "udp", "icmp", "gre", "gretap",
         "ipip", "sit", "l2tp", "none", "aead", "obfs", "tls", "reality", "fast",
         "normal", "turbo", "gaming", "info", "debug", "warn", "error", "chrome",
         "firefox", "safari", "edge", "ios", "random", "127.0.0.1", "::1",
         "www.microsoft.com:443", "/", "h2,http/1.1", "443/both", "443", "ip",
         "tcpobf", "mtcpobf", "wsobf", "rawmux", "0.0.0.0:1080", "127.0.0.1:1080"]
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
(T_NULL, T_FALSE, T_TRUE, T_UINT, T_NEG, T_FLOAT, T_STR, T_WORD, T_IP4, T_IP6,
 T_HP4, T_HP6, T_ANYPORT, T_HOSTPORT, T_B64, T_LIST, T_DICT) = range(17)


def uvar(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def pack(v):
    if v is None:
        return bytes([T_NULL])
    if v is True or v is False:
        return bytes([T_TRUE if v else T_FALSE])
    if isinstance(v, int):
        return bytes([T_UINT]) + uvar(v) if v >= 0 else bytes([T_NEG]) + uvar(-v)
    if isinstance(v, float):
        s = repr(v).encode()
        return bytes([T_FLOAT]) + uvar(len(s)) + s
    if isinstance(v, list):
        return bytes([T_LIST]) + uvar(len(v)) + b"".join(pack(x) for x in v)
    if isinstance(v, dict):
        out = bytearray([T_DICT]) + uvar(len(v))
        for k, x in v.items():
            if k in KEYS:
                out += uvar(KEYS.index(k) + 1)
            else:
                kb = k.encode()
                out += uvar(0) + uvar(len(kb)) + kb
            out += pack(x)
        return bytes(out)
    s = str(v)
    if s in WORDS:
        return bytes([T_WORD]) + uvar(WORDS.index(s))
    try:
        a = ipaddress.ip_address(s)
        if str(a) == s:
            return bytes([T_IP6 if a.version == 6 else T_IP4]) + a.packed
    except ValueError:
        pass
    host, port = split_hp(s)
    if port and port.isdigit() and 0 < int(port) < 65536 and str(int(port)) == port:
        p = int(port).to_bytes(2, "big")
        if host in ("0.0.0.0",):
            return bytes([T_ANYPORT]) + p
        try:
            a = ipaddress.ip_address(host)
            if str(a) == host and s == hostport(host, port):
                return bytes([T_HP6 if a.version == 6 else T_HP4]) + a.packed + p
        except ValueError:
            pass
        if s == host + ":" + port:
            hb = host.encode()
            return bytes([T_HOSTPORT]) + uvar(len(hb)) + hb + p
    if s and len(s) <= 255 and all(ch in B64 for ch in s):
        n = 0
        for ch in s:
            n = n * 64 + B64.index(ch)
        return bytes([T_B64, len(s)]) + n.to_bytes((len(s) * 6 + 7) // 8, "big")
    b = s.encode()
    return bytes([T_STR]) + uvar(len(b)) + b


class Reader(object):
    def __init__(self, b):
        self.b, self.i = b, 0

    def take(self, n):
        if self.i + n > len(self.b):
            raise ValueError("short")
        out = self.b[self.i:self.i + n]
        self.i += n
        return out

    def uvar(self):
        n = shift = 0
        while True:
            c = self.take(1)[0]
            n |= (c & 0x7f) << shift
            shift += 7
            if not c & 0x80:
                return n
            if shift > 63:
                raise ValueError("varint")

    def value(self, depth=0):
        if depth > 8:
            raise ValueError("too deep")
        t = self.take(1)[0]
        if t == T_NULL:
            return None
        if t in (T_FALSE, T_TRUE):
            return t == T_TRUE
        if t == T_UINT:
            return self.uvar()
        if t == T_NEG:
            return -self.uvar()
        if t == T_FLOAT:
            return float(self.take(self.uvar()).decode())
        if t == T_STR:
            return self.take(self.uvar()).decode()
        if t == T_WORD:
            return WORDS[self.uvar()]
        if t in (T_IP4, T_IP6):
            return str(ipaddress.ip_address(bytes(self.take(4 if t == T_IP4 else 16))))
        if t in (T_HP4, T_HP6):
            a = str(ipaddress.ip_address(bytes(self.take(4 if t == T_HP4 else 16))))
            return hostport(a, int.from_bytes(self.take(2), "big"))
        if t == T_ANYPORT:
            return "0.0.0.0:%d" % int.from_bytes(self.take(2), "big")
        if t == T_HOSTPORT:
            h = self.take(self.uvar()).decode()
            return "%s:%d" % (h, int.from_bytes(self.take(2), "big"))
        if t == T_B64:
            ln = self.take(1)[0]
            n = int.from_bytes(self.take((ln * 6 + 7) // 8), "big")
            s = ""
            for _ in range(ln):
                n, r = divmod(n, 64)
                s = B64[r] + s
            return s
        if t == T_LIST:
            return [self.value(depth + 1) for _ in range(self.uvar())]
        if t == T_DICT:
            d = {}
            for _ in range(self.uvar()):
                k = self.uvar()
                k = self.take(self.uvar()).decode() if k == 0 else KEYS[k - 1]
                d[k] = self.value(depth + 1)
            return d
        raise ValueError("type %d" % t)


HEAD = ("mode", "transport", "encryption", "direction")


def pack_cfg(c):
    """A config: its four main settings a byte each, then the rest."""
    c = dict(c)
    head = b""
    for k in HEAD:
        if isinstance(c.get(k), str) and c[k] in WORDS:
            head += uvar(WORDS.index(c.pop(k)) + 1)
        else:
            head += uvar(0)  # absent, or a value packed with the rest as it is
    return head + pack(c)


def read_cfg(r):
    head = [r.uvar() for _ in HEAD]
    c = r.value()
    if not isinstance(c, dict):
        raise ValueError("config")
    for k, w in zip(HEAD, head):
        if w:
            c[k] = WORDS[w - 1]
    return c


def pack_body(body):
    """version and kind in one byte, then the tunnels."""
    kind = body["k"]
    out = bytearray([0x10 | (1 if kind == "backup" else 0)])
    if kind == "backup":
        m = body.get("m") or {}
        out += pack(m.get("ip4") or "") + pack(m.get("ip6") or "") + pack(m.get("host") or "")
        out += uvar(len(body["t"]))
    for t in body["t"]:
        out += pack(str(t["n"]))
        if kind == "backup":
            out.append(1 if t.get("off") else 0)
        out += pack_cfg(t["c"])
    return bytes(out)


def read_body(raw):
    r = Reader(raw)
    vk = r.take(1)[0]
    if vk >> 4 != 1:
        raise KeyError("version")
    kind = "backup" if vk & 1 else "pair"
    body = {"v": 1, "k": kind, "m": {}, "t": []}
    n = 1
    if kind == "backup":
        body["m"] = {"ip4": r.value(), "ip6": r.value(), "host": r.value()}
        n = r.uvar()
        if n > 1000:
            raise ValueError("count")
    for _ in range(n):
        t = {"n": r.value()}
        if kind == "backup" and r.take(1)[0]:
            t["off"] = True
        t["c"] = read_cfg(r)
        body["t"].append(t)
    if r.i != len(raw):
        raise ValueError("trailing bytes")
    return body


def encode(body):
    raw = pack_body(body)
    z = zlib.compressobj(9, zlib.DEFLATED, -15)
    zd = z.compress(raw) + z.flush()
    data = bytes([2]) + zd if len(zd) < len(raw) else bytes([1]) + raw
    data += (zlib.crc32(data) & 0xffffff).to_bytes(3, "big")
    n, s = int.from_bytes(data, "big"), ""
    while n:
        n, r = divmod(n, 58)
        s = B58[r] + s
    return "-".join(s[i:i + 6] for i in range(0, len(s), 6))


def unbase58(s):
    n = 0
    for ch in s:
        n = n * 58 + B58.index(ch)
    return n.to_bytes((n.bit_length() + 7) // 8, "big")


def decode(text):
    # What was pasted may be the whole line ("BrokenNode import <code>"), or
    # the code broken over several lines: the code is everything else, joined.
    words = [w for w in text.split() if w.lower() not in ("brokennode", "import", "sudo", "bash")]
    s = "".join(words).replace("-", "")
    if not s:
        fail("no share code in what was pasted")
    if any(ch not in B58 for ch in s):
        fail("that is not a share code: it has characters a code never has")
    try:
        data = unbase58(s)
        if len(data) < 5 or (zlib.crc32(data[:-3]) & 0xffffff).to_bytes(3, "big") != data[-3:]:
            raise ValueError("checksum")
        if data[0] not in (1, 2):
            raise KeyError("version")
        raw = data[1:-3]
        if data[0] == 2:
            z = zlib.decompressobj(-15)
            # Capped: a short code must not unpack into gigabytes.
            raw = z.decompress(raw, 4 << 20)
            if z.unconsumed_tail or not z.eof:
                raise ValueError("incomplete")
        body = clean(read_body(raw))
    except KeyError:
        fail("the code was made by a newer BrokenNode: update this server first (menu 5)")
    except Exception:
        fail("the code is damaged or incomplete: copy it again, all of it")
    if not isinstance(body, dict) or body.get("k") not in ("pair", "backup"):
        fail("this is not a BrokenNode share code")
    if body.get("v") != 1:
        fail("the code was made by a newer BrokenNode: update this server first (menu 5)")
    tunnels = body.get("t")
    if not isinstance(tunnels, list) or not tunnels:
        fail("the code holds no tunnel")
    for t in tunnels:
        if not isinstance(t, dict) or not isinstance(t.get("c"), dict):
            fail("the code is damaged: a tunnel in it is not a config")
        # The name becomes a file name here: only what a tunnel name may be.
        t["n"] = re.sub(r"[^A-Za-z0-9_-]", "", str(t.get("n") or ""))[:40] or "main"
    return body


cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "pair":
    path, name, pubip = args
    try:
        src = load(path)
    except Exception as e:
        fail("cannot read %s: %s" % (path, e))
    print(encode({"v": 1, "k": "pair", "t": [{"n": name, "c": mirror(src, pubip)}]}))
elif cmd == "backup":
    cfgdir, ip4, ip6, host, off = args
    off = set(off.split(","))
    tunnels = []
    for f in sorted(glob.glob(os.path.join(cfgdir, "*.json"))):
        n = os.path.basename(f)[:-5]
        try:
            t = {"n": n, "c": load(f)}
            if n in off:
                t["off"] = True
            tunnels.append(t)
        except Exception as e:
            sys.stderr.write("\033[1;33m  [!]\033[0m %s is not a valid config (%s) — left out\n" % (f, e))
    if not tunnels:
        fail("there is no tunnel on this server to back up")
    print(encode({"v": 1, "k": "backup", "m": {"ip4": ip4, "ip6": ip6, "host": host}, "t": tunnels}))
elif cmd == "encode":
    # The body of a code from a JSON file, as it is: for the tests.
    print(encode(load(args[0])))
elif cmd == "probe":
    devnull = open(os.devnull, "w")
    sys.stderr = devnull
    decode(args[0])
elif cmd == "unpack":
    body = decode(args[0])
    m = body.get("m") if isinstance(body.get("m"), dict) else {}
    field = lambda v: re.sub(r"[\s]", "", str(v or "")) or "-"
    print("\t".join([body["k"], str(len(body["t"])), field(m.get("ip4")), field(m.get("ip6")), field(m.get("host") or m.get("from"))]))
    for i, t in enumerate(body["t"], 1):
        if body["k"] == "pair":
            # Never in a pair code made here; dropped from any other, so a
            # code cannot open a proxy or point at files on this server.
            for k in LOCAL:
                t["c"].pop(k, None)
        save(os.path.join(args[1], "%d.json" % i), t["c"])
        print("%d\t%s\t%s" % (i, t["n"], "off" if t.get("off") else "on"))
elif cmd == "match":
    cfgdir, token = args
    for f in sorted(glob.glob(os.path.join(cfgdir, "*.json"))):
        try:
            c = load(f)
        except Exception:
            continue
        if token and c.get("token") == token:
            print("%s\t%s" % (os.path.basename(f)[:-5], c.get("mode") or "-"))
elif cmd == "merge":
    cur, new = load(args[0]), load(args[1])
    stream = lambda c: c.get("transport") not in P2P
    if stream(cur) != stream(new):
        # A switch between a stream transport and a point-to-point tunnel:
        # the old kind's addresses mean nothing any more.
        for k in (("local_ip", "remote_ip", "tun_local", "tun_remote") if stream(new) else ("bind_addr", "remote_addr")):
            cur.pop(k, None)
    for k in MATCH:
        if k not in new:
            cur.pop(k, None)
    cur.update(new)
    save(args[2], cur)
else:
    fail("bnshare: unknown command %s" % cmd)
PYEOF
}

# is_private_ip ADDR — ADDR is one no other server can reach directly: RFC 1918,
# carrier-grade NAT, loopback, link-local or a v6 ULA. A VPS behind NAT reports
# such an address as its own.
is_private_ip(){
  python3 - "$1" <<'PYEOF' 2>/dev/null
import ipaddress, sys
a = ipaddress.ip_address(sys.argv[1])
nets = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8",
        "169.254.0.0/16", "fc00::/7", "fe80::/10", "::1/128"]
sys.exit(0 if any(a in ipaddress.ip_network(n) for n in nets) else 1)
PYEOF
}

# has_local_addr ADDR — an interface of this machine holds ADDR.
has_local_addr(){ ip -o addr show 2>/dev/null | awk '{print $4}' | sed 's#/.*##' | grep -qxF "$1"; }

# share_pubip ASK — this server's public IP, the one the other server dials.
# Detected; asked (the detected one offered) when ASK is 1 or when detection
# finds none or a private address. Asked once per run.
share_pubip(){
  if [ -n "${SHARE_PUB:-}" ]; then echo "$SHARE_PUB"; return 0; fi
  local d def; d="$(detect_ip)"
  if [ "${1:-0}" = 1 ] || [ -z "$d" ] || is_private_ip "$d"; then
    [ -n "$d" ] && is_private_ip "$d" && echo -e "  ${C_D}$d is a private address (this server is behind NAT): give its PUBLIC IP.${C_N}" >&2
    def="$d"
    # Not a public address this server knows: only the operator can say.
    { [ -z "$d" ] || is_private_ip "$d"; } && local IMPORT_AUTO=0
    while :; do
      d=$(ask "This server's public IP (the other server connects to it)" "$def"); d="${d// /}"; d="${d#[}"; d="${d%]}"
      { is_ipv4 "$d" || is_ipv6 "$d"; } && break
      warn "'$d' is not an IPv4 or IPv6 address." >&2
    done
  fi
  SHARE_PUB="$d"; echo "$d"
}

# pair_code NAME ASK — the pair code of tunnel NAME. This server's public IP
# goes in only when the other end dials this one and the listen address is
# not one it can dial (the wildcard, or a private address behind NAT).
pair_code(){
  local n="$1" cfg="$CFG_DIR/$1.json" ip="" b h
  [ -f "$cfg" ] || { err "There is no tunnel '$n' on this server."; return 1; }
  if [ "$(transport_family "$(jget "$cfg" transport)")" = stream ] && tunnel_listens "$cfg"; then
    b="$(jget "$cfg" bind_addr)"; h="${b%:*}"; h="${h#[}"; h="${h%]}"
    case "$h" in
      ""|0.0.0.0|::|"*") ip="$(share_pubip "${2:-0}")" ;;
      *) is_private_ip "$h" && ip="$(share_pubip "${2:-0}")" ;;
    esac
  fi
  bnshare pair "$cfg" "$n" "$ip"
}

# print_code CODE — the line that imports CODE on another server, and the one
# for a server without BrokenNode yet (the installer installs, then imports).
print_code(){
  echo
  echo "    BrokenNode import $1"
  echo
  echo -e "  ${C_D}No BrokenNode on that server yet? This line installs it and imports:${C_N}"
  echo
  echo "    bash <(curl -fsSL $INSTALL_URL) import $1"
  echo
  echo -e "  ${C_D}Or there: BrokenNode → 6) Share codes → 3) Paste a code, and paste just the code.${C_N}"
}

# show_pair_code NAME ASK — the code that sets up the other end of NAME.
show_pair_code(){
  local n="$1" cfg="$CFG_DIR/$1.json" code other="FOREIGN server"
  code="$(pair_code "$n" "${2:-0}")" || return 1
  [ "$(jget "$cfg" mode)" = client ] && other="IRAN server"
  echo
  echo -e "  ${C_B}Share code — sets up the other end of '$n' with one paste.${C_N}"
  echo -e "  On the ${C_Y}$other${C_N}, paste this line into its terminal:"
  print_code "$code"
  [ -n "${SHARE_PUB:-}" ] && echo -e "  ${C_D}The other server will connect to this one at ${C_N}$SHARE_PUB${C_D}.${C_N}"
  echo -e "  ${C_Y}The code holds this tunnel's secret token — keep it private.${C_N}"
}

# show_backup_code — one code with every tunnel on this server.
show_backup_code(){
  local f n=0 code
  for f in "$CFG_DIR"/*.json; do [ -e "$f" ] && n=$((n+1)); done
  [ "$n" -gt 0 ] || { warn "There are no tunnels on this server yet."; return 1; }
  # Stopped tunnels are restored stopped.
  local off="" t
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue; t="$(basename "$f" .json)"
    [ "$(systemctl is-enabled "brokennode@$t" 2>/dev/null)" = disabled ] && off="$off,$t"
  done
  code="$(bnshare backup "$CFG_DIR" "$(detect_ip)" "$(detect_ip6)" "$(hostname 2>/dev/null)" "${off#,}")" || return 1
  echo
  echo -e "  ${C_B}Backup code — all $n tunnel(s) of this server in one line.${C_N}"
  echo -e "  ${C_D}Copy it NOW and keep it somewhere safe (Saved Messages, a note): once this server's IP${C_N}"
  echo -e "  ${C_D}is filtered you may not reach it any more. On the new server, paste:${C_N}"
  print_code "$code"
  echo -e "  ${C_D}Every tunnel comes back as it was, and the new server prints a code for each other${C_N}"
  echo -e "  ${C_D}server that has to learn its new IP.${C_N}"
  echo -e "  ${C_Y}The code holds every tunnel's secret token — keep it private.${C_N}"
}

# read_code — a pasted code. Read with readline (-e): a terminal's line buffer
# otherwise cuts a pasted line at 4095 characters, and a backup of many tunnels
# is longer. Lines are joined until they make a whole code, so one a terminal
# broke over several lines still comes through.
read_code(){
  local acc="" line
  echo -e "  ${C_D}Paste the code, then press Enter (an empty line cancels).${C_N}" >&2
  while :; do
    if [ -t 0 ]; then IFS= read -r -e -p "  > " line || break
    else IFS= read -r line || break; fi
    [ -n "${line//[[:space:]]/}" ] || break
    acc="$acc$line"
    bnshare probe "$acc" && break
    echo -e "  ${C_D}Not a whole code yet — paste the rest, or an empty line to stop.${C_N}" >&2
  done
  echo "$acc"
}

# share_name NAME — the name to import a tunnel under: NAME when no tunnel here
# has it; otherwise asked, a free variant offered. A taken name is used only
# when the operator agrees to replace that tunnel.
share_name(){
  local n="$1" alt i=2
  [ -f "$CFG_DIR/$n.json" ] || { echo "$n"; return 0; }
  while [ -f "$CFG_DIR/$n-$i.json" ]; do i=$((i+1)); done
  warn "This server already has a different tunnel named '$n'." >&2
  while :; do
    alt=$(ask "Name for the imported tunnel" "$n-$i"); alt="$(echo "$alt" | tr -cd 'A-Za-z0-9_-')"
    [ -n "$alt" ] || continue
    [ -f "$CFG_DIR/$alt.json" ] || { echo "$alt"; return 0; }
    yes_no "Replace the tunnel '$alt' that is here with this one? y/N" n && { echo "$alt"; return 0; }
  done
}

# share_local_ip FILE KEEP — a point-to-point tunnel's local_ip must be an
# address of this server. The one in a code may not be: the other server's
# idea of this one (behind NAT it is the public address), or the OLD server's
# in a backup. KEEP (the tunnel's current local_ip, on an update) is kept when
# this server holds it; otherwise asked once per address family, the
# detected address offered.
# shellcheck disable=SC2178,SC2128  # keep is a local string here, not edit_ports' array
share_local_ip(){
  local f="$1" keep="${2:-}" cur fam=4 isfam=is_ipv4 d def var
  cur="$(jget "$f" local_ip)"; [ -n "$cur" ] || return 0
  has_local_addr "$cur" && return 0
  case "$cur" in *:*) fam=6; isfam=is_ipv6 ;; esac
  if [ -n "$keep" ] && $isfam "$keep" && has_local_addr "$keep"; then jset "$f" local_ip "$keep"; return 0; fi
  var="SHARE_IP$fam"
  if [ -z "${!var:-}" ]; then
    if [ "$fam" = 6 ]; then def="$(detect_ip6)"; else def="$(detect_ip)"; fi
    echo -e "  ${C_D}The code names $cur as this server's address, but no interface here holds it.${C_N}" >&2
    # Chosen automatically only when this server holds the detected address.
    { [ -n "$def" ] && has_local_addr "$def"; } || local IMPORT_AUTO=0
    while :; do
      d=$(ask "This server's IPv$fam for point-to-point tunnels" "$def"); d="${d// /}"; d="${d#[}"; d="${d%]}"
      $isfam "$d" && break
      warn "'$d' is not an IPv$fam address." >&2
    done
    printf -v "$var" '%s' "$d"
  fi
  jset "$f" local_ip "${!var}"
}

# share_bind FILE — a listen address naming an IP this server does not have
# (the old server's, in a backup) becomes the wildcard on the same port.
share_bind(){
  local f="$1" b h p w; b="$(jget "$f" bind_addr)"; [ -n "$b" ] || return 0
  h="${b%:*}"; p="${b##*:}"; h="${h#[}"; h="${h%]}"
  case "$h" in ""|0.0.0.0|::|"*") return 0 ;; esac
  has_local_addr "$h" && return 0
  w="0.0.0.0:$p"; case "$h" in *:*) w="[::]:$p" ;; esac
  jset "$f" bind_addr "$w"
  info "Listen address $b is not one of this server's: it listens on $w instead."
}

# start_tunnel_unit NAME — enable and (re)start the tunnel and say whether it
# came up.
start_tunnel_unit(){
  local n="$1"
  systemctl enable "brokennode@$n" >/dev/null 2>&1; systemctl restart "brokennode@$n"; sleep 1.5
  if [ "$(systemctl is-active "brokennode@$n" 2>/dev/null)" = active ]; then info "Tunnel '$n' is ${C_G}active${C_N}."; return 0; fi
  err "Tunnel '$n' failed to start. Recent log:"; journalctl -u "brokennode@$n" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

# share_install FILE NAME [off] — FILE becomes tunnel NAME and starts (with
# "off": stays stopped, as it was on the server the backup came from).
# Replacing a tunnel goes through cfg_begin/cfg_commit: one the core refuses
# is rolled back rather than lost.
share_install(){
  local f="$1" n="$2" cfg="$CFG_DIR/$2.json"
  if [ -f "$cfg" ]; then
    cfg_begin "$cfg"; cat "$f" > "$cfg"; cfg_commit "$cfg" || return 1
  else
    new_cfg_file "$cfg"; cat "$f" > "$cfg"; core_check "$cfg" || return 1
  fi
  install_health
  if [ "${3:-}" = off ]; then
    systemctl disable --now "brokennode@$n" >/dev/null 2>&1
    info "Tunnel '$n' restored, stopped (it was stopped there too)."
    return 0
  fi
  start_tunnel_unit "$n"
}

# import_note CFG — what this server still needs after an import.
import_note(){
  local cfg="$1" dir listens addr ports ip proto=tcp
  IFS=$'\t' read -r dir listens addr ports < <(tunnel_summary "$cfg")
  if [ "$(jget "$cfg" mode)" = server ] && [ "$ports" != "?" ]; then
    ip="$(detect_ip)"
    echo -e "  ${C_G}Users / client configs connect to${C_N} ${C_Y}${ip:-THIS-SERVER-IP}${C_N} ${C_D}ports${C_N} ${C_Y}$(printf '%s' "$ports" | sed 's#=[0-9]*##g; s#/[a-z]*##g')${C_N}"
  fi
  [ -n "$(jget "$cfg" socks)" ] && socks_summary "$cfg"
  if [ "$(transport_family "$(jget "$cfg" transport)")" = stream ] && [ "$listens" = 1 ]; then
    [ "$(jget "$cfg" transport)" = kcp ] && proto=udp
    echo -e "  ${C_D}The other server connects to this one on ${proto^^} ${addr##*:}: allow it inbound in the firewall (e.g. ufw allow ${addr##*:}/$proto).${C_N}"
  fi
}

# import_pair DIR — set up (or update) this end of the tunnel in a pair code.
import_pair(){
  local tmp="$1" i name f mode tr enc
  IFS=$'\t' read -r i name _ < <(sed -n 2p "$tmp/list")
  f="$tmp/$i.json"
  mode="$(jget "$f" mode)"; tr="$(jget "$f" transport)"; enc="$(jget "$f" encryption)"
  local role="the FOREIGN server (client)" other="the Iran server"
  [ "$mode" = server ] && { role="the IRAN relay (server)"; other="the foreign server"; }
  echo
  echo -e "  ${C_B}Tunnel '$name'${C_N}: ${C_Y}$tr${C_N} + ${C_Y}${enc:-none}${C_N}${C_D}, direction $(direction_label "$f")${C_N}"
  echo -e "  This server becomes ${C_Y}$role${C_N} of it."

  # The same tunnel (same token) already here: update it in place. The same
  # tunnel as the OTHER end: the code was pasted back on the server that made it.
  local tok en em same="" self=""; tok="$(jget "$f" token)"
  while IFS=$'\t' read -r en em; do
    [ -n "$en" ] || continue
    if [ "$em" = "$mode" ]; then same="$en"; else self="$en"; fi
  done < <(bnshare match "$CFG_DIR" "$tok")
  if [ -z "$same" ] && [ -n "$self" ]; then
    warn "This code was made on THIS server (from its tunnel '$self'): paste it on $other."
    yes_no "Import it here anyway? y/N" n || { warn "Cancelled."; return 1; }
  fi
  local target update=0 cfg
  if [ -n "$same" ]; then
    echo -e "  ${C_D}This server already has this tunnel, as '$same' (same token).${C_N}"
    yes_no "Update '$same' to match the other server? Y/n" y || { warn "Cancelled."; return 1; }
    target="$same"; update=1
  else
    target="$(share_name "$name")" || return 1
  fi
  cfg="$CFG_DIR/$target.json"

  [ "$(transport_family "$tr")" = stream ] || share_local_ip "$f" "$([ "$update" = 1 ] && jget "$cfg" local_ip)"
  local final="$f"
  if [ "$update" = 1 ]; then bnshare merge "$cfg" "$f" "$f.new" || return 1; final="$f.new"; fi
  # What a code cannot carry: where the foreign end delivers, and the user
  # ports of the relay (the foreign server does not know them).
  if [ "$mode" = client ] && [ -z "$(jget "$final" target_host)" ]; then
    if [ "$tr" = sit ]; then jset "$final" target_host ::1; else jset "$final" target_host 127.0.0.1; fi
  fi
  local own=""
  if [ "$(transport_family "$tr")" = stream ] && tunnel_listens "$final"; then
    own="$(jget "$final" bind_addr)"; own="${own##*:}"
    warn_port_clash "" "$target" "$own" "$([ "$tr" = kcp ] && echo udp || echo tcp)" || true
  fi
  if [ "$mode" = server ] && [ -z "$(jget "$final" socks)" ] && [ -z "$(jq_ports "$final")" ]; then
    echo -e "  ${C_D}The code comes from the foreign server, which does not know the user ports: give them here.${C_N}"
    local p last="" IMPORT_AUTO=0
    while :; do
      p="$(ask_ports "$target")" || return 1
      # The tunnel's own port cannot also be a user port (the core refuses it).
      case ",$(printf '%s' "$p" | tr -d '"' | sed 's#=[0-9]*##g; s#/[a-z]*##g')," in
        *",$own,"*) [ -n "$own" ] && {
            warn "Port $own is the tunnel's own port here — give the users another one."
            input_ended "$p" "$last" && return 1
            last="$p"; continue; } ;;
      esac
      break
    done
    jmerge "$final" "{\"ports\":[$p]}"
  fi
  if [ "$enc" = tls ] && tunnel_listens "$final" && [ "$(onoff "$final" tls_selfsigned)" = off ] && [ "$(onoff "$final" tls_insecure)" = off ] && [ -z "$(jget "$final" tls_cert)" ]; then
    warn "This end shows the TLS certificate, and the other server checks it against a real CA:"
    echo -e "  ${C_D}it is fetched from Let's Encrypt, so ${C_N}$(jget "$final" server_name)${C_D} must point to this server and the tunnel must${C_N}"
    echo -e "  ${C_D}listen on port 443 — or set certificate files later in 14) Encryption & stealth.${C_N}"
  fi
  share_install "$final" "$target" || return 1
  [ "$update" = 1 ] && info "Updated '$target' to match the other server."
  import_note "$cfg"
}

# import_backup DIR — rebuild every tunnel of a backup code on this server,
# then print the code each other server needs to learn this server's address.
import_backup(){
  local tmp="$1" kind count oip4 oip6 ohost i name f
  IFS=$'\t' read -r kind count oip4 oip6 ohost < <(head -n 1 "$tmp/list")
  [ "$oip4" = - ] && oip4=""; [ "$oip6" = - ] && oip6=""; [ "$ohost" = - ] && ohost="another server"
  echo
  echo -e "  ${C_B}Backup of $count tunnel(s)${C_N} from ${C_Y}$ohost${C_N}${C_D}${oip4:+ ($oip4)}${C_N}:"
  local on sx risky=""
  while IFS=$'\t' read -r i name on; do
    f="$tmp/$i.json"
    printf "   %-16s ${C_D}%s/%s + %s, %s%s${C_N}\n" "$name" "$(jget "$f" mode)" "$(jget "$f" transport)" "$(jget "$f" encryption)" "$(direction_label "$f")" "$([ "$on" = off ] && echo ', stopped')"
    # What a restore opens on THIS server, beyond the tunnel itself: a backup
    # restores every setting, and one made by someone else could carry any.
    sx="$(jget "$f" socks)"
    if [ -n "$sx" ] && [ -z "$(jget "$f" socks_user)" ] && [ "$(jget "$f" socks_open)" = True ]; then
      echo -e "   ${C_R}  ↳ opens a proxy on $sx with NO password, open to anyone who finds it${C_N}"; risky=1
    elif [ -n "$sx" ]; then
      echo -e "   ${C_D}  ↳ opens a proxy on $sx$([ -n "$(jget "$f" socks_user)" ] && echo ' (password protected)')${C_N}"
    fi
    [ -n "$(jget "$f" tun_name)" ] && echo -e "   ${C_D}  ↳ uses the network interface name $(jget "$f" tun_name)${C_N}"
  done < <(tail -n +2 "$tmp/list")
  if [ -n "$risky" ]; then
    local IMPORT_AUTO=0   # never restored without the operator saying so
    warn "A backup you did not make yourself can carry settings like these: restore only your own."
    yes_no "Restore them on this server? y/N" n || { warn "Cancelled."; return 1; }
  else
    yes_no "Restore them on this server? Y/n" y || { warn "Cancelled."; return 1; }
  fi

  local restored=() peers=() target was pub=""
  while IFS=$'\t' read -r i name on <&3; do
    f="$tmp/$i.json"; target="$name"
    echo; echo -e "  ${C_B}$name${C_N}"
    if [ -f "$CFG_DIR/$name.json" ]; then
      if [ "$(jget "$CFG_DIR/$name.json" token)" = "$(jget "$f" token)" ]; then
        yes_no "'$name' is already on this server. Replace it with the backup? y/N" n || { info "Kept '$name' as it is."; continue; }
      else
        target="$(share_name "$name")" || continue
      fi
    fi
    was="$(jget "$f" local_ip)"
    if [ "$(transport_family "$(jget "$f" transport)")" = stream ]; then share_bind "$f"; else share_local_ip "$f"; fi
    if [ -n "$(jget "$f" sctp_multihoming)" ]; then
      jset "$f" sctp_multihoming "" del
      warn "Dropped sctp_multihoming: those were the old server's extra addresses."
    fi
    local k p
    for k in tls_cert tls_key; do
      p="$(jget "$f" "$k")"
      [ -n "$p" ] && [ ! -f "$p" ] && warn "$k $p does not exist on this server: copy it here, or switch to self-signed (14 Encryption & stealth)."
    done
    share_install "$f" "$target" "$on" || continue
    restored+=("$target")
    # Does the other end have to learn this server's address? It does when it
    # dials this one (a stream tunnel that listens here) or names it (every
    # point-to-point tunnel), and the address changed.
    local cfg="$CFG_DIR/$target.json"
    if [ "$(transport_family "$(jget "$cfg" transport)")" = stream ]; then
      if tunnel_listens "$cfg"; then
        [ -n "$pub" ] || pub="$(share_pubip 0)"
        [ "$pub" != "$oip4" ] && [ "$pub" != "$oip6" ] && peers+=("$target")
      fi
    elif [ "$(jget "$cfg" local_ip)" != "$was" ]; then
      peers+=("$target")
    fi
  done 3< <(tail -n +2 "$tmp/list")

  echo
  if [ "${#restored[@]}" -gt 0 ]; then info "Restored ${#restored[@]} of $count tunnel(s): ${restored[*]}."
  else warn "No tunnel was restored."; fi
  [ "${#peers[@]}" -gt 0 ] || return 0
  echo
  echo -e "  ${C_B}The other servers still know this server's OLD address.${C_N}"
  echo -e "  ${C_D}Paste each line on the server named: it updates its end of that tunnel in place.${C_N}"
  local n code who
  for n in "${peers[@]}"; do
    cfg="$CFG_DIR/$n.json"
    who="the foreign server"; [ "$(jget "$cfg" mode)" = client ] && who="the Iran server"
    [ "$(transport_family "$(jget "$cfg" transport)")" = stream ] || who="$who ($(jget "$cfg" remote_ip))"
    code="$(bnshare pair "$cfg" "$n" "$pub")" || continue
    echo
    echo -e "  ${C_Y}$n${C_N} — on $who:"
    echo
    echo "    BrokenNode import $code"
  done
  echo
}

# import_code [CODE] — import a pair or backup code; asked for when not given.
import_code(){
  need_root; ensure_core || return 1; mkdir -p "$CFG_DIR"; harden_cfg_dir; write_template
  install_command; auto_tune_once
  local code="$*" tmp rc=0 kind IMPORT_AUTO=0
  if [ -z "${code//[[:space:]]/}" ]; then
    echo; echo -e "${C_B}  Paste a share or backup code${C_N}"
    code="$(read_code)"
  else
    IMPORT_AUTO=1
  fi
  [ -n "${code//[[:space:]]/}" ] || { warn "Nothing pasted — cancelled."; return 1; }
  tmp="$(mktemp -d "$CFG_DIR/.import.XXXXXX")" || return 1
  # shellcheck disable=SC2034  # share_local_ip reads them as ${!var}
  SHARE_IP4="" SHARE_IP6="" SHARE_PUB=""
  if bnshare unpack "$code" "$tmp" > "$tmp/list"; then
    kind="$(head -n 1 "$tmp/list" | cut -f1)"
    if [ "$kind" = pair ]; then import_pair "$tmp" || rc=1; else import_backup "$tmp" || rc=1; fi
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# pick_tunnel — list the tunnels; PICKED is the one chosen (fails when there
# is none or nothing is chosen).
pick_tunnel(){
  PICKED=""; list_tunnels
  [ "${#TUNNELS[@]}" -gt 0 ] || return 1
  local sel; sel="$(menu_ask 'Tunnel number (empty=back)')"
  case "$sel" in ''|__eof__|*[!0-9]*) return 1 ;; esac
  [ "$sel" -ge 1 ] && [ "$sel" -le "${#TUNNELS[@]}" ] || { err "Out of range."; return 1; }
  PICKED="${TUNNELS[$((sel-1))]}"
}

share_menu(){
  while true; do
    echo
    echo -e "${C_B}  Share codes${C_N}  ${C_D}(one line to paste into another server's terminal)${C_N}"
    echo "   1) Code for the OTHER end of a tunnel   (pasted there, it sets up that server's side)"
    echo "   2) Backup code of ALL tunnels here      (pasted on a new server when this one's IP is filtered)"
    echo "   3) Paste a code                         (a share or backup code from another server)"
    echo "   0) Back"
    case "$(menu_ask 'Choice')" in
      1) SHARE_PUB=""; pick_tunnel && show_pair_code "$PICKED" 1; read -rp "  ▶ press ENTER to continue... " _ ;;
      2) show_backup_code; read -rp "  ▶ press ENTER to continue... " _ ;;
      3) import_code; read -t 60 -rp "  ▶ press ENTER to continue... " _ ;;
      0|__eof__) return ;;
      *) warn "Invalid." ;;
    esac
  done
}


# --- Health check ------------------------------------------------------------
#
# systemd's Restart=always already brings a tunnel back when its process exits.
# This adds a second safety net for the cases systemd cannot see on its own: a
# unit that is enabled but somehow not active, and a tunnel whose process is
# alive but whose peer link has been DOWN for a while (a lost FIN, a dead relay).
# A systemd timer runs `health-check` every couple of minutes.
HEALTH_SVC=/etc/systemd/system/brokennode-health.service
HEALTH_TMR=/etc/systemd/system/brokennode-health.timer
# The check runs from a small standalone script at a fixed path, generated from
# health_check below. It used to run the manager itself as "bash $SELF", but
# the installer starts the manager as "bash BrokenNode.sh", so $SELF was a bare
# relative name: systemd runs units from /, the unit failed every time, and no
# tunnel was ever restarted. It also broke whenever the download folder moved.
HEALTH_SH=/usr/local/lib/brokennode/health.sh

install_health(){
  [ "$(id -u)" -eq 0 ] || return 0
  mkdir -p "${HEALTH_SH%/*}" || return 0
  {
    echo '#!/bin/bash'
    echo '# Generated by the BrokenNode manager (install_health) — rewritten on every update.'
    printf 'CFG_DIR=%q\n' "$CFG_DIR"
    declare -f health_check
    echo 'health_check'
  } > "$HEALTH_SH.tmp" && chmod 755 "$HEALTH_SH.tmp" && mv -f "$HEALTH_SH.tmp" "$HEALTH_SH"
  cat > "$HEALTH_SVC" <<EOF
[Unit]
Description=BrokenNode tunnel health check
[Service]
Type=oneshot
ExecStart=/bin/bash $HEALTH_SH
EOF
  cat > "$HEALTH_TMR" <<EOF
[Unit]
Description=Run the BrokenNode health check periodically
[Timer]
OnBootSec=90
OnUnitActiveSec=120
AccuracySec=15
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now brokennode-health.timer >/dev/null 2>&1
}

# health_check is the timer's body. It must stand alone (it is copied into
# $HEALTH_SH with declare -f): no calls to other functions of this script.
#
# A tunnel counts as wanted only while its unit is ENABLED — the menu's Stop and
# stop-all disable it, so a tunnel taken down on purpose stays down. For each
# wanted tunnel:
#   - not running (inactive/failed) → restart it;
#   - running, but the LAST link event of THIS run is a drop with no link left,
#     at least 3 minutes old → restart it once.
# Only the current run's journal is read (its invocation id): a disconnect from
# before the last restart must not trigger another one. A drop that leaves
# links up ("· N link(s) left", N > 0) is a healthy multi-link tunnel shedding
# one link, not an outage. A fresh start gets 3 minutes to connect first.
health_check(){
  local f n st now started inv last ts
  now="$(date +%s)"
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .json)"
    systemctl is-enabled "brokennode@$n" >/dev/null 2>&1 || continue
    st="$(systemctl is-active "brokennode@$n" 2>/dev/null)"
    case "$st" in
      active) : ;;
      activating|reloading|deactivating) continue ;;   # systemd is already on it
      *) logger -t brokennode-health "restarting brokennode@$n (state: $st)" 2>/dev/null
         systemctl restart "brokennode@$n" 2>/dev/null
         continue ;;
    esac
    started="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "brokennode@$n" 2>/dev/null)" +%s 2>/dev/null)"
    case "$started" in ''|*[!0-9]*) started=0 ;; esac
    [ $((now - started)) -lt 180 ] && continue
    inv="$(systemctl show -p InvocationID --value "brokennode@$n" 2>/dev/null)"
    [ -n "$inv" ] || continue
    last="$(journalctl _SYSTEMD_INVOCATION_ID="$inv" -o short-unix --no-pager 2>/dev/null \
            | grep -E '🟢 Connected|peer CONNECTED|🔴 Disconnected|TUNNEL IS DOWN|peer timeout' | tail -1)"
    [ -n "$last" ] || continue
    case "$last" in *"🟢 Connected"*|*"peer CONNECTED"*) continue ;; esac
    if [[ "$last" =~ ·\ ([0-9]+)\ link\(s\)\ left ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
      continue
    fi
    ts="${last%%.*}"
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    if [ $((now - ts)) -ge 180 ]; then
      logger -t brokennode-health "restarting brokennode@$n (no link to the other end for $((now - ts))s)" 2>/dev/null
      systemctl restart "brokennode@$n" 2>/dev/null
    fi
  done
  # NAT rules of tunnels that no longer run (a stop that could not remove
  # them, rules restored at boot) would keep stealing their ports.
  /usr/local/bin/brokennode cleanup >/dev/null 2>&1 || true
}

# restart_all_tunnels: refresh the unit and restart every configured instance.
restart_all_tunnels(){
  write_template
  install_health
  systemctl daemon-reload 2>/dev/null
  local f n any=0
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue
    any=1; n="$(basename "$f" .json)"
    systemctl enable "brokennode@$n" >/dev/null 2>&1
    systemctl restart "brokennode@$n"
    local st; st="$(systemctl is-active "brokennode@$n" 2>/dev/null)"
    [ "$st" = active ] && info "restarted brokennode@$n (${C_G}active${C_N})" || err "brokennode@$n -> $st"
  done
  [ "$any" = 0 ] && warn "No tunnels configured yet."
}

# auto_tune_once applies the network tuning (BBR + fq + buffers) the first time
# this host runs the manager. The manual menu entry is gone, so tuning has to
# happen on its own — but only ONCE, tracked by a stamp file, so we never fight
# an operator who deliberately changed sysctl afterwards.
auto_tune_once(){
  [ "$(id -u)" -eq 0 ] || return 0
  local stamp="$CFG_DIR/.tuned" conf=/etc/sysctl.d/99-brokennode.conf
  # A host tuned by an older release keeps the profile it chose and gets the
  # current values for it. Without this, the tuning was written once and never
  # again, so every improvement to it skipped every existing server.
  if [ -f "$conf" ] && ! grep -q "^# tune-version: $TUNE_VERSION\$" "$conf"; then
    if grep -q "GAMING profile" "$conf"; then apply_sysctl_gaming >/dev/null 2>&1
    else apply_sysctl_throughput >/dev/null 2>&1; fi
    info "Network tuning updated to version $TUNE_VERSION (profile kept)."
  fi
  [ -f "$stamp" ] && return 0
  local cc; cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if [ "$cc" != bbr ]; then
    info "First run: applying network tuning (BBR + fq + buffers)..."
    # The throughput profile directly, NOT tune_network: that one asks which
    # profile to use, and a prompt here — with output redirected — would hang
    # the menu before it drew its first frame.
    apply_sysctl_throughput >/dev/null 2>&1
    local now; now="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    if [ "$now" = bbr ]; then info "Network tuned: BBR active."
    else warn "Could not enable BBR (kernel may lack tcp_bbr). Tunnels still work."; fi
  fi
  mkdir -p "$CFG_DIR" 2>/dev/null; : > "$stamp"
}

# auto_apply_bundled: run at startup. If the binary shipped next to the script
# differs from what's installed, install it and restart tunnels automatically —
# so customers never have to pick an "update" menu item. No-op when already
# up to date, or when not root. Never a downgrade: a folder older than the
# installed core only says so (see bundled_is_older).
auto_apply_bundled(){
  [ "$(id -u)" -eq 0 ] || return 0
  auto_tune_once
  local src; src="$(detect_bin)"
  [ -n "$src" ] && [ -f "$src" ] || return 0
  if bundled_is_older "$src"; then
    warn_old_folder "$src"
    read -t 15 -rp "  ▶ Press ENTER to continue (auto-continuing in 15s)... " _ 2>/dev/null || true
    return 0
  fi
  forget_old_core
  if [ ! -x "$BIN" ] || ! cmp -s "$src" "$BIN"; then
    warn "New core bundled with this package — applying automatically..."
    install_core "$src" || return 0
    info "Core: $("$BIN" version)"
    restart_all_tunnels
    info "Auto-update done — configs untouched."
    read -t 15 -rp "  ▶ Press ENTER to continue (auto-continuing in 15s)... " _ 2>/dev/null || true
  fi
}

# update_self downloads the latest release into THIS folder — the one the
# operator opens with "cd BrokenNode && bash BrokenNode.sh" — and restarts the
# menu from it, which then applies the new core and restarts the tunnels.
# Updating in place is the point: the installer run from somewhere else makes a
# second folder, and the old one kept offering (and installing) its old core.
update_self(){
  need_root
  local tmp; tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$tmp" "$INSTALL_URL"
  else wget -q --tries=3 -O "$tmp" "$INSTALL_URL"; fi || { err "Could not download the installer ($INSTALL_URL)."; rm -f "$tmp"; return; }
  info "Updating $SRC_DIR ..."
  forget_old_core
  cd "$(dirname "$SRC_DIR")" || return
  BROKENNODE_DIR="$(basename "$SRC_DIR")" exec bash "$tmp"
}

# uninstall_all: remove EVERYTHING — tunnels, core, configs, units.
uninstall_all(){
  need_root; banner
  echo
  warn "This permanently DELETES: all tunnels, the core binary, every config,"
  warn "and the systemd units. This cannot be undone."
  local c; c=$(ask "Type ${C_Y}wipe${C_N} to confirm full uninstall" "")
  [ "$c" = wipe ] || { info "Cancelled — nothing removed."; return; }
  local n
  for f in "$CFG_DIR"/*.json; do [ -e "$f" ] || continue; n="$(basename "$f" .json)"; systemctl disable --now "brokennode@$n" >/dev/null 2>&1; done
  systemctl list-units --all --no-legend 2>/dev/null | grep -o 'brokennode@[^ ]*\.service' | sort -u | while read -r u; do systemctl disable --now "$u" >/dev/null 2>&1; done
  systemctl disable --now brokennode-autoupdate.timer >/dev/null 2>&1
  systemctl disable --now brokennode-health.timer >/dev/null 2>&1
  # Every rule any release added, now that no tunnel runs.
  "$BIN" cleanup --all 2>/dev/null | sed 's/^/  /'
  unshape_egress
  rm -f "$AU_SVC" "$AU_TIMER" "$HEALTH_SVC" "$HEALTH_TMR" "$TPL"; rm -rf "${HEALTH_SH%/*}"
  rm -rf /run/brokennode /var/lib/brokennode
  systemctl daemon-reload 2>/dev/null; systemctl reset-failed 2>/dev/null
  rm -f "$BIN" "$BIN.bak" "$BIN.prev"
  remove_command
  rm -rf "$CFG_DIR"
  info "BrokenNode fully removed — core, tunnels, configs and units are gone."
  [ -f /etc/sysctl.d/99-brokennode.conf ] && echo -e "  ${C_D}The network tuning (/etc/sysctl.d/99-brokennode.conf) is kept — other services may rely on it. Delete that file to drop it.${C_N}"
}

# tune_network: the biggest real throughput lever for a lossy intercontinental
# path. Enables BBR congestion control + fq qdisc and raises TCP buffer ceilings.
# Run on BOTH the Iran relay AND the foreign server. Persisted across reboots.
# ---------------------------------------------------------------------------
#  Network tuning
#
#  Two profiles, because throughput and latency want opposite things and a relay
#  carrying game traffic should not be tuned like one carrying backups.
#
#  Throughput wants deep buffers so a high-BDP path stays full. Latency wants
#  shallow ones, because every byte queued ahead of a game packet is delay that
#  packet cannot avoid. There is no setting that is best at both.
#
#  apply_* take no input: auto_tune_once runs the throughput profile on first
#  boot with its output redirected, and a prompt there would hang the menu
#  before it ever drew.
# ---------------------------------------------------------------------------

apply_sysctl_throughput(){
  modprobe tcp_bbr 2>/dev/null || true
  grep -q '^tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-brokennode.conf <<EOF
# BrokenNode network tuning — THROUGHPUT profile
# tune-version: $TUNE_VERSION
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Buffers sized for multi-gigabit on a long path: 1 Gbit/s x 150 ms is ~19 MB
# in flight per flow. Autotuning only grows a socket this far when it needs to.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
$(sysctl_common)
EOF
  sysctl --system >/dev/null 2>&1
}

# sysctl_common is the part of the tuning both profiles need: it is about how
# many packets and connections the host can take, not about latency.
#   - netdev_budget(_usecs): packets handled per softirq pass. At gigabit rates
#     the default 300 ends passes early and leaves packets waiting in the ring.
#   - netdev_max_backlog: the per-CPU queue RPS feeds; drops here are silent.
#   - somaxconn / tcp_max_syn_backlog: a burst of users arriving at once must
#     not overflow the accept queue — overflow looks like "sometimes it just
#     does not connect".
#   - ip_local_port_range: one outbound socket per user (to the service, and
#     for mtcp links); the default 28k ports is a ceiling on concurrent users.
sysctl_common(){
  cat <<'EOC'
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
# Room for hundreds of thousands of users: every user is an open socket on
# each server (and an entry in the connection-tracking table wherever NAT or a
# firewall is in use: the kernel tunnels' port forwarding always is). Linux's
# defaults stop at 1 million files per process and 65536-262144 tracked
# connections, and a full table silently drops new connections. (fs.file-max
# is left alone: current kernels already set it to the maximum.) The conntrack
# lines only apply while nf_conntrack is loaded, which at boot it may not be
# yet: the core raises the table itself when it starts.
fs.nr_open = 4194304
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.ipv4.tcp_max_orphans = 262144
EOC
  # The table size follows RAM (an entry is ~300 bytes: RAM/8192 keeps even a
  # full table under 4% of memory), the same rule the core applies itself.
  local kb; kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
  local ct=$(( ${kb:-1048576} * 1024 / 8192 ))
  [ "$ct" -lt 131072 ] && ct=131072; [ "$ct" -gt 2097152 ] && ct=2097152
  echo "net.netfilter.nf_conntrack_max = $ct"
}

apply_sysctl_gaming(){
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_cake 2>/dev/null || true
  grep -q '^tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo tcp_bbr > /etc/modules-load.d/bbr.conf
  # cake does everything fq_codel does and shapes as well, so prefer it when the
  # kernel has it. modprobe answers this without touching any interface —
  # probing by installing a qdisc on lo has a side effect, and reports a false
  # negative whenever lo already has a root qdisc.
  local qd=fq_codel
  if modprobe sch_cake 2>/dev/null; then qd=cake; fi
  cat > /etc/sysctl.d/99-brokennode.conf <<EOF
# BrokenNode network tuning — GAMING profile
# tune-version: $TUNE_VERSION
#
# Buffers are deliberately far smaller than the throughput profile's. A 64MB
# socket buffer is depth for a game packet to wait behind, and waiting is the
# only thing that hurts it.
net.core.default_qdisc = $qd
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
# Keep unsent data in the socket small so a bulk sender cannot build a queue
# the kernel then has to drain before anything interactive gets out.
net.ipv4.tcp_notsent_lowat = 16384
$(sysctl_common)
EOF
  sysctl --system >/dev/null 2>&1
  echo "$qd"
}

# shape_egress caps the outgoing rate slightly below what the line can actually
# do, which is the single biggest jitter fix on a loaded link.
#
# Why capping helps: without it the bottleneck is a buffer in the ISP's
# equipment that you cannot see or manage, and a saturating upload fills it with
# hundreds of milliseconds of queue. Move the bottleneck onto this machine, and
# the queue becomes one cake can manage — it keeps it short and lets interactive
# traffic past. The few percent of bandwidth given up buys back far more in
# latency under load.
# unshape_egress removes the shaping shape_egress set up — and only that: "0 =
# skip" used to delete whatever root qdisc the interface had, ours or not. The
# unit is disabled BEFORE its file goes (the other order left its enable link
# dangling), and stopping it runs its ExecStop, which removes the qdisc.
SHAPE_SVC=/etc/systemd/system/brokennode-shape.service
unshape_egress(){
  [ -f "$SHAPE_SVC" ] || return 0
  local dev; dev="$(sed -n 's/^ExecStart=.* dev \([^ ]*\) root.*/\1/p' "$SHAPE_SVC")"
  systemctl disable --now brokennode-shape.service >/dev/null 2>&1
  [ -n "$dev" ] && tc qdisc del dev "$dev" root 2>/dev/null
  rm -f "$SHAPE_SVC"
  systemctl daemon-reload >/dev/null 2>&1
  info "Shaping removed${dev:+ from $dev}."
}

shape_egress(){
  local mbit="$1" dev; dev="$(default_iface)"
  [ -n "$dev" ] || { err "Could not find the default interface."; return 1; }
  command -v tc >/dev/null 2>&1 || { err "tc is missing (install iproute2)."; return 1; }
  if [ "${mbit:-0}" = 0 ]; then
    unshape_egress
    return 0
  fi
  if ! tc qdisc replace dev "$dev" root cake bandwidth "${mbit}mbit" 2>/dev/null; then
    warn "cake is unavailable; falling back to fq_codel (manages the queue, does not shape)."
    tc qdisc replace dev "$dev" root fq_codel 2>/dev/null || { err "Could not set a qdisc on $dev."; return 1; }
    return 0
  fi
  # A tc rule lives in memory only. Without this it silently disappears at the
  # next reboot and the operator is left wondering why the jitter came back.
  cat > /etc/systemd/system/brokennode-shape.service <<EOF
[Unit]
Description=BrokenNode egress shaping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/tc qdisc replace dev $dev root cake bandwidth ${mbit}mbit
ExecStop=/sbin/tc qdisc del dev $dev root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable brokennode-shape.service >/dev/null 2>&1
  info "Shaping $dev at ${mbit} Mbit with cake (persists across reboots)."
}

tune_network(){
  need_root
  banner
  echo
  echo -e "${C_B}  Network tuning${C_N}"
  echo -e "  ${C_D}Run this on BOTH servers. Throughput and latency want opposite${C_N}"
  echo -e "  ${C_D}settings, so pick the one this relay is actually for.${C_N}"
  echo
  echo "   1) Throughput  — big buffers, fq. For bulk traffic and downloads."
  echo "   2) Gaming      — shallow buffers, fq_codel/cake, queue control."
  echo "   0) Back"
  echo
  case "$(ask 'Profile' '1')" in
    1)
      apply_sysctl_throughput
      local cc qd
      cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
      qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
      if [ "$cc" = bbr ]; then info "Throughput profile applied (congestion=$cc, qdisc=$qd)."
      else warn "Applied, but congestion control is '$cc' (kernel may lack BBR; needs Linux >= 4.9)."; fi
      ;;
    2)
      local qd; qd="$(apply_sysctl_gaming)"
      info "Gaming profile applied (qdisc=$qd, shallow buffers)."
      echo
      echo -e "  ${C_D}Shaping just below the real line rate is what stops a big upload${C_N}"
      echo -e "  ${C_D}from parking a queue in front of your game. Measure the uplink${C_N}"
      echo -e "  ${C_D}first, then enter about 90-95%% of it. 0 skips shaping.${C_N}"
      local mbit; mbit="$(ask 'Uplink to shape to, in Mbit (0 = skip)' '0')"
      case "$mbit" in ''|*[!0-9]*) mbit=0 ;; esac
      shape_egress "$mbit"
      ;;
    *) return ;;
  esac
  warn "Run this on the OTHER server too, then restart the tunnels."
}

# warn_removed_transports names the tunnels still configured for quic, which
# 2.3.22 removed: their service now stops at start with a message saying so,
# and this says the same up front, with the way out.
warn_removed_transports(){
  local f n list=""
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jget "$f" transport)" = quic ] || continue
    n="$(basename "$f" .json)"; list="$list $n"
  done
  [ -n "$list" ] || return 0
  echo
  warn "These tunnels use quic, which this release removed:${C_Y}$list${C_N}"
  echo -e "  ${C_D}They will not start. Switch each to kcp (UDP) or mtcp (TCP) on BOTH servers:${C_N}"
  echo -e "  ${C_D}Manage tunnels → the tunnel → 9) Change transport.${C_N}"
  read -t 15 -rp "  ▶ Press ENTER to continue (auto-continuing in 15s)... " _ 2>/dev/null || true
}

# sweep_temp removes the hidden working files an edit uses (.tune-/.undo-/
# .pair-/.check-, and an import's .import. folder). A clean edit deletes its own; one left behind means the
# manager was killed mid-edit (input ended at a prompt), so it is stale and
# safe to drop — the live <name>.json was never touched.
# The menu shortcut: "BrokenNode" (or "brokennode", in any mix of upper and
# lower case) typed anywhere opens this menu, from the folder it lives in, so
# nobody has to "cd BrokenNode && bash BrokenNode.sh" every time.
#   - MENU_CMD is a small launcher that cd's into this folder and runs it here
#     (the update and the bundled core both work from this folder).
#   - "brokennode" is the core itself: run with no arguments it opens the menu
#     through MENU_CMD (the tunnel services always pass -c).
#   - Any other spelling (Brokennode, BROKENNODE...) goes through bash's
#     command_not_found_handle, wrapping the distribution's own handler.
MENU_CMD="/usr/local/bin/BrokenNode"
MENU_HOOK="/etc/profile.d/brokennode.sh"
MENU_MARK="# brokennode-menu-launcher"

install_command(){
  [ "$(id -u)" -eq 0 ] || return 0
  # On a case-insensitive filesystem the launcher would BE the core: skip.
  [ -e "$MENU_CMD" ] && [ -e "$BIN" ] && [ "$MENU_CMD" -ef "$BIN" ] && return 0
  # A file with that name that we did not write is left alone.
  if [ -e "$MENU_CMD" ] && ! grep -q "$MENU_MARK" "$MENU_CMD" 2>/dev/null; then return 0; fi
  local dir="${SRC_DIR//\'/\'\\\'\'}" self; self="$(basename "$SELF")"
  local want
  want="#!/bin/sh
$MENU_MARK — written by BrokenNode.sh: opens the menu from the folder
# BrokenNode was installed into. Run the menu once from a moved folder to
# point this at it again.
DIR='$dir'
if [ ! -f \"\$DIR/$self\" ]; then
  echo \"BrokenNode: the menu is no longer in \$DIR — open it once from its new folder: bash $self\" >&2
  exit 1
fi
cd \"\$DIR\" || exit 1
if [ \"\$(id -u)\" -ne 0 ] && command -v sudo >/dev/null 2>&1; then exec sudo bash \"./$self\" \"\$@\"; fi
exec bash \"./$self\" \"\$@\""
  local new=0
  [ -f "$MENU_CMD" ] || new=1
  if [ "$(cat "$MENU_CMD" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" > "$MENU_CMD.new" && chmod 755 "$MENU_CMD.new" && mv -f "$MENU_CMD.new" "$MENU_CMD" || { rm -f "$MENU_CMD.new"; return 0; }
  fi
  # Written to stay valid in every shell that reads /etc/profile.d (dash
  # included): bash-only syntax sits behind the BASH_VERSION check.
  local hook
  hook="$MENU_MARK — written by BrokenNode.sh
# Any spelling of \"brokennode\" (BrokenNode, BROKENNODE...) opens the menu.
if [ -n \"\${BASH_VERSION:-}\" ]; then
  if declare -f command_not_found_handle >/dev/null 2>&1 && ! declare -f _bn_orig_cnfh >/dev/null 2>&1; then
    eval \"_bn_orig_cnfh() \$(declare -f command_not_found_handle | tail -n +2)\"
  fi
  command_not_found_handle() {
    case \"\$(printf '%s' \"\$1\" | tr 'A-Z' 'a-z')\" in
      brokennode) shift; $MENU_CMD \"\$@\"; return \$? ;;
    esac
    if declare -f _bn_orig_cnfh >/dev/null 2>&1; then _bn_orig_cnfh \"\$@\"; return \$?; fi
    printf 'bash: %s: command not found\\n' \"\$1\" >&2
    return 127
  }
fi"
  if [ "$(cat "$MENU_HOOK" 2>/dev/null)" != "$hook" ]; then
    printf '%s\n' "$hook" > "$MENU_HOOK.new" && chmod 644 "$MENU_HOOK.new" && mv -f "$MENU_HOOK.new" "$MENU_HOOK" || rm -f "$MENU_HOOK.new"
  fi
  [ "$new" = 1 ] && info "Shortcut installed: type ${C_Y}BrokenNode${C_N} (or brokennode) anywhere to open this menu."
  return 0
}

remove_command(){
  grep -q "$MENU_MARK" "$MENU_CMD" 2>/dev/null && rm -f "$MENU_CMD"
  grep -q "$MENU_MARK" "$MENU_HOOK" 2>/dev/null && rm -f "$MENU_HOOK"
  return 0
}

sweep_temp(){ rm -f "$CFG_DIR"/.tune-*.json "$CFG_DIR"/.undo-*.json "$CFG_DIR"/.pair-*.json "$CFG_DIR"/.check-*.json 2>/dev/null; rm -rf "$CFG_DIR"/.import.* 2>/dev/null; }

main_menu(){
  auto_apply_bundled
  install_command
  sweep_temp
  warn_removed_transports
  # Repair a health-check unit written by 2.3.16–2.3.19, whose ExecStart
  # pointed at a relative path and never ran. Cheap and idempotent.
  [ -f "$HEALTH_SVC" ] && ! grep -q "$HEALTH_SH" "$HEALTH_SVC" 2>/dev/null && install_health
  while true; do
    banner
    echo
    echo "   1) Create SERVER tunnel   (Iran relay)"
    echo "   2) Create CLIENT tunnel   (foreign server)"
    echo "   3) Manage tunnels         (edit / transport / IP / logs / stats)"
    echo "   4) Health check           (doctor: BBR / ports / loss / IP)"
    echo "   5) Update BrokenNode      (download the latest into this folder)"
    echo "   6) Share codes            (set up the other server, or move every tunnel, with one paste)"
    echo "   0) Exit"
    echo -e "  ${C_D}(the core in this folder is applied automatically on start)${C_N}"
    echo
    case "$(menu_ask 'Choice')" in
      1) create_tunnel server; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      2) create_tunnel client; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      3) manage_tunnels ;;
      4) doctor; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      5) update_self ;;
      6) share_menu ;;
      0|__eof__) echo; exit 0 ;;
      *) warn "Invalid." ;;
    esac
  done
}

case "${1:-}" in
  server) create_tunnel server ;;
  client) create_tunnel client ;;
  manage) manage_tunnels ;;
  transports) ensure_core && "$BIN" -transports ;;
  tune|tune-network) tune_network ;;
  doctor|health|check) doctor ;;
  _health) health_check ;;
  restart-all|start-all|stop-all)
    action="${1%-all}"
    units=""
    for f in "$CFG_DIR"/*.json; do [ -e "$f" ] || continue; n=$(basename "$f" .json); units="$units brokennode@$n"; done
    if [ -z "$units" ]; then echo "no tunnels found in $CFG_DIR"; exit 0; fi
    echo "${action}ing:$units"
    # Enabled means "wanted running": stop disables (so the health check and a
    # reboot leave the tunnels down), start and restart enable.
    # shellcheck disable=SC2086
    case "$action" in
      stop)  systemctl disable --now $units >/dev/null 2>&1 ;;
      start) systemctl enable --now $units >/dev/null 2>&1 ;;
      *)     systemctl enable $units >/dev/null 2>&1; systemctl restart $units ;;
    esac && echo "done." ;;
  import) shift; import_code "$@" ;;
  share)
    [ -n "${2:-}" ] || { echo "usage: BrokenNode share <tunnel name>"; exit 1; }
    show_pair_code "$2" 0 ;;
  backup) show_backup_code ;;
  uninstall|purge) uninstall_all ;;
  version) echo "BrokenNode manager v$VERSION" ;;
  update) update_self ;;
  ""|menu) main_menu ;;
  *) echo "usage: sudo bash $SELF [server|client|manage|import <code>|share <tunnel>|backup|transports|tune|restart-all|start-all|stop-all|doctor|update|uninstall|version]"; exit 1 ;;
esac
