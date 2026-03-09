# server-setup

面向 Debian/Ubuntu 的服务器初始化脚本集合，覆盖基础环境、别名、安全基线、Docker、Node.js、Nginx 反向代理与 SSL。

设计目标：
- 直接可执行，尽量幂等。
- 每个脚本单一职责，可单独运行。
- 依赖公开地址，不需要登录 GitHub。

## 0. 无需 clone：curl 一键安装

提权方式：
- 已是 `root`：使用 `| bash`
- 非 `root`：优先使用 `su -c '... | bash'`
- 非 `root` 且有 `sudo`：也可使用 `| sudo bash`

默认步骤（`base aliases security docker`）：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash
```

全量步骤（含 `node`）：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- all
```

只执行指定步骤：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- base aliases node
```

Nginx + SSL（`domains.json` 从 URL 下载）：

```bash
curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- nginx --config-url https://example.com/domains.json --certbot-email you@example.com
```

说明：
- `install.sh` 会临时下载仓库压缩包执行，不会 `git clone`。
- 若默认分支不是 `main`，可追加 `--ref master`（或具体 tag/commit）。
- `nginx` 步骤需要 `--config-file` 或 `--config-url`。
- `nginx` 是安装步骤参数，必须放在 `bash -s --` 后，不要写成 `nginx curl ...`。
- `install.sh` 会自动选择目标用户（用于 aliases/docker/node），如需覆盖可设置环境变量 `TARGET_USER`。
- `security` 步骤默认会自动放行当前正在对外监听的端口，避免启用 UFW 后业务不可访问。
- 自动放行基于 `ss -lntup` 探测，仅对非 `127.0.0.1`/`::1` 监听端口生效（本机回环端口不会放行）。
- 如需关闭自动放行，可加 `--disable-auto-allow-listening` 并手动用 `--allow-ports` 指定端口。

如果你不是 root，可用：

```bash
su -c 'curl -fsSL https://raw.githubusercontent.com/tuziapi/server-setup/main/install.sh | bash -s -- all'
```

## 1. 脚本清单

| 脚本 | 作用 | 常用命令 |
|---|---|---|
| `install.sh` | 远程引导脚本：下载仓库压缩包并执行步骤（无需 clone） | `curl -fsSL .../install.sh \| bash -s -- all` |
| `setup_base.sh` | 安装基础软件（curl/git/jq/tmux/ufw/fail2ban 等）并拉起常用服务 | `bash setup_base.sh` |
| `setup_aliases.sh` | 为用户写入 `~/.server_aliases`，自动接入 `.bashrc/.zshrc` | `TARGET_USER=your_user bash setup_aliases.sh` |
| `setup_security.sh` | 配置 UFW + fail2ban，默认自动放行当前监听端口，支持 SSH 加固 | `SSH_PORT=22 ALLOW_PORTS=80,443 bash setup_security.sh` |
| `setup_docker.sh` | 使用 Docker 官方安装脚本安装 Docker | `TARGET_USER=your_user bash setup_docker.sh` |
| `setup_nodejs.sh` | 使用 nvm 官方安装脚本安装 Node.js（默认 LTS） | `TARGET_USER=your_user bash setup_nodejs.sh` |
| `setup_nginx_proxy.sh` | 按 `domains.json` 批量配置 Nginx 反向代理，可选自动签发证书 | `bash setup_nginx_proxy.sh --config domains.json --email you@example.com` |
| `setup_all.sh` | 一键执行多个步骤（默认 base+aliases+security+docker） | `TARGET_USER=your_user bash setup_all.sh` |

## 2. 推荐执行顺序

说明：以下命令默认以 `root` 执行；非 root 用户请先 `su` 提权（有 `sudo` 也可）。

1. `bash setup_base.sh`
2. `TARGET_USER=your_user bash setup_aliases.sh`
3. `SSH_PORT=22 ALLOW_PORTS=80,443 bash setup_security.sh`
4. `TARGET_USER=your_user bash setup_docker.sh`
5. `TARGET_USER=your_user bash setup_nodejs.sh`（如需 Node.js）
6. `bash setup_nginx_proxy.sh --config domains.json --email you@example.com`（如需反代 + SSL）

如果想一次执行（不含 nginx）：

```bash
TARGET_USER=your_user bash setup_all.sh all
```

## 3. Nginx 反向代理配置

1. 复制示例配置：

```bash
cp domains.example.json domains.json
```

2. 编辑 `domains.json`：

```json
{
  "domains": [
    {
      "domain": "api.example.com",
      "target_host": "127.0.0.1",
      "target_port": 3000,
      "completed": false
    }
  ]
}
```

3. 执行脚本：

```bash
bash setup_nginx_proxy.sh --config domains.json --email you@example.com
```

可选参数：
- `--no-ssl`：只写 Nginx 反代，不申请证书。
- `--force`：忽略 `completed=true` 强制重建。
- `CERTBOT_EMAIL=...`：可用环境变量代替 `--email`。

## 3.1 后续手动放开端口（UFW）

说明：`security` 步骤只会自动放行“执行时已在监听”的端口。后续新上线服务（新端口）需要手动放行。

常用命令：

```bash
# 查看当前规则
ufw status numbered

