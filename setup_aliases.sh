#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_aliases.sh
  TARGET_USER=your_user bash setup_aliases.sh

可选环境变量:
  TARGET_USER=your_user   指定要写入别名的用户

说明:
  - 为当前用户配置时可直接执行。
  - 为其他用户配置时需要 root 权限（非 root 可先用 su 提权，有 sudo 也可）。
EOF
  exit 0
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
CURRENT_USER="$(id -un)"

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
  die "当前用户无权修改 ${TARGET_USER} 的 shell 配置。请切换 root 执行（可先用 su 提权，有 sudo 也可）。"
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

reload_aliases_for_target_user() {
  if [[ "$EUID" -eq 0 && "$TARGET_USER" != "$CURRENT_USER" ]]; then
    su - "$TARGET_USER" -c "bash -lc 'source ~/.bashrc >/dev/null 2>&1 || true; source ~/.server_aliases >/dev/null 2>&1 || true'" \
      || warn "自动加载别名失败（用户: $TARGET_USER），下次登录会自动生效。"
  else
    # shellcheck disable=SC1090
    source "$TARGET_HOME/.bashrc" >/dev/null 2>&1 || true
    # shellcheck disable=SC1090
    source "$ALIAS_FILE" >/dev/null 2>&1 || true
  fi
}

log "自动加载 shell 配置（source ~/.bashrc && source ~/.server_aliases）..."
reload_aliases_for_target_user

log "配置 Git 别名 ..."
tmp_git_script="$(mktemp)"
cat >"$tmp_git_script" <<'EOF'
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

chmod +x "$tmp_git_script"
if [[ "$EUID" -eq 0 ]]; then
  chown "$TARGET_USER" "$tmp_git_script"
  su - "$TARGET_USER" -c "$tmp_git_script"
else
  "$tmp_git_script"
fi
rm -f "$tmp_git_script"

log "别名配置完成。当前执行已自动加载；新终端会话也会自动生效。"
