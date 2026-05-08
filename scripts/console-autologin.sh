#!/usr/bin/env bash
# scripts/console-autologin.sh — drop straight into a root shell on the
# Proxmox web UI's "Console" tab, so you don't have to log in every time.
#
# Background: the Proxmox web console attaches to /dev/tty1 inside the
# container, which by default runs `agetty` and prompts for a username +
# password (Debian's stock behaviour). `pct enter <CTID>` from the Proxmox
# host shell does NOT prompt — but the web UI Console does.
#
# This installs a systemd drop-in that makes agetty auto-login as root on
# tty1 (and on /dev/console for good measure). It's only safe in a
# single-household / private LXC where root SSH/console access is already
# implicitly trusted.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root

install_autologin() {
  local unit="$1"
  install -d -m 0755 "/etc/systemd/system/${unit}.d"
  cat >"/etc/systemd/system/${unit}.d/airprint-autologin.conf" <<'EOF'
# Managed by airprint-v2 — auto-login root on the LXC console so the
# Proxmox web UI's "Console" tab drops straight into a shell.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 38400 linux
EOF
  log "wrote /etc/systemd/system/${unit}.d/airprint-autologin.conf"
}

install_autologin "getty@tty1.service"
install_autologin "container-getty@1.service"

# Reload + restart so it takes effect immediately.
systemctl daemon-reload
# These units may not exist (depends on PID-1) — ignore failure cleanly.
systemctl restart "getty@tty1.service" 2>/dev/null || true
systemctl restart "container-getty@1.service" 2>/dev/null || true

ok "console autologin enabled — Proxmox web Console tab will drop into a root shell"
