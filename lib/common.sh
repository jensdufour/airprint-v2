#!/usr/bin/env bash
# lib/common.sh — shared helpers for airprint-v2.
# Sourced by both the host bootstrap (airprint-v2.sh) and the in-container
# installer (install.sh) and helper scripts.
# shellcheck shell=bash

# Idempotent guard so this file can be sourced multiple times safely.
if [[ -n "${__AIRPRINT_COMMON_SOURCED:-}" ]]; then
  return 0
fi
__AIRPRINT_COMMON_SOURCED=1

# ---- strict mode -----------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

# ---- colours (auto-disable when not a TTY or NO_COLOR set) -----------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

# ---- logging ---------------------------------------------------------------
_ts() { date '+%H:%M:%S'; }

log()   { printf '%s %s[airprint-v2]%s %s\n' "$(_ts)" "$C_BLUE"   "$C_RESET" "$*" >&2; }
ok()    { printf '%s %s[ ok ]%s %s\n'        "$(_ts)" "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn()  { printf '%s %s[warn]%s %s\n'        "$(_ts)" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s %s[fail]%s %s\n'        "$(_ts)" "$C_RED"    "$C_RESET" "$*" >&2; }
info()  { printf '%s %s..%s %s\n'            "$(_ts)" "$C_BLUE"   "$C_RESET" "$*" >&2; }

die()   { err "$*"; exit 1; }

# Run a command, suppress stdout but keep stderr (good for noisy installers).
silent() { "$@" >/dev/null; }

# ---- error trap ------------------------------------------------------------
__airprint_on_err() {
  local exit_code=$?
  local line=${1:-?}
  err "command failed (exit ${exit_code}) at ${BASH_SOURCE[1]:-?}:${line}"
  err "last command: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap '__airprint_on_err "$LINENO"' ERR

# ---- small helpers ---------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_root() { [[ "$(id -u)" -eq 0 ]]; }
require_root() { is_root || die "must run as root"; }

# Backup a file in-place once (adds .airprint-orig if absent), then noop.
backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -f "${f}.airprint-orig" ]] || cp -a "$f" "${f}.airprint-orig"
}

# Append a managed block to a config file, replacing any prior block.
# Usage: managed_block <file> <marker> <<'EOF' ...content... EOF
managed_block() {
  local file="$1" marker="$2"
  local begin="# >>> airprint-v2: ${marker} >>>"
  local end="# <<< airprint-v2: ${marker} <<<"
  local content
  content="$(cat)"
  backup_once "$file"
  if [[ -f "$file" ]] && grep -qF "$begin" "$file"; then
    # Replace existing block in-place.
    awk -v b="$begin" -v e="$end" -v new="$content" '
      BEGIN{in_blk=0; printed=0}
      $0==b {print b; print new; print e; in_blk=1; printed=1; next}
      $0==e && in_blk {in_blk=0; next}
      !in_blk {print}
    ' "$file" > "${file}.airprint-tmp"
    mv "${file}.airprint-tmp" "$file"
  else
    {
      [[ -f "$file" ]] && cat "$file"
      printf '%s\n%s\n%s\n' "$begin" "$content" "$end"
    } > "${file}.airprint-tmp"
    mv "${file}.airprint-tmp" "$file"
  fi
}

# Ask yes/no with a default. Honours AIRPRINT_NONINTERACTIVE=1.
confirm() {
  local prompt="$1" default="${2:-n}" reply
  if [[ "${AIRPRINT_NONINTERACTIVE:-0}" == "1" ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  local hint="[y/N]"; [[ "$default" == "y" ]] && hint="[Y/n]"
  read -r -p "$prompt $hint " reply || reply=""
  reply="${reply:-$default}"
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# Ask for a value with a default. Honours AIRPRINT_NONINTERACTIVE=1.
ask() {
  local prompt="$1" default="${2:-}" varname="${3:-}" reply
  if [[ "${AIRPRINT_NONINTERACTIVE:-0}" == "1" ]]; then
    reply="$default"
  else
    read -r -p "$prompt [$default]: " reply || reply=""
    reply="${reply:-$default}"
  fi
  if [[ -n "$varname" ]]; then
    printf -v "$varname" '%s' "$reply"
  else
    printf '%s' "$reply"
  fi
}

# Detect script directory (resolves symlinks).
script_dir() {
  local src="${BASH_SOURCE[1]:-$0}"
  while [[ -h "$src" ]]; do
    local d; d="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$d/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
