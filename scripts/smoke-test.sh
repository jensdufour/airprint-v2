#!/usr/bin/env bash
# scripts/smoke-test.sh — end-to-end verification of an airprint-v2 install.
#
# Run inside the LXC after install.sh has finished:
#   /opt/airprint-v2/scripts/smoke-test.sh
#
# Verifies, in order:
#   1. CUPS / Avahi / Samba services are up.
#   2. The configured queue exists and is enabled.
#   3. The IPP endpoint answers Get-Printer-Attributes.
#   4. Bonjour TXT records are valid for AirPrint (pdl, URF, rp, kind).
#   5. The Samba scan share is reachable.
#   6. The printer responds on TCP/9100 (or 631).
#   7. The PPD declares the AirPrint hints we patched in.
#
# Exits 0 on full success, 1 on any failure. Prints a one-line summary.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

: "${AIRPRINT_QUEUE_NAME:=Canon_iR1133A}"
: "${AIRPRINT_PRINTER_IP:=}"
: "${AIRPRINT_SCAN_SHARE:=scans}"

# Allow the queue name + printer IP to be looked up from the cron file
# (install.sh writes them there) so the user can run this with no env.
if [[ -f /etc/cron.d/airprint-healthcheck ]]; then
  q="$(awk -F'=' '/^AIRPRINT_QUEUE_NAME=/ {print $2; exit}' /etc/cron.d/airprint-healthcheck || true)"
  [[ -n "$q" ]] && AIRPRINT_QUEUE_NAME="$q"
fi
if [[ -z "$AIRPRINT_PRINTER_IP" && -f /etc/cups/printers.conf ]]; then
  AIRPRINT_PRINTER_IP="$(grep -oE 'socket://[^:]+' /etc/cups/printers.conf | head -n1 | sed 's|socket://||' || true)"
fi

PASS=()
FAIL=()
record_pass() { PASS+=("$1"); ok "$1"; }
record_fail() { FAIL+=("$1"); err "$1"; }

# ---------------------------------------------------------------------- 1.
log "[1/7] services up"
for svc in cups avahi-daemon smbd; do
  if systemctl is-active --quiet "$svc"; then
    record_pass "service $svc is active"
  else
    record_fail "service $svc is NOT active"
  fi
done

# ---------------------------------------------------------------------- 2.
log "[2/7] CUPS queue '$AIRPRINT_QUEUE_NAME' exists and is enabled"
if lpstat -p "$AIRPRINT_QUEUE_NAME" 2>/dev/null | grep -qi 'enabled'; then
  record_pass "queue '$AIRPRINT_QUEUE_NAME' enabled"
else
  record_fail "queue '$AIRPRINT_QUEUE_NAME' missing or disabled"
fi

# ---------------------------------------------------------------------- 3.
log "[3/7] IPP endpoint answers Get-Printer-Attributes"
if ipptool_out="$(ipptool -tv "ipp://localhost:631/printers/$AIRPRINT_QUEUE_NAME" \
        /usr/share/cups/ipptool/get-printer-attributes.test 2>&1)"; then
  if grep -q 'successful-ok' <<<"$ipptool_out"; then
    record_pass "IPP Get-Printer-Attributes → successful-ok"
  else
    record_fail "IPP responded but not with successful-ok (see /tmp/ipptool.out)"
    printf '%s' "$ipptool_out" >/tmp/ipptool.out
  fi
else
  record_fail "ipptool failed to query the queue"
fi

# ---------------------------------------------------------------------- 4.
log "[4/7] Bonjour TXT records valid for AirPrint"
if ! command -v avahi-browse >/dev/null 2>&1; then
  record_fail "avahi-browse not installed (apt install avahi-utils)"
else
  txt="$(timeout 6 avahi-browse -rtp _ipp._tcp 2>/dev/null \
          | awk -F';' -v q="$AIRPRINT_QUEUE_NAME" '$4==q {print $0; exit}')"
  if [[ -z "$txt" ]]; then
    record_fail "no _ipp._tcp record for '$AIRPRINT_QUEUE_NAME' on the local Avahi"
  else
    # Required-for-AirPrint TXT keys.
    for key in 'rp=printers/' 'pdl=' 'kind='; do
      if grep -q "$key" <<<"$txt"; then
        record_pass "TXT contains '$key…'"
      else
        record_fail "TXT missing '$key'"
      fi
    done
    # URF is nice-to-have; not required when pdl includes application/pdf.
    if grep -q 'URF=' <<<"$txt"; then
      record_pass "TXT contains 'URF=…' (full AirPrint)"
    else
      log "  TXT has no URF= — fine when pdl advertises application/pdf"
    fi
  fi
fi

# ---------------------------------------------------------------------- 5.
log "[5/7] Samba scan share reachable"
if smbclient -L //127.0.0.1 -N 2>/dev/null | grep -qE "^\s+${AIRPRINT_SCAN_SHARE}\s"; then
  record_pass "SMB share '\\\\127.0.0.1\\${AIRPRINT_SCAN_SHARE}' visible"
else
  record_fail "SMB share '\\\\127.0.0.1\\${AIRPRINT_SCAN_SHARE}' not visible"
fi

# ---------------------------------------------------------------------- 6.
log "[6/7] printer reachable"
if [[ -z "$AIRPRINT_PRINTER_IP" ]]; then
  record_fail "could not determine printer IP — set AIRPRINT_PRINTER_IP"
else
  if ping -c 1 -W 2 "$AIRPRINT_PRINTER_IP" >/dev/null 2>&1; then
    record_pass "printer answers ping at $AIRPRINT_PRINTER_IP"
  else
    record_fail "printer does NOT answer ping at $AIRPRINT_PRINTER_IP"
  fi
  # TCP/9100 (raw print port) — the most common path on Canon iR series.
  if timeout 3 bash -c ">/dev/tcp/$AIRPRINT_PRINTER_IP/9100" 2>/dev/null; then
    record_pass "printer accepts TCP/9100"
  else
    record_fail "printer not listening on TCP/9100 (jobs may not print)"
  fi
fi

# ---------------------------------------------------------------------- 7.
log "[7/7] PPD declares supplies hints"
PPD="/etc/cups/ppd/${AIRPRINT_QUEUE_NAME}.ppd"
if [[ -f "$PPD" ]]; then
  for key in cupsIPPSupplies cupsSNMPSupplies; do
    if grep -qE "^\*${key}:" "$PPD"; then
      record_pass "PPD declares *${key}"
    else
      record_fail "PPD missing *${key} (toner/page status may not surface on iOS)"
    fi
  done
  if grep -qE '^\*cupsURF:' "$PPD"; then
    record_pass "PPD declares *cupsURF (URF advertised over Bonjour)"
  else
    log "  PPD has no *cupsURF — that's fine, CUPS driverless detection handles it"
  fi
else
  record_fail "PPD '$PPD' not found"
fi

# ---------------------------------------------------------------------- summary
printf '\n%s== smoke-test summary ==%s\n' "$C_BOLD" "$C_RESET"
printf '  passed: %d\n' "${#PASS[@]}"
printf '  failed: %d\n' "${#FAIL[@]}"
if (( ${#FAIL[@]} > 0 )); then
  printf '\n%sFailures:%s\n' "$C_RED" "$C_RESET"
  printf '  - %s\n' "${FAIL[@]}"
  exit 1
fi
ok "all checks passed"
