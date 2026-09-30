#!/usr/bin/env bash
# ============================================================================
#  BrokenNode Tunnel - Manager (prebuilt core, no build / no internet)
#  Multi-instance | presets | per-port tcp/udp/both | systemd
#  Transport and encryption are chosen separately (see pick_transport /
#  pick_encryption).
# ============================================================================
set -uo pipefail

VERSION="2.3.19"
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
ask(){ local p="$1" d="${2:-}" a; if [ -n "$d" ]; then read -rp "$(echo -e "${C_B}  ?${C_N} $p [${C_D}$d${C_N}]: ")" a; echo "${a:-$d}"; else read -rp "$(echo -e "${C_B}  ?${C_N} $p: ")" a; echo "$a"; fi; }
# menu_ask PROMPT — a menu choice; "__eof__" once input has ended. The menus
# loop until a choice exits them, and ask() cannot tell end of input from an
# empty answer, so a closed stdin (a script feeding the menu, a dropped SSH
# session) spun them forever printing "Invalid.".
menu_ask(){ local a; if read -rp "$(echo -e "${C_B}  ?${C_N} $1: ")" a; then echo "$a"; else echo "__eof__"; fi; }
need_root(){ [ "$(id -u)" -eq 0 ] || { err "Run as root: sudo bash $SELF"; exit 1; }; }
detect_ip(){ ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || true; }
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

warn_old_folder(){
  warn "This folder ($SRC_DIR) holds an OLDER BrokenNode (core v$(core_version "$1")) than the one installed (v$(core_version "$BIN")) — not downgrading."
  echo -e "  ${C_D}Update this folder: menu option 5, or  cd \"$SRC_DIR\" && bash <(curl -fsSL $INSTALL_URL)${C_N}"
}

ensure_core(){
  local src; src="$(detect_bin)"
  if [ -n "$src" ] && [ -f "$src" ]; then
    if bundled_is_older "$src"; then warn_old_folder "$src"; return 0; fi
    { [ ! -x "$BIN" ] || ! cmp -s "$src" "$BIN"; } && { install -m0755 "$src" "$BIN"; info "Core updated: $("$BIN" version)"; }
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
gen_token(){ ( head -c 24 /dev/urandom | base64 2>/dev/null | tr -d '/+=' | head -c 24 ) || echo "bn$(date +%s)$RANDOM"; }

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
#   stream  bind_addr / remote_addr         tcp mtcp mptcp ws tcpnomux kcp quic sctp
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

pick_direction(){
  echo -e "${C_B}  Connection direction:${C_N}" >&2
  echo -e "   1) reverse  the FOREIGN server connects to the Iran server  ${C_D}(classic)${C_N}" >&2
  echo -e "   2) direct   the IRAN server connects to the foreign server" >&2
  echo -e "  ${C_D}Pick direct when connections INTO the Iran server are being cut.${C_N}" >&2
  echo -e "  ${C_D}Both servers must use the SAME direction.${C_N}" >&2
  local d; d=$(ask "Choice [1-2]" "1"); case "$d" in 2|d|direct) echo direct;; *) echo reverse;; esac
}

# ask_hostport PROMPT DEFAULT_PORT [DEFAULT] — a host:port, with the port
# added when only a host is typed. Empty stays empty (the caller decides).
ask_hostport(){
  local a; a=$(ask "$1" "${3:-}")
  a="$(echo "$a" | tr -d ' ')"
  [ -z "$a" ] && { echo ""; return; }
  case "$a" in
    *:*) echo "$a" ;;
    *)   echo "$a:$2" ;;
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
            pr = "udp" if c.get("transport") in ("kcp", "quic") else "tcp"
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

# next_free_net EXCLUDE — N such that 10.10.N.x is not used by another tunnel.
next_free_net(){
  local used n; used=" $( { cfg_scan values "$1" tun_local; cfg_scan values "$1" tun_remote; } | tr '\n' ' ') "
  for n in $(seq "${2:-30}" 254); do
    [[ "$used" == *" 10.10.$n."* || "$used" == *" fd00:10:$n::"* ]] || { echo "$n"; return; }
  done
  echo 30
}

# show_pair_code CFG — print the pairing code for a relay config. Everything
# the foreign server needs (transport, encryption, token, addresses, subnet,
# keys, ids, ports, direction, transport settings) is in it, so the foreign
# wizard asks for nothing else and nothing can be mistyped. It holds the token:
# treat it like the token.
show_pair_code(){
  local cfg="$1" ip="" fam; fam="$(transport_family "$(jget "$cfg" transport)")"
  case "$fam" in
    stream)
      if [ "$(tunnel_direction "$cfg")" = direct ]; then ip="-"
      else
        ip="$(jget "$cfg" public_ip)"
        if [ -z "$ip" ]; then
          ip=$(ask "This server's PUBLIC IP (the foreign server connects to it)" "$(detect_ip)")
          jset "$cfg" public_ip "$ip"
        fi
      fi ;;
    *)     ip="$(jget "$cfg" local_ip)" ;;
  esac
  local code; code="$(bnpy pair make "$cfg" "$ip")" || { err "Could not build the pairing code."; return; }
  echo
  echo -e "  ${C_B}╭─ Pairing code — on the FOREIGN server: Create CLIENT tunnel, paste this ─╮${C_N}"
  echo -e "  ${C_Y}$code${C_N}"
  echo -e "  ${C_B}╰──────────────────────────────────────────────────────────────────────────╯${C_N}"
  echo -e "  ${C_D}It carries every setting (and the token): nothing else to type on the other side.${C_N}"
  echo -e "  ${C_D}Setting the foreign server up by hand instead (or it runs an older manager)? Its values:${C_N}"
  bnpy pair show "$cfg" "$ip" 2>/dev/null | sed "s/^/      /"
}

