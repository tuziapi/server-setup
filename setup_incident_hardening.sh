#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
用法:
  bash setup_incident_hardening.sh

可选环境变量:
  BLOCK_TELNET_SCAN_PORTS=1     阻断出站 tcp/23,tcp/2323（默认 1）
  BLOCK_KNOWN_C2=1              阻断已知 C2 IP（默认 1）
  KNOWN_C2_IPS=ip1,ip2          已知 C2 IP 列表
  TELNET_SCAN_PORTS=23,2323     出站扫描端口列表
  HARDEN_NEZHA=1                若存在 Nezha 配置，写入 disable_command_execute: true（默认 1）
  STOP_NEZHA_AGENT=0            是否停止并禁用 nezha-agent.service（默认 0）
  CHECK_ROOT_AUTHORIZED_KEYS=1  检查 /root/.ssh/authorized_keys 权限/属性/已知恶意 key（默认 1）

说明:
  - 面向重装后和事故后节点的防复发加固。
  - 不会默认开启 UFW；使用 iptables 直接添加出站阻断并保存到 /etc/iptables/rules.v4。
  - 若系统缺少 netfilter-persistent.service，会创建一个最小 systemd restore unit。
EOF
  exit 0
fi

require_root
detect_os

BLOCK_TELNET_SCAN_PORTS="${BLOCK_TELNET_SCAN_PORTS:-1}"
BLOCK_KNOWN_C2="${BLOCK_KNOWN_C2:-1}"
KNOWN_C2_IPS="${KNOWN_C2_IPS:-207.58.173.192,103.106.228.23}"
TELNET_SCAN_PORTS="${TELNET_SCAN_PORTS:-23,2323}"
HARDEN_NEZHA="${HARDEN_NEZHA:-1}"
STOP_NEZHA_AGENT="${STOP_NEZHA_AGENT:-0}"
CHECK_ROOT_AUTHORIZED_KEYS="${CHECK_ROOT_AUTHORIZED_KEYS:-1}"

BAD_KEY_REGEX='gary@gary|AAAAC3NzaC1lZDI1NTE5AAAAIMMDxNliLAR1lLp5koxMHQtdCN0cNrV9HQbtzaDfNu8J'
IOC_REGEX='nezha|probe-agent|/tmp/b|/var/tmp/b|/dev/shm/b|jdjjdjiysiys|207\.58\.173\.192|103\.106\.228\.23|agent\.sh|609f82b|d72ddfb|kinsing|xmrig|mirai'

iptables_ensure_output_rule() {
  has_cmd iptables || return 0
  if iptables -C OUTPUT "$@" >/dev/null 2>&1; then
    log "iptables OUTPUT 已存在: $*"
  else
    log "添加 iptables OUTPUT: $*"
    iptables -I OUTPUT "$@"
  fi
}

persist_iptables_rules() {
  has_cmd iptables-save || return 0

  mkdir -p /etc/iptables
  iptables-save >/etc/iptables/rules.v4
  log "已保存 iptables 规则: /etc/iptables/rules.v4"

  has_cmd iptables-restore || return 0

  if [[ ! -e /lib/systemd/system/netfilter-persistent.service && ! -e /etc/systemd/system/netfilter-persistent.service ]]; then
    cat >/lib/systemd/system/netfilter-persistent.service <<'UNIT'
[Unit]
Description=Restore persistent iptables rules
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
ConditionFileNotEmpty=/etc/iptables/rules.v4

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    log "已创建 /lib/systemd/system/netfilter-persistent.service"
  fi

  if [[ "$OS_FAMILY" != "alpine" ]] && has_cmd systemctl; then
    systemctl daemon-reload || true
    systemctl enable netfilter-persistent.service || true
    iptables-restore --test /etc/iptables/rules.v4 || true
  fi
}

