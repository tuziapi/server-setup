# Nezha 入侵处置经验总结

本文总结 2026 年 6 月一次因主机对外 telnet 扫描而被 EGP Cloudblock RBL 列入黑名单的处置经验，并说明这些经验如何沉淀到 `server-setup` 自动化脚本中。

## 入侵特征

RBL 报告显示主机向外部随机 IP 的 TCP `23` 端口发起扫描。现场排查确认不是误报：

- 被举报 IP 确实绑定在当前主机上。
- `ss -Htnp state syn-sent` 显示大量对外 `23/2323` 半连接扫描。
- 扫描进程为 root 用户，进程可执行文件显示为 `/tmp/b (deleted)`。
- 父进程和子进程都来自同一个已删除的 `/tmp/b` 镜像。
- 取证目录中已有 `/tmp/b`、`/tmp/probe-agent`、`/opt/nezha/agent/agent.sh` 等可疑文件。

最可能的入口是 Nezha Dashboard 的命令执行能力被滥用。事故节点上的 Nezha agent 配置仍为 `disable_command_execute: false`，如果 Dashboard 凭据或密钥泄露，攻击者可通过 Dashboard 向 agent 下发命令。

## 关键检测命令

排查时必须使用宿主机真实视图，不要只看沙箱内进程：

```bash
ip -brief addr
ss -Htnp state syn-sent
ps auxww --sort=-%cpu
readlink -f /proc/<pid>/exe
tr '\0' ' ' </proc/<pid>/cmdline
find /tmp /var/tmp /dev/shm -maxdepth 2 -type f -printf '%p %s %TY-%Tm-%Td %TH:%TM %m\n'
```

本次事故里，单靠 `pgrep -f /tmp/b` 不可靠。恶意程序启动后会删除落地文件，只能通过 `/proc/<pid>/exe` 看到 `/tmp/b (deleted)`。

## 立即止血

先阻断扫描和 C2，再做深度清理：

```bash
iptables -I OUTPUT -p tcp -m multiport --dports 23,2323 -j REJECT --reject-with tcp-reset
iptables -I OUTPUT -d 207.58.173.192/32 -j DROP
iptables -I OUTPUT -d 103.106.228.23/32 -j DROP
```

杀进程前先复制内存中的样本：

```bash
mkdir -p /root/forensics/<case>
cp /proc/<pid>/exe /root/forensics/<case>/proc_<pid>_exe.bin
sha256sum /root/forensics/<case>/proc_<pid>_exe.bin
```

进程处理策略：先发 `SIGTERM`，仍存活再发 `SIGKILL`。

## 清理原则

清理脚本应覆盖以下行为：

- 同时通过命令行和 `/proc/<pid>/exe` 发现 IOC 进程。
- 杀进程前备份已删除但仍运行的进程镜像。
- 清理 `/tmp`、`/var/tmp`、`/dev/shm`、`/opt/nezha/agent` 中的已知恶意文件。
- 清理可疑 `nezha-agent-*` systemd 服务。
- 将所有 `/opt/nezha/agent/config*.yml` 写入 `disable_command_execute: true`。
- Dashboard 密钥轮换前，默认停止并禁用 `nezha-agent.service`。
- 尽可能移除已知攻击者 SSH key，但遇到 immutable 或权限问题时不能中断后续处置。
- 保存 iptables 规则，并确保重启后能恢复。

## 持久化防护经验

仅添加 runtime iptables 规则不够。事故节点上存在 `/etc/iptables/rules.v4`，但 `iptables.service` 和 `ip6tables.service` 是指向缺失 `netfilter-persistent.service` 的坏链接，重启后规则可能丢失。

因此项目现在会在需要时创建最小 `netfilter-persistent.service`：

```ini
[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes
```

这样出站扫描阻断规则会在重启后恢复。

## 是否需要重装

低风险节点可以先清理、轮换密钥并观察，但必须满足：

- 无 IOC 进程残留。
- 无对外扫描连接。
- Nezha 命令执行已禁用。
- 已知 C2 和 `23/2323` 出站扫描端口已持久阻断。
- 观察 24-72 小时没有复发。

以下情况建议重装系统：

- 节点承载高价值业务或敏感数据。
- 节点上保存数据库凭据、支付凭据、上游 API token 等重要密钥。
- 无法确认 root 环境是否被深度篡改。
- 清理后再次出现 `/tmp/b (deleted)` 或 `23/2323` 扫描。

原因很简单：攻击者一旦获得 root 命令执行权限，就无法 100% 证明系统仍可信。

## 必须轮换的凭据

即使攻击者不一定拿到了 root 密码明文，也要按 root 已被攻陷处理：

- 修改 root 密码。
- 重建 `/root/.ssh/authorized_keys`，只保留可信公钥。
- 轮换 Nezha `agent_secret_key` 和 `jwt_secret_key`。
- 轮换主机上的 API key、数据库密码、服务 token。
- 检查 shell history、本地 `.env` 和服务配置中是否有敏感信息。

## 已沉淀到项目的自动化

新增 `setup_incident_hardening.sh`，用于重装后或已清理节点：

- 安装 iptables 相关工具。
- 阻断已知 C2 IP。
- 阻断出站 `23/2323`。
- 持久化 iptables 规则。
- 写入 Nezha `disable_command_execute: true`。
- 检查 root SSH key 状态。

新增 `remediation/nezha-compromise-remediate.sh`，用于未重装、疑似仍感染节点：

- 复制内存中恶意进程样本。
- 杀 IOC 进程。
- 删除已知恶意文件。
- 禁用 Nezha，等待 Dashboard 密钥轮换。

重装节点推荐：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash
```

未重装、疑似感染节点推荐：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- remediate --stop-nezha-agent
```
