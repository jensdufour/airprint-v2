#!/usr/bin/env bash
# scripts/diag.sh — print everything you need to triage a printing problem.
# Designed to be copy-pasteable into a bug report / chat with the maintainer.
#
# Usage (inside the LXC):
#   /opt/airprint-v2/scripts/diag.sh
# shellcheck shell=bash
set -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

QUEUE="${AIRPRINT_QUEUE_NAME:-Canon_iR1133A}"
if [[ -f /etc/cron.d/airprint-healthcheck ]]; then
  q="$(awk -F'=' '/^AIRPRINT_QUEUE_NAME=/ {print $2; exit}' /etc/cron.d/airprint-healthcheck || true)"
  [[ -n "$q" ]] && QUEUE="$q"
fi

section() { printf '\n%s### %s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

section "Host"
hostname -f 2>/dev/null || hostname
ip -4 -o addr show | awk '{print $2, $4}'

section "Services"
for s in cups avahi-daemon smbd nmbd cron ufw; do
  state="$(systemctl is-active "$s" 2>/dev/null || true)"
  printf '  %-15s %s\n' "$s" "$state"
done

section "CUPS listeners"
ss -ltnp 2>/dev/null | grep -E ':631\s' || echo "  (nothing listening on 631)"

section "ufw status"
ufw status verbose 2>/dev/null | sed 's/^/  /' || echo "  ufw not installed"

section "Queues"
lpstat -t 2>&1 | sed 's/^/  /' || true

section "Default queue + URI"
lpstat -v 2>&1 | sed 's/^/  /'
lpoptions -p "$QUEUE" 2>&1 | sed 's/^/  /' || true

section "Local IPP probe (curl -v http://localhost:631/)"
curl --max-time 5 -sSv http://localhost:631/ 2>&1 | head -n 25 | sed 's/^/  /'

section "Local IPP attribute query (Get-Printer-Attributes)"
if command -v ipptool >/dev/null 2>&1; then
  ipptool -tv "ipp://localhost:631/printers/${QUEUE}" \
    /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 | head -n 40 | sed 's/^/  /'
else
  echo "  ipptool not installed (apt install cups-ipp-utils)"
fi

section "Bonjour _ipp._tcp announcements"
if command -v avahi-browse >/dev/null 2>&1; then
  timeout 6 avahi-browse -rtp _ipp._tcp 2>/dev/null | sed 's/^/  /' \
    || echo "  (no announcements observed)"
else
  echo "  avahi-utils not installed"
fi

section "PPD attributes for queue '$QUEUE'"
PPD="/etc/cups/ppd/${QUEUE}.ppd"
if [[ -f "$PPD" ]]; then
  grep -E '^\*(NickName|cupsFilter|cupsURF|cupsIPPSupplies|cupsSNMPSupplies|FileVersion|cups[A-Z][A-Za-z]+):' "$PPD" \
    | sed 's/^/  /'
else
  echo "  PPD not found at $PPD"
fi

section "Recent CUPS errors (last 30 lines)"
journalctl -u cups --no-pager -n 30 2>&1 | sed 's/^/  /'

section "Printer reachability"
PRINTER_IP="$(grep -oE 'socket://[^:/]+' /etc/cups/printers.conf 2>/dev/null | head -n1 | sed 's|socket://||' || true)"
if [[ -n "$PRINTER_IP" ]]; then
  printf '  printer: %s\n' "$PRINTER_IP"
  if ping -c 1 -W 2 "$PRINTER_IP" >/dev/null 2>&1; then
    echo "  ping: OK"
  else
    echo "  ping: FAIL"
  fi
  if timeout 3 bash -c ">/dev/tcp/${PRINTER_IP}/9100" 2>/dev/null; then
    echo "  TCP/9100: OK"
  else
    echo "  TCP/9100: FAIL"
  fi
else
  echo "  could not determine printer IP from /etc/cups/printers.conf"
fi

section "Done"
echo "Paste the output above when reporting an issue."