# 放行 TCP 端口（示例：3000）
ufw allow 3000/tcp

# 放行 UDP 端口（示例：3478）
ufw allow 3478/udp

# 删除规则（按编号，编号来自 status numbered）
ufw delete <rule_number>

# 重新加载规则
ufw reload
```

建议：
- 对外服务新开端口后，先 `ufw allow ...` 再对外发布。
- 只放行业务必需端口，避免暴露不必要服务。
- 若端口没有自动放行，先执行 `ss -tulpn | grep :端口`，确认服务是否仅监听 `127.0.0.1`/`::1`。

## 4. 常用环境变量

- `TARGET_USER`：要写入别名/Node 环境/Docker 组的目标用户。
- `TIMEZONE`：例如 `Asia/Shanghai`，用于 `setup_base.sh`。
- `SSH_PORT`：SSH 端口，默认 `22`。
- `ALLOW_PORTS`：额外开放端口，逗号分隔，例如 `80,443,8080/tcp`。
- `AUTO_ALLOW_LISTENING_PORTS`：是否自动放行当前监听端口，默认 `1`。
- `AUTO_ALLOW_EXCLUDE_PORTS`：自动放行排除列表，默认 `68/udp,546/udp`。
- `HARDEN_SSH=1`：启用 SSH 基础加固（`PermitRootLogin prohibit-password`）。
- `DISABLE_PASSWORD_AUTH=1`：配合 `HARDEN_SSH=1` 禁用 SSH 密码登录。
- `DOCKER_CHANNEL`：Docker 渠道，默认 `stable`。
- `NODE_VERSION`：Node 版本，默认 `lts/*`。

## 4.1 常用工具说明

- `dnsutils`：DNS 排障工具集（`dig`/`nslookup`/`host`），用于排查域名解析，尤其在 Nginx + Certbot 配置证书时很常用。
- `software-properties-common`：提供 `add-apt-repository` 等能力。部分发行版镜像可能不提供该包，`setup_base.sh` 会自动跳过不可用包，不影响其他常用工具安装。

## 5. 仓库内一键入口脚本

```bash
# 默认执行: base aliases security docker
TARGET_USER=your_user bash setup_all.sh

# 执行指定步骤
TARGET_USER=your_user bash setup_all.sh base aliases node

# 包含 node 的全量步骤（不含 nginx）
TARGET_USER=your_user bash setup_all.sh all
```

## 6. 参考的 GitHub 开源项目（均为公开地址）

- Docker 安装脚本: https://github.com/docker/docker-install
- nvm: https://github.com/nvm-sh/nvm
- Oh My Zsh 常用别名插件: https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/common-aliases
- Certbot: https://github.com/certbot/certbot

以上项目均可匿名访问，本仓库脚本中的下载地址也不需要 GitHub 账号登录。

## 7. 自助帮助

每个脚本均支持 `-h/--help`，可直接查看用法，例如：

```bash
bash install.sh --help
bash setup_security.sh --help
bash setup_nginx_proxy.sh --help
```
