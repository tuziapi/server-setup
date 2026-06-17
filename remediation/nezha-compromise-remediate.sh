#!/usr/bin/env bash
set -Eeuo pipefail

# Remediate the Nezha Dashboard command-exec compromise seen on multiple nodes.
# Default mode performs changes. Use --dry-run to preview.

DRY_RUN=0
KEEP_NEZHA_DISABLED=1
FORENSICS_BASE="/root/forensics"
TS="$(date +%Y%m%d-%H%M%S)"
CASE_DIR="${FORENSICS_BASE}/nezha-remediate-${TS}"

BAD_IPS=(
  "207.58.173.192"
  "103.106.228.23"
)

BAD_DOMAINS=(
  "jdjjdjiysiys.xyz"
)

TELNET_SCAN_PORTS=(
  "23"
  "2323"
)

SUSPICIOUS_PROCESS_REGEX='nezha|probe-agent|/tmp/b|/var/tmp/b|/dev/shm/b|jdjjdjiysiys|207\.58\.173\.192|103\.106\.228\.23|agent\.sh|609f82b|d72ddfb|kinsing|xmrig|mirai'

BAD_KEY_COMMENTS=(
  "gary@gary"
)

BAD_KEY_BLOBS=(
  "AAAAC3NzaC1lZDI1NTE5AAAAIMMDxNliLAR1lLp5koxMHQtdCN0cNrV9HQbtzaDfNu8J"
)

BAD_FILE_GLOBS=(
  "/tmp/b"
  "/tmp/probe-agent"
  "/var/tmp/b"
  "/dev/shm/b"
  "/opt/nezha/agent/agent.sh"
  "/opt/nezha/agent/config-p029m.yml"
  "/opt/nezha/agent/config-smzqe.yml"
  "/opt/nezha/agent/config-bvusf.yml"
  "/opt/nezha/agent/config-*.yml"
  "/root/agent.sh"
)

SUSPICIOUS_NEZHA_CONFIG_GLOBS=(
  "/opt/nezha/agent/config*.yml"
)

