# 常见问题排查

## NodeSource 源签名错误 (Debian Trixie)

### 现象

```
E: The repository 'https://deb.nodesource.com/node_24.x nodistro InRelease' is not signed.
```

错误信息中包含：
- `SHA1 is not considered secure since 2026-02-01`
- `Signing key ... is not bound`
- `Sub-process /usr/bin/sqv returned an error code (1)`

### 原因

Debian Trixie 使用 Sequoia PGP (`sqv`) 替代了传统的 GnuPG 进行签名验证。从 2026-02-01 起，Sequoia 的安全策略拒绝接受使用 SHA1 算法的 GPG 绑定签名。NodeSource 的 GPG 密钥仍使用 SHA1 签名，导致 `apt-get update` 失败。

### 解决方案

脚本已内置自动处理：`apt_update_once()` 会检测此错误并自动禁用 NodeSource 源，然后重试 `apt-get update`。Node.js 通过 nvm 安装，不依赖 NodeSource 仓库。

如需手动处理：

```bash
# 方法1: 删除 NodeSource 源
sudo rm /etc/apt/sources.list.d/nodesource.list
sudo apt-get update

# 方法2: 注释掉 NodeSource 源
sudo sed -i 's/^deb/# deb/' /etc/apt/sources.list.d/nodesource.list
sudo apt-get update
```

### 适用范围

- Debian Trixie (13) 及更新版本
- 任何使用 Sequoia PGP 且启用 SHA1 拒绝策略的发行版
