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
# Where to install. Run from INSIDE an existing BrokenNode folder, update that
# folder in place: creating ./BrokenNode there left a nested second copy, and
# the old folder — the one opened with "cd BrokenNode && bash BrokenNode.sh" —
# kept its old core and menu.
if [ -z "${BROKENNODE_DIR:-}" ] && [ -f ./BrokenNode.sh ] && [ -d ./bin ]; then
  DIR="."
else
  DIR="${BROKENNODE_DIR:-BrokenNode}"
fi

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
# Everything lands in a temporary folder first and replaces the old files only
# once it is complete and verified: when this updates a folder in place, a
# download that breaks halfway must leave the working copy as it was.
mkdir -p "$DIR/bin"
if [ "$DIR" = . ]; then info "Updating this folder ($(pwd))"; else info "Downloading into ./$DIR"; fi
TMP="$(mktemp -d "$DIR/.download.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# checksum_ok FILE PATH-IN-SUMS — FILE matches its line in SHA256SUMS (true
# when the list has no line for it).
checksum_ok(){
  local want got
  want="$(awk -v f="$2" '$2 == f || $2 == "*"f {print $1}' "$TMP/SHA256SUMS" | head -1)"
  [ -z "$want" ] && return 0
  got="$(sha256sum "$1" | awk '{print $1}')"
  [ "$want" = "$got" ]
}

# GitHub serves these files through a CDN that caches each one for up to five
# minutes, separately. Right after a release, one edge can hand out the new
# SHA256SUMS with the old binary (or the reverse) — a checksum mismatch that
# is nobody's fault. So every attempt asks for fresh copies (a unique query
# string is a different cache key), and a mismatch is retried a few times
# before it is treated as real.
verified=0
for attempt in 1 2 3 4; do
  q="?nocache=$(date +%s)$RANDOM"
  fetch "$BASE/bin/brokennode-linux-${ARCH}$q" "$TMP/brokennode-linux-${ARCH}" \
    || die "Download failed. Check the server's internet access, or grab the file manually from https://github.com/${REPO}"
  fetch "$BASE/BrokenNode.sh$q" "$TMP/BrokenNode.sh" || die "Could not download BrokenNode.sh"
  if ! fetch "$BASE/SHA256SUMS$q" "$TMP/SHA256SUMS" || ! command -v sha256sum >/dev/null 2>&1; then
    warn "Could not verify the download (no SHA256SUMS or sha256sum) — continuing unverified"
    verified=1; break
  fi
  # A truncated or mixed download produces a binary that fails in confusing
  # ways much later, so it is worth catching here rather than mid-tunnel.
  if checksum_ok "$TMP/brokennode-linux-${ARCH}" "bin/brokennode-linux-${ARCH}" &&
     checksum_ok "$TMP/BrokenNode.sh" "BrokenNode.sh"; then
    info "Checksum verified"; verified=1; break
  fi
  [ "$attempt" = 4 ] && break
  warn "Checksum mismatch — GitHub's cache may still be serving the previous release. Retrying in $((attempt * 10))s..."
  sleep $((attempt * 10))
done
[ "$verified" = 1 ] || die "Checksum mismatch — the download is corrupt or tampered with. Nothing was changed; retry in a few minutes."
fetch "$BASE/VERSION$q"   "$TMP/VERSION"   || true
fetch "$BASE/README.md$q" "$TMP/README.md" || true

# --- put in place ------------------------------------------------------------
chmod +x "$TMP/brokennode-linux-${ARCH}" "$TMP/BrokenNode.sh"
mv -f "$TMP/brokennode-linux-${ARCH}" "$DIR/bin/brokennode-linux-${ARCH}"
for f in BrokenNode.sh SHA256SUMS VERSION README.md; do
  if [ -s "$TMP/$f" ]; then mv -f "$TMP/$f" "$DIR/$f"; fi
done
rm -rf "$TMP"; trap - EXIT   # exec below would skip the trap
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
