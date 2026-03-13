#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf "${YELLOW}[%s] [WARN] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  printf "${RED}[%s] [ERROR] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法:
  bash install.sh                           # 交互式菜单（如果无参数且在终端中）
  bash install.sh base aliases security     # 自动安装指定步骤

支持步骤:
  base aliases security docker node nginx nezha all

常用参数:
  --repo <owner/repo>          GitHub 仓库（默认: tuziapi/server-setup）
  --ref <branch/tag/sha>        Git 引用（默认: main）
  --timezone <TZ>               传给 setup_base.sh（例如 Asia/Shanghai）
  --ssh-port <port>             传给 setup_security.sh（默认 22）
  --allow-ports <list>          额外开放端口（如 80,443,8080/tcp）
  --disable-auto-allow-listening
                                关闭自动放行当前监听端口
  --auto-allow-exclude-ports <list>
                                自动放行排除列表（默认 68/udp,546/udp）
  --harden-ssh                  启用 SSH 基础加固
  --disable-password-auth       禁用 SSH 密码登录（会自动开启 --harden-ssh）
  --docker-channel <channel>    Docker 渠道（默认 stable）
  --node-version <version>      Node 版本（默认 lts/*）
  --nvm-version <version>       nvm 版本（默认 v0.40.4）
  --config-file <path>          nginx 步骤使用的 domains.json 本地路径
  --config-url <url>            nginx 步骤使用的 domains.json 下载地址
  --certbot-email <email>       nginx SSL 证书邮箱
  --no-ssl                      nginx 仅反向代理，不申请证书
  --force-nginx                 nginx 忽略 completed=true 强制重建
  --workdir <dir>               临时工作目录基路径（默认 /tmp）
  --keep-workdir                保留临时目录，便于排查
  --dry-run                     仅输出计划，不实际执行
  -h, --help                    查看帮助

环境变量:
  支持从当前目录下的 .env 文件加载环境变量。
  NZ_SERVER                     哪吒监控 Server 地址
  NZ_CLIENT_SECRET              哪吒监控 Client Secret
  NZ_TLS                        哪吒监控 TLS (true/false)

示例（无需 clone）:
  curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- all
  # 非 root 可改用: su -c '... | bash'（有 sudo 也可用 sudo bash）
EOF
}

# Load .env file if exists
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# Function to save environment variables to .env file
save_env_var() {
  local key="$1"
  local value="$2"
  
  if [[ -z "$value" ]]; then
    return
  fi

  if [[ ! -f .env ]]; then
    touch .env
  fi

  # Escape special characters for sed
  local escaped_value
  escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')

  if grep -q "^${key}=" .env; then
    # Update existing key
    sed -i "s/^${key}=.*/${key}=${escaped_value}/" .env
  else
    # Append new key
    echo "${key}=${value}" >> .env
  fi
}

