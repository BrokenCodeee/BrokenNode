#!/usr/bin/env bash
# ============================================================================
#  BrokenNode installer
#
#  Downloads the compiled tunnel for THIS machine's CPU into a ./BrokenNode
#  folder and opens the manager. No Go toolchain, no compiler, no source.
#
#      bash <(curl -fsSL https://raw.githubusercontent.com/BrokenCodeee/BrokenNode/main/install.sh)
#
#  Works on every Linux distribution — Debian, Ubuntu, Alpine, CentOS, Rocky,
#  Arch — because the binaries are statically linked and depend on no libc.
# ============================================================================
set -euo pipefail

REPO="BrokenCodeee/BrokenNode"
BRANCH="main"
BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
DIR="${BROKENNODE_DIR:-BrokenNode}"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_M='\033[0;35m'; C_D='\033[0;90m'; C_N='\033[0m'
info(){ echo -e "${C_G}  [+]${C_N} $*"; }
warn(){ echo -e "${C_Y}  [!]${C_N} $*"; }
die(){  echo -e "${C_R}  [x]${C_N} $*" >&2; exit 1; }

echo -e "${C_M}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║           B R O K E N   N O D E              ║"
echo "  ║              installer                       ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${C_N}"

# --- which CPU are we on -----------------------------------------------------
# `uname -m` is reported identically by every Linux distribution, so this needs
# no distro detection at all.
case "$(uname -m)" in
  x86_64|amd64)              ARCH=amd64   ;;
  aarch64|arm64)             ARCH=arm64   ;;
  armv8l|armv7l|armv7|armhf) ARCH=armv7   ;;
  armv6l|armv6|arm)          ARCH=armv6   ;;
  i386|i486|i586|i686|x86)   ARCH=386     ;;
  riscv64)                   ARCH=riscv64 ;;
  *) die "Unsupported CPU: $(uname -m). Builds exist for amd64, arm64, armv7, armv6, 386 and riscv64." ;;
esac
[ "$(uname -s)" = "Linux" ] || die "BrokenNode runs on Linux only (this is $(uname -s))."
info "CPU: $(uname -m) → brokennode-linux-${ARCH}"

# --- how do we fetch ---------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  fetch(){ curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch(){ wget -q --tries=3 -O "$2" "$1"; }
else
  die "Neither curl nor wget is installed. Install one:  apt install -y curl   |   yum install -y curl"
fi

# --- download ----------------------------------------------------------------
mkdir -p "$DIR/bin"
info "Downloading into ./$DIR"
fetch "$BASE/bin/brokennode-linux-${ARCH}" "$DIR/bin/brokennode-linux-${ARCH}" \
  || die "Download failed. Check the server's internet access, or grab the file manually from https://github.com/${REPO}"
fetch "$BASE/BrokenNode.sh" "$DIR/BrokenNode.sh" || die "Could not download BrokenNode.sh"
fetch "$BASE/SHA256SUMS"    "$DIR/SHA256SUMS"    || warn "Could not download SHA256SUMS — skipping verification"
fetch "$BASE/VERSION"       "$DIR/VERSION"       || true
fetch "$BASE/README.md"     "$DIR/README.md"     || true

# --- verify ------------------------------------------------------------------
# A truncated download produces a binary that fails in confusing ways much
# later, so it is worth catching here rather than mid-tunnel.
if [ -s "$DIR/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
  want="$(awk -v f="bin/brokennode-linux-${ARCH}" '$2 == f || $2 == "*"f {print $1}' "$DIR/SHA256SUMS" | head -1)"
  if [ -n "$want" ]; then
    got="$(sha256sum "$DIR/bin/brokennode-linux-${ARCH}" | awk '{print $1}')"
    [ "$want" = "$got" ] || die "Checksum mismatch — the download is corrupt or tampered with. Delete ./$DIR and retry."
    info "Checksum verified"
  fi
fi

chmod +x "$DIR/bin/brokennode-linux-${ARCH}" "$DIR/BrokenNode.sh"
info "Installed: $("$DIR/bin/brokennode-linux-${ARCH}" version 2>/dev/null || echo "brokennode ($ARCH)")"

# --- hand over to the manager ------------------------------------------------
cd "$DIR"
if [ "$(id -u)" -ne 0 ]; then
  warn "The manager needs root (it writes systemd units and tunes sockets)."
  echo -e "${C_D}    cd $DIR && sudo bash BrokenNode.sh${C_N}"
  exit 0
fi
if [ ! -t 0 ]; then
  # Piping the installer into bash leaves the menu with no keyboard.
  warn "No terminal attached — start the menu yourself:"
  echo -e "${C_D}    cd $DIR && bash BrokenNode.sh${C_N}"
  exit 0
fi
exec bash BrokenNode.sh