# client_from_code NAME CODE — the foreign server's side of pairing: build the
# config from the code, check it against what this machine already uses, start
# it, and wait to see it connect.
client_from_code(){
  local name="$1" code="$2" target out line
  target=$(ask "Local services host (Enter = this server)" "")
  local rc=0; out="$(bnpy pair apply "$code" "$name" "$target" 2>&1)" || rc=$?
  if grep -q '^ERR ' <<<"$out"; then err "$(sed -n 's/^ERR //p' <<<"$out")"; return 1; fi
  if [ "$rc" != 0 ] || ! grep -q '^OK ' <<<"$out"; then
    err "Could not build the config from this code:"; echo "$out" | tail -n 3 | sed 's/^/    /'; return 1
  fi
  info "Config created from the pairing code: $(sed -n 's/^OK //p' <<<"$out")"
  if grep -q '^CONFLICT ' <<<"$out"; then
    while IFS= read -r line; do warn "${line#CONFLICT }"; done < <(grep '^CONFLICT ' <<<"$out")
    echo -e "  ${C_D}Re-create the tunnel on the Iran server (it picks other free values) and paste the new code.${C_N}"
    local go; go=$(ask "Start it anyway? y/N" "N"); case "$go" in y|Y) : ;; *) warn "Not started — config kept at $CFG_DIR/$name.json"; return 1 ;; esac
  fi
  local cfg="$CFG_DIR/$name.json" b
  b="$(jget "$cfg" bind_addr)"
  if [ -n "$b" ]; then
    local pr=tcp; case "$(jget "$cfg" transport)" in kcp|quic) pr=udp ;; esac
    echo -e "  ${C_D}Direct mode: the Iran server connects here on ${pr^^} ${b##*:} — allow it in this server's firewall.${C_N}"
  fi
  # Only log lines from THIS start count: an overwritten tunnel of the same
  # name may have "Connected" from its previous run in the journal.
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  install_health
  systemctl enable "brokennode@$name" >/dev/null 2>&1; systemctl restart "brokennode@$name"; sleep 1.5
  if [ "$(systemctl is-active "brokennode@$name" 2>/dev/null)" != active ]; then
    err "Tunnel '$name' failed to start. Recent log:"; journalctl -u "brokennode@$name" --since "$since" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'; return 1
  fi
  info "Tunnel '$name' is ${C_G}active${C_N} — waiting for the other end..."
  local i; for i in $(seq 1 20); do
    journalctl -u "brokennode@$name" --since "$since" --no-pager -o cat 2>/dev/null | grep -q -E '🟢 Connected|ready on' && { info "${C_G}Connected.${C_N}"; return 0; }
    sleep 1
  done
  warn "No connection yet. If the Iran side is running, check with the Health check (menu 4)."
}

