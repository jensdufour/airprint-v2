#!/usr/bin/env bash
# uninstall.sh — remove airprint-v2 configuration from the container.
# Does NOT remove apt packages by default (use --purge to also remove them).
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

require_root

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

# Restore configs we touched (best-effort).
restore_orig() {
  local f="$1"
  if [[ -f "${f}.airprint-orig" ]]; then
    log "restoring ${f}"
    mv -f "${f}.airprint-orig" "$f"
  fi
}

log "removing airprint-v2 cron"
rm -f /etc/cron.d/airprint-healthcheck /usr/local/sbin/airprint-healthcheck

log "removing CUPS queue (if present)"
if command -v lpadmin >/dev/null 2>&1; then
  lpadmin -x "${AIRPRINT_QUEUE_NAME:-Canon_iR1133A}" 2>/dev/null || true
fi

log "restoring touched config files"
restore_orig /etc/avahi/avahi-daemon.conf
restore_orig /etc/cups/cupsd.conf
restore_orig /etc/cups/snmp.conf
restore_orig /etc/samba/smb.conf
restore_orig /etc/nsswitch.conf

log "removing Samba scan share data dir (kept by default)"
warn "leaving /srv/scans in place — remove manually if desired"

log "disabling firewall"
ufw --force reset >/dev/null 2>&1 || true
ufw disable      >/dev/null 2>&1 || true

systemctl restart avahi-daemon cups smbd nmbd 2>/dev/null || true

if [[ "$PURGE" -eq 1 ]]; then
  log "purging packages installed by airprint-v2"
  DEBIAN_FRONTEND=noninteractive apt-get -y purge \
    cups cups-filters cups-pdf \
    avahi-daemon avahi-utils libnss-mdns \
    sane sane-utils sane-airscan \
    samba samba-common-bin \
    printer-driver-postscript-hp printer-driver-all \
    foomatic-db foomatic-db-engine || true
  apt-get -y autoremove --purge || true
fi

ok "uninstall complete"
