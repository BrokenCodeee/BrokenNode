#!/usr/bin/env bash
# ============================================================================
#  BrokenNode Tunnel - Manager (prebuilt core, no build / no internet)
#  Multi-instance | presets | per-port tcp/udp/both | systemd
#  Transport and encryption are chosen separately (see pick_transport /
#  pick_encryption). ip-spoofing is built into the core and uses the same
#  config/unit as every other transport.
# ============================================================================
set -uo pipefail

VERSION="2.3.5"
# Bump when the sysctl tuning changes: hosts tuned by an older release pick
# the new values up automatically (see auto_tune_once).
TUNE_VERSION=2
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

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_M='\033[0;35m'; C_D='\033[0;90m'; C_N='\033[0m'
info(){ echo -e "${C_G}  [+]${C_N} $*"; }
warn(){ echo -e "${C_Y}  [!]${C_N} $*"; }
err(){ echo -e "${C_R}  [x]${C_N} $*" >&2; }
ask(){ local p="$1" d="${2:-}" a; if [ -n "$d" ]; then read -rp "$(echo -e "${C_B}  ?${C_N} $p [${C_D}$d${C_N}]: ")" a; echo "${a:-$d}"; else read -rp "$(echo -e "${C_B}  ?${C_N} $p: ")" a; echo "$a"; fi; }
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
ensure_core(){
  local src; src="$(detect_bin)"
  if [ -n "$src" ] && [ -f "$src" ]; then
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
#   spoof   spoof_* fields
transport_family(){
  case "$1" in
    sit) echo sit ;;
    spoof) echo spoof ;;
    *) if is_tunnel_transport "$1"; then echo p2p4; else echo stream; fi ;;
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
#   carriers   : udp carrier ports in use (6262 when a udp tunnel leaves it unset)
cfg_scan(){
  python3 - "$CFG_DIR" "$1" "$2" "${3:-}" <<'PYEOF2'
import json, os, sys, glob
d, mode, excl, key = sys.argv[1:5]
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
        b = c.get("bind_addr") or ""
        if ":" in b:
            pr = "udp" if c.get("transport") in ("kcp", "quic") else "tcp"
            print(b.rsplit(":", 1)[1] + "/" + pr)
    elif mode == "carriers":
        if c.get("transport") in ("udp", "spoof") and c.get("carrier_proto", "udp") in ("", "udp"):
            print(c.get("carrier_port") or 6262)
PYEOF2
}