# auto_or_ask ROLE PROMPT VALUE — on the relay a value that must not clash
# with anything else on this server is chosen, not asked (the operator asked
# not to have to pick them); it is shown and ends up in the pairing code. The
# foreign server, set up by hand, is still asked.
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
#   pair make CFG IP          the pairing code for relay config CFG; IP is the
#                             address the foreign server reaches this one at
#   pair apply CODE NAME TGT  write the foreign server's config NAME from a
#                             pairing code; TGT is its local services host
#   pair check CFG            conflicts of config CFG with this machine
#
# Values are picked at RANDOM among the free ones, not the lowest: a foreign
# server may carry tunnels from several Iran relays, and relays that all chose
# "the first free" would all choose the same subnet, id and port.
bnpy(){
  python3 - "$CFG_DIR" "$@" <<'PYEOF'
import base64, glob, json, os, random, re, subprocess, sys, zlib

cfgdir, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
P2P = ("gre", "gretap", "ipip", "sit", "l2tp", "udp", "icmp")
KNOWN = P2P + ("tcp", "mtcp", "mptcp", "ws", "tcpnomux", "kcp", "quic", "sctp",
               "tcpobf", "mtcpobf", "wsobf", "rawmux")

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

def mirror(r, relay_ip, target):
    """The foreign server's config: the relay's, seen from the other end."""
    c = {k: v for k, v in r.items() if k not in ("ports", "quota_total_gb", "quota_up_gb", "quota_down_gb", "public_ip")}
    c["mode"] = "client"
    t = c.get("transport")
    sw = lambda a, b: c.update({a: r.get(b), b: r.get(a)}) if (a in r or b in r) else None
    if t in P2P:
        sw("local_ip", "remote_ip"); sw("tun_local", "tun_remote")
    else:
        if str(r.get("direction") or "").lower() == "direct":
            port = str(r.get("remote_addr") or ":8443").rsplit(":", 1)[-1] or "8443"
            c["bind_addr"] = "0.0.0.0:" + port
            c.pop("remote_addr", None)
        else:
            port = str(r.get("bind_addr") or ":8443").rsplit(":", 1)[-1] or "8443"
            host = "[" + relay_ip + "]" if ":" in relay_ip and not relay_ip.startswith("[") else relay_ip
            c["remote_addr"] = host + ":" + port
            c.pop("bind_addr", None)
    c["target_host"] = target or ("::1" if t == "sit" else "127.0.0.1")
    return {k: v for k, v in c.items() if v is not None}

def own_values(name):
    """Values the existing config NAME (about to be replaced) holds: its running
    tunnel shows them on this machine, but they are not a conflict with it."""
    try:
        o = json.load(open(os.path.join(cfgdir, name + ".json")))
    except Exception:
        return set(), set(), set()
    nets, ports, ids = set(), set(), set()
    m = re.match(r"10\.10\.(\d+)\.", str(o.get("tun_local") or ""))
    if m:
        nets.add(int(m.group(1)))
    for k in ("carrier_port", "l2tp_port"):
        if o.get(k):
            ports.add(int(o[k]))
    for k in ("bind_addr",):
        v = str(o.get(k) or "")
        if v.rsplit(":", 1)[-1].isdigit():
            ports.add(int(v.rsplit(":", 1)[-1]))
    for k in ("l2tp_tunnel_id", "l2tp_session_id"):
        if o.get(k):
            ids.add(int(o[k]))
    return nets, ports, ids

def conflicts(name, c):
    """What in config c is already taken on THIS machine."""
    out = []
    own_nets, own_ports, own_ids = own_values(name)
    used_nets_ = lambda n: used_nets(n) - own_nets
    used_ports_ = lambda pr, n: used_ports(pr, n) - own_ports
    used_l2tp_ = lambda n: used_l2tp(n) - own_ids
    t = c.get("transport")
    for k in ("tun_local",):
        m = re.match(r"10\.10\.(\d+)\.", str(c.get(k) or ""))
        if m and int(m.group(1)) in used_nets_(name):
            out.append("tunnel subnet 10.10.%s.x is already used here" % m.group(1))
    if t == "l2tp":
        for k in ("l2tp_tunnel_id", "l2tp_session_id"):
            if c.get(k) and int(c[k]) in used_l2tp_(name):
                out.append("%s %s is already used here" % (k, c[k]))
        if (c.get("l2tp_encap") or "udp") == "udp" and int(c.get("l2tp_port") or 1701) in used_ports_("udp", name):
            out.append("l2tp udp port %s is already used here" % (c.get("l2tp_port") or 1701))
    if t in ("gre", "gretap"):
        for n, o in configs(name):
            if o.get("transport") == t and o.get("remote_ip") == c.get("remote_ip") and int(o.get("gre_key") or 0) == int(c.get("gre_key") or 0):
                out.append("%s tunnel '%s' to %s already uses gre key %s" % (t, n, c.get("remote_ip"), int(c.get("gre_key") or 0)))
    if t in ("ipip", "sit"):
        for n, o in configs(name):
            if o.get("transport") == t and o.get("remote_ip") == c.get("remote_ip"):
                out.append("%s tunnel '%s' to %s exists — the kernel allows only one" % (t, n, c.get("remote_ip")))
    if t == "udp":
        if int(c.get("carrier_port") or 6262) in used_ports_("udp", name):
            out.append("udp carrier port %s is already used here" % (c.get("carrier_port") or 6262))
    b = str(c.get("bind_addr") or "")
    if c.get("mode") == "client" and ":" in b:
        proto = "udp" if t in ("kcp", "quic") else "tcp"
        if int(b.rsplit(":", 1)[1]) in used_ports_(proto, name):
            out.append("port %s/%s (to listen on) is already used here" % (b.rsplit(":", 1)[1], proto))
    return out

if cmd == "alloc":
    what = args[0]
    if what == "net":
        print(pick(30, 250, used_nets(args[1])))
    elif what == "port":
        print(pick(20000, 40000, used_ports(args[1], args[2])))
    elif what == "l2tpid":
        print(pick(1000, 60000, used_l2tp(args[1])))
elif cmd == "pair" and args[0] == "make":
    r = json.load(open(args[1]))
    blob = json.dumps({"v": 1, "ip": args[2], "cfg": r}, separators=(",", ":")).encode()
    print("BN1:" + base64.urlsafe_b64encode(zlib.compress(blob, 9)).decode().rstrip("="))
elif cmd == "pair" and args[0] == "apply":
    code, name, target = args[1].strip(), args[2], args[3] if len(args) > 3 else ""
    try:
        if not code.startswith("BN1:"):
            raise ValueError("not a pairing code (it starts with BN1:)")
        raw = code[4:] + "=" * (-len(code[4:]) % 4)
        d = json.loads(zlib.decompress(base64.urlsafe_b64decode(raw)))
    except Exception as e:
        print("ERR the pairing code is damaged or incomplete (%s) — copy the whole line again" % e)
        sys.exit(2)
    if (d["cfg"].get("transport") or "tcp") not in KNOWN:
        print("ERR this pairing code is for a transport this release does not have — re-create the tunnel on the Iran server with another transport")
        sys.exit(2)
    c = mirror(d["cfg"], d.get("ip", ""), target)
    bad = conflicts(name, c)
    path = os.path.join(cfgdir, name + ".json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(c, f, indent=2); f.write("\n")
    t = c.get("transport")
    info = [t + ("+" + c["encryption"] if c.get("encryption") not in (None, "", "none") else "")]
    if t not in P2P:
        info.append("direction " + (c.get("direction") or "reverse"))
        info.append(("listens on " + c["bind_addr"]) if c.get("bind_addr") else ("connects to " + c.get("remote_addr", "?")))
    else:
        info.append("tunnel " + str(c.get("tun_local")) + " <-> " + str(c.get("tun_remote")))
    for k in ("gre_key", "l2tp_tunnel_id", "l2tp_port", "carrier_port"):
        if c.get(k):
            info.append("%s %s" % (k, c[k]))
    print("OK " + " · ".join(info))
    for b in bad:
        print("CONFLICT " + b)
elif cmd == "pair" and args[0] == "show":
    # the foreign side's values, for setting it up by hand (an older manager)
    c = mirror(json.load(open(args[1])), args[2], "")
    keys = ("transport", "encryption", "token", "direction", "remote_addr", "bind_addr",
            "local_ip", "remote_ip", "tun_local", "tun_remote", "gre_key", "l2tp_tunnel_id",
            "l2tp_session_id", "l2tp_encap", "l2tp_port", "carrier_port", "ws_path", "mtu")
    for k in keys:
        if c.get(k) not in (None, "", 0) or (k == "gre_key" and c.get(k)):
            print("%-16s %s" % (k, c[k]))
elif cmd == "pair" and args[0] == "check":
    for b in conflicts(os.path.basename(args[1])[:-5], json.load(open(args[1]))):
        print(b)
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
  fi
}

pick_transport(){
  # Numbers 1-7 are exactly what 2.2.0 and earlier used. Operators pick these by
  # habit on both servers, so renumbering them (2.3.0 inserted the new ones in
  # the middle) silently put the two ends on different transports and the
  # tunnel never connected. New transports only ever get appended.
  echo >&2
  echo -e "${C_B}  Select transport:${C_N}" >&2
  echo -e "  ${C_D}── proxy (users connect to a port) ───────────${C_N}" >&2
  echo -e "   1) tcp       Plain TCP + smux         ${C_G}(stable baseline)${C_N}" >&2
  echo -e "   2) mtcp      Multi-link TCP           ${C_G}(beats throttling, best for Iran)${C_N}" >&2
  echo    "   3) ws        WebSocket/HTTP + smux    (HTTP mimicry)" >&2
  echo    "   4) tcpnomux  TCP pool, no HoL         (heavy single-flow)" >&2
  echo -e "   5) kcp       KCP/UDP + FEC            ${C_Y}(only if UDP works)${C_N}" >&2
  echo -e "   6) quic      QUIC/UDP, built-in TLS   ${C_R}(slow on lossy paths — prefer kcp)${C_N}" >&2
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
        # Measured: with 0.3% packet loss on an 80ms path, quic carried 4-5
        # Mbit in total and 0.1 Mbit per download, where the TCP carriers
        # carried 220 (its congestion control backs off on every random loss).
        # And with NO loss: traffic one way fills the path's queue, the RTT
        # the other way rises, quic-go's hybrid slow start takes that for
        # congestion and leaves slow start with a ~40 KB window that then
        # grows one packet per round trip — about 10 Mbit (measured, 2.3.9).
        {
          echo -e "  ${C_Y}[!]${C_N} quic slows to a crawl when the path loses packets — as paths in Iran do"
          echo -e "      ${C_D}(tested: 0.3% loss → about 5 Mbit in total). mtcp or kcp hold up far better.${C_N}"
          echo -e "      ${C_D}Even with no loss, while users download, its upload direction stays near 10 Mbit.${C_N}"
        } >&2
        local qc; qc=$(ask "Use quic anyway? y/N" "N")
        case "$qc" in y|Y) echo quic; return ;; *) continue ;; esac ;;
      8|mptcp) echo mptcp; return ;;    9|sctp) echo sctp; return ;;
      10|gre) echo gre; return ;;       11|gretap) echo gretap; return ;;
      12|ipip) echo ipip; return ;;     13|sit) echo sit; return ;;
      14|l2tp) echo l2tp; return ;;     15|udp) echo udp; return ;;
      16|icmp) echo icmp; return ;;
      *) err "'$n' is not one of the choices." ;;
    esac
  done
}

