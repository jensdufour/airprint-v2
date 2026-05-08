#!/usr/bin/env bash
# scripts/console-autologin.sh — drop straight into a root shell on the
# Proxmox web UI's "Console" tab, so you don't have to log in every time.
#
# Background: the Proxmox web console attaches to /dev/tty1 inside the
# container, which by default runs `agetty` and prompts for a username +
# password (Debian's stock behaviour). `pct enter <CTID>` from the Proxmox
# host shell does NOT prompt — but the web UI Console does.
#
# This installs systemd drop-ins that make agetty auto-login as root on
# tty1 / the LXC container console / /dev/console (depending on which one
# is actually wired up by Proxmox). It then force-restarts the running
# agetty so the change takes effect without rebooting the LXC.
#
# Single-household / private LXC only — root SSH/console access is implicitly
# trusted in this product's threat model.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root

# All the unit names that might be running an agetty for the LXC console,
# across Proxmox/Debian variants. Writing a drop-in for each is a no-op for
# the ones that don't exist on this host.
UNITS=(
  "getty@tty1.service"
  "container-getty@1.service"
  "container-getty@0.service"
  "console-getty.service"
)

install_dropin() {
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

for u in "${UNITS[@]}"; do
  install_dropin "$u"
done

# Reload + try to restart each unit. Most won't exist on any given host —
# that's expected and harmless.
systemctl daemon-reload

restart_unit() {
  local u="$1"
  if systemctl cat "$u" >/dev/null 2>&1; then
    systemctl restart "$u" 2>/dev/null || true
  fi
}
for u in "${UNITS[@]}"; do
  restart_unit "$u"
done

# `systemctl restart` of a getty template unit doesn't always reliably kill
# the lingering agetty process bound to the tty (it's a known quirk in
# containerized systemd). Force-kill any agetty whose ExecStart predates
# our drop-in (i.e. doesn't include --autologin) so the new ExecStart
# actually takes effect on the next attach.
if pgrep -af agetty 2>/dev/null | grep -vq -- '--autologin'; then
  log "killing stale agetty processes (without --autologin)"
  # shellcheck disable=SC2009
  ps -eo pid,cmd | awk '/agetty/ && !/--autologin/ && !/awk/ {print $1}' \
    | while read -r pid; do
        if [[ -n "$pid" ]]; then
          kill "$pid" 2>/dev/null || true
        fi
      done
  # Give systemd a moment to respawn the unit with the new ExecStart.
  sleep 1
fi

# Verify: at least one agetty must now be running with --autologin.
if pgrep -af agetty 2>/dev/null | grep -q -- '--autologin'; then
  ok "console autologin enabled — Proxmox web Console tab will drop into a root shell"
  log "→ if the Console tab in your browser still asks for login, close the tab and reopen it"
else
  warn "could not verify a running agetty with --autologin"
  warn "the drop-ins are in place, but you may need to reboot the LXC: 'pct reboot <CTID>' on the Proxmox host"
fi
