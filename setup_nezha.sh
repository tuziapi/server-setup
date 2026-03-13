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

说明:
  - 安装哪吒监控 Agent。
  - 需要 root 权限。
EOF
  exit 0
fi

NZ_SERVER="${NZ_SERVER:-}"
NZ_TLS="${NZ_TLS:-false}"
NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:-}"

if [[ -z "$NZ_SERVER" ]]; then
  die "未设置 NZ_SERVER 环境变量。"
fi

if [[ -z "$NZ_CLIENT_SECRET" ]]; then
  die "未设置 NZ_CLIENT_SECRET 环境变量。"
fi

if [[ "$EUID" -ne 0 ]]; then
  die "请使用 root 权限运行此脚本。"
fi

if systemctl is-active --quiet nezha-agent || [ -f "/etc/systemd/system/nezha-agent.service" ]; then
  log "哪吒监控 Agent 已安装，跳过。"
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

log "哪吒监控 Agent 安装完成。"