usage() {
  cat <<'USAGE'
Usage: ./remediation/nezha-compromise-remediate.sh [--dry-run] [--allow-nezha-restart]

Actions:
  - Back up matching suspicious files to /root/forensics/nezha-remediate-<timestamp>/
  - Back up deleted-but-running /tmp/b style process images from /proc/<pid>/exe
  - Stop/disable suspicious nezha-agent-* systemd services
  - Remove known malicious files and configs
  - Remove the gary@gary attacker SSH key from /root/.ssh/authorized_keys
  - Set /opt/nezha/agent/config*.yml disable_command_execute: true
  - Stop and disable the legitimate nezha-agent.service by default
  - Block known C2 IPs and outbound telnet scan ports 23/2323
  - Persist iptables rules through /etc/iptables/rules.v4 when iptables-save is available
  - Blackhole known malicious domains in /etc/hosts
  - Print verification output

Options:
  --dry-run              Show actions without changing files/services.
  --allow-nezha-restart  Do not keep nezha-agent.service disabled. Still sets
                         disable_command_execute: true before restart.
  -h, --help             Show this help.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

run() {
  if (( DRY_RUN )); then
    printf 'DRY-RUN: %q' "$1"
    shift || true
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

unit_file_exists() {
  local name="$1"
  systemctl list-unit-files --no-pager "${name}" 2>/dev/null | awk '{print $1}' | grep -qx "${name}"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root." >&2
    exit 1
  fi
}

ensure_case_dir() {
  if (( DRY_RUN )); then
    log "Forensics directory would be ${CASE_DIR}"
  else
    mkdir -p "${CASE_DIR}"
    chmod 700 "${CASE_DIR}"
    log "Forensics directory: ${CASE_DIR}"
  fi
}

backup_path() {
  local path="$1"
  [[ -e "${path}" ]] || return 0

  local rel dest
  rel="${path#/}"
  dest="${CASE_DIR}/${rel//\//__}"

  if (( DRY_RUN )); then
    log "Would back up ${path} -> ${dest}"
  else
    cp -a -- "${path}" "${dest}"
    log "Backed up ${path} -> ${dest}"
  fi
}

expand_existing() {
  local pattern="$1"
  local matches=()
  shopt -s nullglob
  matches=( ${pattern} )
  shopt -u nullglob
  printf '%s\n' "${matches[@]:-}"
}

stop_disable_unit() {
  local unit="$1"
  local name
  name="$(basename "${unit}")"

  backup_path "${unit}"
  if systemctl list-unit-files --no-pager "${name}" >/dev/null 2>&1 || [[ -e "${unit}" ]]; then
    log "Stopping/disabling ${name}"
    run systemctl stop "${name}" || true
    run systemctl disable "${name}" || true
  fi
}

remove_path() {
  local path="$1"
  [[ -e "${path}" ]] || return 0
  backup_path "${path}"
  log "Removing ${path}"
  run rm -f -- "${path}"
}

backup_proc_exe() {
  local pid="$1"
  local exe_link="/proc/${pid}/exe"
  [[ -e "${exe_link}" ]] || return 0

  local target dest
  target="$(readlink "${exe_link}" 2>/dev/null || true)"
  [[ -n "${target}" ]] || return 0

  dest="${CASE_DIR}/proc_${pid}_exe.bin"
  if (( DRY_RUN )); then
    log "Would back up process image PID ${pid} (${target}) -> ${dest}"
  else
    cp -- "${exe_link}" "${dest}" 2>/dev/null || true
    if [[ -s "${dest}" ]]; then
      log "Backed up process image PID ${pid} (${target}) -> ${dest}"
    else
      rm -f -- "${dest}"
    fi
  fi
}

discover_ioc_pids() {
  local pid exe cmd

  ps -eo pid=,cmd= 2>/dev/null \
    | grep -Ei "${SUSPICIOUS_PROCESS_REGEX}" \
    | grep -vE 'grep -Ei|fix_nezha_compromise\.sh|nezha-compromise-remediate\.sh' \
    | awk '{print $1}' || true

  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [[ -r "/proc/${pid}/cmdline" ]] || continue
    exe="$(readlink "/proc/${pid}/exe" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    if [[ "${exe}" =~ /tmp/b\ \(deleted\)|/var/tmp/b\ \(deleted\)|/dev/shm/b\ \(deleted\) ]] \
      || [[ "${cmd}" =~ /tmp/b|/var/tmp/b|/dev/shm/b|probe-agent|jdjjdjiysiys ]]; then
      printf '%s\n' "${pid}"
    fi
  done
}

kill_ioc_processes() {
  log "Killing known malicious processes when present"

  local pids
  pids="$(discover_ioc_pids | sort -nu || true)"
  [[ -n "${pids}" ]] || return 0

  local pid
  for pid in ${pids}; do
    backup_proc_exe "${pid}"
  done

  log "Killing suspicious PIDs: ${pids//$'\n'/ }"
  if (( DRY_RUN )); then
    log "Would kill: ${pids//$'\n'/ }"
  else
    kill ${pids} 2>/dev/null || true
    sleep 1
    pids="$(discover_ioc_pids | sort -nu || true)"
    if [[ -n "${pids}" ]]; then
      log "Processes survived SIGTERM; sending SIGKILL: ${pids//$'\n'/ }"
      kill -9 ${pids} 2>/dev/null || true
    fi
  fi
}

discover_suspicious_nezha_units() {
  local unit
  systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^nezha-agent-.+\.service$' || true

  shopt -s nullglob
  for unit in /etc/systemd/system/nezha-agent-*.service; do
    basename "${unit}"
  done
  shopt -u nullglob
}

unit_path_for_name() {
  local name="$1"
  local path

  path="$(systemctl show -p FragmentPath --value "${name}" 2>/dev/null || true)"
  if [[ -n "${path}" && "${path}" != "/dev/null" ]]; then
    printf '%s\n' "${path}"
  elif [[ -e "/etc/systemd/system/${name}" ]]; then
    printf '%s\n' "/etc/systemd/system/${name}"
  fi
}

discover_suspicious_nezha_configs() {
  local cfg

  shopt -s nullglob
  for cfg in "${SUSPICIOUS_NEZHA_CONFIG_GLOBS[@]}"; do
    printf '%s\n' ${cfg}
  done
  shopt -u nullglob

  ps -eo cmd \
    | sed -nE 's#.*nezha-agent[[:space:]].*-c[[:space:]]+("?)(/opt/nezha/agent/config[^" ]+\.yml)\1.*#\2#p' \
    | sort -u || true
}

remediate_units_and_files() {
  log "Removing known Nezha backdoor units"
  local unit path
  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    path="$(unit_path_for_name "${unit}")"
    if [[ -n "${path}" ]]; then
      stop_disable_unit "${path}"
      remove_path "${path}"
    else
      log "Stopping/disabling ${unit}"
      run systemctl stop "${unit}" || true
      run systemctl disable "${unit}" || true
    fi
  done < <(discover_suspicious_nezha_units | sort -u)

  log "Removing known malicious files"
  local pattern
  for pattern in "${BAD_FILE_GLOBS[@]}"; do
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      remove_path "${path}"
    done < <(expand_existing "${pattern}")
  done

  log "Reloading systemd"
  run systemctl daemon-reload || true
}

fix_authorized_keys() {
  local ak="/root/.ssh/authorized_keys"
  [[ -e "${ak}" ]] || return 0

  backup_path "${ak}"
  log "Removing known attacker SSH key from ${ak}"

  if (( DRY_RUN )); then
    grep -En "$(IFS='|'; echo "${BAD_KEY_COMMENTS[*]}|${BAD_KEY_BLOBS[*]}")" "${ak}" || true
    return 0
  fi

  local tmp new
  tmp="$(mktemp)"
  new="$(mktemp)"
  if ! cp -a -- "${ak}" "${tmp}"; then
    log "WARNING: could not copy ${ak}; skipping authorized_keys cleanup"
    rm -f -- "${tmp}" "${new}"
    return 0
  fi
  local expr=""
  local item
  for item in "${BAD_KEY_COMMENTS[@]}" "${BAD_KEY_BLOBS[@]}"; do
    expr="${expr:+${expr}|}${item}"
  done
  grep -Ev -- "${expr}" "${tmp}" > "${new}" || true

  if cmp -s "${tmp}" "${new}"; then
    log "No known attacker SSH key found in ${ak}"
    rm -f -- "${tmp}" "${new}"
    return 0
  fi

  if command -v chattr >/dev/null 2>&1; then
    chattr -i "${ak}" 2>/dev/null || true
  fi

  if cp -- "${new}" "${ak}" 2>/dev/null; then
    chmod 600 "${ak}" 2>/dev/null || log "WARNING: chmod 600 failed for ${ak}"
    log "Updated ${ak}"
  else
    log "WARNING: could not update ${ak}; file may be immutable or protected. Manual fix required."
    log "WARNING: cleaned replacement saved at ${CASE_DIR}/authorized_keys.cleaned"
    cp -- "${new}" "${CASE_DIR}/authorized_keys.cleaned" 2>/dev/null || true
  fi
  rm -f -- "${tmp}" "${new}"
}

set_command_execute_disabled() {
  local cfg="$1"
  [[ -e "${cfg}" ]] || return 0

  backup_path "${cfg}"
  log "Setting disable_command_execute: true in ${cfg}"

  if (( DRY_RUN )); then
    grep -n '^disable_command_execute:' "${cfg}" || true
    return 0
  fi

  if grep -q '^disable_command_execute:' "${cfg}"; then
    sed -i 's/^disable_command_execute:.*/disable_command_execute: true/' "${cfg}"
  else
    printf '\ndisable_command_execute: true\n' >> "${cfg}"
  fi
}

fix_nezha_configs() {
  local cfg
  while IFS= read -r cfg; do
    [[ -n "${cfg}" ]] || continue
    set_command_execute_disabled "${cfg}"
  done < <(discover_suspicious_nezha_configs | sort -u)
}

handle_legit_nezha() {
  if ! unit_file_exists nezha-agent.service; then
    log "nezha-agent.service not installed; skipping legitimate agent service handling"
    return 0
  fi

  if (( KEEP_NEZHA_DISABLED )); then
    log "Stopping and disabling legitimate nezha-agent.service until Dashboard secrets are rotated"
    run systemctl stop nezha-agent.service || true
    run systemctl disable nezha-agent.service || true
    run systemctl reset-failed nezha-agent.service || true
  else
    log "Restarting legitimate nezha-agent.service with command execution disabled"
    run systemctl restart nezha-agent.service || true
  fi
}

iptables_ensure_output_rule() {
  command -v iptables >/dev/null 2>&1 || return 0

  if iptables -C OUTPUT "$@" >/dev/null 2>&1; then
    log "iptables OUTPUT rule already exists: $*"
  else
    log "Adding iptables OUTPUT rule: $*"
    run iptables -I OUTPUT "$@" || true
  fi
}

persist_iptables_rules() {
  command -v iptables-save >/dev/null 2>&1 || return 0

  if (( DRY_RUN )); then
    log "Would save iptables rules to /etc/iptables/rules.v4"
    return 0
  fi

  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  log "Saved iptables rules to /etc/iptables/rules.v4"

  if command -v iptables-restore >/dev/null 2>&1; then
    if [[ ! -e /lib/systemd/system/netfilter-persistent.service && ! -e /etc/systemd/system/netfilter-persistent.service ]]; then
      cat > /lib/systemd/system/netfilter-persistent.service <<'UNIT'
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
      log "Created /lib/systemd/system/netfilter-persistent.service"
    fi
    systemctl daemon-reload || true
    systemctl enable netfilter-persistent.service || true
    iptables-restore --test /etc/iptables/rules.v4 || true
  fi
}

block_network_iocs() {
  local ip domain port ports_csv ufw_active=0

  ports_csv="$(IFS=,; echo "${TELNET_SCAN_PORTS[*]}")"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
      ufw_active=1
    fi
    for ip in "${BAD_IPS[@]}"; do
      if ufw status numbered 2>/dev/null | grep -q "${ip}.*DENY OUT"; then
        log "UFW deny-out already exists for ${ip}"
      else
        log "Adding UFW deny-out for ${ip}"
        run ufw deny out to "${ip}" || true
      fi
    done
    for port in "${TELNET_SCAN_PORTS[@]}"; do
      log "Adding UFW deny-out for tcp/${port}"
      run ufw deny out "${port}/tcp" || true
    done
    if (( ! ufw_active )); then
      log "UFW is installed but inactive; adding iptables runtime rules as the active protection"
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    for ip in "${BAD_IPS[@]}"; do
      iptables_ensure_output_rule -d "${ip}" -j DROP
    done
    iptables_ensure_output_rule -p tcp -m multiport --dports "${ports_csv}" -j REJECT --reject-with tcp-reset
    persist_iptables_rules
  else
    log "iptables not found; cannot add active runtime firewall rules"
  fi

  backup_path /etc/hosts
  for domain in "${BAD_DOMAINS[@]}"; do
    if grep -qE "^[[:space:]]*(0\.0\.0\.0|::)[[:space:]]+${domain//./\\.}([[:space:]]|$)" /etc/hosts; then
      log "hosts blackhole already exists for ${domain}"
    else
      log "Adding hosts blackhole for ${domain}"
      if (( DRY_RUN )); then
        log "Would append hosts entries for ${domain}"
      else
        printf '\n0.0.0.0 %s\n:: %s\n' "${domain}" "${domain}" >> /etc/hosts
      fi
    fi
  done
}

write_ioc_report() {
  (( DRY_RUN )) && return 0

  {
    echo "timestamp=${TS}"
    echo "hostname=$(hostname -f 2>/dev/null || hostname)"
    echo
    echo "[sha256 backups]"
    if compgen -G "${CASE_DIR}/*" >/dev/null; then
      sha256sum "${CASE_DIR}"/* 2>/dev/null || true
    fi
    echo
	    echo "[active ioc processes]"
	    ps -eo pid,ppid,user,lstart,cmd --sort=start_time | grep -Ei "${SUSPICIOUS_PROCESS_REGEX}" | grep -v grep || true
	    echo
	    echo "[ioc network]"
	    ss -tupna 2>/dev/null | grep -Ei '207\.58\.173\.192|103\.106\.228\.23|:8088|:23|:2323|nezha-agent|probe-agent|/tmp/b' || true
	    echo
	    echo "[syn-sent]"
	    ss -Htnp state syn-sent 2>/dev/null || true
	    echo
	    echo "[nezha configs]"
	    grep -Hn '^disable_command_execute:' /opt/nezha/agent/config*.yml 2>/dev/null || true
    echo
    echo "[authorized_keys size]"
    wc -c /root/.ssh/authorized_keys 2>/dev/null || true
  } > "${CASE_DIR}/remediation-report.txt"

  log "Wrote report: ${CASE_DIR}/remediation-report.txt"
}

verify() {
  log "Verification summary"
  echo "---- processes ----"
  ps -eo pid,ppid,user,lstart,cmd --sort=start_time | grep -Ei "${SUSPICIOUS_PROCESS_REGEX}" | grep -v grep || true
  echo "---- network ----"
  ss -tupna 2>/dev/null | grep -Ei '207\.58\.173\.192|103\.106\.228\.23|:8088|:23|:2323|nezha-agent|probe-agent|/tmp/b' || true
  echo "---- syn-sent ----"
  ss -Htnp state syn-sent 2>/dev/null || true
  echo "---- services ----"
  systemctl list-units --type=service --all --no-pager | grep -Ei 'nezha|probe|609f82b|d72ddfb|agent|qemu' || true
  echo "---- nezha command execution ----"
  grep -Hn '^disable_command_execute:' /opt/nezha/agent/config*.yml 2>/dev/null || true
  echo "---- authorized_keys ----"
  wc -c /root/.ssh/authorized_keys 2>/dev/null || true
  grep -En 'gary@gary|AAAAC3NzaC1lZDI1NTE5AAAAIMMDxNliLAR1lLp5koxMHQtdCN0cNrV9HQbtzaDfNu8J' /root/.ssh/authorized_keys 2>/dev/null || true
  echo "---- ufw c2 deny ----"
  ufw status numbered 2>/dev/null | grep -E '207\.58\.173\.192|103\.106\.228\.23|Status' || true
  echo "---- iptables c2 reject ----"
  iptables -S OUTPUT 2>/dev/null | grep -E '207\.58\.173\.192|103\.106\.228\.23|dports 23,2323' || true
  echo "---- persistent iptables ----"
  grep -nE '207\.58\.173\.192|103\.106\.228\.23|dports 23,2323' /etc/iptables/rules.v4 2>/dev/null || true
  echo "---- hosts domain block ----"
  grep -En 'jdjjdjiysiys\.xyz' /etc/hosts 2>/dev/null || true
}

main() {
  while (($#)); do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --allow-nezha-restart)
        KEEP_NEZHA_DISABLED=0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  need_root
  ensure_case_dir
  kill_ioc_processes
  remediate_units_and_files
  fix_authorized_keys
  fix_nezha_configs
  handle_legit_nezha
  block_network_iocs
  write_ioc_report
  verify

  log "Done. Rotate Nezha Dashboard agent_secret_key/jwt_secret_key before re-enabling agents."
  if (( KEEP_NEZHA_DISABLED )); then
    log "nezha-agent.service was intentionally left disabled."
  fi
}

main "$@"
