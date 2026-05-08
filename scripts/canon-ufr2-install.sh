#!/usr/bin/env bash
# scripts/canon-ufr2-install.sh — Canon UFR II Linux driver helper.
#
# Canon ships UFR II for Linux as a tarball that requires accepting their
# EULA. We can't redistribute it, but Canon's downloads are open URLs, so
# this script defaults to fetching the v6.30 m17n release directly. Sources,
# in priority order:
#   1. A tarball already present at /opt/airprint-v2/drivers/canon-ufr2.tar.gz
#      (drop one in there if you want to pin a specific version offline).
#   2. The URL in CANON_UFR2_URL — defaults to Canon's v6.30 m17n release.
#   3. Nothing fetched / nothing installable — exit 0 with a warning so
#      install.sh can fall back to generic driverless PPDs.
#
# Tarball layouts handled:
#   * m17n (v6.x): `linux-UFRII-drv-vXXX-m17n-NN/{32,64}-bit_Driver/Debian/*.deb`
#   * uken (v5.x and earlier): `linux-UFRII-drv-vXXX-uken-NN/Debian/*.deb`
#   * Anything else with cndrvcups-{common,ufr2}*.deb files anywhere inside.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root

# Canon's v6.30 m17n release — the latest Linux UFR II that supports the
# imageRUNNER 1133/1133A. Override CANON_UFR2_URL to pin a different version.
: "${CANON_UFR2_URL:=https://gdlp01.c-wss.com/gds/8/0100007658/48/linux-UFRII-drv-v630-m17n-07.tar.gz}"

DRIVERS_DIR="$ROOT/drivers"
LOCAL_TARBALL="$DRIVERS_DIR/canon-ufr2.tar.gz"
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Already installed? Match both legacy `cndrvcups-*` (uken) and current
# `cnrdrvcups-*` (m17n v6.x) package families.
if dpkg -l 2>/dev/null | grep -qE '^ii\s+cn[r]?drvcups-(common|ufr2)'; then
  ok "Canon UFR II driver already installed — skipping"
  exit 0
fi

# Resolve a tarball path.
TARBALL=""
if [[ -f "$LOCAL_TARBALL" ]]; then
  TARBALL="$LOCAL_TARBALL"
  log "using local Canon driver tarball: $TARBALL"
elif [[ -n "${CANON_UFR2_URL:-}" ]]; then
  log "downloading Canon driver from $CANON_UFR2_URL"
  TARBALL="$WORKDIR/canon-ufr2.tar.gz"
  if ! curl -fsSL --retry 3 "$CANON_UFR2_URL" -o "$TARBALL"; then
    warn "download failed — skipping Canon driver"
    warn "  set CANON_UFR2_URL=<url> or drop a tarball at $LOCAL_TARBALL"
    exit 0
  fi
  if [[ ! -s "$TARBALL" ]]; then
    warn "downloaded tarball is empty — skipping Canon driver"
    exit 0
  fi
else
  warn "no Canon UFR II driver source provided"
  warn "  -> place the tarball at: $LOCAL_TARBALL"
  warn "  -> or set CANON_UFR2_URL=<url> before re-running"
  warn "falling back to generic PostScript / driverless PPD (basic printing only)"
  exit 0
fi

log "extracting Canon driver tarball"
tar -xf "$TARBALL" -C "$WORKDIR"

# Find amd64 cndrvcups-{common,ufr2} / cnrdrvcups-{common,ufr2,*} .debs.
# Canon's tarballs evolved over the years:
#   * uken / pre-v6.x: package names are `cndrvcups-common`, `cndrvcups-ufr2`
#   * m17n v6.x:        package names are `cnrdrvcups-ufr2-<locale>` (and an
#                       optional `cnrdrvcups-common`); arch dirs are
#                       x86, x64, ARM, ARM64.
# We only want amd64. Filenames end in `_amd64.deb` for m17n, but legacy
# uken tarballs sometimes don't tag arch in the filename — hence the fallback.
mapfile -t DEBS < <(find "$WORKDIR" -type f \
  \( -name 'cndrvcups-common*amd64.deb' \
     -o -name 'cndrvcups-ufr2*amd64.deb' \
     -o -name 'cnrdrvcups-common*amd64.deb' \
     -o -name 'cnrdrvcups-ufr2*amd64.deb' \) | sort)