# pick_encryption asks whether the chosen transport should be encrypted. quic
# already encrypts with TLS 1.3 and the kernel tunnels carry plain IP, so
# neither takes a layer and neither is asked.
pick_encryption(){
  local tr="$1"
  # quic (TLS 1.3) and the kernel tunnels (encrypt at the service) take no
  # encryption layer, so they are not asked.
  case "$tr" in
    quic|gre|gretap|ipip|sit|l2tp) echo none; return ;;
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
  echo    "   3) none   No encryption layer (lowest overhead)" >&2
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}" >&2
  echo -e "  ${C_D}Both ends of the tunnel must use the SAME choice.${C_N}" >&2
  local n; n=$(ask "Choice [1-3]" "1")
  case "$n" in 2) echo obfs ;; 3) echo none ;; *) echo aead ;; esac
}

pick_preset(){
  echo >&2
  echo -e "${C_B}  Connection preset:${C_N}" >&2
  echo    "   1) Optimized    balanced (Recommended)" >&2
  echo    "   2) High-Speed   max throughput" >&2
  echo    "   3) Stable       tolerate high packet loss" >&2
  echo    "   4) Low-Latency  gaming / VoIP" >&2
  echo    "   5) Eco          low CPU/RAM, weak VPS" >&2
  local n; n=$(ask "Choice [1-5]" "1")
  case "$n" in 2) echo "15 turbo 10 2";; 3) echo "8 normal 10 4";; 4) echo "5 gaming 10 4";; 5) echo "20 normal 10 1";; *) echo "10 fast 10 3";; esac
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
build_extra(){ local role="$1" tr="$2" dir="${3:-reverse}"; EXTRA=""; TLSJSON=""
  local dials=0
  { [ "$role" = client ] && [ "$dir" = reverse ]; } || { [ "$role" = server ] && [ "$dir" = direct ]; } && dials=1
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
      local w; w=$(ask 'KCP window (send/recv, empty=1024)' '')
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
  lip=$(ask "This server's real (public) IP" "$(detect_ip)")
  rip=$(ask "The OTHER server's real IP" "")
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

  local tokline=""; local token
  token=$(ask "Shared token (same on both ends)" "$(gen_token)")
  tokline="\"token\": \"$(jstr "$token")\","

  local portsjson=""
  if [ "$role" = server ]; then portsjson=$(build_ports); warn_port_clash "$portsjson" "$name"; fi

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
    info "Saved $cfg"
    show_pair_code "$cfg"
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
  install_health
  systemctl enable "brokennode@$name" >/dev/null 2>&1; systemctl restart "brokennode@$name"; sleep 1.5
  if [ "$(systemctl is-active "brokennode@$name" 2>/dev/null)" = active ]; then info "Tunnel '$name' is ${C_G}active${C_N}."
  else err "Tunnel '$name' failed to start. Recent log:"; journalctl -u "brokennode@$name" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'; fi
}

create_tunnel(){
  need_root; ensure_core || return; mkdir -p "$CFG_DIR"; harden_cfg_dir; write_template
  local role="$1" name tr enc ka kmode kdata kparity
  echo; info "Create ${role^^} tunnel"
  name=$(ask "Instance name" "main"); name="$(echo "$name" | tr -cd 'A-Za-z0-9_-')"; [ -z "$name" ] && name=main
  if [ -f "$CFG_DIR/$name.json" ]; then local o; o=$(ask "'$name' exists. Overwrite? y/N" "N"); case "$o" in y|Y) :;; *) warn "Cancelled."; return;; esac; fi
  if [ "$role" = client ]; then
    echo -e "  ${C_D}Paste the pairing code the Iran server printed (starts with BN1:) and every${C_N}"
    echo -e "  ${C_D}setting comes from it. Press Enter instead to set this tunnel up by hand.${C_N}"
    local code; code=$(ask "Pairing code" "")
    if [ -n "$code" ]; then client_from_code "$name" "$code"; return; fi
  fi
  tr=$(pick_transport)
  [ -z "$tr" ] && { warn "Cancelled."; return; }
  enc=$(pick_encryption "$tr")

  if is_tunnel_transport "$tr"; then
    write_tunnel_cfg "$role" "$name" "$tr" "$enc"
  else
    local dir; dir=$(pick_direction)
    read -r ka kmode kdata kparity <<< "$(pick_preset)"; build_extra "$role" "$tr" "$dir"
    local cfg="$CFG_DIR/$name.json"
    local bproto=tcp; case "$tr" in kcp|quic) bproto=udp ;; esac
    if [ "$role" = server ]; then
      local bind="" remote="" addrline ports token qtotal qup qdown
      if [ "$dir" = direct ]; then
        # This relay dials out; nothing listens here but the user ports. The
        # foreign server's listen port is picked at random from a quiet range
        # so tunnels from several relays to one foreign server do not collide
        # (it checks the port is free when the pairing code is applied there).
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
      ports=$(build_ports)
      if [ "$dir" = direct ]; then warn_port_clash "$ports" "$name"
      else warn_port_clash "$ports" "$name" "${bind##*:}" "$bproto"; fi
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
  $TLSJSON$EXTRA
  "keepalive": $ka,
  "kcp_mode": "$kmode", "kcp_data": $kdata, "kcp_parity": $kparity,
  "quota_total_gb": $qtotal, "quota_up_gb": $qup, "quota_down_gb": $qdown,
  "log_level": "info"
}
EOF
      info "Saved $cfg"
      if [ "$dir" = direct ]; then server_summary_direct "$remote" "$ports" "$bproto"
      else server_summary "$bind" "$ports"; fi
      show_pair_code "$cfg"
    else
      local remote="" bind="" addrline token target
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
  $EXTRA
  "keepalive": $ka,
  "kcp_mode": "$kmode", "kcp_data": $kdata, "kcp_parity": $kparity,
  "log_level": "info"
}
EOF
      info "Saved $cfg"
      if [ "$dir" = direct ]; then
        echo
        echo -e "  ${C_B}Direct mode:${C_N} the Iran server connects to this one on ${C_Y}${bproto^^} ${bind##*:}${C_N}."
        echo -e "  ${C_D}This server's firewall must allow that port inbound, e.g.${C_N}"
        echo -e "  ${C_D}  ufw allow ${bind##*:}/$bproto   or   iptables -I INPUT -p $bproto --dport ${bind##*:} -j ACCEPT${C_N}"
        echo -e "  ${C_D}On the Iran server enter:${C_N} ${C_Y}$(detect_ip):${bind##*:}${C_N}"
      fi
    fi
  fi

  install_health
  systemctl enable "brokennode@$name" >/dev/null 2>&1; systemctl restart "brokennode@$name"; sleep 1.5
  if [ "$(systemctl is-active "brokennode@$name" 2>/dev/null)" = active ]; then info "Tunnel '$name' is ${C_G}active${C_N}."
  else err "Tunnel '$name' failed to start. Recent log:"; journalctl -u "brokennode@$name" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'; fi
}