interactive_menu() {
  clear
  printf "${GREEN}========================================${NC}\n"
  printf "${GREEN}   服务器初始化安装脚本${NC}\n"
  printf "${GREEN}========================================${NC}\n"
  printf "\n"
  printf "请选择安装场景:\n"
  printf "  ${YELLOW}1)${NC} 基础环境 (Base + Aliases + Security)\n"
  printf "  ${YELLOW}2)${NC} Docker 环境 (推荐, 含基础)\n"
  printf "  ${YELLOW}3)${NC} Node.js 环境 (含基础)\n"
  printf "  ${YELLOW}4)${NC} 全功能环境 (Docker + Node + 基础)\n"
  printf "  ${YELLOW}5)${NC} Web 服务环境 (Docker + Nginx + 基础)\n"
  printf "  ${YELLOW}6)${NC} 监控代理 (Nezha Agent)\n"
  printf "  ${YELLOW}7)${NC} 自定义选择\n"
  printf "  ${YELLOW}0)${NC} 退出\n"
  printf "\n"

  local choice
  read -p "请输入选项 [2]: " choice
  choice="${choice:-2}"

  case "$choice" in
    1) STEPS=(base aliases security) ;;
    2) STEPS=(base aliases security docker) ;;
    3) STEPS=(base aliases security node) ;;
    4) STEPS=(base aliases security docker node) ;;
    5) STEPS=(base aliases security docker nginx) ;;
    6) STEPS=(nezha) ;;
    7)
       printf "\n请选择步骤 (空格分隔，例如: base docker):\n"
       printf "可用步骤: base aliases security docker node nginx nezha\n"
       read -p "> " -a custom_steps
       STEPS=("${custom_steps[@]}")
       ;;
    0) exit 0 ;;
    *) die "无效选项" ;;
  esac

  # Check for Nginx requirements
  if [[ "${STEPS[*]}" =~ "nginx" ]]; then
     if [[ -z "$CONFIG_FILE" && -z "$CONFIG_URL" ]]; then
        printf "\n${YELLOW}检测到 Nginx 安装，需要配置信息:${NC}\n"
        read -p "请输入 domains.json 路径或 URL: " nginx_conf
        if [[ "$nginx_conf" =~ ^https?:// ]]; then
           CONFIG_URL="$nginx_conf"
           save_env_var "CONFIG_URL" "$CONFIG_URL"
        else
           CONFIG_FILE="$nginx_conf"
           save_env_var "CONFIG_FILE" "$CONFIG_FILE"
        fi

        if [[ "$NO_SSL" -eq 0 ]]; then
             if [[ -z "$CERTBOT_EMAIL" ]]; then
                 read -p "请输入 Certbot 邮箱 (SSL证书用): " CERTBOT_EMAIL
                 save_env_var "CERTBOT_EMAIL" "$CERTBOT_EMAIL"
             fi
        fi
     fi
  fi

  # Check for Nezha requirements
  if [[ "${STEPS[*]}" =~ "nezha" ]]; then
     if [[ -z "$NZ_SERVER" ]]; then
        printf "\n${YELLOW}检测到 Nezha 安装，需要配置信息:${NC}\n"
        read -p "Nezha Server (host:port): " NZ_SERVER
        save_env_var "NZ_SERVER" "$NZ_SERVER"
     fi
     if [[ -z "$NZ_CLIENT_SECRET" ]]; then
        read -p "Nezha Client Secret: " NZ_CLIENT_SECRET
        save_env_var "NZ_CLIENT_SECRET" "$NZ_CLIENT_SECRET"
     fi
  fi
}

require_value() {
  local opt="$1"
  local val="${2:-}"
  [[ -n "$val" ]] || die "参数 $opt 缺少值。"
}

validate_step() {
  case "$1" in
    base|aliases|security|docker|node|nginx|nezha) return 0 ;;
    *) return 1 ;;
  esac
}

detect_primary_user() {
  awk -F: '
    ($3 >= 1000) && ($1 != "nobody") && ($7 !~ /(nologin|false)$/) { print $1; exit }
  ' /etc/passwd
}

steps_need_target_user() {
  for step in "${STEPS[@]}"; do
    case "$step" in
      aliases|docker|node)
        return 0
        ;;
    esac
  done
  return 1
}

