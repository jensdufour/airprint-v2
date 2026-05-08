#!/usr/bin/env bash
# lib/host_prompts.sh — interactive prompts for the Proxmox host bootstrap.
# Sourced by airprint-v2.sh. Keeps prompt logic out of the entry script.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Pick the next free CTID by scanning `pct list`.
next_free_ctid() {
  local start=200 used
  used="$(pct list 2>/dev/null | awk 'NR>1 {print $1}')"
  while grep -qx "$start" <<<"$used"; do start=$((start+1)); done
  printf '%s' "$start"
}

# Pick a sensible default storage pool (prefers 'local-lvm' or 'local-zfs').
default_storage() {
  local pools
  pools="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}')"
  for p in local-lvm local-zfs local; do
    grep -qx "$p" <<<"$pools" && { printf '%s' "$p"; return; }
  done
  printf '%s' "$(awk 'NR==1' <<<"$pools")"
}

# Pick a sensible default template storage (where vztmpl content lives).
default_template_storage() {
  local pools
  pools="$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')"
  for p in local local-lvm local-zfs; do
    grep -qx "$p" <<<"$pools" && { printf '%s' "$p"; return; }
  done
  printf '%s' "$(awk 'NR==1' <<<"$pools")"
}

# Run the interactive wizard. Sets AIRPRINT_* vars in the caller's scope.
run_host_wizard() {
  : "${AIRPRINT_CTID:=$(next_free_ctid)}"
  : "${AIRPRINT_HOSTNAME:=airprint}"
  : "${AIRPRINT_STORAGE:=$(default_storage)}"
  : "${AIRPRINT_TPL_STORAGE:=$(default_template_storage)}"
  : "${AIRPRINT_BRIDGE:=vmbr0}"
  : "${AIRPRINT_VLAN:=}"
  : "${AIRPRINT_IP:=dhcp}"
  : "${AIRPRINT_GATEWAY:=}"
  : "${AIRPRINT_CORES:=1}"
  : "${AIRPRINT_RAM:=512}"
  : "${AIRPRINT_DISK:=4}"
  : "${AIRPRINT_UNPRIVILEGED:=1}"
  : "${AIRPRINT_PRINTER_IP:=}"
  : "${AIRPRINT_PRINTER_MODEL:=Canon iR1133A}"
  : "${AIRPRINT_QUEUE_NAME:=Canon_iR1133A}"

  if [[ "${AIRPRINT_NONINTERACTIVE:-0}" == "1" ]]; then
    log "non-interactive mode — using env defaults"
    return 0
  fi

  printf '\n%s== airprint-v2 — Proxmox LXC bootstrap ==%s\n\n' "$C_BOLD" "$C_RESET" >&2

  ask "Container ID"          "$AIRPRINT_CTID"        AIRPRINT_CTID
  ask "Hostname"              "$AIRPRINT_HOSTNAME"    AIRPRINT_HOSTNAME
  ask "Root disk storage"     "$AIRPRINT_STORAGE"     AIRPRINT_STORAGE
  ask "Template storage"      "$AIRPRINT_TPL_STORAGE" AIRPRINT_TPL_STORAGE
  ask "Bridge"                "$AIRPRINT_BRIDGE"      AIRPRINT_BRIDGE
  ask "VLAN tag (blank=none)" "$AIRPRINT_VLAN"        AIRPRINT_VLAN
  ask "IP (dhcp or CIDR e.g. 192.168.10.20/24)" "$AIRPRINT_IP" AIRPRINT_IP
  if [[ "$AIRPRINT_IP" != "dhcp" ]]; then
    ask "Gateway"             "${AIRPRINT_GATEWAY:-}" AIRPRINT_GATEWAY
  fi
  ask "CPU cores"             "$AIRPRINT_CORES"       AIRPRINT_CORES
  ask "RAM (MB)"              "$AIRPRINT_RAM"         AIRPRINT_RAM
  ask "Disk (GB)"             "$AIRPRINT_DISK"        AIRPRINT_DISK
  ask "Printer IP address"    "${AIRPRINT_PRINTER_IP:-192.168.1.50}" AIRPRINT_PRINTER_IP
  ask "Printer model (label)" "$AIRPRINT_PRINTER_MODEL" AIRPRINT_PRINTER_MODEL
  ask "CUPS queue name"       "$AIRPRINT_QUEUE_NAME"   AIRPRINT_QUEUE_NAME

  printf '\n%sSummary:%s\n' "$C_BOLD" "$C_RESET" >&2
  printf '  CTID/host : %s / %s\n'      "$AIRPRINT_CTID" "$AIRPRINT_HOSTNAME" >&2
  printf '  storage   : %s (tmpl=%s)\n' "$AIRPRINT_STORAGE" "$AIRPRINT_TPL_STORAGE" >&2
  printf '  network   : bridge=%s vlan=%s ip=%s gw=%s\n' \
    "$AIRPRINT_BRIDGE" "${AIRPRINT_VLAN:-none}" "$AIRPRINT_IP" "${AIRPRINT_GATEWAY:-auto}" >&2
  printf '  resources : %s vCPU / %s MB / %s GB\n' \
    "$AIRPRINT_CORES" "$AIRPRINT_RAM" "$AIRPRINT_DISK" >&2
  printf '  printer   : %s @ %s (queue=%s)\n\n' \
    "$AIRPRINT_PRINTER_MODEL" "$AIRPRINT_PRINTER_IP" "$AIRPRINT_QUEUE_NAME" >&2

  confirm "Proceed?" "y" || die "aborted by user"
}