# link_state reports the REAL connection state by looking at the most recent
# connect/disconnect event in the journal, rather than trusting systemd's notion
# of "active" (which only means the process is alive).
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
      while IFS='=' read -r k v; do [ -n "$k" ] && L[$k]="$v"; done < "$lf"
    fi
    local ts="${L[ts]:-0}" age=$(( now - ${L[ts]:-0} ))
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
  local n="$1" cfg="$CFG_DIR/$1.json" hist="$CFG_DIR/.speedtests"
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
    if awk -v l="${ploss:-0}" 'BEGIN{exit !(l > 2)}'; then warnln "The path loses ${ploss}% of packets: kcp or udp copes with loss best; quic suffers most."; fi
  fi
  if awk -v d="$down" 'BEGIN{exit !(d < 20)}'; then
    case "$tr" in
      quic) warnln "quic slows down sharply on lossy paths. Compare with mtcp or tcp (option 9 changes the transport)." ;;
      *) warnln "Low speed: run the test again with another transport (option 9) and compare below." ;;
    esac
  fi
  if awk -v j="$tjit" 'BEGIN{exit !(j > 20)}'; then warnln "High jitter: games and calls will feel it. Try the udp transport or the gaming profile."; fi
  local dir; dir="$(jget "$cfg" direction)"
  printf '%s %s %s %s down=%s up=%s ping=%s jitter=%s streams=%s\n' "$(date '+%Y-%m-%d %H:%M')" "$n" "$tr" "${dir:-reverse}" \
    "$down" "$up" "$tping" "$tjit" "$streams" >> "$hist" 2>/dev/null
  tail -n 200 "$hist" > "$hist.tmp" 2>/dev/null && mv "$hist.tmp" "$hist"
  echo
  echo -e "  ${C_B}Recent results${C_N} ${C_D}(all tunnels on this server — compare transports)${C_N}"
  printf "  %-16s %-12s %-9s %9s %9s %8s %7s\n" "when" "tunnel" "transport" "↓ Mbit" "↑ Mbit" "ping" "jitter"
  tail -n 8 "$hist" | while read -r d t nm tt dir dn u p j st; do
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
  # A TCP carrier can be probed directly; kcp and quic run over UDP and sctp
  # over its own protocol, where a TCP probe says nothing, so for them only
  # the ping below speaks.
  case "$trans" in
  kcp|quic|sctp) : ;;
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
        [ -n "$l1" ] && [ "$l1" != 100 ] && echo -e "  ${C_Y}    The IP answers but the tunnel does not: is the other side running, with the addresses swapped?${C_N}"
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
  echo -e "  ${C_D}Note: UDP transports (kcp/quic) also need UDP open end-to-end;${C_N}"
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
d=json.load(open(f))
if kind=="int": d[k]=int(v)
elif kind=="float": d[k]=float(v)
elif kind=="bool": d[k]=(v.lower() in ("1","true","yes","on"))
elif kind=="del": d.pop(k,None)
else: d[k]=v
json.dump(d,open(f,"w"),indent=2)
open(f,"a").write("\n")
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

# udp_dup_state reads the switch back. jget prints a JSON bool through Python,
# so the value is the word True or False.
udp_dup_state(){
  [ "$(jget "$CFG_DIR/$1.json" udp_duplicate)" = "True" ] && echo on || echo off
}

# toggle_udp_duplicate turns duplicate-send on or off for ONE tunnel.
#
# Per tunnel and not a global default because it costs exactly double the
# bandwidth of the UDP it applies to. For a game that is a few hundred kbit and
# well worth it; for a bulk UDP flow it is not.
toggle_udp_duplicate(){
  local n="$1"; local cfg="$CFG_DIR/$n.json" cur
  cur="$(udp_dup_state "$n")"
  echo
  echo -e "${C_B}  Duplicate UDP packets  ${C_D}— currently $cur${C_N}"
  echo -e "  ${C_D}Sends every UDP datagram twice and drops the copy at the far end,${C_N}"
  echo -e "  ${C_D}so a packet has to be lost TWICE before the game notices.${C_N}"
  echo
  echo -e "  ${C_G}Fixes${C_N} loss that hits the two copies independently: a policer"
  echo -e "  ${C_D}dropping one packet in a hundred, or a lossy last mile.${C_N}"
  echo -e "  ${C_Y}Does not fix${C_N} loss from a full queue — both copies sit in that same"
  echo -e "  ${C_D}queue, so both are dropped. Shape the uplink for that (tune, option 2).${C_N}"
  echo
  echo -e "  ${C_D}Costs double this tunnel's UDP bandwidth. Needs quic at both ends,${C_N}"
  echo -e "  ${C_D}both new enough to negotiate it; otherwise it quietly does nothing.${C_N}"
  echo
  local target; target=$([ "$cur" = on ] && echo off || echo on)
  local want; want="$(ask "Turn it $target? yes/no" "no")"
  [ "$want" = yes ] || { info "Left it $cur."; return; }
  if [ "$target" = on ]; then
    jset "$cfg" udp_duplicate true bool
    info "Duplicate-send is ON for $n."
    warn "Set it on the OTHER end too, or only one direction is protected."
  else
    jset "$cfg" udp_duplicate false bool
    info "Duplicate-send is OFF for $n."
  fi
  systemctl restart "brokennode@$n" >/dev/null 2>&1
  info "Restarted brokennode@$n."
}

# is_udp_transport: carried over UDP, so the relay's firewall must allow UDP.
is_udp_transport(){ case "$1" in kcp|quic) return 0 ;; *) return 1 ;; esac; }

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
  local n="$1"; local cfg="$CFG_DIR/$n.json"
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
  jset "$cfg" transport "$new"
  jset "$cfg" encryption "$newenc"
  # Drop transport-specific leftovers.
  case "$new" in
    tcpnomux) jset "$cfg" links "" del ;;
    mtcp)     jset "$cfg" pool_size "" del ;;
    *)        jset "$cfg" pool_size "" del; jset "$cfg" links "" del ;;
  esac
  [ "$new" != sctp ] && { jset "$cfg" sctp_streams "" del; jset "$cfg" sctp_multihoming "" del; }
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

