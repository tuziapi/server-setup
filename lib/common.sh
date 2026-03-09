#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TS_FORMAT="+%Y-%m-%d %H:%M:%S"

log() {
  printf '[%s] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

warn() {
  printf '[%s] [WARN] %s\n' "$(date "$LOG_TS_FORMAT")" "$*" >&2
}

die() {
  printf '[%s] [ERROR] %s\n' "$(date "$LOG_TS_FORMAT")" "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 执行该脚本（可先通过 su 提权；有 sudo 也可用）。"
  fi
}

apt_updated=0

apt_update_once() {
  if [[ "$apt_updated" -eq 0 ]]; then
    log "执行 apt-get update ..."
    apt-get update -y
    apt_updated=1
  fi
}

apt_install() {
  apt_update_once
  log "安装软件包: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local bak="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$file" "$bak"
    log "已备份: $bak"
  fi
}

append_once() {
  local line="$1"
  local file="$2"
  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >>"$file"
  fi
}

user_home() {
  local user="$1"
  getent passwd "$user" | cut -d: -f6
}
