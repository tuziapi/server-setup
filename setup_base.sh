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
  ufw
  fail2ban
  cron
)

log "开始初始化基础环境 ..."
apt_install "${PACKAGES[@]}"

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
