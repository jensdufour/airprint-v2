#!/usr/bin/env bash
# scripts/healthcheck.sh — periodic health probe.
# Logs to syslog. Exits non-zero on failure (so cron MAILTO catches it).
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

LOG_TAG="airprint-healthcheck"
QUEUE="${AIRPRINT_QUEUE_NAME:-Canon_iR1133A}"

log() { logger -t "$LOG_TAG" -- "$1"; }
fail() { logger -t "$LOG_TAG" -p user.warn -- "FAIL: $1"; FAILED=1; }

FAILED=0

# CUPS daemon up?
if ! systemctl is-active --quiet cups; then
  fail "cups.service not active"
fi

# Avahi up?
if ! systemctl is-active --quiet avahi-daemon; then
  fail "avahi-daemon not active"
fi

# Samba up?
if ! systemctl is-active --quiet smbd; then
  fail "smbd not active"
fi

# Queue exists and is enabled?
if ! lpstat -p "$QUEUE" >/dev/null 2>&1; then
  fail "CUPS queue '$QUEUE' missing"
elif ! lpstat -p "$QUEUE" 2>/dev/null | grep -qi 'enabled'; then
  fail "CUPS queue '$QUEUE' is disabled"
fi

# Bonjour announcement visible to the local Avahi daemon?
if command -v avahi-browse >/dev/null 2>&1; then
  if ! timeout 5 avahi-browse -rtp _ipp._tcp 2>/dev/null | grep -q "$QUEUE"; then
    fail "Bonjour _ipp._tcp.local does not include '$QUEUE'"
  fi
fi

if (( FAILED == 0 )); then
  log "ok: cups+avahi+smbd up, queue '$QUEUE' healthy, advertised over Bonjour"
fi
exit "$FAILED"
