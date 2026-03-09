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

disable_nodesource_repo() {
  local file changed=0

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$file" ]] || continue
    if grep -qE 'deb\.nodesource\.com' "$file"; then
      backup_file "$file"
      sed -ri '/deb\.nodesource\.com/s/^[[:space:]]*deb[[:space:]]/# disabled by server-setup: deb /' "$file"
      changed=1
    fi
  done

  if [[ "$changed" -eq 1 ]]; then
    return 0
  fi
  return 1
}

apt_update_once() {
  if [[ "$apt_updated" -eq 0 ]]; then
    log "执行 apt-get update ..."
    local tmp_log
    tmp_log="$(mktemp)"
    if ! apt-get update -y 2>&1 | tee "$tmp_log"; then
      rm -f "$tmp_log"
      die "apt-get update 失败，请检查网络和软件源配置。"
    fi

    # Debian trixie/sqv 在 2026-02 后会拒绝带 SHA1 绑定签名的旧 NodeSource 源。
    if grep -q 'deb.nodesource.com' "$tmp_log" && grep -Eq 'SHA1|sqv|Signing key .* not bound' "$tmp_log"; then
      warn "检测到 NodeSource 源签名不被当前策略接受，尝试自动禁用该源并重试 apt-get update。"
      if disable_nodesource_repo; then
        apt-get update -y
      else
        warn "未能定位 NodeSource 源文件，请手动检查 /etc/apt/sources.list(.d)。"
      fi
    fi

    rm -f "$tmp_log"
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
