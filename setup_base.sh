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
  支持 Debian/Ubuntu、RHEL/CentOS/AlmaLinux/Rocky/Fedora、Alpine、Arch Linux。
  仓库里不存在的软件包会自动跳过，不会中断其他常用工具安装。
EOF
  exit 0
fi

require_root
detect_os

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

build_install_list() {
  INSTALL_LIST=()
  SKIPPED_LIST=()

  pkg_update

  for pkg in "${PACKAGES[@]}"; do
    local mapped
    if mapped="$(map_pkg "$pkg" 2>/dev/null)"; then
      if pkg_available "$pkg" 2>/dev/null; then
        INSTALL_LIST+=("$mapped")
      else
        SKIPPED_LIST+=("$pkg")
      fi
    else
      SKIPPED_LIST+=("$pkg")
    fi
  done
}

log "开始初始化基础环境 (${OS_ID}) ..."

if [[ "$OS_FAMILY" == "rhel" ]]; then
  ensure_epel
fi

build_install_list

if [[ "${#SKIPPED_LIST[@]}" -gt 0 ]]; then
  warn "以下包在当前系统仓库中不可用，已跳过: ${SKIPPED_LIST[*]}"
fi

if [[ "${#INSTALL_LIST[@]}" -eq 0 ]]; then
  die "未找到可安装的软件包，请检查软件源配置后重试。"
fi

log "将安装可用软件包: ${INSTALL_LIST[*]}"
case "$OS_FAMILY" in
  debian)
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${INSTALL_LIST[@]}"
    ;;
  rhel)
    if has_cmd dnf; then
      dnf install -y "${INSTALL_LIST[@]}"
    else
      yum install -y "${INSTALL_LIST[@]}"
    fi
    ;;
  alpine)
    apk add --no-cache "${INSTALL_LIST[@]}"
    ;;
  arch)
    pacman -S --noconfirm --needed "${INSTALL_LIST[@]}"
    ;;
esac

if svc_exists cron; then
  svc_enable_now cron
elif svc_exists crond; then
  svc_enable_now crond
elif svc_exists cronie; then
  svc_enable_now cronie
fi

if svc_exists fail2ban; then
  svc_enable_now fail2ban
fi

if [[ -n "${TIMEZONE:-}" ]]; then
  if has_cmd timedatectl; then
    if timedatectl list-timezones | grep -Fxq "$TIMEZONE"; then
      timedatectl set-timezone "$TIMEZONE"
      log "时区已设置为: $TIMEZONE"
    else
      warn "无效时区 TIMEZONE=$TIMEZONE，跳过时区设置。"
    fi
  elif [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone 2>/dev/null || true
    log "时区已设置为: $TIMEZONE"
  else
    warn "无效时区 TIMEZONE=$TIMEZONE，跳过时区设置。"
  fi
fi

log "基础环境初始化完成。"