# next_free_int KEY START EXCLUDE — smallest integer >= START no other tunnel uses for KEY.
next_free_int(){
  local key="$1" v="$2" used
  used=" $( { if [ "$key" = carrier_port ]; then cfg_scan carriers "$3"; else cfg_scan values "$3" "$key"; fi; } | tr '\n' ' ') "
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

# print_peer_values tells the operator exactly what to type on the foreign
# server, whose wizard cannot know which free values this relay picked.
print_peer_values(){
  echo
  echo -e "  ${C_B}Enter these on the OTHER (foreign) server:${C_N}"
  echo -e "    this server's real IP      ${C_Y}$1${C_N}   (the other server's own IP: $2)"
  echo -e "    this end's tunnel address  ${C_Y}$3${C_N}"
  echo -e "    other end's tunnel address ${C_Y}$4${C_N}"
  [ -n "$5" ] && echo -e "    token                      ${C_Y}$5${C_N}"
  [ -n "$PEER_HINT" ] && printf "$PEER_HINT" | sed "s/^/  /"
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
  echo -e "   7) ip-spoofing  Spoofed-IP TUN        ${C_M}(blackout / national whitelist)${C_N}" >&2
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
      5|kcp) echo kcp; return ;;        6|quic) echo quic; return ;;
      7|spoof|ip-spoofing) echo spoof; return ;;
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
# already encrypts with TLS 1.3 and spoof is a packet carrier, so neither takes a
# layer and neither is asked.
pick_encryption(){
  local tr="$1"
  # quic (TLS 1.3) and the kernel tunnels (encrypt at the service) take no
  # encryption layer, so they are not asked.
  case "$tr" in
    quic|gre|gretap|ipip|sit|l2tp) echo none; return ;;
  esac
  # udp/icmp seal each datagram, exactly like spoof: offer aead/none.
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
  if [ "$tr" = spoof ]; then
    # spoof seals each datagram; a stream cipher cannot key reorderable packets.
    echo -e "   1) aead   ChaCha20-Poly1305   ${C_G}(encrypted + tamper-proof, Recommended)${C_N}" >&2
    echo    "   2) none   No encryption (what older builds did)" >&2
    echo -e "  ${C_D}──────────────────────────────────────────────${C_N}" >&2
    echo -e "  ${C_D}Without this, anyone who can forge the whitelisted source IP can${C_N}" >&2
    echo -e "  ${C_D}inject packets straight into your TUN device.${C_N}" >&2
    local n; n=$(ask "Choice [1-2]" "1")
    case "$n" in 2) echo none ;; *) echo aead ;; esac
    return
  fi
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
    spec=$(ask "Port(s) (empty=done)" ""); [ -z "$spec" ] && break
    proto=$(ask "Protocol  1)tcp 2)udp 3)both" "3")
    case "$proto" in 1) sfx="";; 2) sfx="/udp";; *) sfx="/both";; esac
    arr+=("\"${spec}${sfx}\""); echo -e "${C_G}    added ${spec}${sfx}${C_N}" >&2
  done
  [ ${#arr[@]} -eq 0 ] && arr+=("\"443/both\""); ( IFS=,; echo "${arr[*]}" )
}

build_extra(){ local role="$1" tr="$2"; EXTRA=""; TLSJSON=""
  case "$tr" in
    ws)
      EXTRA="\"ws_path\":\"$(ask 'WebSocket path' '/')\","
      if [ "$role" = client ]; then
        local h u; h=$(ask 'Fake Host header (domain fronting, empty=none)' '')
        u=$(ask 'User-Agent (empty=default)' '')
        [ -n "$h" ] && EXTRA="$EXTRA\"ws_host\":\"$h\","
        [ -n "$u" ] && EXTRA="$EXTRA\"ws_user_agent\":\"$u\","
      fi ;;
    tcpnomux) EXTRA="\"pool_size\":$(ask 'Connection pool size (0 = AUTO, scales with load — recommended)' '0'),";;
    kcp)
      local w; w=$(ask 'KCP window (send/recv, empty=1024)' '')
      [ -n "$w" ] && EXTRA="\"kcp_sndwnd\":$w,\"kcp_rcvwnd\":$w," ;;
    mtcp) [ "$role" = client ] && EXTRA="\"links\":$(ask 'Parallel links (0 = AUTO, scales with load — recommended)' '0'),";;
    sctp)
      local mh; mh=$(ask 'Extra local IPs for multihoming (comma-separated, blank = none)' '')
      local st; st=$(ask 'Outbound streams' '8')
      EXTRA="\"sctp_streams\":${st:-8},"
      [ -n "$mh" ] && EXTRA="$EXTRA\"sctp_multihoming\":\"$mh\","
      ;;
  esac
}

