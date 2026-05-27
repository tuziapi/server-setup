#!/usr/bin/env bash
set -euo pipefail

readonly LOG_TS_FORMAT="+%Y-%m-%d %H:%M:%S"

log() {
  printf '[%s] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

warn() {
  printf '[%s] [WARN] %s\n' "$(date "$LOG_TS_FORMAT")" "$*" >&2
}

die() {
  printf '[%s] [ERROR] %s\n' "$(date "$LOG_TS_FORMAT")" "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 执行该脚本（可先通过 su 提权；有 sudo 也可用）。"
  fi
}

# --- OS Detection ---

OS_FAMILY=""
OS_ID=""
OS_VERSION=""

detect_os() {
  [[ -n "$OS_FAMILY" ]] && return 0

  if [[ ! -f /etc/os-release ]]; then
    die "无法检测操作系统：/etc/os-release 不存在。"
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-}"

  case "$OS_ID" in
    debian|ubuntu|linuxmint|pop|kali)
      OS_FAMILY="debian"
      ;;
    rhel|centos|almalinux|rocky|ol|scientific)
      OS_FAMILY="rhel"
      ;;
    fedora)
      OS_FAMILY="rhel"
      ;;
    alpine)
      OS_FAMILY="alpine"
      ;;
    arch|manjaro|endeavouros)
      OS_FAMILY="arch"
      ;;
    *)
      if [[ -n "${ID_LIKE:-}" ]]; then
        case "$ID_LIKE" in
          *debian*|*ubuntu*) OS_FAMILY="debian" ;;
          *rhel*|*centos*|*fedora*) OS_FAMILY="rhel" ;;
          *arch*) OS_FAMILY="arch" ;;
          *) die "不支持的发行版: $OS_ID (ID_LIKE=$ID_LIKE)" ;;
        esac
      else
        die "不支持的发行版: $OS_ID"
      fi
      ;;
  esac
}

# --- Package Name Mapping ---

map_pkg() {
  local pkg="$1"
  detect_os

  case "$OS_FAMILY" in
    debian)
      case "$pkg" in
        dnsutils)
          if apt-cache show dnsutils >/dev/null 2>&1; then
            echo "dnsutils"
          elif apt-cache show bind9-dnsutils >/dev/null 2>&1; then
            echo "bind9-dnsutils"
          else
            return 1
          fi
          ;;
        *) echo "$pkg" ;;
      esac
      ;;
    rhel)
      case "$pkg" in
        dnsutils) echo "bind-utils" ;;
        lsb-release|lsb_release) echo "redhat-lsb-core" ;;
        software-properties-common) return 1 ;;
        gnupg) echo "gnupg2" ;;
        cron) echo "cronie" ;;
        iproute2) echo "iproute" ;;
        python3-certbot-nginx) echo "python3-certbot-nginx" ;;
        *) echo "$pkg" ;;
      esac
      ;;
    alpine)
      case "$pkg" in
        dnsutils) echo "bind-tools" ;;
        lsb-release|lsb_release) return 1 ;;
        software-properties-common) return 1 ;;
        gnupg) echo "gnupg" ;;
        cron) return 1 ;;
        net-tools) echo "net-tools" ;;
        iproute2) echo "iproute2" ;;
        python3-certbot-nginx) echo "certbot-nginx" ;;
        vim) echo "vim" ;;
        *) echo "$pkg" ;;
      esac
      ;;
    arch)
      case "$pkg" in
        dnsutils) echo "bind" ;;
        lsb-release|lsb_release) echo "lsb-release" ;;
        software-properties-common) return 1 ;;
        gnupg) echo "gnupg" ;;
        cron) echo "cronie" ;;
        iproute2) echo "iproute2" ;;
        python3-certbot-nginx) echo "certbot-nginx" ;;
        ca-certificates) echo "ca-certificates" ;;
        *) echo "$pkg" ;;
      esac
      ;;
  esac
}

# --- EPEL Management (RHEL family) ---

_epel_ensured=0

ensure_epel() {
  [[ "$OS_FAMILY" == "rhel" ]] || return 0
  [[ "$_epel_ensured" -eq 0 ]] || return 0

  if ! rpm -q epel-release >/dev/null 2>&1; then
    log "启用 EPEL 仓库 ..."
    if has_cmd dnf; then
      dnf install -y epel-release 2>/dev/null || dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VERSION%%.*}.noarch.rpm"
    else
      yum install -y epel-release 2>/dev/null || yum install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VERSION%%.*}.noarch.rpm"
    fi
  fi
  _epel_ensured=1
}

# --- Package Management ---

_pkg_updated=0

pkg_update() {
  detect_os
  [[ "$_pkg_updated" -eq 0 ]] || return 0

  case "$OS_FAMILY" in
    debian)
      _apt_update_impl
      ;;
    rhel)
      log "执行包索引更新 ..."
      if has_cmd dnf; then
        dnf makecache -y >/dev/null 2>&1 || true
      else
        yum makecache -y >/dev/null 2>&1 || true
      fi
      ;;
    alpine)
      log "执行 apk update ..."
      apk update >/dev/null 2>&1
      ;;
    arch)
      log "执行 pacman -Sy ..."
      pacman -Sy --noconfirm >/dev/null 2>&1
      ;;
  esac
  _pkg_updated=1
}

