#!/usr/bin/env bash
# scripts/canon-ufr2-install.sh — Canon UFR II Linux driver helper.
#
# Canon ships UFR II for Linux as a tarball that requires accepting their
# EULA. We can't redistribute it. This script handles three sources, in
# priority order:
#   1. A tarball already present at /opt/airprint-v2/drivers/canon-ufr2.tar.gz
#   2. A URL provided via the CANON_UFR2_URL env var.
#   3. None — exit 0 with a warning so install.sh can fall back to a
#      generic PostScript / driverless PPD.
#
# The tarball layout has changed over the years; the script tries the two
# common patterns:
#   * `linux-UFRII-drv-vXXX-uken-*/` containing a `Debian/` folder of .debs.
#   * A flat directory with `cndrvcups-common_*.deb` + `cndrvcups-ufr2-*.deb`.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root

DRIVERS_DIR="$ROOT/drivers"
LOCAL_TARBALL="$DRIVERS_DIR/canon-ufr2.tar.gz"
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Already installed?
if dpkg -l 2>/dev/null | grep -qE '^ii\s+cndrvcups-(common|ufr2)'; then
  ok "Canon UFR II driver already installed — skipping"
  exit 0
fi

# Resolve a tarball path.
TARBALL=""
if [[ -f "$LOCAL_TARBALL" ]]; then
  TARBALL="$LOCAL_TARBALL"
  log "using local Canon driver tarball: $TARBALL"
elif [[ -n "${CANON_UFR2_URL:-}" ]]; then
  log "downloading Canon driver from CANON_UFR2_URL"
  TARBALL="$WORKDIR/canon-ufr2.tar.gz"
  curl -fsSL --retry 3 "$CANON_UFR2_URL" -o "$TARBALL" \
    || { warn "download failed — skipping Canon driver"; exit 0; }
else
  warn "no Canon UFR II driver source provided"
  warn "  -> place the tarball at: $LOCAL_TARBALL"
  warn "  -> or set CANON_UFR2_URL=<url> before re-running"
  warn "falling back to generic PostScript / driverless PPD (basic printing only)"
  exit 0
fi

log "extracting Canon driver tarball"
tar -xf "$TARBALL" -C "$WORKDIR"

# Find a Debian package directory inside the tree.
# `-print -quit` stops `find` after the first match without SIGPIPE.
DEB_DIR="$(find "$WORKDIR" -type d -iname 'Debian' -print -quit)"
if [[ -z "$DEB_DIR" ]]; then
  DEB_DIR="$(find "$WORKDIR" -type d \( -iname '*deb*' -o -iname 'amd64' \) -print -quit)"
fi
if [[ -z "$DEB_DIR" ]]; then
  # Maybe the .debs are scattered.
  DEB_DIR="$WORKDIR"
fi

mapfile -t DEBS < <(find "$DEB_DIR" -maxdepth 3 -type f -name '*.deb' \
                    -regex '.*\(cndrvcups-common\|cndrvcups-ufr2\).*' | sort)
if (( ${#DEBS[@]} == 0 )); then
  warn "no cndrvcups-* .deb packages found inside the tarball"
  warn "tarball contents (top 50 entries):"
  # Diagnostic only — `|| true` keeps SIGPIPE from killing the script.
  { find "$WORKDIR" -maxdepth 4 | awk 'NR<=50 {print "    " $0}'; } || true
  warn "falling back to generic PPD"
  exit 0
fi

log "installing ${#DEBS[@]} Canon .deb package(s):"
printf '    %s\n' "${DEBS[@]}"

# Make sure 32-bit support is available for older Canon binaries (some need libc6:i386).
dpkg --add-architecture i386 >/dev/null 2>&1 || true
apt-get update -qq
apt-get install -y -qq --no-install-recommends libc6:i386 libstdc++6:i386 || true

# Install with apt (handles deps); fall back to dpkg + apt --fix-broken.
if ! apt-get install -y --no-install-recommends "${DEBS[@]}" 2>/dev/null; then
  log "apt could not install directly — using dpkg + apt --fix-broken"
  dpkg -i "${DEBS[@]}" || true
  apt-get install -y --fix-broken
fi

# The Canon installer drops PPDs under /opt/cel/share/ppd/ on some versions;
# symlink them into /usr/share/ppd/canon/ so lpinfo -m can see them.
mkdir -p /usr/share/ppd/canon
for src in /opt/cel/share/ppd /opt/cel/ppd /usr/share/cups/model; do
  [[ -d "$src" ]] || continue
  for ppd in "$src"/CNCUPSIR1133*.ppd; do
    [[ -f "$ppd" ]] || continue
    ln -sf "$ppd" "/usr/share/ppd/canon/$(basename "$ppd")"
  done
done

# Make sure ccpd / cnsetuputil2 helper services don't run — we only need the
# CUPS filter components for network printing.
systemctl disable --now ccpd 2>/dev/null || true

ok "Canon UFR II driver installed"
