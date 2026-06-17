#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_nezha.sh

环境变量:
  NZ_SERVER           哪吒监控服务器地址 (例如: nezha.example.com:8008)
  NZ_TLS              是否启用 TLS (true/false, 默认 false)
  NZ_CLIENT_SECRET    客户端密钥
  NEZHA_DISABLE_COMMAND_EXECUTE=true
                      写入 disable_command_execute: true（默认 true）

说明:
  - 安装哪吒监控 Agent。
  - 默认禁用 Agent 远程命令执行能力，降低 Dashboard 被打穿后的横向风险。
  - 需要 root 权限。
EOF
  exit 0
fi

NZ_SERVER="${NZ_SERVER:-}"
NZ_TLS="${NZ_TLS:-false}"
NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:-}"
NEZHA_DISABLE_COMMAND_EXECUTE="${NEZHA_DISABLE_COMMAND_EXECUTE:-true}"

if [[ -z "$NZ_SERVER" ]]; then
  die "未设置 NZ_SERVER 环境变量。"
fi

if [[ -z "$NZ_CLIENT_SECRET" ]]; then
  die "未设置 NZ_CLIENT_SECRET 环境变量。"
fi

if [[ "$EUID" -ne 0 ]]; then
  die "请使用 root 权限运行此脚本。"
fi

set_nezha_command_execute_policy() {
  local cfg="/opt/nezha/agent/config.yml"
  [[ "${NEZHA_DISABLE_COMMAND_EXECUTE}" == "true" || "${NEZHA_DISABLE_COMMAND_EXECUTE}" == "1" ]] || return 0
  [[ -f "$cfg" ]] || return 0

  log "禁用 Nezha Agent 远程命令执行: $cfg"
  backup_file "$cfg"
  if grep -q '^disable_command_execute:' "$cfg"; then
    sed -i 's/^disable_command_execute:.*/disable_command_execute: true/' "$cfg"
  else
    printf '\ndisable_command_execute: true\n' >>"$cfg"
  fi
}

if systemctl is-active --quiet nezha-agent || [ -f "/etc/systemd/system/nezha-agent.service" ]; then
  log "哪吒监控 Agent 已安装，更新安全配置。"
  set_nezha_command_execute_policy
  systemctl restart nezha-agent 2>/dev/null || true
  exit 0
fi

log "正在安装哪吒监控 Agent..."
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh

# export variables for the install script
export NZ_SERVER
export NZ_TLS
export NZ_CLIENT_SECRET

./agent.sh
rm -f agent.sh

set_nezha_command_execute_policy
systemctl restart nezha-agent 2>/dev/null || true

log "哪吒监控 Agent 安装完成。"