# spoof transport: collect spoof_* fields, write a NORMAL JSON config (transport=spoof)
write_spoof_cfg(){
  # NOTE: these must be SEPARATE 'local' statements. Bash does not make an
  # earlier assignment visible to a later one in the same 'local', so
  #   local name="$2" cfg="$CFG_DIR/$name.json"
  # silently produced "/etc/brokennode/.json" (name empty) and every
  # ip-spoofing tunnel was written to the wrong path.
  local role="$1"
  local name="$2"
  local enc="${3:-none}"
  local cfg="$CFG_DIR/$name.json"
  # An encrypted spoof tunnel needs a shared token: it keys the per-packet
  # sealer. Both ends must use the SAME one, exactly like every other transport.
  local token="" tokline=""
  if [ "$enc" != none ]; then
    if [ "$role" = server ]; then
      token=$(ask "Shared token (for encryption)" "$(gen_token)")
    else
      token=$(ask "Shared token (same as the other side)" "")
    fi
    tokline="
  \"token\": \"$token\","
  fi
  echo -e "${C_B}  Spoof carrier protocol:${C_N}" >&2
  echo    "   1) udp    (tested, recommended)" >&2
  echo -e "   2) tcp    fake-TCP ${C_Y}(untested)${C_N}" >&2
  echo -e "   3) icmp   echo      ${C_Y}(untested)${C_N}" >&2
  echo -e "   4) gre    IP proto 47 ${C_Y}(untested; often whitelisted)${C_N}" >&2
  local pn cproto; pn=$(ask "Choice [1-4]" "1"); case "$pn" in 2) cproto=tcp;; 3) cproto=icmp;; 4) cproto=gre;; *) cproto=udp;; esac
  echo -e "  ${C_D}Enter the SAME IPs on BOTH servers; cross-over is automatic.${C_N}" >&2
  local det iran foreign w1 w2; det=$(detect_ip)
  if [ "$role" = server ]; then
    iran=$(ask "Iran IP    (this machine, real)" "$det")
    foreign=$(ask "Foreign IP (peer, real)" "")
  else
    foreign=$(ask "Foreign IP (this machine, real)" "$det")
    iran=$(ask "Iran IP    (peer, real)" "")
  fi
  w1=$(ask "White IP #1 — the one IRAN sends as source" "")
  w2=$(ask "White IP #2 — the one FOREIGN sends as source" "")
  # The relay offers a carrier port and tunnel subnet no other tunnel here
  # uses; the foreign side offers the base values and must match the relay.
  local dcp=6262 nn=20
  if [ "$role" = server ]; then dcp=$(next_free_int carrier_port 6262 "$name"); nn=$(next_free_net "$name" 20); fi
  local cport mtu jit jjson; cport=$(ask "Carrier port (udp/tcp, same on both ends)" "$dcp"); mtu=$(ask "MTU" "1320")
  # These go into the JSON unquoted: anything but a number in range would
  # leave a config the core cannot parse, so fall back to the default.
  case "$cport" in ''|*[!0-9]*) cport=$dcp ;; esac
  if [ "$cport" -lt 1 ] || [ "$cport" -gt 65535 ]; then warn "Carrier port must be 1-65535; using $dcp"; cport=$dcp; fi
  case "$mtu" in ''|*[!0-9]*) mtu=1320 ;; esac
  if [ "$mtu" -lt 576 ] || [ "$mtu" -gt 9000 ]; then warn "MTU must be 576-9000; using 1320"; mtu=1320; fi
  local dnn=$nn
  nn=$(ask "Tunnel subnet: 10.10.N.x — N (same on both ends)" "$nn"); case "$nn" in ''|*[!0-9]*) nn=$dnn ;; esac
  if [ "$nn" -gt 255 ]; then warn "N must be 0-255; using $dnn"; nn=$dnn; fi
  jit=$(ask "TTL jitter? (anti-fingerprint) y/N" "N")
  local jline jtail; case "$jit" in y|Y) jline='
  "ttl_jitter": true,'; jtail=',
  "ttl_jitter": true';; *) jline=''; jtail='';; esac
  local lip pip ssrc sdst tl trr
  if [ "$role" = server ]; then
    lip="$iran"; pip="$foreign"; ssrc="$w1"; sdst="$w2"; tl=10.10.$nn.1; trr=10.10.$nn.2
  else
    lip="$foreign"; pip="$iran"; ssrc="$w2"; sdst="$w1"; tl=10.10.$nn.2; trr=10.10.$nn.1
  fi
  local portsjson=""
  if [ "$role" = server ]; then
    portsjson=$(build_ports)
    warn_port_clash "$portsjson" "$name"
  fi
  if [ "$role" = server ]; then
    new_cfg_file "$cfg"
    cat > "$cfg" <<EOF
{
  "mode": "server",
  "transport": "spoof",
  "encryption": "$enc",$tokline
  "log_level": "info",
  "spoof_local_ip": "$lip",
  "spoof_peer_ip": "$pip",
  "spoof_src": "$ssrc",
  "spoof_dst": "$sdst",
  "carrier_proto": "$cproto",
  "carrier_port": $cport,
  "tun_local": "$tl",
  "tun_remote": "$trr",
  "mtu": $mtu,$jline
  "ports": [$portsjson]
}
EOF
  else
    new_cfg_file "$cfg"
    cat > "$cfg" <<EOF
{
  "mode": "client",
  "transport": "spoof",
  "encryption": "$enc",$tokline
  "log_level": "info",
  "spoof_local_ip": "$lip",
  "spoof_peer_ip": "$pip",
  "spoof_src": "$ssrc",
  "spoof_dst": "$sdst",
  "carrier_proto": "$cproto",
  "carrier_port": $cport,
  "tun_local": "$tl",
  "tun_remote": "$trr",
  "mtu": $mtu$jtail
}
EOF
  fi
  info "Saved $cfg"
  echo -e "  ${C_D}  proto=$cproto  spoof_src=$ssrc  spoof_dst=$sdst  encryption=$enc${C_N}"
  if [ "$role" = server ]; then
    # The foreign wizard offers the base carrier port and subnet; this relay
    # may have picked others to stay clear of its other tunnels.
    echo
    echo -e "  ${C_B}Enter these on the OTHER (foreign) server:${C_N}"
    echo -e "    carrier port   ${C_Y}$cport${C_N}"
    echo -e "    subnet N       ${C_Y}$nn${C_N}   (10.10.$nn.x)"
    [ "$enc" != none ] && echo -e "    token          ${C_Y}$token${C_N}"
  fi
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
    echo -e "  ${C_D}bind_addr is where the relay LISTENS, so it must be an address this${C_N}"
    echo -e "  ${C_D}server actually has. On a VPS behind NAT the public ip lives on the${C_N}"
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

