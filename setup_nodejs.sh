#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_nodejs.sh
  sudo TARGET_USER=ubuntu bash setup_nodejs.sh

可选环境变量:
  TARGET_USER=ubuntu
  NVM_VERSION=v0.40.4
  NODE_VERSION=lts/*
  NVM_INSTALL_URL=https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh
EOF
  exit 0
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
CURRENT_USER="$(id -un)"
NVM_VERSION="${NVM_VERSION:-v0.40.4}"
NODE_VERSION="${NODE_VERSION:-lts/*}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh}"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  die "用户不存在: $TARGET_USER"
fi

if [[ "$EUID" -ne 0 && "$TARGET_USER" != "$CURRENT_USER" ]]; then
  die "当前用户无权为 $TARGET_USER 安装 Node.js。请使用 sudo。"
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
EOF

chmod 755 "$tmp_script"

log "为用户 $TARGET_USER 安装 nvm + Node.js ($NODE_VERSION) ..."
if [[ "$EUID" -eq 0 ]]; then
  su - "$TARGET_USER" -c "bash '$tmp_script'"
else
  bash "$tmp_script"
fi

log "Node.js 安装完成。"
