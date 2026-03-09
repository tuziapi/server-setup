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
  ALLOW_PORTS=80,443,8080/tcp  额外开放端口（逗号分隔）
  AUTO_ALLOW_LISTENING_PORTS=1 自动放行当前对外监听端口（默认 1）
  AUTO_ALLOW_EXCLUDE_PORTS=68/udp,546/udp
                               自动放行时要排除的端口（逗号分隔）
  HARDEN_SSH=1                 启用 SSH 基础加固
  DISABLE_PASSWORD_AUTH=1      配合 HARDEN_SSH=1 禁用 SSH 密码登录

说明:
  该脚本需要 root 权限；非 root 用户请先用 su 提权（有 sudo 也可）。
EOF
  exit 0
fi

require_root

SSH_PORT="${SSH_PORT:-22}"
ALLOW_PORTS="${ALLOW_PORTS:-}"
AUTO_ALLOW_LISTENING_PORTS="${AUTO_ALLOW_LISTENING_PORTS:-1}"
AUTO_ALLOW_EXCLUDE_PORTS="${AUTO_ALLOW_EXCLUDE_PORTS:-68/udp,546/udp}"
HARDEN_SSH="${HARDEN_SSH:-0}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-0}"

apt_install ufw fail2ban

normalize_rule() {
  local raw="$1"
  local trimmed port proto

  trimmed="$(echo "$raw" | xargs)"
  [[ -n "$trimmed" ]] || return 1

  if [[ "$trimmed" == */* ]]; then
    port="${trimmed%/*}"
    proto="${trimmed#*/}"
  else
    port="$trimmed"
    proto="tcp"
  fi

  proto="${proto,,}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || return 1

  printf '%s/%s\n' "$port" "$proto"
}

detect_listening_entries() {
  ss -H -lntup | awk '
    {
      proto=$1
      if (proto != "tcp" && proto != "udp") next

      local_addr=$5
      host=""
      port=""

      if (local_addr ~ /^\[.*\]:[0-9]+$/) {
        host=local_addr
        sub(/^\[/, "", host)
        sub(/\]:[0-9]+$/, "", host)

        port=local_addr
        sub(/^.*\]:/, "", port)
      } else {
        port=local_addr
        sub(/^.*:/, "", port)

        host=local_addr
        sub(/:[^:]*$/, "", host)
      }

      if (port !~ /^[0-9]+$/) next

      sub(/%.*/, "", host)
      if (host == "") host="*"

      print proto, host, port
    }
  ' | sort -u
}

declare -A UFW_RULES=()
declare -A EXCLUDED_RULES=()
declare -A LOOPBACK_SKIPPED_RULES=()
declare -A EXCLUDED_SKIPPED_RULES=()
AUTO_RULES_APPLIED=()

add_rule() {
  local rule="$1"
  UFW_RULES["$rule"]=1
}

build_excluded_rules() {
  local raw item normalized
  IFS=',' read -r -a raw <<<"$AUTO_ALLOW_EXCLUDE_PORTS"
  for item in "${raw[@]}"; do
    normalized="$(normalize_rule "$item" || true)"
    [[ -z "$normalized" ]] && continue
    EXCLUDED_RULES["$normalized"]=1
  done
}

is_excluded_rule() {
  local rule="$1"
  [[ -n "${EXCLUDED_RULES[$rule]:-}" ]]
}

normalized_ssh_rule="$(normalize_rule "${SSH_PORT}/tcp" || true)"
[[ -n "$normalized_ssh_rule" ]] || die "SSH_PORT 无效: $SSH_PORT"
add_rule "$normalized_ssh_rule"

if [[ -n "$ALLOW_PORTS" ]]; then
  IFS=',' read -r -a extra_ports <<<"$ALLOW_PORTS"
  for raw_port in "${extra_ports[@]}"; do
    normalized="$(normalize_rule "$raw_port" || true)"
    if [[ -z "$normalized" ]]; then
      warn "忽略无效端口规则: $raw_port"
      continue
    fi
    add_rule "$normalized"
  done
fi

if [[ "$AUTO_ALLOW_LISTENING_PORTS" == "1" ]]; then
  if ! has_cmd ss; then
    warn "未检测到 ss 命令，跳过自动探测监听端口。"
  else
    build_excluded_rules
    while read -r proto host port; do
      [[ -z "$proto" || -z "$host" || -z "$port" ]] && continue
      normalized="$(normalize_rule "${port}/${proto}" || true)"
      [[ -z "$normalized" ]] && continue

      if [[ "$host" =~ ^127\. || "$host" == "::1" || "$host" =~ ^::ffff:127\. || "$host" == "localhost" ]]; then
        LOOPBACK_SKIPPED_RULES["$normalized"]=1
        continue
      fi

      if is_excluded_rule "$normalized"; then
        EXCLUDED_SKIPPED_RULES["$normalized"]=1
        continue
      fi

      if [[ -z "${UFW_RULES[$normalized]:-}" ]]; then
        add_rule "$normalized"
        AUTO_RULES_APPLIED+=("$normalized")
      fi
    done < <(detect_listening_entries)
  fi
fi

log "配置 UFW 防火墙 ..."
ufw default deny incoming
ufw default allow outgoing

mapfile -t sorted_rules < <(printf '%s\n' "${!UFW_RULES[@]}" | sort)
for rule in "${sorted_rules[@]}"; do
  ufw allow "$rule"
done

ufw --force enable

if [[ "$AUTO_ALLOW_LISTENING_PORTS" == "1" ]]; then
  if [[ "${#AUTO_RULES_APPLIED[@]}" -gt 0 ]]; then
    log "已自动放行当前监听端口: ${AUTO_RULES_APPLIED[*]}"
  else
    log "未检测到需要自动新增放行的监听端口。"
  fi

  if [[ "${#LOOPBACK_SKIPPED_RULES[@]}" -gt 0 ]]; then
    mapfile -t skipped_loopback < <(printf '%s\n' "${!LOOPBACK_SKIPPED_RULES[@]}" | sort)
    log "以下监听端口仅绑定本机(127.0.0.1/::1)，未放行: ${skipped_loopback[*]}"
  fi

  if [[ "${#EXCLUDED_SKIPPED_RULES[@]}" -gt 0 ]]; then
    mapfile -t skipped_excluded < <(printf '%s\n' "${!EXCLUDED_SKIPPED_RULES[@]}" | sort)
    log "以下监听端口在 AUTO_ALLOW_EXCLUDE_PORTS 中，未放行: ${skipped_excluded[*]}"
  fi
fi

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
