#!/usr/bin/env bash
# scripts/add-scan-share.sh — Samba scan-to-folder fallback.
#
# Creates an SMB share at \\<container>\scans backed by /srv/scans, world
# writable from the LAN (single-household assumption — no auth).
# Configure the printer's "Send to SMB" feature with:
#   Server      : <container IP or hostname>.local
#   Share       : scans
#   Username    : guest   (or leave blank, allow guest)
#   Password    : (blank)
#   Path        : /        (the share's root)
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root
need_cmd smbd

: "${AIRPRINT_SCAN_SHARE:=scans}"
: "${AIRPRINT_SCAN_DIR:=/srv/scans}"

log "creating scan directory at $AIRPRINT_SCAN_DIR"
install -d -m 0777 -o nobody -g nogroup "$AIRPRINT_SCAN_DIR"

log "writing /etc/samba/smb.conf (backup at /etc/samba/smb.conf.airprint-orig)"
backup_once /etc/samba/smb.conf
cat >/etc/samba/smb.conf <<EOF
# /etc/samba/smb.conf — managed by airprint-v2 (scan-to-folder share).
# Original config preserved at /etc/samba/smb.conf.airprint-orig.

[global]
    workgroup = WORKGROUP
    server string = airprint-v2 scan host
    security = user
    map to guest = Bad User
    guest account = nobody
    log file = /var/log/samba/log.%m
    max log size = 1000
    server min protocol = SMB2_02
    disable netbios = no
    load printers = no
    printing = bsd
    printcap name = /dev/null

[${AIRPRINT_SCAN_SHARE}]
    comment = Scan-to-folder drop for airprint-v2
    path = ${AIRPRINT_SCAN_DIR}
    browseable = yes
    read only = no
    writable = yes
    guest ok = yes
    guest only = yes
    create mask = 0666
    directory mask = 0777
    force user = nobody
    force group = nogroup
EOF

# Validate config before bouncing services.
if ! testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
  err "smb.conf failed testparm validation"
  testparm -s /etc/samba/smb.conf || true
  exit 1
fi

systemctl enable --now smbd nmbd
systemctl restart smbd nmbd

ok "Samba scan share '${AIRPRINT_SCAN_SHARE}' is up at ${AIRPRINT_SCAN_DIR}"
ip4="$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 || true)"
log "configure your printer's Send-to-SMB target as: \\\\${ip4:-<host>}\\${AIRPRINT_SCAN_SHARE}"