pkg_install() {
  detect_os
  pkg_update

  local mapped_pkgs=()
  local skipped=()
  local pkg mapped

  for pkg in "$@"; do
    if mapped="$(map_pkg "$pkg")"; then
      mapped_pkgs+=("$mapped")
    else
      skipped+=("$pkg")
    fi
  done

  if [[ "${#skipped[@]}" -gt 0 ]]; then
    warn "以下包在当前系统 ($OS_ID) 上不适用，已跳过: ${skipped[*]}"
  fi

  [[ "${#mapped_pkgs[@]}" -gt 0 ]] || return 0

  log "安装软件包: ${mapped_pkgs[*]}"
  case "$OS_FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${mapped_pkgs[@]}"
      ;;
    rhel)
      if has_cmd dnf; then
        dnf install -y "${mapped_pkgs[@]}"
      else
        yum install -y "${mapped_pkgs[@]}"
      fi
      ;;
    alpine)
      apk add --no-cache "${mapped_pkgs[@]}"
      ;;
    arch)
      pacman -S --noconfirm --needed "${mapped_pkgs[@]}"
      ;;
  esac
}

pkg_available() {
  detect_os
  local pkg="$1"
  local mapped

  mapped="$(map_pkg "$pkg" 2>/dev/null)" || return 1

  case "$OS_FAMILY" in
    debian)
      apt-cache show "$mapped" >/dev/null 2>&1
      ;;
    rhel)
      if has_cmd dnf; then
        dnf info "$mapped" >/dev/null 2>&1
      else
        yum info "$mapped" >/dev/null 2>&1
      fi
      ;;
    alpine)
      apk info -e "$mapped" >/dev/null 2>&1 || apk search -x "$mapped" | grep -q .
      ;;
    arch)
      pacman -Si "$mapped" >/dev/null 2>&1
      ;;
  esac
}

# --- Service Management ---

svc_enable() {
  local svc="$1"
  detect_os

  case "$OS_FAMILY" in
    alpine)
      rc-update add "$svc" default 2>/dev/null || true
      ;;
    *)
      systemctl enable "$svc" >/dev/null 2>&1 || true
      ;;
  esac
}

svc_start() {
  local svc="$1"
  detect_os

  case "$OS_FAMILY" in
    alpine)
      rc-service "$svc" start 2>/dev/null || true
      ;;
    *)
      systemctl start "$svc" >/dev/null 2>&1 || true
      ;;
  esac
}

svc_enable_now() {
  local svc="$1"
  detect_os

  case "$OS_FAMILY" in
    alpine)
      rc-update add "$svc" default 2>/dev/null || true
      rc-service "$svc" start 2>/dev/null || true
      ;;
    *)
      systemctl enable --now "$svc" >/dev/null 2>&1 || true
      ;;
  esac
}

svc_reload() {
  local svc="$1"
  detect_os

  case "$OS_FAMILY" in
    alpine)
      rc-service "$svc" reload 2>/dev/null || rc-service "$svc" restart 2>/dev/null || true
      ;;
    *)
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc" 2>/dev/null || true
      ;;
  esac
}

svc_restart() {
  local svc="$1"
  detect_os

  case "$OS_FAMILY" in
    alpine)
      rc-service "$svc" restart 2>/dev/null || true
      ;;
    *)
      systemctl restart "$svc" >/dev/null 2>&1 || true
      ;;
  esac
}

svc_exists() {
  local svc="$1"
  detect_os

  case "$OS_FAMILY" in
    alpine)
      [[ -f "/etc/init.d/$svc" ]]
      ;;
    *)
      systemctl list-unit-files | grep -q "^${svc}\\.service"
      ;;
  esac
}

# --- Debian-specific apt helpers (used internally) ---

_apt_updated=0

disable_nodesource_repo() {
  [[ "$OS_FAMILY" == "debian" ]] || return 1

  local file changed=0

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$file" ]] || continue
    if grep -qE 'deb\.nodesource\.com' "$file"; then
      backup_file "$file"
      sed -ri '/deb\.nodesource\.com/s/^[[:space:]]*deb[[:space:]]/# disabled by server-setup: deb /' "$file"
      changed=1
    fi
  done

  [[ "$changed" -eq 1 ]]
}

_apt_update_impl() {
  [[ "$_apt_updated" -eq 0 ]] || return 0

  log "执行 apt-get update ..."
  local tmp_log
  tmp_log="$(mktemp)"
  local rc=0
  apt-get update -y >"$tmp_log" 2>&1 || rc=$?

  if grep -q 'deb.nodesource.com' "$tmp_log" && grep -Eq 'SHA1|sqv|Signing key .* not bound' "$tmp_log"; then
    warn "检测到 NodeSource 源签名不被当前策略接受，尝试自动禁用该源并重试 apt-get update。"
    if disable_nodesource_repo; then
      if ! apt-get update -y; then
        rm -f "$tmp_log"
        die "apt-get update 失败，请检查网络和软件源配置。"
      fi
      rc=0
    else
      warn "未能定位 NodeSource 源文件，请手动检查 /etc/apt/sources.list(.d)。"
    fi
  fi

  rm -f "$tmp_log"

  if [[ "$rc" -ne 0 ]]; then
    die "apt-get update 失败，请检查网络和软件源配置。"
  fi

  _apt_updated=1
}

# Legacy wrappers (kept for backward compatibility within this project)
apt_updated=0
apt_update_once() {
  detect_os
  if [[ "$OS_FAMILY" != "debian" ]]; then
    pkg_update
    return
  fi
  _apt_update_impl
  _pkg_updated=1
  apt_updated=1
}

apt_install() {
  detect_os
  if [[ "$OS_FAMILY" != "debian" ]]; then
    pkg_install "$@"
    return
  fi
  apt_update_once
  log "安装软件包: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# --- Utility Functions ---

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local bak="${file}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$file" "$bak"
    log "已备份: $bak"
  fi
}

append_once() {
  local line="$1"
  local file="$2"
  touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '%s\n' "$line" >>"$file"
  fi
}

user_home() {
  local user="$1"
  getent passwd "$user" | cut -d: -f6
}
