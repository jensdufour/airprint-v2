#!/usr/bin/env bash
# install.sh — runs INSIDE the Debian 12 LXC.
# Idempotent: safe to re-run on an existing container.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

require_root

# Inputs (passed in via env from the host bootstrap, or supplied manually).
: "${AIRPRINT_PRINTER_IP:?AIRPRINT_PRINTER_IP must be set}"
: "${AIRPRINT_PRINTER_MODEL:=Canon iR1133A}"
: "${AIRPRINT_QUEUE_NAME:=Canon_iR1133A}"
: "${AIRPRINT_SCAN_SHARE:=scans}"

export DEBIAN_FRONTEND=noninteractive

log "airprint-v2 installer starting (printer=$AIRPRINT_PRINTER_MODEL @ $AIRPRINT_PRINTER_IP, queue=$AIRPRINT_QUEUE_NAME)"

# Ensure helper scripts are executable (the working tree may have been shipped
# over from a Windows host without preserving the +x bit).
find "$ROOT" -type f -name '*.sh' -exec chmod +x {} +

# ---- 1. base packages ------------------------------------------------------
log "installing base packages (apt update + upgrade)"
apt-get update -qq
apt-get -y -qq upgrade

PKGS=(
  # core printing
  cups cups-filters cups-pdf cups-ipp-utils
  printer-driver-postscript-hp printer-driver-all
  ghostscript foomatic-db foomatic-db-engine
  # mDNS
  avahi-daemon avahi-utils libnss-mdns
  # scanning
  sane sane-utils sane-airscan
  # scan-to-folder fallback
  samba samba-common-bin smbclient
  # housekeeping
  cron logrotate ufw curl ca-certificates xz-utils tar jq
  # smoke test deps
  iputils-ping
)
log "installing: ${PKGS[*]}"
apt-get -y -qq install --no-install-recommends "${PKGS[@]}"
ok "base packages installed"

# ---- 2. avahi reflector ----------------------------------------------------
log "applying Avahi reflector config"
install -m 0644 "$ROOT/config/avahi-daemon.conf" /etc/avahi/avahi-daemon.conf
# Make sure mdns shows up in nsswitch (libnss-mdns).
if ! grep -qE '^hosts:.*mdns4' /etc/nsswitch.conf; then
  sed -ri 's/^(hosts:.*)$/\1 mdns4_minimal [NOTFOUND=return]/' /etc/nsswitch.conf
fi
systemctl enable --now avahi-daemon
systemctl restart avahi-daemon
ok "Avahi reflector active"

# ---- 3. cups ---------------------------------------------------------------
log "configuring CUPS (replacing /etc/cups/cupsd.conf with the airprint-v2 template)"
backup_once /etc/cups/cupsd.conf
install -m 0640 -o root -g lp "$ROOT/config/cupsd.conf" /etc/cups/cupsd.conf

log "enabling CUPS SNMP supplies / page-counter polling"
backup_once /etc/cups/snmp.conf
install -m 0640 -o root -g lp "$ROOT/config/snmp.conf" /etc/cups/snmp.conf

# Allow lpadmin without password for the local 'root' (in-container only).
usermod -aG lpadmin root 2>/dev/null || true

systemctl enable --now cups
systemctl restart cups
# Wait for socket.
for _ in $(seq 1 15); do
  lpstat -r >/dev/null 2>&1 && break
  sleep 1
done
ok "CUPS up"

# ---- 4. canon driver (best-effort) ----------------------------------------
log "attempting Canon UFR II driver install (best-effort)"
"$ROOT/scripts/canon-ufr2-install.sh" || warn "Canon driver step failed — falling back to generic PPD"

# ---- 5. add the printer queue ---------------------------------------------
log "adding printer queue"
"$ROOT/scripts/add-printer.sh"

# ---- 6. scanning -----------------------------------------------------------
log "configuring scanner (best-effort) + scan-to-folder fallback"
"$ROOT/scripts/add-scanner.sh"   || warn "scanner setup did not complete; SMB fallback will still work"
"$ROOT/scripts/add-scan-share.sh"

# ---- 7. firewall -----------------------------------------------------------
log "applying minimal ufw ruleset"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 631/tcp comment 'IPP / AirPrint'      >/dev/null
ufw allow 5353/udp comment 'mDNS / Bonjour'     >/dev/null
ufw allow 137,138/udp comment 'NetBIOS (Samba)' >/dev/null
ufw allow 139,445/tcp comment 'SMB (scan share)' >/dev/null
ufw allow 22/tcp comment 'ssh'                  >/dev/null
ufw --force enable >/dev/null
ok "ufw active"

# ---- 8. healthcheck cron ---------------------------------------------------
log "installing healthcheck cron"
install -m 0755 "$ROOT/scripts/healthcheck.sh" /usr/local/sbin/airprint-healthcheck
cat >/etc/cron.d/airprint-healthcheck <<EOF
# airprint-v2 — periodic health check (logs to syslog).
AIRPRINT_QUEUE_NAME=${AIRPRINT_QUEUE_NAME}
*/5 * * * * root /usr/local/sbin/airprint-healthcheck >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/airprint-healthcheck
ok "healthcheck installed"

# ---- 9. summary ------------------------------------------------------------
ip4="$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 || true)"
printf '\n%s== airprint-v2 inside-container install complete ==%s\n' "$C_BOLD" "$C_RESET"
printf '  hostname  : %s\n'   "$(hostname)"
printf '  ip        : %s\n'   "${ip4:-<unknown>}"
printf '  queue     : %s\n'   "$AIRPRINT_QUEUE_NAME"
printf '  IPP URL   : ipp://%s:631/printers/%s\n' "${ip4:-<host>}" "$AIRPRINT_QUEUE_NAME"
printf '  CUPS web  : https://%s:631/\n' "${ip4:-<host>}"
printf '  scan SMB  : \\\\%s\\%s\n' "${ip4:-<host>}" "$AIRPRINT_SCAN_SHARE"
printf '\nUse the helper scripts under /opt/airprint-v2/scripts/ to re-run any step.\n'