# write_tunnel_cfg writes the config for a point-to-point tunnel: the kernel
# tunnels (gre/gretap/ipip/sit/l2tp) and the raw carriers (udp/icmp). These do
# not bind a listen port like tcp — they need the two servers' real addresses
# and the addresses on the tunnel itself. The server also maps user ports across
# the tunnel; the client names the local backend.
write_tunnel_cfg(){
  # Two statements: in one 'local', $name would expand before it is assigned
  # (see write_spoof_cfg). It only worked because the caller has its own $name.
  local role="$1" name="$2" tr="$3" enc="$4"
  local cfg="$CFG_DIR/$name.json"
  PEER_HINT=""
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
  # sit carries IPv6, so its tunnel addresses are IPv6 (a ULA pair); every
  # other point-to-point tunnel here uses an IPv4 pair.
  # A free pair: every tunnel on this server needs its own tunnel addresses,
  # or their routes collide and one tunnel takes the other's traffic.
  # Only the relay picks free values: it is the side that carries several
  # tunnels. The foreign server usually has one and cannot know what the relay
  # picked, so it offers the base values; the relay prints what to enter.
  local nn=30; [ "$role" = server ] && nn="$(next_free_net "$name")"
  local a1=10.10.$nn.1 a2=10.10.$nn.2
  if [ "$tr" = sit ]; then
    a1=fd00:10:$nn::1 a2=fd00:10:$nn::2
    echo -e "  ${C_D}sit carries IPv6: the tunnel addresses below must be IPv6.${C_N}"
  fi
  tl=$(ask "This end's tunnel address" "$([ "$role" = server ] && echo $a1 || echo $a2)")
  trr=$(ask "The OTHER end's tunnel address" "$([ "$role" = server ] && echo $a2 || echo $a1)")
  local mtu; mtu=$(ask "MTU (blank = auto)" "")
  case "$mtu" in ""|*[!0-9]*) mtu=0 ;; esac

  # transport-specific extras
  local extra=""
  case "$tr" in
    gre|gretap)
      local k; k=$(ask "GRE key (0 = none)" "0"); case "$k" in *[!0-9]*) k=0 ;; esac
      [ "$k" != 0 ] && extra="\"gre_key\": $k,"
      ;;
    l2tp)
      local tid sid en
      local dt=1000 ds=1000
      [ "$role" = server ] && { dt=$(next_free_int l2tp_tunnel_id 1000 "$name"); ds=$(next_free_int l2tp_session_id 1000 "$name"); }
      tid=$(ask "Tunnel id (same on both ends)" "$dt")
      sid=$(ask "Session id (same on both ends)" "$ds")
      PEER_HINT="$PEER_HINT  l2tp tunnel id $tid, session id $sid\n"
      en=$(ask "Encap  1)udp 2)ip" "1"); [ "$en" = 2 ] && en=ip || en=udp
      extra="\"l2tp_tunnel_id\": ${tid:-1000}, \"l2tp_session_id\": ${sid:-1000}, \"l2tp_encap\": \"$en\","
      ;;
    udp|icmp)
      echo -e "  ${C_D}By default the real source IP is used (no forging). To forge a${C_N}"
      echo -e "  ${C_D}whitelisted source for a blackout, answer the next two; blank = no forging.${C_N}"
      local ssrc sdst; ssrc=$(ask "Forge source IP (blank = real)" "")
      sdst=$(ask "Expected peer source IP (blank = real)" "")
      [ -n "$ssrc" ] && extra="$extra\"spoof_src\": \"$ssrc\","
      [ -n "$sdst" ] && extra="$extra\"spoof_dst\": \"$sdst\","
      if [ "$tr" = udp ]; then
        # Each udp tunnel on this server needs its own carrier port: a second
        # tunnel on a taken one cannot bind and will not start.
        local dcp=6262; [ "$role" = server ] && dcp=$(next_free_int carrier_port 6262 "$name")
        local cport; cport=$(ask "Carrier UDP port (same on both ends)" "$dcp")
        case "$cport" in ''|*[!0-9]*) cport=6262 ;; esac
        extra="$extra\"carrier_port\": $cport,"
        PEER_HINT="$PEER_HINT  carrier port $cport\n"
      fi
      ;;
  esac

  local tokline=""; local token
  token=$(ask "Shared token (same on both ends)" "$(gen_token)")
  tokline="\"token\": \"$token\","

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
    info "Saved $cfg"; warn "Token for the client: ${C_Y}$token${C_N}"
    print_peer_values "$rip" "$lip" "$trr" "$tl" "$token"
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
  "target_host": "$target",
  "mtu": $mtu,
  $extra
  "log_level": "info"
}
EOF
    info "Saved $cfg"
  fi
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
  tr=$(pick_transport)
  [ -z "$tr" ] && { warn "Cancelled."; return; }
  enc=$(pick_encryption "$tr")

  if [ "$tr" = spoof ]; then
    write_spoof_cfg "$role" "$name" "$enc"
  elif is_tunnel_transport "$tr"; then
    write_tunnel_cfg "$role" "$name" "$tr" "$enc"
  else
    read -r ka kmode kdata kparity <<< "$(pick_preset)"; build_extra "$role" "$tr"
    local cfg="$CFG_DIR/$name.json"
    if [ "$role" = server ]; then
      local bind ports token qtotal qup qdown
      bind=$(ask "Tunnel listen address (host:port)" "0.0.0.0:8443")
      bind="$(check_bind "$bind")"
      ports=$(build_ports)
      local bproto=tcp; case "$tr" in kcp|quic) bproto=udp ;; esac
      warn_port_clash "$ports" "$name" "${bind##*:}" "$bproto"
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
  "token": "$token",
  "bind_addr": "$bind",
  "ports": [$ports],
  $TLSJSON$EXTRA
  "keepalive": $ka,
  "kcp_mode": "$kmode", "kcp_data": $kdata, "kcp_parity": $kparity,
  "quota_total_gb": $qtotal, "quota_up_gb": $qup, "quota_down_gb": $qdown,
  "log_level": "info"
}
EOF
      info "Saved $cfg"; warn "Token for the client: ${C_Y}$token${C_N}"
      server_summary "$bind" "$ports"
    else
      local remote token target
      remote=$(ask "Tunnel server address (Iran relay IP:port)" "1.2.3.4:8443")
      token=$(ask "Shared token (same as server)" ""); target=$(ask "Local services host" "127.0.0.1")
      new_cfg_file "$cfg"
    cat > "$cfg" <<EOF
{
  "mode": "client",
  "transport": "$tr",
  "encryption": "$enc",
  "token": "$token",
  "remote_addr": "$remote",
  "target_host": "$target",
  $EXTRA
  "keepalive": $ka,
  "kcp_mode": "$kmode", "kcp_data": $kdata, "kcp_parity": $kparity,
  "log_level": "info"
}
EOF
      info "Saved $cfg"
    fi
  fi

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
    printf "  %2d) %-14s ${col}%-8s${C_N} %-22s ${C_D}%s/%s${C_N}\n" "$i" "$n" "$st" "$link" "$m" "$tr"
    # second line: address/port + psk (token), so both sides can be re-checked
    # against each other at a glance without opening the config file.
    local psk addr ports
    psk="$(sed -n 's/.*"token"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$f")"
    if [ "$m" = server ]; then
      addr="$(sed -n 's/.*"bind_addr"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$f")"
      ports="$(sed -n 's/.*"ports"[ ]*:[ ]*\[\([^]]*\)\].*/\1/p' "$f" | tr -d '"')"
      printf "      ${C_D}listen: %-22s ports: %-18s psk: %s${C_N}\n" "${addr:-?}" "${ports:-?}" "${psk:-?}"
    else
      addr="$(sed -n 's/.*"remote_addr"[ ]*:[ ]*"\([^"]*\)".*/\1/p' "$f")"
      printf "      ${C_D}relay:  %-22s psk: %s${C_N}\n" "${addr:-?}" "${psk:-?}"
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

# stats_page: live per-tunnel traffic (upload/download/total + connections),
# refreshed from the core's stats file. Ctrl+C returns to the menu.
stats_page(){
  local n="$1" unit="brokennode@$1" f="/var/lib/brokennode/$1.stats"
  local leave=0
  # Ctrl+C must LEAVE this page, as the on-screen hint promises. The previous
  # trap made SIGINT a no-op (':'), so pressing Ctrl+C only cut the sleep short
  # and the "while true" loop kept redrawing forever — the page was inescapable
  # and the "trap - INT" below was unreachable. Set a flag the loop can see.
  trap 'leave=1' INT
  while [ "$leave" -eq 0 ]; do
    banner
    echo -e "${C_B}  Live stats: $n${C_N}   ${C_D}[$(systemctl is-active "$unit" 2>/dev/null)]  (Ctrl+C = back)${C_N}"
    echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
    if [ -f "$f" ]; then
      local lup ldown ltot sup sdown stot atcp audp peak conns ts age
      lup=$(sed -n 's/^life_up=//p' "$f");     ldown=$(sed -n 's/^life_down=//p' "$f");   ltot=$(sed -n 's/^life_total=//p' "$f")
      sup=$(sed -n 's/^sess_up=//p' "$f");     sdown=$(sed -n 's/^sess_down=//p' "$f");   stot=$(sed -n 's/^sess_total=//p' "$f")
      atcp=$(sed -n 's/^active_tcp=//p' "$f"); audp=$(sed -n 's/^active_udp=//p' "$f")
      peak=$(sed -n 's/^peak=//p' "$f");       conns=$(sed -n 's/^conns=//p' "$f");       ts=$(sed -n 's/^ts=//p' "$f")
      age=$(( $(date +%s) - ${ts:-0} ))
      echo -e "    ${C_B}Lifetime${C_N} ${C_D}(survives restarts & reboots)${C_N}"
      printf "      ↑ %s   ↓ %s   total %s\n" "$(hb "${lup:-0}")" "$(hb "${ldown:-0}")" "$(hb "${ltot:-0}")"
      echo -e "    ${C_B}This session${C_N}"
      printf "      ↑ %s   ↓ %s   total %s\n" "$(hb "${sup:-0}")" "$(hb "${sdown:-0}")" "$(hb "${stot:-0}")"
      echo -e "  ${C_D}──────────────────────────────────────────────${C_N}"
      printf "    Active connections : %s  (tcp %s, udp %s)\n" "$(( ${atcp:-0} + ${audp:-0} ))" "${atcp:-0}" "${audp:-0}"
      printf "    Peak / total seen  : %s / %s\n" "${peak:-0}" "${conns:-0}"
      echo -e "  ${C_D}  (updated ${age}s ago; core writes stats every 30s)${C_N}"
    else
      echo "    No stats yet — start the tunnel; the core writes stats every 30s."
    fi
    sleep 2
  done
  trap - INT
  echo -e "\n${C_G}  ← back to menu${C_N}"; sleep 0.3
}

okln(){   echo -e "  ${C_G}✔${C_N} $*"; }
warnln(){ echo -e "  ${C_Y}▲${C_N} $*"; }
badln(){  echo -e "  ${C_R}✗${C_N} $*"; }

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
      dev="$(cat "/run/brokennode/$n.dev" 2>/dev/null)"
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

    if [ "$mode" = server ]; then
      local port; port="${bind##*:}"
      if [ -n "$port" ]; then
        ss -ltnup 2>/dev/null | grep -q ":$port " && okln "  listening on port $port" || { warnln "  port $port not listening"; warns=$((warns+1)); }
      fi
      # Traffic quota status (only meaningful for non-spoof transports — see
      # quota_test.go / the stats system; ip-spoofing doesn't route through it).
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
    else
      # client: measure path quality to the relay
      local host="${remote%%:*}"
      if [ -n "$host" ]; then
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

# change_transport swaps a tunnel's transport in place, keeping token, ports and
# addresses. It also clears settings that belong to the OLD transport so a
# leftover field cannot confuse the new one.
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
  if [ "$mode" = server ] && is_udp_transport "$new" && ! is_udp_transport "$cur"; then
    local port; port="$(jget "$cfg" bind_addr)"; port="${port##*:}"
    warn "$new runs over UDP: the relay firewall must allow ${C_Y}UDP $port${C_N} (TCP alone is not enough)."
    warn "e.g.  ufw allow $port/udp   or   iptables -I INPUT -p udp --dport $port -j ACCEPT"
  fi
  warn "Do the SAME on the other server: '$new' with encryption '$newenc', or they will not connect."
  service_check "$n"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
}

# change_relay_ip updates where a CLIENT tunnel dials, keeping the port. This is
# the operation needed every time the Iran relay's IP changes.
change_relay_ip(){
  local n="$1"; local cfg="$CFG_DIR/$n.json"
  local mode; mode="$(jget "$cfg" mode)"
  if [ "$mode" != client ]; then
    warn "'$n' is a SERVER tunnel — it listens rather than dials, so it has no relay IP."
    warn "Change its listen address with 'Tune settings' instead."
    read -t 30 -rp "  ▶ press ENTER to continue... " _; return
  fi
  local cur port newip; cur="$(jget "$cfg" remote_addr)"; port="${cur##*:}"
  echo; echo -e "${C_B}  Change relay IP for '$n'${C_N}  ${C_D}(current: $cur)${C_N}"
  newip=$(ask "New relay IP (port $port kept)" "")
  [ -z "$newip" ] && { warn "cancelled"; return; }
  case "$newip" in *[!0-9.]*) err "Not an IPv4 address."; return;; esac
  jset "$cfg" remote_addr "$newip:$port"
  info "relay: $cur -> $newip:$port"
  systemctl restart "brokennode@$n" >/dev/null 2>&1
  info "restarted '$n'"
  read -t 30 -rp "  ▶ press ENTER to continue... " _
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

  if [ "$mode" = server ]; then
    cur="$(jget "$cfg" bind_addr)"
    v=$(ask "  bind_addr (listen host:port) [$cur]" "")
    [ -n "$v" ] && jset "$cfg" bind_addr "$(check_bind "$v")"
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
      echo -e "   ${C_G}9) Change transport${C_N}   ${C_G}10) Change relay IP${C_N}   ${C_G}11) Tune settings (MTU/FEC/window...)${C_N}"
      echo -e "   ${C_G}12) Duplicate UDP packets${C_N}  ${C_D}[$(udp_dup_state "$n")]${C_N}"
      echo "   0) Back"
      case "$(ask 'Choice' '')" in
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
        0) break;;
        *) warn "Invalid.";;
      esac
    done
  done
}