# Fallback: legacy single-arch tarballs that don't tag the deb filename.
if (( ${#DEBS[@]} == 0 )); then
  mapfile -t DEBS < <(find "$WORKDIR" -type f \
    \( -name 'cndrvcups-common*.deb' \
       -o -name 'cndrvcups-ufr2*.deb' \
       -o -name 'cnrdrvcups-common*.deb' \
       -o -name 'cnrdrvcups-ufr2*.deb' \) \
    ! -name '*i386*' ! -name '*armhf*' ! -name '*arm64*' ! -name '*aarch64*' \
    | sort)
fi

if (( ${#DEBS[@]} == 0 )); then
  warn "no Canon driver .deb packages (cndrvcups-* / cnrdrvcups-*) found in the tarball"
  warn "tarball .deb / .rpm entries:"
  # Diagnostic only — list every package so we can see if the tarball is
  # source-only / arm64-only / etc. `|| true` keeps SIGPIPE from killing
  # the script.
  { find "$WORKDIR" -type f \( -name '*.deb' -o -name '*.rpm' -o -name '*.tar.xz' \) \
      | sed 's|^|    |'; } || true
  warn "falling back to generic PPD"
  exit 0
fi

# Some m17n tarballs only ship one locale-specific package (e.g.
# cnrdrvcups-ufr2-uk_*.deb). De-duplicate so we don't try to install both
# cnrdrvcups-ufr2-uk and cnrdrvcups-ufr2-us — they conflict on file paths.
# Prefer the 'uk' (UK English) variant when multiple locales are present;
# fall back to whichever sorts first.
filter_locales() {
  local -a out=()
  local d basename
  local -A seen=()
  for d in "${DEBS[@]}"; do
    basename="$(basename "$d")"
    case "$basename" in
      cnrdrvcups-ufr2-*)
        # Reduce all locale-specific ufr2 packages to a single key.
        if [[ -z "${seen[ufr2]:-}" ]]; then
          seen[ufr2]="$d"
        elif [[ "$basename" == cnrdrvcups-ufr2-uk_* ]]; then
          seen[ufr2]="$d"   # prefer UK English
        fi
        ;;
      *)
        out+=("$d")
        ;;
    esac
  done
  [[ -n "${seen[ufr2]:-}" ]] && out+=("${seen[ufr2]}")
  printf '%s\n' "${out[@]}"
}
mapfile -t DEBS < <(filter_locales)

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

# The Canon installer drops PPDs in different places depending on the
# version:
#   uken / pre-v6.x : /opt/cel/share/ppd/, /opt/cel/ppd/
#   m17n v6.x       : /opt/cnrdrvcups-ufr2/data/ppd/, /opt/cnrdrvcups-ufr2/share/ppd/
# Symlink anything matching the imageRUNNER 1133 family into
# /usr/share/ppd/canon/ so cups-driverd / lpinfo -m surfaces them.
mkdir -p /usr/share/ppd/canon
for src in \
    /opt/cel/share/ppd /opt/cel/ppd \
    /opt/cnrdrvcups-ufr2 /opt/cnrdrvcups-ufr2-uk /opt/cnrdrvcups-ufr2-us \
    /opt/cnrdrvcups-common \
    /usr/share/cups/model /usr/share/ppd; do
  [[ -d "$src" ]] || continue
  while IFS= read -r ppd; do
    [[ -f "$ppd" ]] || continue
    ln -sf "$ppd" "/usr/share/ppd/canon/$(basename "$ppd")"
  done < <(find "$src" -maxdepth 6 -type f -iname 'CNCUPSIR1133*.ppd' 2>/dev/null)
done

# Make sure ccpd / cnsetuputil2 helper services don't run — we only need the
# CUPS filter components for network printing.
systemctl disable --now ccpd 2>/dev/null || true

# Refresh CUPS so cups-driverd indexes the new Canon PPDs before add-printer.sh
# runs.
systemctl reload-or-restart cups 2>/dev/null || true
sleep 1

ok "Canon UFR II driver installed"