block_network_iocs() {
  if ! has_cmd iptables; then
    warn "未安装 iptables，跳过出站阻断。"
    return 0
  fi

  local ip port
  if [[ "$BLOCK_KNOWN_C2" == "1" ]]; then
    IFS=',' read -r -a c2_ips <<<"$KNOWN_C2_IPS"
    for ip in "${c2_ips[@]}"; do
      ip="$(echo "$ip" | xargs)"
      [[ -n "$ip" ]] || continue
      iptables_ensure_output_rule -d "$ip" -j DROP
    done
  fi

  if [[ "$BLOCK_TELNET_SCAN_PORTS" == "1" ]]; then
    IFS=',' read -r -a scan_ports <<<"$TELNET_SCAN_PORTS"
    for port in "${scan_ports[@]}"; do
      port="$(echo "$port" | xargs)"
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      iptables_ensure_output_rule -p tcp --dport "$port" -j REJECT --reject-with tcp-reset
    done
  fi

  persist_iptables_rules
}

harden_nezha_configs() {
  [[ "$HARDEN_NEZHA" == "1" ]] || return 0

  local cfg found=0
  shopt -s nullglob
  for cfg in /opt/nezha/agent/config*.yml; do
    found=1
    log "设置 Nezha disable_command_execute: true -> $cfg"
    backup_file "$cfg"
    if grep -q '^disable_command_execute:' "$cfg"; then
      sed -i 's/^disable_command_execute:.*/disable_command_execute: true/' "$cfg"
    else
      printf '\ndisable_command_execute: true\n' >>"$cfg"
    fi
  done
  shopt -u nullglob

  [[ "$found" -eq 1 ]] || log "未发现 /opt/nezha/agent/config*.yml，跳过 Nezha 配置加固。"

  if [[ "$STOP_NEZHA_AGENT" == "1" ]] && has_cmd systemctl && systemctl list-unit-files --no-pager nezha-agent.service >/dev/null 2>&1; then
    log "停止并禁用 nezha-agent.service"
    systemctl stop nezha-agent.service || true
    systemctl disable nezha-agent.service || true
    systemctl reset-failed nezha-agent.service || true
  elif has_cmd systemctl && systemctl is-active --quiet nezha-agent.service; then
    systemctl restart nezha-agent.service || true
  fi
}

check_root_authorized_keys() {
  [[ "$CHECK_ROOT_AUTHORIZED_KEYS" == "1" ]] || return 0

  local ak="/root/.ssh/authorized_keys"
  if [[ ! -e "$ak" ]]; then
    log "未发现 $ak"
    return 0
  fi

  chmod 700 /root/.ssh 2>/dev/null || true
  chmod 600 "$ak" 2>/dev/null || true

  if has_cmd lsattr; then
    log "authorized_keys 属性: $(lsattr "$ak" 2>/dev/null || true)"
  fi

  if grep -Eq "$BAD_KEY_REGEX" "$ak"; then
    warn "检测到已知恶意 SSH key，请立即清理: $ak"
    grep -En "$BAD_KEY_REGEX" "$ak" || true
  else
    log "未在 $ak 检测到已知恶意 SSH key。"
  fi
}

write_summary() {
  local out="/root/server-setup-hardening-report-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "timestamp=$(date -Is)"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo
    echo "[ioc processes]"
    ps -eo pid,ppid,user,lstart,cmd --sort=start_time | grep -Ei "$IOC_REGEX" | grep -v grep || true
    echo
    echo "[syn-sent]"
    ss -Htnp state syn-sent 2>/dev/null || true
    echo
    echo "[iptables output]"
    iptables -S OUTPUT 2>/dev/null || true
    echo
    echo "[nezha]"
    grep -Hn '^disable_command_execute:' /opt/nezha/agent/config*.yml 2>/dev/null || true
    systemctl show nezha-agent.service -p ActiveState -p UnitFileState --no-pager 2>/dev/null || true
  } >"$out"
  log "已写入加固报告: $out"
}

log "开始事故防复发加固 ..."
pkg_install iptables iproute2
block_network_iocs
harden_nezha_configs
check_root_authorized_keys
write_summary
log "事故防复发加固完成。"
