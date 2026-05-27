#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_security.sh

可选环境变量:
  SSH_PORT=22                  SSH 端口（默认 22）
  HARDEN_SSH=1                 启用 SSH 基础加固
  DISABLE_PASSWORD_AUTH=1      配合 HARDEN_SSH=1 禁用 SSH 密码登录

说明:
  该脚本需要 root 权限；非 root 用户请先用 su 提权（有 sudo 也可）。
  支持 Debian/Ubuntu、RHEL/CentOS/AlmaLinux/Rocky/Fedora、Alpine、Arch Linux。
EOF
  exit 0
fi

require_root
detect_os

SSH_PORT="${SSH_PORT:-22}"
HARDEN_SSH="${HARDEN_SSH:-0}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-0}"

if [[ "$OS_FAMILY" == "rhel" ]]; then
  ensure_epel
fi

pkg_install fail2ban

log "配置 fail2ban（SSH 防爆破）..."
mkdir -p /etc/fail2ban/jail.d

if [[ "$OS_FAMILY" == "alpine" ]]; then
  F2B_BACKEND="polling"
else
  F2B_BACKEND="systemd"
fi

cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = ${F2B_BACKEND}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

svc_enable_now fail2ban
svc_restart fail2ban

if [[ "$HARDEN_SSH" == "1" ]]; then
  log "开启 SSH 基础加固 ..."
  backup_file /etc/ssh/sshd_config
  sed -ri 's/^#?PermitRootLogin\s+.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

  if [[ "$DISABLE_PASSWORD_AUTH" == "1" ]]; then
    sed -ri 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  fi

  if svc_exists ssh; then
    svc_reload ssh
  elif svc_exists sshd; then
    svc_reload sshd
  else
    warn "未检测到 ssh/sshd 服务，请手动重启 SSH 服务。"
  fi
fi

log "安全基线配置完成。"
