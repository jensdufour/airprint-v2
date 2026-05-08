#!/usr/bin/env bash
# scripts/add-scanner.sh — best-effort scanner setup.
#
# The Canon iR 1133A doesn't expose eSCL/AirScan natively, so this script:
#   1. Tries `sane-airscan` auto-discovery (works only if the printer ever
#      did expose eSCL — most 1133A firmwares don't).
#   2. Falls back to SANE network backends (pixma, canon, canon_pp).
#   3. If `scanimage -L` lists a device, ensures `saned` is enabled and
#      `sane-airscan` re-publishes it via Bonjour as an AirScan device.
#
# If nothing detects, the Samba scan-to-folder share (add-scan-share.sh)
# remains the reliable path.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_root
need_cmd scanimage

: "${AIRPRINT_PRINTER_IP:?AIRPRINT_PRINTER_IP must be set}"

# 1. Configure sane-airscan to probe the printer's IP explicitly. This is a
#    no-op if the device doesn't speak eSCL, but it's harmless to try.
mkdir -p /etc/sane.d
cat >/etc/sane.d/airscan.conf <<EOF
[devices]
"airprint-v2-${AIRPRINT_PRINTER_IP}" = http://${AIRPRINT_PRINTER_IP}:80/eSCL, eSCL

[options]
discovery = enable
model     = network
trace     = ""
socket_dir = ""
EOF

# 2. Make sure the legacy SANE backends are enabled (best chance for Canon iR).
if [[ -f /etc/sane.d/dll.conf ]]; then
  for be in airscan pixma canon canon_pp escl; do
    if ! grep -qE "^${be}\s*$" /etc/sane.d/dll.conf; then
      echo "$be" >> /etc/sane.d/dll.conf
    fi
  done
fi

# 3. Probe.
log "probing for scanners (this can take ~10s)…"
SCAN_OUT="$(scanimage -L 2>&1 || true)"
# Indent each line by 4 spaces (no spawn — pure bash parameter expansion).
printf '    %s\n' "${SCAN_OUT//$'\n'/$'\n    '}"

if echo "$SCAN_OUT" | grep -qiE 'canon|airscan|escl'; then
  ok "scanner detected via SANE — enabling AirScan publishing"

  # Enable saned so airscan can re-export over the network if needed.
  systemctl enable --now saned.socket 2>/dev/null || true

  # Avahi will pick up the airscan service file shipped by sane-airscan.
  systemctl restart avahi-daemon
  ok "scanner advertised via Bonjour (AirScan)"
else
  warn "no scanner detected — this is expected for a stock iR 1133A."
  warn "use the Samba scan-to-folder share instead (see add-scan-share.sh)."
fi
