#!/usr/bin/env bash
# scripts/update.sh — in-container updater for airprint-v2.
#
# Run from inside the LXC console / shell:
#   update                # community-scripts.org-style alias
#   airprint-update       # explicit name
#
# What it does:
#   1. Pulls the latest repo into /opt/airprint-v2 (git fetch + reset --hard).
#   2. Re-applies install.sh non-interactively, using the printer/queue
#      settings from the previous install (persisted in /etc/airprint-v2/install.env)
#      or — if that file is missing — derived from the existing CUPS state.
#
# Flags:
#   --branch BRANCH    pull a different branch (default: main)
#   --no-pull          skip the git step (just re-run installer with current tree)
#   --apt-upgrade      run `apt-get full-upgrade -y` after the installer
#   --help / -h
#
# Env overrides: AIRPRINT_REPO_BRANCH, AIRPRINT_PRINTER_IP, AIRPRINT_QUEUE_NAME,
# AIRPRINT_PRINTER_MODEL, AIRPRINT_PATCH_URF.
# shellcheck shell=bash
set -o errexit -o nounset -o pipefail

ROOT="${AIRPRINT_ROOT:-/opt/airprint-v2}"
ENV_FILE="${AIRPRINT_ENV_FILE:-/etc/airprint-v2/install.env}"
BRANCH="${AIRPRINT_REPO_BRANCH:-main}"
DO_PULL=1
DO_APT_UPGRADE=0

while (( $# > 0 )); do
  case "$1" in
    --branch)        BRANCH="$2"; shift 2 ;;
    --branch=*)      BRANCH="${1#*=}"; shift ;;
    --no-pull)       DO_PULL=0; shift ;;
    --apt-upgrade)   DO_APT_UPGRADE=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "update: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# We need common.sh from the (current, pre-pull) tree for the colour log/ok/warn helpers.
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
require_root

# ---- 1. pull latest repo --------------------------------------------------
if (( DO_PULL == 1 )); then
  if [[ ! -d "$ROOT/.git" ]]; then
    warn "$ROOT is not a git checkout — re-cloning fresh"
    : "${AIRPRINT_REPO_URL:=https://github.com/jensdufour/airprint-v2.git}"
    tmp="$(mktemp -d)"
    git clone --depth 1 --branch "$BRANCH" "$AIRPRINT_REPO_URL" "$tmp/airprint-v2"
    rm -rf "$ROOT"
    mv "$tmp/airprint-v2" "$ROOT"
    rm -rf "$tmp"
  else
    log "fetching origin/$BRANCH in $ROOT"
    git -C "$ROOT" fetch --depth 1 origin "$BRANCH"
    before="$(git -C "$ROOT" rev-parse HEAD)"
    git -C "$ROOT" reset --hard "origin/$BRANCH"
    after="$(git -C "$ROOT" rev-parse HEAD)"
    if [[ "$before" == "$after" ]]; then
      ok "already at latest $BRANCH ($after)"
    else
      ok "updated $before → $after"
      log "changed files:"
      git -C "$ROOT" diff --name-only "$before" "$after" | sed 's/^/  /'
    fi
  fi
  # Ensure scripts are executable (Windows clones strip +x).
  find "$ROOT" -type f -name '*.sh' -exec chmod +x {} +
fi

# Re-source common.sh from the (possibly updated) tree so any new helpers are picked up.
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

# ---- 2. load persisted settings or recover from CUPS state -----------------
load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

derive_from_cups() {
  log "no $ENV_FILE — deriving printer settings from existing CUPS state"
  local q uri
  q="$(lpstat -d 2>/dev/null | awk -F': ' '/system default destination/ {print $2}')"
  if [[ -z "$q" ]]; then
    q="$(lpstat -p 2>/dev/null | awk '/^printer / {print $2; exit}')"
  fi
  if [[ -z "$q" ]]; then
    err "could not detect a CUPS queue — set AIRPRINT_QUEUE_NAME / AIRPRINT_PRINTER_IP and re-run"
    return 1
  fi
  uri="$(lpstat -v "$q" 2>/dev/null | sed 's/.*: //')"
  : "${AIRPRINT_QUEUE_NAME:=$q}"
  : "${AIRPRINT_PRINTER_IP:=$(awk -F'[/:]' '/^socket:/{print $4}' <<<"$uri")}"
  : "${AIRPRINT_PRINTER_MODEL:=Canon iR1133A}"
  if [[ -z "${AIRPRINT_PRINTER_IP:-}" ]]; then
    err "could not parse printer IP from queue URI '$uri' — set AIRPRINT_PRINTER_IP"
    return 1
  fi
  export AIRPRINT_QUEUE_NAME AIRPRINT_PRINTER_IP AIRPRINT_PRINTER_MODEL
  ok "recovered queue=$AIRPRINT_QUEUE_NAME, printer=$AIRPRINT_PRINTER_IP"
}

if ! load_env_file "$ENV_FILE"; then
  derive_from_cups
fi

# Inputs install.sh needs.
: "${AIRPRINT_PRINTER_IP:?AIRPRINT_PRINTER_IP must be set (no $ENV_FILE and no CUPS queue found)}"
: "${AIRPRINT_PRINTER_MODEL:=Canon iR1133A}"
: "${AIRPRINT_QUEUE_NAME:=Canon_iR1133A}"

# ---- 3. re-run installer ---------------------------------------------------
log "re-running $ROOT/install.sh non-interactively"
AIRPRINT_NONINTERACTIVE=1 \
AIRPRINT_PRINTER_IP="$AIRPRINT_PRINTER_IP" \
AIRPRINT_PRINTER_MODEL="$AIRPRINT_PRINTER_MODEL" \
AIRPRINT_QUEUE_NAME="$AIRPRINT_QUEUE_NAME" \
  bash "$ROOT/install.sh"

# ---- 4. optional apt upgrade -----------------------------------------------
if (( DO_APT_UPGRADE == 1 )); then
  log "running apt full-upgrade"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y -qq full-upgrade
  apt-get -y -qq autoremove --purge
  ok "apt upgrade done"
fi

ok "airprint-v2 update complete"
