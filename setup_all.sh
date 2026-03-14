#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法:
  bash setup_all.sh                # 默认执行: base aliases security docker
  bash setup_all.sh all            # 执行: base aliases security docker node
  bash setup_all.sh base aliases   # 仅执行指定步骤

可选步骤:
  base aliases security docker node nginx ufw

说明:
  1) 除 aliases/node（针对当前用户）外，其他步骤通常需要 root。
  2) 建议传入 TARGET_USER=你的用户名（例如 TARGET_USER=your_user）。
  3) 执行 nginx 步骤时，需准备 domains.json，且默认要求 CERTBOT_EMAIL。
  4) security 步骤仅包含 fail2ban/ssh 加固，不再默认包含 ufw。如需防火墙，请显式添加 ufw 步骤。
EOF
}

script_for_step() {
  case "$1" in
    base) echo "setup_base.sh" ;;
    aliases) echo "setup_aliases.sh" ;;
    security) echo "setup_security.sh" ;;
    docker) echo "setup_docker.sh" ;;
    node) echo "setup_nodejs.sh" ;;
    nginx) echo "setup_nginx_proxy.sh" ;;
    ufw) echo "setup_ufw.sh" ;;
    *) return 1 ;;
  esac
}

DEFAULT_STEPS=(base aliases security docker)
ALL_STEPS=(base aliases security docker node)

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -eq 0 ]]; then
  STEPS=("${DEFAULT_STEPS[@]}")
elif [[ "$#" -eq 1 && "$1" == "all" ]]; then
  STEPS=("${ALL_STEPS[@]}")
else
  STEPS=("$@")
fi

for step in "${STEPS[@]}"; do
  if ! script="$(script_for_step "$step")"; then
    echo "未知步骤: $step" >&2
    usage
    exit 1
  fi

  echo "========== 运行步骤: $step =========="
  bash "$SCRIPT_DIR/$script"
  echo "========== 步骤完成: $step =========="
done

echo "全部步骤执行完成。"
