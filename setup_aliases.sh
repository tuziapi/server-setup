#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_aliases.sh
  sudo TARGET_USER=ubuntu bash setup_aliases.sh

可选环境变量:
  TARGET_USER=ubuntu   指定要写入别名的用户
EOF
  exit 0
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
CURRENT_USER="$(id -un)"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  die "用户不存在: $TARGET_USER"
fi

if [[ "$EUID" -ne 0 && "$TARGET_USER" != "$CURRENT_USER" ]]; then
  die "当前用户无权修改 $TARGET_USER 的 shell 配置。请使用 sudo。"
fi

TARGET_HOME="$(user_home "$TARGET_USER")"
ALIAS_FILE="$TARGET_HOME/.server_aliases"

log "为用户 $TARGET_USER 写入常用别名 ..."
cat >"$ALIAS_FILE" <<'EOF'
# Added by server-setup/setup_aliases.sh
alias l='ls -lhF'
alias la='ls -A'
alias ll='ls -alhF'

alias ..='cd ..'
alias ...='cd ../..'

alias gs='git status -sb'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'
alias gd='git diff'

alias ports='ss -tulpen'
alias myip='curl -fsSL ifconfig.me'
alias reload-bash='source ~/.bashrc'
alias reload-zsh='source ~/.zshrc'
EOF

for shell_rc in ".bashrc" ".zshrc"; do
  rc_file="$TARGET_HOME/$shell_rc"
  touch "$rc_file"
  append_once '[[ -f ~/.server_aliases ]] && source ~/.server_aliases' "$rc_file"
done

if [[ "$EUID" -eq 0 ]]; then
  chown "$TARGET_USER:$TARGET_USER" "$ALIAS_FILE" "$TARGET_HOME/.bashrc" "$TARGET_HOME/.zshrc"
fi

log "配置 Git 别名 ..."
tmp_git_script="$(mktemp)"
cat >"$tmp_script" <<'EOF'
#!/bin/bash
if ! command -v git &> /dev/null; then
  echo "Git 未安装，跳过 Git 别名配置。"
  exit 0
fi
git config --global alias.st status
git config --global alias.co checkout
git config --global alias.ci commit
git config --global alias.br branch
git config --global alias.df diff
git config --global alias.last "log -1 HEAD"
git config --global alias.unstage "reset HEAD --"
git config --global alias.rst "reset --hard"
git config --global alias.amend "commit --amend"
git config --global alias.slog "log --oneline --decorate"
git config --global alias.lg "log --graph --pretty=format:'%C(yellow)%h%C(reset) %C(bold blue)%an%C(reset) %C(green)(%ar)%C(reset) %C(bold cyan)%s%C(reset) %C(red)%d%C(reset)' --abbrev-commit"
EOF

chmod +x "$tmp_script"
if [[ "$EUID" -eq 0 ]]; then
  chown "$TARGET_USER" "$tmp_script"
  su - "$TARGET_USER" -c "$tmp_script"
else
  "$tmp_script"
fi
rm -f "$tmp_script"

log "别名配置完成。重新登录或执行 'source ~/.bashrc' / 'source ~/.zshrc' 生效。"
