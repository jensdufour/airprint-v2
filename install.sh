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
# Force a locale that's guaranteed to exist on a fresh Debian 12 LXC. The host
# `pct exec` inherits LANG=en_US.UTF-8 from the Proxmox shell, but the CT only
# has C.UTF-8 generated, so without this every apt step prints a wall of
# "locale: Cannot set LC_CTYPE to default locale" warnings.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LANGUAGE=

log "airprint-v2 installer starting (printer=$AIRPRINT_PRINTER_MODEL @ $AIRPRINT_PRINTER_IP, queue=$AIRPRINT_QUEUE_NAME)"

# Ensure helper scripts are executable (the working tree may have been shipped
# over from a Windows host without preserving the +x bit).
find "$ROOT" -type f -name '*.sh' -exec chmod +x {} +

# ---- 1. base packages ------------------------------------------------------
log "installing base packages (apt update + upgrade)"
apt-get update -qq
apt-get -y -qq upgrade

PKGS=(
  # core printing — cups-filters pulls ghostscript, qpdf, poppler, etc. transitively.
  cups cups-filters cups-ipp-utils
  # mDNS / Bonjour
  avahi-daemon avahi-utils libnss-mdns
  # scanning (sane-utils gives us scanimage; sane-airscan is the eSCL bridge)
  sane-utils sane-airscan
  # scan-to-folder fallback
  samba samba-common-bin smbclient
  # housekeeping
  cron curl ca-certificates
  # smoke test / diag deps
  iputils-ping iproute2
)
log "installing: ${PKGS[*]}"
apt-get -y -qq install --no-install-recommends "${PKGS[@]}"
ok "base packages installed"

