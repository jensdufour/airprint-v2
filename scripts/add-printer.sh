#!/usr/bin/env bash
# scripts/add-printer.sh — idempotent CUPS queue creator.
# Picks the best available PPD (UFR II → PostScript → generic) and ensures
# the queue is shared with the right Bonjour/AirPrint TXT records.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root
need_cmd lpadmin
need_cmd lpstat

: "${AIRPRINT_PRINTER_IP:?AIRPRINT_PRINTER_IP must be set}"
: "${AIRPRINT_PRINTER_MODEL:=Canon iR1133A}"
: "${AIRPRINT_QUEUE_NAME:=Canon_iR1133A}"

# Validate queue name (CUPS rules: no spaces, /, #, or @).
if [[ ! "$AIRPRINT_QUEUE_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  die "queue name '$AIRPRINT_QUEUE_NAME' has illegal characters (use [A-Za-z0-9_-])"
fi

# Connection URI — socket://host:9100 is more reliable than LPR on Canon firmware.
URI="socket://${AIRPRINT_PRINTER_IP}:9100"

# Pick the best PPD we can find.
pick_ppd() {
  # 1. UFR II driver paths laid down by canon-ufr2-install.sh. The PPD
  #    filename varies by tarball locale (CNCUPSIR1133ZK.ppd is common, but
  #    m17n bundles ship CNCUPSIR1133*US.ppd, etc.) — glob to be tolerant.
  local ppd_dirs=(
    # uken / pre-v6.x layout
    /opt/cel/ppd
    /opt/cel/share/ppd
    # m17n v6.x layout — packages install under /opt/cnrdrvcups-*
    /opt/cnrdrvcups-ufr2/data/ppd
    /opt/cnrdrvcups-ufr2/share/ppd
    /opt/cnrdrvcups-ufr2-uk/data/ppd
    /opt/cnrdrvcups-ufr2-us/data/ppd
    # symlinks our installer drops here, plus distro defaults
    /usr/share/ppd/canon
    /usr/share/ppd/Canon
    /usr/share/cups/model
  )
  for d in "${ppd_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    # shellcheck disable=SC2231
    for c in "$d"/CNCUPSIR1133*.ppd; do
      [[ -r "$c" ]] && { printf 'file://%s' "$c"; return; }
    done
  done

  # 2. Try foomatic / cups-driverd to find a Canon iR PPD.
  local match
  match="$(lpinfo -m 2>/dev/null | awk '/[Cc]anon.*iR.*1133/ {print $1; exit}')" || true
  if [[ -n "${match:-}" ]]; then
    printf '%s' "$match"
    return
  fi

  # 3. Generic PostScript fallback.
  match="$(lpinfo -m 2>/dev/null | awk '/[Pp]ost[Ss]cript.*generic/ {print $1; exit}')" || true
  if [[ -n "${match:-}" ]]; then
    warn "no Canon-specific PPD found — using generic PostScript"
    printf '%s' "$match"
    return
  fi

  warn "no PPD found at all — using CUPS sample driverless"
  printf 'drv:///sample.drv/generic.ppd'
}

PPD_REF="$(pick_ppd)"
log "queue=$AIRPRINT_QUEUE_NAME uri=$URI ppd=$PPD_REF"

# Remove existing queue with the same name to keep this idempotent.
if lpstat -p "$AIRPRINT_QUEUE_NAME" >/dev/null 2>&1; then
  log "removing existing queue '$AIRPRINT_QUEUE_NAME' (will recreate)"
  lpadmin -x "$AIRPRINT_QUEUE_NAME"
fi

# Add the queue.
case "$PPD_REF" in
  file://*) lpadmin -p "$AIRPRINT_QUEUE_NAME" -E -v "$URI" -P "${PPD_REF#file://}" \
              -L "$AIRPRINT_PRINTER_MODEL" -D "$AIRPRINT_PRINTER_MODEL (airprint-v2)" -o printer-is-shared=true ;;
  drv://*|*) lpadmin -p "$AIRPRINT_QUEUE_NAME" -E -v "$URI" -m "$PPD_REF" \
              -L "$AIRPRINT_PRINTER_MODEL" -D "$AIRPRINT_PRINTER_MODEL (airprint-v2)" -o printer-is-shared=true ;;
esac

# Make it the default and accept jobs.
cupsenable "$AIRPRINT_QUEUE_NAME"
cupsaccept "$AIRPRINT_QUEUE_NAME"
lpadmin -d "$AIRPRINT_QUEUE_NAME"

# Patch the generated PPD with SNMP / IPP-supplies hints — but ONLY if missing
# and ONLY for inert, well-supported attributes. We deliberately do NOT touch
# *cupsURF here unless explicitly asked: declaring URF capabilities the filter
# chain can't actually produce makes iOS silently refuse to select the
# printer (taps don't apply). Set AIRPRINT_PATCH_URF=1 to opt in.
PPD_FILE="/etc/cups/ppd/${AIRPRINT_QUEUE_NAME}.ppd"
if [[ -f "$PPD_FILE" ]]; then
  declare -A want=(
    [cupsIPPSupplies]='*cupsIPPSupplies: True'
    [cupsSNMPSupplies]='*cupsSNMPSupplies: True'
  )
  if [[ "${AIRPRINT_PATCH_URF:-0}" == "1" ]]; then
    # Conservative, broadly-producible URF baseline; only touch this if the
    # default driverless detection doesn't already publish a URF= TXT record.
    want[cupsURF]='*cupsURF: "V1.4,DM1,RS300"'
  fi
  patched=0
  for key in "${!want[@]}"; do
    if ! grep -qE "^\*${key}:" "$PPD_FILE"; then
      printf '%s\n' "${want[$key]}" >> "$PPD_FILE"
      patched=$((patched+1))
    fi
  done
  if (( patched > 0 )); then
    log "patched $patched supplies-related attribute(s) into PPD"
  fi
fi

# Restart CUPS so the new TXT records are advertised.
systemctl reload-or-restart cups
sleep 2

# Verify.
if lpstat -p "$AIRPRINT_QUEUE_NAME" 2>/dev/null | grep -qi 'enabled'; then
  ok "queue '$AIRPRINT_QUEUE_NAME' is enabled and accepting jobs"
else
  err "queue did not come up cleanly"
  lpstat -t || true
  exit 1
fi

# Ping the printer (informational only).
if command -v ping >/dev/null && ping -c 1 -W 2 "$AIRPRINT_PRINTER_IP" >/dev/null 2>&1; then
  ok "printer is reachable at $AIRPRINT_PRINTER_IP"
else
  warn "could not ping $AIRPRINT_PRINTER_IP — jobs may queue but not print"
fi

ip4="$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 || true)"
log "test from a Mac:    lp -h ${ip4:-<host>}:631 -d $AIRPRINT_QUEUE_NAME some.pdf"
log "test from iOS:      Print → printer should appear as '$AIRPRINT_QUEUE_NAME'"
log "test from Windows:  Settings → Printers → Add printer (IPP/Bonjour discovery)"
