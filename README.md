# server-setup

面向 Debian/Ubuntu 的服务器初始化脚本集合，覆盖基础环境、别名、安全基线、Docker、Node.js、Nginx 反向代理与 SSL。

设计目标：
- 直接可执行，尽量幂等。
- 每个脚本单一职责，可单独运行。
- 依赖公开地址，不需要登录 GitHub。

## 1. 脚本清单

| 脚本 | 作用 | 常用命令 |
|---|---|---|
| `setup_base.sh` | 安装基础软件（curl/git/jq/tmux/ufw/fail2ban 等）并拉起常用服务 | `sudo bash setup_base.sh` |
| `setup_aliases.sh` | 为用户写入 `~/.server_aliases`，自动接入 `.bashrc/.zshrc` | `sudo TARGET_USER=ubuntu bash setup_aliases.sh` |
| `setup_security.sh` | 配置 UFW + fail2ban，支持可选 SSH 加固 | `sudo SSH_PORT=22 ALLOW_PORTS=80,443 bash setup_security.sh` |
| `setup_docker.sh` | 使用 Docker 官方安装脚本安装 Docker | `sudo TARGET_USER=ubuntu bash setup_docker.sh` |
| `setup_nodejs.sh` | 使用 nvm 官方安装脚本安装 Node.js（默认 LTS） | `sudo TARGET_USER=ubuntu bash setup_nodejs.sh` |
| `setup_nginx_proxy.sh` | 按 `domains.json` 批量配置 Nginx 反向代理，可选自动签发证书 | `sudo bash setup_nginx_proxy.sh --config domains.json --email you@example.com` |
| `setup_all.sh` | 一键执行多个步骤（默认 base+aliases+security+docker） | `sudo TARGET_USER=ubuntu bash setup_all.sh` |

## 2. 推荐执行顺序

1. `sudo TARGET_USER=ubuntu bash setup_base.sh`
2. `sudo TARGET_USER=ubuntu bash setup_aliases.sh`
3. `sudo SSH_PORT=22 ALLOW_PORTS=80,443 bash setup_security.sh`
4. `sudo TARGET_USER=ubuntu bash setup_docker.sh`
5. `sudo TARGET_USER=ubuntu bash setup_nodejs.sh`（如需 Node.js）
6. `sudo bash setup_nginx_proxy.sh --config domains.json --email you@example.com`（如需反代 + SSL）

如果想一次执行（不含 nginx）：

```bash
sudo TARGET_USER=ubuntu bash setup_all.sh all
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
sudo bash setup_nginx_proxy.sh --config domains.json --email you@example.com
```

可选参数：
- `--no-ssl`：只写 Nginx 反代，不申请证书。
- `--force`：忽略 `completed=true` 强制重建。
- `CERTBOT_EMAIL=...`：可用环境变量代替 `--email`。

## 4. 常用环境变量

- `TARGET_USER`：要写入别名/Node 环境/Docker 组的目标用户。
- `TIMEZONE`：例如 `Asia/Shanghai`，用于 `setup_base.sh`。
- `SSH_PORT`：SSH 端口，默认 `22`。
- `ALLOW_PORTS`：额外开放端口，逗号分隔，例如 `80,443,8080/tcp`。
- `HARDEN_SSH=1`：启用 SSH 基础加固（`PermitRootLogin prohibit-password`）。
- `DISABLE_PASSWORD_AUTH=1`：配合 `HARDEN_SSH=1` 禁用 SSH 密码登录。
- `DOCKER_CHANNEL`：Docker 渠道，默认 `stable`。
- `NODE_VERSION`：Node 版本，默认 `lts/*`。

## 5. 一键入口脚本

```bash
# 默认执行: base aliases security docker
sudo TARGET_USER=ubuntu bash setup_all.sh

# 执行指定步骤
sudo TARGET_USER=ubuntu bash setup_all.sh base aliases node

# 包含 node 的全量步骤（不含 nginx）
sudo TARGET_USER=ubuntu bash setup_all.sh all
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
bash setup_security.sh --help
bash setup_nginx_proxy.sh --help
```
