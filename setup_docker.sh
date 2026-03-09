#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_docker.sh

可选环境变量:
  TARGET_USER=your_user          将用户加入 docker 组
  DOCKER_CHANNEL=stable            Docker 渠道（默认 stable）
  DOCKER_INSTALL_URL=https://get.docker.com
                                   Docker 官方安装脚本地址

说明:
  该脚本需要 root 权限；非 root 用户请先用 su 提权（有 sudo 也可）。
EOF
  exit 0
fi

require_root

DOCKER_CHANNEL="${DOCKER_CHANNEL:-stable}"
DOCKER_INSTALL_URL="${DOCKER_INSTALL_URL:-https://get.docker.com}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"

apt_install ca-certificates curl

tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT

log "下载 Docker 官方安装脚本: $DOCKER_INSTALL_URL"
curl -fsSL "$DOCKER_INSTALL_URL" -o "$tmp_script"

log "安装 Docker（channel=$DOCKER_CHANNEL）..."
sh "$tmp_script" --channel "$DOCKER_CHANNEL"

systemctl enable --now docker

if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  usermod -aG docker "$TARGET_USER"
  log "已将用户 $TARGET_USER 加入 docker 组（重新登录后生效）。"
fi

if has_cmd docker; then
  log "Docker 已安装: $(docker --version)"
fi
