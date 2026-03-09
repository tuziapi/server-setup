#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  sudo bash setup_security.sh

可选环境变量:
  SSH_PORT=22                  SSH 端口（默认 22）
  ALLOW_PORTS=80,443,8080/tcp  额外开放端口（逗号分隔）
  HARDEN_SSH=1                 启用 SSH 基础加固
  DISABLE_PASSWORD_AUTH=1      配合 HARDEN_SSH=1 禁用 SSH 密码登录
EOF
  exit 0
fi

require_root

SSH_PORT="${SSH_PORT:-22}"
ALLOW_PORTS="${ALLOW_PORTS:-}"
HARDEN_SSH="${HARDEN_SSH:-0}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-0}"

apt_install ufw fail2ban

log "配置 UFW 防火墙 ..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"

if [[ -n "$ALLOW_PORTS" ]]; then
  IFS=',' read -r -a extra_ports <<<"$ALLOW_PORTS"
  for raw_port in "${extra_ports[@]}"; do
    port="$(echo "$raw_port" | xargs)"
    [[ -z "$port" ]] && continue
    if [[ "$port" == */* ]]; then
      ufw allow "$port"
    else
      ufw allow "${port}/tcp"
    fi
  done
fi

ufw --force enable

log "配置 fail2ban（SSH 防爆破）..."
mkdir -p /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

if [[ "$HARDEN_SSH" == "1" ]]; then
  log "开启 SSH 基础加固 ..."
  backup_file /etc/ssh/sshd_config
  sed -ri 's/^#?PermitRootLogin\s+.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

  if [[ "$DISABLE_PASSWORD_AUTH" == "1" ]]; then
    sed -ri 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  fi

  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl reload sshd
  else
    warn "未检测到 ssh/sshd 服务，请手动重启 SSH 服务。"
  fi
fi

log "安全基线配置完成。"
