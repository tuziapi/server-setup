#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_nodejs.sh
  TARGET_USER=your_user bash setup_nodejs.sh

可选环境变量:
  TARGET_USER=your_user
  NVM_VERSION=v0.40.4
  NODE_VERSION=lts/*
  NVM_INSTALL_URL=https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh

说明:
  - 为当前用户安装时可直接执行。
  - 为其他用户安装时需要 root 权限（非 root 可先用 su 提权，有 sudo 也可）。
EOF
  exit 0
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
CURRENT_USER="$(id -un)"
NVM_VERSION="${NVM_VERSION:-v0.40.4}"
NODE_VERSION="${NODE_VERSION:-lts/*}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh}"

list_human_users() {
  awk -F: '
    ($3 >= 1000) && ($1 != "nobody") && ($7 !~ /(nologin|false)$/) { print $1 }
  ' /etc/passwd | paste -sd ', ' -
}

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  users="$(list_human_users || true)"
  if [[ -n "$users" ]]; then
    die "用户不存在: ${TARGET_USER}。可用用户: ${users}"
  fi
  die "用户不存在: ${TARGET_USER}。当前系统未检测到常规用户，请先创建用户后重试。"
fi

if [[ "$EUID" -ne 0 && "$TARGET_USER" != "$CURRENT_USER" ]]; then
  die "当前用户无权为 ${TARGET_USER} 安装 Node.js。请切换 root 执行（可先用 su 提权，有 sudo 也可）。"
fi

if ! has_cmd curl; then
  if [[ "$EUID" -eq 0 ]]; then
    apt_install ca-certificates curl
  else
    die "缺少 curl，请先安装后重试。"
  fi
fi

tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT

cat >"$tmp_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
curl -fsSL "$NVM_INSTALL_URL" | bash
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
node -v
npm -v

echo "Installing Claude Code and Statusline Plugin..."
npm install -g https://gaccode.com/claudecode/install --registry=https://registry.npmmirror.com
npm i -g https://gaccode.com/claudecode/install/statusline-plugin --registry=https://registry.npmmirror.com/
EOF

chmod 755 "$tmp_script"

log "为用户 $TARGET_USER 安装 nvm + Node.js ($NODE_VERSION) ..."
if [[ "$EUID" -eq 0 ]]; then
  su - "$TARGET_USER" -c "bash '$tmp_script'"
else
  bash "$tmp_script"
fi

log "Node.js 安装完成。"
