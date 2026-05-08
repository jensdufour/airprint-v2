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
  local candidates=(
    # UFR II driver paths (set up by canon-ufr2-install.sh).
    /opt/cel/ppd/CNCUPSIR1133ZK.ppd
    /opt/cel/ppd/CNCUPSIR1133.ppd
    /usr/share/ppd/canon/CNCUPSIR1133ZK.ppd
    /usr/share/ppd/canon/CNCUPSIR1133.ppd
  )
  for c in "${candidates[@]}"; do
    [[ -r "$c" ]] && { printf 'file://%s' "$c"; return; }
  done

  # Try foomatic / cups-driverd to find a Canon iR PPD.
  local match
  match="$(lpinfo -m 2>/dev/null | awk '/[Cc]anon.*iR.*1133/ {print $1; exit}')" || true
  if [[ -n "${match:-}" ]]; then
    printf '%s' "$match"
    return
  fi

  # Generic PostScript fallback.
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

# Patch the generated PPD with AirPrint / IPP / SNMP hints — but ONLY if they
# are missing (modern Canon/HP PPDs already declare these). We deliberately
# DO NOT touch *cupsFilter2: a wrong value silently kills printing.
#
# What each line means:
#   *cupsURF       — declares URF (Apple Raster) support. Without this iOS
#                    sometimes greys out the Print button. The value below is
#                    the conservative monochrome-greyscale baseline that any
#                    laser printer can satisfy via cupsfilters' rasteriser.
#   *cupsIPPSupplies / *cupsSNMPSupplies — let CUPS poll toner level via SNMP
#                    and surface it on iOS / macOS print dialogs.
#   *cupsManualCopies — CUPS handles copies in software (Canon UFR II prefers).
#   *cupsFax       — explicitly off; no fax queue.
PPD_FILE="/etc/cups/ppd/${AIRPRINT_QUEUE_NAME}.ppd"
if [[ -f "$PPD_FILE" ]]; then
  declare -A want=(
    [cupsURF]='*cupsURF: "RS300,W8,SRGB24"'
    [cupsIPPSupplies]='*cupsIPPSupplies: True'
    [cupsSNMPSupplies]='*cupsSNMPSupplies: True'
    [cupsManualCopies]='*cupsManualCopies: True'
    [cupsFax]='*cupsFax: False'
  )
  patched=0
  for key in "${!want[@]}"; do
    if ! grep -qE "^\*${key}:" "$PPD_FILE"; then
      printf '%s\n' "${want[$key]}" >> "$PPD_FILE"
      patched=$((patched+1))
    fi
  done
  if (( patched > 0 )); then
    log "patched $patched AirPrint/SNMP attribute(s) into PPD"
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
