#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_base.sh

可选环境变量:
  TIMEZONE=Asia/Shanghai   设置系统时区（可选）

说明:
  该脚本需要 root 权限；非 root 用户请先用 su 提权（有 sudo 也可）。
  仓库里不存在的软件包会自动跳过，不会中断其他常用工具安装。
EOF
  exit 0
fi

require_root

PACKAGES=(
  ca-certificates
  curl
  wget
  git
  jq
  vim
  nano
  tmux
  htop
  tree
  unzip
  zip
  rsync
  lsof
  net-tools
  dnsutils
  gnupg
  lsb-release
  software-properties-common
  fail2ban
  cron
)

resolve_package() {
  local pkg="$1"
  case "$pkg" in
    dnsutils)
      # Debian 新版常见为 bind9-dnsutils，旧配置里常见 dnsutils。
      if apt-cache show dnsutils >/dev/null 2>&1; then
        echo "dnsutils"
        return 0
      fi
      if apt-cache show bind9-dnsutils >/dev/null 2>&1; then
        echo "bind9-dnsutils"
        return 0
      fi
      return 1
      ;;
    *)
      apt-cache show "$pkg" >/dev/null 2>&1 || return 1
      echo "$pkg"
      return 0
      ;;
  esac
}

build_install_list() {
  local resolved=""
  INSTALL_LIST=()
  SKIPPED_LIST=()

  # 先 update，保证 apt-cache 查询结果准确。
  apt_update_once

  for pkg in "${PACKAGES[@]}"; do
    if resolved="$(resolve_package "$pkg")"; then
      INSTALL_LIST+=("$resolved")
    else
      SKIPPED_LIST+=("$pkg")
    fi
  done
}

log "开始初始化基础环境 ..."
build_install_list

if [[ "${#SKIPPED_LIST[@]}" -gt 0 ]]; then
  warn "以下包在当前系统仓库中不可用，已跳过: ${SKIPPED_LIST[*]}"
fi

if [[ "${#INSTALL_LIST[@]}" -eq 0 ]]; then
  die "未找到可安装的软件包，请检查 apt 源配置后重试。"
fi

log "将安装可用软件包: ${INSTALL_LIST[*]}"
apt_install "${INSTALL_LIST[@]}"

if systemctl list-unit-files | grep -q '^cron\.service'; then
  systemctl enable --now cron >/dev/null 2>&1 || warn "cron 启动失败，请手动检查。"
fi

if systemctl list-unit-files | grep -q '^fail2ban\.service'; then
  systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban 启动失败，请手动检查。"
fi

if [[ -n "${TIMEZONE:-}" ]]; then
  if timedatectl list-timezones | grep -Fxq "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE"
    log "时区已设置为: $TIMEZONE"
  else
    warn "无效时区 TIMEZONE=$TIMEZONE，跳过时区设置。"
  fi
fi

log "基础环境初始化完成。"