# ---- 1b. trim legacy bloat from older installs -----------------------------
# Earlier versions of this script pulled in printer-driver-all (200+ deps
# incl. GIMP / GTK / ffmpeg), foomatic-db, cups-pdf, ufw, etc. None of those
# are needed for a Canon UFR II AirPrint bridge. Purge them if present so
# `update` slims existing CTs. Skip with AIRPRINT_KEEP_LEGACY=1.
if [[ "${AIRPRINT_KEEP_LEGACY:-0}" != "1" ]]; then
  LEGACY_PKGS=(
    printer-driver-all
    printer-driver-postscript-hp
    printer-driver-cups-pdf
    cups-pdf
    foomatic-db
    foomatic-db-engine
    logrotate
    xz-utils
    jq
    sane
  )
  # Don't drop ufw if the user opted in to keep it.
  if [[ "${AIRPRINT_ENABLE_UFW:-0}" != "1" ]]; then
    LEGACY_PKGS+=(ufw)
  fi
  # Filter to packages actually installed — dpkg -P on a missing package
  # is fine but noisy. dpkg-query lists exactly what's there.
  TO_PURGE=()
  for p in "${LEGACY_PKGS[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}\n' "$p" 2>/dev/null | grep -q '^installed$'; then
      TO_PURGE+=("$p")
    fi
  done
  if (( ${#TO_PURGE[@]} > 0 )); then
    log "purging legacy / no-longer-needed packages: ${TO_PURGE[*]}"
    apt-get -y -qq purge "${TO_PURGE[@]}" || warn "some purges failed (non-fatal)"
    apt-get -y -qq autoremove --purge >/dev/null || true
    ok "legacy packages purged"
  fi
fi

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

# ---- 7. firewall (opt-in) --------------------------------------------------
# UFW is overkill for a single-household airprint LXC behind a home router
# and frequently breaks LAN access to :631 inside unprivileged LXCs (the
# container can't fully load nftables/iptables modules, so the deny-by-default
# policy can leak through in odd ways). Default: not even installed. Set
# AIRPRINT_ENABLE_UFW=1 to install + configure it.
if [[ "${AIRPRINT_ENABLE_UFW:-0}" == "1" ]]; then
  log "installing + applying minimal ufw ruleset (AIRPRINT_ENABLE_UFW=1)"
  apt-get -y -qq install --no-install-recommends ufw
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
else
  log "ufw not installed (set AIRPRINT_ENABLE_UFW=1 to opt in)"
fi

# ---- 7b. CUPS reachability check ------------------------------------------
# After cups+ufw are settled, verify the daemon is actually bound to *:631 and
# answering HTTP. This catches misconfigurations early rather than letting the
# user discover them by hitting a dead URL.
log "verifying CUPS web UI is reachable on http://localhost:631/"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)\*?:?631$|0\.0\.0\.0:631$'; then
  ok "cupsd is listening on *:631"
else
  warn "cupsd is NOT listening on *:631 — check /etc/cups/cupsd.conf"
  ss -ltn 2>/dev/null | sed 's/^/    /'
fi
if curl -fsSI --max-time 4 http://localhost:631/ >/dev/null 2>&1; then
  ok "http://localhost:631/ responds"
else
  warn "http://localhost:631/ did NOT respond — see 'journalctl -u cups -n 30'"
fi

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

# ---- 9. console autologin --------------------------------------------------
log "enabling root autologin on the LXC console (Proxmox web UI)"
"$ROOT/scripts/console-autologin.sh" || warn "console autologin step failed"

# ---- 10. persist install env + install `update` command -------------------
log "persisting install settings to /etc/airprint-v2/install.env"
install -d -m 0755 /etc/airprint-v2
umask 077
cat >/etc/airprint-v2/install.env <<EOF
# airprint-v2 — generated by install.sh on $(date -Is)
# Sourced by /opt/airprint-v2/scripts/update.sh on every \`update\` run.
AIRPRINT_PRINTER_IP=${AIRPRINT_PRINTER_IP}
AIRPRINT_PRINTER_MODEL=${AIRPRINT_PRINTER_MODEL}
AIRPRINT_QUEUE_NAME=${AIRPRINT_QUEUE_NAME}
AIRPRINT_SCAN_SHARE=${AIRPRINT_SCAN_SHARE}
EOF
chmod 0600 /etc/airprint-v2/install.env
umask 022

log "installing 'update' / 'airprint-update' commands in /usr/local/sbin"
ln -sf "$ROOT/scripts/update.sh" /usr/local/sbin/airprint-update
# 'update' mirrors the community-scripts.org convention. Skip the symlink if
# something (Debian package, admin) already provided a /usr/local/sbin/update
# that doesn't belong to us.
if [[ ! -e /usr/local/sbin/update ]] || [[ "$(readlink -f /usr/local/sbin/update 2>/dev/null)" == "$ROOT/scripts/update.sh" ]]; then
  ln -sf "$ROOT/scripts/update.sh" /usr/local/sbin/update
else
  warn "/usr/local/sbin/update exists and is not ours — skipping (use 'airprint-update' instead)"
fi
ok "update command available — run \`update\` from inside the LXC to refresh"

# ---- 11. summary -----------------------------------------------------------
ip4="$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 || true)"
printf '\n%s== airprint-v2 inside-container install complete ==%s\n' "$C_BOLD" "$C_RESET"
printf '  hostname  : %s\n'   "$(hostname)"
printf '  ip        : %s\n'   "${ip4:-<unknown>}"
printf '  queue     : %s\n'   "$AIRPRINT_QUEUE_NAME"
printf '  IPP URL   : ipp://%s:631/printers/%s\n' "${ip4:-<host>}" "$AIRPRINT_QUEUE_NAME"
printf '  CUPS web  : http://%s:631/\n' "${ip4:-<host>}"
printf '  scan SMB  : \\\\%s\\%s\n' "${ip4:-<host>}" "$AIRPRINT_SCAN_SHARE"
printf '\nTo refresh in the future, run %supdate%s from inside this container.\n' "$C_BOLD" "$C_RESET"
printf 'Use the helper scripts under /opt/airprint-v2/scripts/ to re-run any step.\n'