# change_relay_ip updates the IP this end dials, keeping the port: the Iran
# relay's IP on a foreign server in reverse mode (needed every time the relay's
# IP changes), or the foreign server's IP on the relay in direct mode.
change_relay_ip(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local fam; fam="$(transport_family "$(jget "$cfg" transport)")"
  if [ "$fam" != stream ]; then
    warn "'$n' is a point-to-point tunnel: change remote_ip with 'Edit config' instead."
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
  newip=$(ask "New $what IP (port $port kept)" "")
  [ -z "$newip" ] && { warn "cancelled"; return; }
  case "$newip" in *[!0-9.]*) err "Not an IPv4 address."; return;; esac
  jset "$cfg" remote_addr "$newip:$port"
  info "$what: $cur -> $newip:$port"
  systemctl restart "brokennode@$n" >/dev/null 2>&1
  info "restarted '$n'"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# change_direction flips a stream tunnel between reverse (the foreign server
# dials the relay) and direct (the relay dials the foreign server). Each end
# needs the address for its new role; the old one stays in the config, so
# flipping back later offers it as the default.
change_direction(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local tr mode cur new; tr="$(jget "$cfg" transport)"; mode="$(jget "$cfg" mode)"
  if [ "$(transport_family "$tr")" != stream ]; then
    warn "$tr has no direction: both ends send to each other, so it already works either way."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  cur="$(tunnel_direction "$cfg")"; [ "$cur" = direct ] && new=reverse || new=direct
  echo; echo -e "${C_B}  Direction of '$n'${C_N}  ${C_D}(now: $cur)${C_N}"
  echo -e "  ${C_D}reverse: the foreign server connects to the Iran server.${C_N}"
  echo -e "  ${C_D}direct:  the Iran server connects to the foreign server.${C_N}"
  local c; c=$(ask "Switch to $new? y/N" "N"); case "$c" in y|Y) :;; *) warn "cancelled"; return;; esac
  local bproto=tcp; case "$tr" in kcp|quic) bproto=udp ;; esac
  local bind remote port
  bind="$(jget "$cfg" bind_addr)"; remote="$(jget "$cfg" remote_addr)"
  # The side that will listen needs bind_addr; the side that will dial needs
  # remote_addr. The tunnel port is the same number either way.
  if { [ "$mode" = server ] && [ "$new" = reverse ]; } || { [ "$mode" = client ] && [ "$new" = direct ]; }; then
    port="${bind##*:}"; [ -z "$bind" ] && port="${remote##*:}"; [ -z "$port" ] && port=8443
    local v; v=$(ask "Listen address (host:port)" "${bind:-0.0.0.0:$port}")
    jset "$cfg" bind_addr "$(check_bind "$v")"
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
  fi
  jset "$cfg" direction "$new"
  info "direction: $cur -> $new"
  warn "Switch the OTHER server to ${C_Y}$new${C_N} too, or the two will not connect."
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
  local ka kmode kdata kparity
  read -r ka kmode kdata kparity <<< "$(pick_preset)"
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
    echo "   a) add a port     r) remove by number(s)     c) clear ALL     0) done"
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
        ports+=("${spec}${sfx}")
        ports_set "$cfg" "${ports[@]}"
        info "added ${spec}${sfx}"; service_check "$n"
        ;;
      r|R)
        [ "${#ports[@]}" -eq 0 ] && { warn "nothing to remove"; continue; }
        echo -e "  ${C_D}Enter numbers to remove: e.g. 1 3, or a range 2-4, or 'all'.${C_N}"
        local rsel; rsel=$(ask "Remove which" ""); [ -z "$rsel" ] && continue
        if [ "$rsel" = all ]; then rsel="1-${#ports[@]}"; fi
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
        ports_set "$cfg" "${keep[@]}"
        info "removed $removed port-forward(s)"; service_check "$n"
        ;;
      c|C)
        [ "${#ports[@]}" -eq 0 ] && { warn "already empty"; continue; }
        local yn; yn=$(ask "Remove ALL ${#ports[@]} port-forward(s)? y/N" "N")
        case "$yn" in y|Y) ports_set "$cfg"; info "all port-forwards removed"; service_check "$n";; *) : ;; esac
        ;;
      0|"") return ;;
      __eof__) return ;;
      *) warn "Invalid." ;;
    esac
  done
}