# restart_all_tunnels: refresh the unit and restart every configured instance.
restart_all_tunnels(){
  write_template
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

# auto_apply_bundled: run at startup. If the binary shipped next to the script
# differs from what's installed, install it and restart tunnels automatically —
# so customers never have to pick an "update" menu item. No-op when already
# up to date, or when not root.
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

auto_apply_bundled(){
  [ "$(id -u)" -eq 0 ] || return 0
  auto_tune_once
  local src; src="$(detect_bin)"
  [ -n "$src" ] && [ -f "$src" ] || return 0
  if [ ! -x "$BIN" ] || ! cmp -s "$src" "$BIN"; then
    warn "New core bundled with this package — applying automatically..."
    install -m0755 "$src" "$BIN"; info "Core: $("$BIN" version)"
    restart_all_tunnels
    info "Auto-update done — configs untouched."
    read -t 15 -rp "  ▶ Press ENTER to continue (auto-continuing in 15s)... " _ 2>/dev/null || true
  fi
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
  rm -f "$AU_SVC" "$AU_TIMER" "$TPL"
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
EOC
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
    echo "   0) Exit"
    echo -e "  ${C_D}(the core in this folder is applied automatically on start)${C_N}"
    echo
    case "$(ask 'Choice' '')" in
      1) create_tunnel server; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      2) create_tunnel client; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      3) manage_tunnels ;;
      4) doctor; read -t 30 -rp "  ▶ press ENTER to continue... " _ ;;
      0) exit 0 ;;
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
  ""|menu) main_menu ;;
  *) echo "usage: sudo bash $SELF [server|client|manage|transports|tune|restart-all|start-all|stop-all|doctor|uninstall|version]"; exit 1 ;;
esac