normalize_target_user() {
  local auto_user=""

  if [[ -n "$TARGET_USER" ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    return 0
  fi

  auto_user="$(detect_primary_user || true)"
  if [[ -n "$auto_user" ]]; then
    if [[ -n "$TARGET_USER" ]]; then
      warn "目标用户 '${TARGET_USER}' 不存在，自动切换为 '${auto_user}'。"
    else
      log "自动使用目标用户: ${auto_user}"
    fi
    TARGET_USER="$auto_user"
    return 0
  fi

  if [[ -n "$TARGET_USER" ]]; then
    warn "目标用户 '${TARGET_USER}' 不存在，且未检测到常规用户，自动切换为 'root'。"
  else
    warn "未检测到常规用户，自动使用 root。"
  fi
  TARGET_USER="root"
}

run_dir_cmd() {
  local dir="$1"
  shift
  log "执行: $*"
  (
    cd "$dir"
    "$@"
  )
}

REPO="${REPO:-tuziapi/server-setup}"
REF="${REF:-main}"
WORKDIR_BASE="${WORKDIR_BASE:-/tmp}"
KEEP_WORKDIR=0
DRY_RUN=0

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
TIMEZONE="${TIMEZONE:-}"
SSH_PORT="${SSH_PORT:-22}"
ALLOW_PORTS="${ALLOW_PORTS:-}"
AUTO_ALLOW_LISTENING_PORTS="${AUTO_ALLOW_LISTENING_PORTS:-1}"
AUTO_ALLOW_EXCLUDE_PORTS="${AUTO_ALLOW_EXCLUDE_PORTS:-68/udp,546/udp}"
HARDEN_SSH="${HARDEN_SSH:-0}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-0}"
DOCKER_CHANNEL="${DOCKER_CHANNEL:-stable}"
NODE_VERSION="${NODE_VERSION:-lts/*}"
NVM_VERSION="${NVM_VERSION:-v0.40.4}"

CONFIG_FILE="${CONFIG_FILE:-}"
CONFIG_URL="${CONFIG_URL:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
NO_SSL=0
FORCE_NGINX=0

NZ_SERVER="${NZ_SERVER:-}"
NZ_TLS="${NZ_TLS:-false}"
NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:-}"

STEPS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)
      require_value "$1" "${2:-}"
      REPO="$2"
      shift 2
      ;;
    --ref|--branch)
      require_value "$1" "${2:-}"
      REF="$2"
      shift 2
      ;;
    --target-user)
      die "--target-user 参数已移除：脚本现在会自动选择目标用户。"
      ;;
    --timezone)
      require_value "$1" "${2:-}"
      TIMEZONE="$2"
      shift 2
      ;;
    --ssh-port)
      require_value "$1" "${2:-}"
      SSH_PORT="$2"
      shift 2
      ;;
    --allow-ports)
      require_value "$1" "${2:-}"
      ALLOW_PORTS="$2"
      shift 2
      ;;
    --disable-auto-allow-listening)
      AUTO_ALLOW_LISTENING_PORTS=0
      shift
      ;;
    --auto-allow-exclude-ports)
      require_value "$1" "${2:-}"
      AUTO_ALLOW_EXCLUDE_PORTS="$2"
      shift 2
      ;;
    --harden-ssh)
      HARDEN_SSH=1
      shift
      ;;
    --disable-password-auth)
      DISABLE_PASSWORD_AUTH=1
      HARDEN_SSH=1
      shift
      ;;
    --docker-channel)
      require_value "$1" "${2:-}"
      DOCKER_CHANNEL="$2"
      shift 2
      ;;
    --node-version)
      require_value "$1" "${2:-}"
      NODE_VERSION="$2"
      shift 2
      ;;
    --nvm-version)
      require_value "$1" "${2:-}"
      NVM_VERSION="$2"
      shift 2
      ;;
    --config-file)
      require_value "$1" "${2:-}"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --config-url)
      require_value "$1" "${2:-}"
      CONFIG_URL="$2"
      shift 2
      ;;
    --certbot-email)
      require_value "$1" "${2:-}"
      CERTBOT_EMAIL="$2"
      shift 2
      ;;
    --no-ssl)
      NO_SSL=1
      shift
      ;;
    --force-nginx|--force)
      FORCE_NGINX=1
      shift
      ;;
    --workdir)
      require_value "$1" "${2:-}"
      WORKDIR_BASE="$2"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ "$#" -gt 0 ]]; do
        STEPS+=("$1")
        shift
      done
      ;;
    -*)
      die "未知参数: $1（使用 --help 查看用法）"
      ;;
    *)
      STEPS+=("$1")
      shift
      ;;
  esac
done

if [[ "${#STEPS[@]}" -eq 0 ]]; then
  # Check if running interactively or if /dev/tty is available
  if [[ -t 0 ]] || [[ -e /dev/tty ]]; then
    # Re-open stdin from /dev/tty if needed
    if ! [[ -t 0 ]]; then
      exec 0</dev/tty
    fi
    interactive_menu
  else
    STEPS=(base aliases security docker)
  fi
elif [[ "${#STEPS[@]}" -eq 1 && "${STEPS[0]}" == "all" ]]; then
  STEPS=(base aliases security docker node)
fi

for step in "${STEPS[@]}"; do
  validate_step "$step" || die "未知步骤: $step"
done

if steps_need_target_user; then
  normalize_target_user
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'dry-run:\n'
  printf '  repo=%s\n' "$REPO"
  printf '  ref=%s\n' "$REF"
  printf '  target_user=%s\n' "$TARGET_USER"
  printf '  steps=%s\n' "${STEPS[*]}"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  die "未检测到 curl，请先安装 curl。"
fi