# tune_tunnel exposes the per-tunnel network knobs. Blank input keeps the current
# value, so it doubles as a way to review settings without changing them.
tune_tunnel(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local tr mode; tr="$(jget "$cfg" transport)"; mode="$(jget "$cfg" mode)"
  echo; echo -e "${C_B}  Tune '$n'${C_N}  ${C_D}($mode/$tr) — blank keeps the current value${C_N}"
  echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"

  local v cur
  local fam; fam=$(transport_family "$tr")
  if [ "$fam" != stream ]; then
    # Point-to-point tunnels have no smux, bind port or keepalive; what can be
    # tuned is the MTU and the addresses, which live in the config itself.
    cur="$(jget "$cfg" mtu)"
    v=$(ask "  mtu (0 = default) [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" mtu "$v" int
    if [ "$tr" = gre ] || [ "$tr" = gretap ] || [ "$tr" = ipip ] || [ "$tr" = sit ]; then
      cur="$(jget "$cfg" tun_ttl)"
      v=$(ask "  tun_ttl (outer TTL, 0 = kernel default) [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" tun_ttl "$v" int
    fi
    if [ "$mode" = client ]; then
      cur="$(jget "$cfg" target_host)"
      v=$(ask "  target_host (where traffic is delivered locally) [$cur]" ""); [ -n "$v" ] && jset "$cfg" target_host "$v"
    fi
    cur="$(jget "$cfg" log_level)"
    v=$(ask "  log_level (info/debug/error) [$cur]" ""); [ -n "$v" ] && jset "$cfg" log_level "$v"
    if ! python3 -c "import json,sys; json.load(open('$cfg'))" 2>/dev/null; then
      err "Config is not valid JSON after editing — NOT restarting. Fix it with 'Edit config'."
      read -t 30 -rp "  ▶ press ENTER to continue... " _; return
    fi
    systemctl restart "brokennode@$n" >/dev/null 2>&1
    info "settings saved, '$n' restarted"
    warn "mtu should match on both ends."
    read -t 30 -rp "  ▶ press ENTER to continue... " _
    return
  fi

  cur="$(jget "$cfg" keepalive)"
  v=$(ask "  keepalive seconds (lower = faster dead-peer detection) [$cur]" ""); [ -n "$v" ] && jset "$cfg" keepalive "$v" int

  # Both the current and the legacy transport names are matched here on purpose:
  # this reads whatever is already in the config file, and a tunnel created by an
  # older build still says "rawmux" or "mtcpobf" on disk (the core translates
  # those at load time, but the file itself is untouched).
  case "$tr" in
    kcp|rawmux)
      cur="$(jget "$cfg" kcp_mode)"
      echo -e "  ${C_D}kcp_mode: gaming = lowest/steadiest latency · fast · turbo = throughput · normal = low CPU${C_N}"
      v=$(ask "  kcp_mode [$cur]" ""); [ -n "$v" ] && jset "$cfg" kcp_mode "$v"
      cur="$(jget "$cfg" kcp_data)"
      v=$(ask "  kcp_data  (FEC data shards, e.g. 10) [$cur]" ""); [ -n "$v" ] && jset "$cfg" kcp_data "$v" int
      cur="$(jget "$cfg" kcp_parity)"
      echo -e "  ${C_D}Higher parity repairs more loss without retransmits (steadier ping) but uses more bandwidth.${C_N}"
      v=$(ask "  kcp_parity (FEC parity shards, e.g. 4) [$cur]" ""); [ -n "$v" ] && jset "$cfg" kcp_parity "$v" int
      cur="$(jget "$cfg" kcp_mtu)"
      echo -e "  ${C_D}MTU: 1200 is safe for gaming; raise only if the path has no fragmentation.${C_N}"
      v=$(ask "  kcp_mtu [${cur:-auto}]" ""); [ -n "$v" ] && jset "$cfg" kcp_mtu "$v" int
      cur="$(jget "$cfg" kcp_sndwnd)"
      v=$(ask "  kcp_sndwnd (send window, packets) [${cur:-auto}]" ""); [ -n "$v" ] && jset "$cfg" kcp_sndwnd "$v" int
      cur="$(jget "$cfg" kcp_rcvwnd)"
      v=$(ask "  kcp_rcvwnd (recv window, packets) [${cur:-auto}]" ""); [ -n "$v" ] && jset "$cfg" kcp_rcvwnd "$v" int
      cur="$(jget "$cfg" links)"
      echo -e "  ${C_D}Parallel kcp links (0 = auto: 4). One kcp link tops out near 120 Mbit/s for all users;${C_N}"
      echo -e "  ${C_D}4 carry about twice as much. 1 gives the steadiest ping under heavy load (gaming).${C_N}"
      echo -e "  ${C_D}Set it on the end that dials (the foreign server, or the relay in direct mode).${C_N}"
      v=$(ask "  links [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" links "$v" int
      ;;
    mtcp|mtcpobf)
      cur="$(jget "$cfg" links)"
      echo -e "  ${C_D}links: 0 = auto-scale with load (recommended)${C_N}"
      v=$(ask "  links [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" links "$v" int
      ;;
    tcpnomux)
      cur="$(jget "$cfg" pool_size)"
      echo -e "  ${C_D}pool_size: 0 = auto-scale with load (recommended)${C_N}"
      v=$(ask "  pool_size [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" pool_size "$v" int
      ;;
    sctp)
      cur="$(jget "$cfg" sctp_streams)"
      v=$(ask "  sctp_streams (1-65535) [${cur:-8}]" ""); [ -n "$v" ] && jset "$cfg" sctp_streams "$v" int
      cur="$(jget "$cfg" sctp_multihoming)"
      echo -e "  ${C_D}Extra local IPs for multihoming, comma-separated (blank keeps; '-' clears).${C_N}"
      v=$(ask "  sctp_multihoming [${cur:-none}]" "")
      if [ "$v" = "-" ]; then jset "$cfg" sctp_multihoming "" del; elif [ -n "$v" ]; then jset "$cfg" sctp_multihoming "$v"; fi
      ;;
  esac

  cur="$(jget "$cfg" smux_recv_mb)"
  v=$(ask "  smux_recv_mb (session window MB; larger = more throughput on long links) [${cur:-16}]" ""); [ -n "$v" ] && jset "$cfg" smux_recv_mb "$v" int
  cur="$(jget "$cfg" smux_stream_mb)"
  v=$(ask "  smux_stream_mb (per-stream window MB) [${cur:-8}]" ""); [ -n "$v" ] && jset "$cfg" smux_stream_mb "$v" int

  if [ "$(transport_family "$tr")" = stream ]; then
    if tunnel_listens "$cfg"; then
      cur="$(jget "$cfg" bind_addr)"
      v=$(ask "  bind_addr (listen host:port) [$cur]" "")
      [ -n "$v" ] && jset "$cfg" bind_addr "$(check_bind "$v")"
    else
      cur="$(jget "$cfg" remote_addr)"
      v=$(ask "  remote_addr (the other end, IP:port) [$cur]" ""); v="${v// /}"
      if [ -n "$v" ]; then
        case "$v" in *:*) : ;; *) v="$v:${cur##*:}" ;; esac  # IP only: keep the port
        jset "$cfg" remote_addr "$v"
      fi
    fi
  fi
  if [ "$mode" = server ]; then
    cur="$(jget "$cfg" quota_total_gb)"
    v=$(ask "  quota_total_gb (0 = unlimited) [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" quota_total_gb "$v" float
    cur="$(jget "$cfg" quota_up_gb)"
    v=$(ask "  quota_up_gb   (0 = unlimited) [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" quota_up_gb "$v" float
    cur="$(jget "$cfg" quota_down_gb)"
    v=$(ask "  quota_down_gb (0 = unlimited) [${cur:-0}]" ""); [ -n "$v" ] && jset "$cfg" quota_down_gb "$v" float
  else
    cur="$(jget "$cfg" target_host)"
    v=$(ask "  target_host (where traffic is delivered locally) [$cur]" ""); [ -n "$v" ] && jset "$cfg" target_host "$v"
  fi

  cur="$(jget "$cfg" log_level)"
  v=$(ask "  log_level (info/debug/error) [$cur]" ""); [ -n "$v" ] && jset "$cfg" log_level "$v"

  if ! python3 -c "import json,sys; json.load(open('$cfg'))" 2>/dev/null; then
    err "Config is not valid JSON after editing — NOT restarting. Fix it with 'Edit config'."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  systemctl restart "brokennode@$n" >/dev/null 2>&1
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
  info "all tunnels deleted"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
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
      echo "   1) Start    2) Stop    3) Restart"
      echo "   4) Live logs   5) Show config   6) Edit config (nano)"
      echo "   7) Delete   8) Live stats"
      echo -e "   ${C_G}9) Change transport${C_N}   ${C_G}10) Change peer IP${C_N}   ${C_G}11) Tune settings (MTU/FEC/window...)${C_N}"
      echo -e "   ${C_G}12) Duplicate UDP packets${C_N}  ${C_D}[$(udp_dup_state "$n")]${C_N}   ${C_G}13) Change direction${C_N}  ${C_D}[$(tunnel_direction "$CFG_DIR/$n.json")]${C_N}"
      echo -e "   ${C_G}14) Pairing code${C_N}  ${C_D}(for setting up the foreign server)${C_N}"
      echo -e "   ${C_G}15) Speed test${C_N}  ${C_D}(download/upload/ping through this tunnel)${C_N}"
      echo -e "   ${C_G}16) Apply preset${C_N}  ${C_D}(Optimized/High-Speed/Stable/Low-Latency/Eco)${C_N}   ${C_G}17) Port-forwards${C_N}  ${C_D}(add / remove / clear)${C_N}"
      echo "   0) Back"
      case "$(menu_ask 'Choice')" in
        1) systemctl enable --now "brokennode@$n" >/dev/null 2>&1; systemctl start "brokennode@$n"; info "started";;
        2) systemctl stop "brokennode@$n"; info "stopped";;
        3) systemctl restart "brokennode@$n"; info "restarted";;
        4) live_logs "$n";;
        5) echo; cat "$CFG_DIR/$n.json"; echo; read -t 30 -rp "  ▶ press ENTER to continue... " _;;
        6) "${EDITOR:-$ED}" "$CFG_DIR/$n.json"; systemctl restart "brokennode@$n"; info "saved & restarted";;
        7) local c; c=$(ask "Delete '$n' permanently? yes/no" "no")
           if [ "$c" = yes ]; then systemctl disable --now "brokennode@$n" >/dev/null 2>&1; rm -f "$CFG_DIR/$n.json"; info "deleted '$n'"; break; fi;;
        8) stats_page "$n";;
        9) change_transport "$n";;
        10) change_relay_ip "$n";;
        11) tune_tunnel "$n";;
        12) toggle_udp_duplicate "$n";;
        13) change_direction "$n";;
        14) if [ "$(jget "$CFG_DIR/$n.json" mode)" = server ]; then show_pair_code "$CFG_DIR/$n.json"; else warn "Pairing codes come from the Iran (server) side."; fi
            read -t 60 -rp "  ▶ press ENTER to continue... " _;;
        15) speed_test "$n"; read -t 120 -rp "  ▶ press ENTER to continue... " _;;
        16) apply_preset "$n";;
        17) manage_ports "$n";;
        __eof__) return;;
        0) break;;
        *) warn "Invalid.";;
      esac
    done
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

