# 病毒/木马查杀脚本

本目录存放事故处置脚本，适用于已经确认或怀疑被入侵的节点。它们和普通初始化脚本分开维护，因为这些脚本会杀进程、删除已知恶意文件，并保存取证样本。

## Nezha 命令执行入侵清理

`nezha-compromise-remediate.sh` 用于处理 2026 年 6 月观察到的 Nezha Dashboard 命令执行能力被滥用后，下发木马并触发 telnet 扫描的场景。

典型 IOC：

- 进程可执行文件显示为 `/tmp/b (deleted)`，说明落地文件已被删除但进程仍在内存运行。
- 对外 `SYN-SENT` 扫描 TCP `23` 或 `2323`。
- 可疑文件：`/tmp/b`、`/tmp/probe-agent`、`/opt/nezha/agent/agent.sh`。
- 可疑 Nezha 配置：`/opt/nezha/agent/config-*.yml`。
- 已知 C2 IP：`207.58.173.192`、`103.106.228.23`。
- 已知攻击者 SSH key 标识：`gary@gary`。

先预演：

```bash
bash remediation/nezha-compromise-remediate.sh --dry-run
```

执行清理，并保持 Nezha Agent 禁用：

```bash
bash remediation/nezha-compromise-remediate.sh
```

执行清理，但允许合法 Nezha Agent 在写入 `disable_command_execute: true` 后重启：

```bash
bash remediation/nezha-compromise-remediate.sh --allow-nezha-restart
```

通过远程入口一键执行：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- remediate --stop-nezha-agent
```

## 脚本会做什么

- 将可疑文件备份到 `/root/forensics/nezha-remediate-<timestamp>/`。
- 从 `/proc/<pid>/exe` 复制已删除但仍运行的进程镜像。
- 对 IOC 进程先发 `SIGTERM`，未退出再发 `SIGKILL`。
- 删除已知恶意文件和可疑 Nezha systemd unit/config。
- 尽可能移除已知攻击者 SSH key。
- 将 Nezha 配置中的 `disable_command_execute` 设置为 `true`。
- 默认停止并禁用 `nezha-agent.service`。
- 阻断已知 C2 IP 和出站 TCP `23/2323`。
- 保存 iptables 规则到 `/etc/iptables/rules.v4`。
- 在取证目录中写入 remediation report。

## 清理后复查

执行后检查：

```bash
ss -Htnp state syn-sent
ps auxww | grep -Ei 'tmp/b|probe-agent|nezha|xmrig|mirai|kinsing|jdjjdjiysiys'
iptables -S OUTPUT
grep -Hn '^disable_command_execute:' /opt/nezha/agent/config*.yml 2>/dev/null
systemctl show nezha-agent.service -p ActiveState -p UnitFileState --no-pager
```

正常结果：

- 不应再有 `SYN-SENT` telnet 扫描连接。
- 不应再有 `/tmp/b`、`probe-agent`、`jdjjdjiysiys` 等 IOC 进程。
- 在 Dashboard 密钥轮换前，`nezha-agent.service` 建议保持 disabled/inactive。

## 清理后必须做的事

清理不等于主机已经完全可信。处置完成后仍需：

- 修改 root 密码。
- 重建 `/root/.ssh/authorized_keys`，只保留可信公钥。
- 轮换 Nezha `agent_secret_key` 和 `jwt_secret_key`。
- 轮换主机上的 API key、数据库密码和服务 token。
- 高价值节点或再次复感染节点建议直接重装系统。