if [[ "${EUID}" -ne 0 ]]; then
  die "请使用 root 执行（可先用 su 提权后再运行；有 sudo 也可使用）。"
fi

mkdir -p "$WORKDIR_BASE"
RUN_DIR="$(mktemp -d "${WORKDIR_BASE%/}/server-setup.XXXXXX")"
cleanup() {
  if [[ "$KEEP_WORKDIR" -eq 0 ]]; then
    rm -rf "$RUN_DIR"
  else
    log "已保留临时目录: $RUN_DIR"
  fi
}
trap cleanup EXIT

archive_path="$RUN_DIR/repo.tar.gz"
download_url="https://codeload.github.com/${REPO}/tar.gz/${REF}"
log "下载仓库压缩包: $download_url"
curl -fsSL "$download_url" -o "$archive_path"

tar -xzf "$archive_path" -C "$RUN_DIR"
repo_name="${REPO##*/}"
REPO_DIR="$(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d -name "${repo_name}-*" | head -n 1)"
[[ -n "$REPO_DIR" ]] || die "解压失败，未找到仓库目录。"

if [[ -n "$CONFIG_URL" ]]; then
  CONFIG_FILE="$RUN_DIR/domains.json"
  log "下载 nginx 配置: $CONFIG_URL"
  curl -fsSL "$CONFIG_URL" -o "$CONFIG_FILE"
fi

log "执行步骤: ${STEPS[*]}"

for step in "${STEPS[@]}"; do
  log "开始步骤: $step"
  case "$step" in
    base)
      run_dir_cmd "$REPO_DIR" env TIMEZONE="$TIMEZONE" bash ./setup_base.sh
      ;;
    aliases)
      run_dir_cmd "$REPO_DIR" env TARGET_USER="$TARGET_USER" bash ./setup_aliases.sh
      ;;
    security)
      run_dir_cmd "$REPO_DIR" env \
        SSH_PORT="$SSH_PORT" \
        ALLOW_PORTS="$ALLOW_PORTS" \
        AUTO_ALLOW_LISTENING_PORTS="$AUTO_ALLOW_LISTENING_PORTS" \
        AUTO_ALLOW_EXCLUDE_PORTS="$AUTO_ALLOW_EXCLUDE_PORTS" \
        HARDEN_SSH="$HARDEN_SSH" \
        DISABLE_PASSWORD_AUTH="$DISABLE_PASSWORD_AUTH" \
        bash ./setup_security.sh
      ;;
    docker)
      run_dir_cmd "$REPO_DIR" env \
        TARGET_USER="$TARGET_USER" \
        DOCKER_CHANNEL="$DOCKER_CHANNEL" \
        bash ./setup_docker.sh
      ;;
    node)
      run_dir_cmd "$REPO_DIR" env \
        TARGET_USER="$TARGET_USER" \
        NODE_VERSION="$NODE_VERSION" \
        NVM_VERSION="$NVM_VERSION" \
        bash ./setup_nodejs.sh
      ;;
    nginx)
      [[ -n "$CONFIG_FILE" ]] || die "nginx 步骤需要 --config-file 或 --config-url。"
      [[ -f "$CONFIG_FILE" ]] || die "nginx 配置文件不存在: $CONFIG_FILE"
      nginx_cmd=(bash ./setup_nginx_proxy.sh --config "$CONFIG_FILE")
      if [[ "$NO_SSL" -eq 1 ]]; then
        nginx_cmd+=(--no-ssl)
      else
        [[ -n "$CERTBOT_EMAIL" ]] || die "nginx 启用 SSL 时请传入 --certbot-email。"
        nginx_cmd+=(--email "$CERTBOT_EMAIL")
      fi
      if [[ "$FORCE_NGINX" -eq 1 ]]; then
        nginx_cmd+=(--force)
      fi
      run_dir_cmd "$REPO_DIR" "${nginx_cmd[@]}"
      ;;
    nezha)
      run_dir_cmd "$REPO_DIR" env \
        NZ_SERVER="$NZ_SERVER" \
        NZ_TLS="$NZ_TLS" \
        NZ_CLIENT_SECRET="$NZ_CLIENT_SECRET" \
        bash ./setup_nezha.sh
      ;;
  esac
  log "完成步骤: $step"
done

log "全部步骤执行完成。"