install_health(){
  [ "$(id -u)" -eq 0 ] || return 0
  cat > "$HEALTH_SVC" <<EOF
[Unit]
Description=BrokenNode tunnel health check
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF _health
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

# health_check is the timer's body: restart any tunnel that is enabled but not
# active, or that has reported its peer DOWN with no recovery for a few minutes.
# It is deliberately conservative — it never restarts a tunnel that is merely
# idle — so it cannot turn into a restart loop on a healthy link.
health_check(){
  local f n st
  for f in "$CFG_DIR"/*.json; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .json)"
    # Only look at tunnels the operator wants running.
    systemctl is-enabled "brokennode@$n" >/dev/null 2>&1 || continue
    st="$(systemctl is-active "brokennode@$n" 2>/dev/null)"
    if [ "$st" != active ]; then
      logger -t brokennode-health "restarting brokennode@$n (state: $st)" 2>/dev/null
      systemctl restart "brokennode@$n" 2>/dev/null
      continue
    fi
    # Active process, but has the peer link been down for a while? Compare the
    # unix time of the last "down" line with the last "up" line in the recent
    # journal. A quiet, healthy tunnel logs neither and is left alone; a tunnel
    # whose most recent event is a disconnect older than the threshold is
    # restarted. Timestamps are integers (seconds); the fractional part is cut.
    local jr down up now
    jr="$(journalctl -u "brokennode@$n" --since '-10min' -n 400 --no-pager -o short-unix 2>/dev/null)"
    down="$(printf '%s\n' "$jr" | grep -E '🔴 Disconnected|TUNNEL IS DOWN|peer timeout' | tail -1 | awk '{print int($1)}')"
    [ -z "$down" ] && continue                       # never went down recently
    up="$(printf '%s\n' "$jr" | grep -E '🟢 Connected|peer CONNECTED' | tail -1 | awk '{print int($1)}')"
    [ -n "$up" ] && [ "$up" -ge "$down" ] && continue # it came back after the last drop
    now="$(date +%s)"
    if [ $((now - down)) -ge 180 ]; then
      logger -t brokennode-health "restarting brokennode@$n (peer link down ~$((now - down))s)" 2>/dev/null
      systemctl restart "brokennode@$n" 2>/dev/null
    fi
  done
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
  if [ ! -x "$BIN" ] || ! cmp -s "$src" "$BIN"; then
    warn "New core bundled with this package — applying automatically..."
    install -m0755 "$src" "$BIN"; info "Core: $("$BIN" version)"
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
  rm -f "$AU_SVC" "$AU_TIMER" "$HEALTH_SVC" "$HEALTH_TMR" "$TPL"
  systemctl daemon-reload 2>/dev/null; systemctl reset-failed 2>/dev/null
  rm -f "$BIN" "$BIN.bak"
  rm -rf "$CFG_DIR"
  info "BrokenNode fully removed — core, tunnels, configs and units are gone."
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
shape_egress(){
  local mbit="$1" dev; dev="$(default_iface)"
  [ -n "$dev" ] || { err "Could not find the default interface."; return 1; }
  command -v tc >/dev/null 2>&1 || { err "tc is missing (install iproute2)."; return 1; }
  if [ "${mbit:-0}" = 0 ]; then
    tc qdisc del dev "$dev" root 2>/dev/null
    rm -f /etc/systemd/system/brokennode-shape.service
    systemctl disable brokennode-shape.service >/dev/null 2>&1
    systemctl daemon-reload >/dev/null 2>&1
    info "Shaping removed from $dev."
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

main_menu(){
  auto_apply_bundled
  while true; do
    banner
    echo
    echo "   1) Create SERVER tunnel   (Iran relay)"
    echo "   2) Create CLIENT tunnel   (foreign server)"
    echo "   3) Manage tunnels         (edit / transport / IP / logs / stats)"
    echo "   4) Health check           (doctor: BBR / ports / loss / IP)"
    echo "   5) Update BrokenNode      (download the latest into this folder)"
    echo "   0) Exit"
    echo -e "  ${C_D}(the core in this folder is applied automatically on start)${C_N}"
    echo
    case "$(menu_ask 'Choice')" in
      1) create_tunnel server; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      2) create_tunnel client; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      3) manage_tunnels ;;
      4) doctor; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      5) update_self ;;
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
    # shellcheck disable=SC2086
    systemctl "$action" $units && echo "done." ;;
  uninstall|purge) uninstall_all ;;
  version) echo "BrokenNode manager v$VERSION" ;;
  update) update_self ;;
  ""|menu) main_menu ;;
  *) echo "usage: sudo bash $SELF [server|client|manage|transports|tune|restart-all|start-all|stop-all|doctor|update|uninstall|version]"; exit 1 ;;
esac
