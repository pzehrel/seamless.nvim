# seamless.nvim

> 像编辑本地文件一样编辑远程文件 — 通过 SSHFS，完全透明。
>
> [📖 English Documentation](README.md)

## ✨ 特性

- **路径优先**：`nvim scp://myserver//etc/nginx/nginx.conf` 直接打开，零学习成本
- **自动挂载**：sshfs 挂载/卸载全程自动管理
- **引用计数**：同一主机多个文件共享一个挂载点
- **预检机制**：挂载前测试 SSH 连通性，失败时给出清晰错误信息
- **远端零依赖**：远程服务器无需安装任何东西 — 只需 SSH
- **完全透明**：nvim-tree、neo-tree、treesitter、LSP 全部原生可用
- **自动清理**：关闭 buffer 或退出 Neovim 时自动卸载

## 📦 安装

### 系统依赖

macOS 支持两种 FUSE 实现：

**方案 A：macFUSE（推荐）**

macFUSE 需要内核扩展。Apple Silicon 机型需先进入恢复模式降低安全策略：

1. 关机，按住电源键进入恢复模式
2. **实用工具 → 启动安全性实用工具** → 选择磁盘 → **安全策略**
3. 选择 **降低安全性**，勾选"允许用户管理来自被认可开发者的内核扩展"

然后安装：

```bash
brew install --cask macfuse
brew install sshfs
```

安装后在 **系统设置 → 隐私与安全性** 中点击 macFUSE 内核扩展旁边的"允许"，重启生效。

> macOS 27 当前为 beta 版本，需要 **macFUSE ≥ 5.3.1**
> （预发布版）。Homebrew 稳定版 `macfuse` cask（5.2.0）
> 尚不支持，请使用 `brew install --cask macfuse@dev`。

卸载：`brew uninstall --cask macfuse; brew uninstall sshfs`

**方案 B：fuse-t**

纯用户态方案，无需内核扩展，也无需进入恢复模式或降低安全策略。

```bash
brew tap macos-fuse-t/cask
brew install --cask fuse-t
brew trust macos-fuse-t/cask
brew install --cask fuse-t-sshfs
```

> ⚠️ **已知问题**：fuse-t-sshfs 在密码认证下可能静默失败
> （`short read on fuse device`）。Publickey 认证可正常使用。如需密码认证，请使用 macFUSE。

卸载：`brew uninstall --cask fuse-t fuse-t-sshfs; brew untap macos-fuse-t/cask`

**Linux：**

| 发行版 | 命令 |
|--------|------|
| Debian/Ubuntu | `sudo apt install sshfs` |
| Arch | `sudo pacman -S sshfs` |

### 插件安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "pzehrel/seamless.nvim",
  lazy = false,   -- 必须：需要在启动时注册 autocmd
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  opts = {
    -- 在这里覆盖默认配置
  },
}
```

> **为什么 `lazy = false`？** 插件通过 `BufReadCmd` autocmd 拦截 `scp://` URI。
> 如果 autocmd 未在打开 URI 之前注册，netrw 会接管并失败。

## ⚡️ 快速上手

```bash
nvim scp://myserver//etc/nginx/nginx.conf
nvim sftp://user@devbox//var/www/index.html
nvim scp://myserver:2222//home/user/.bashrc
```

主机名后面的 `//` 表示远程的绝对路径。

## ⚙️ 配置

以下是全部默认配置：

```lua
require("seamless").setup({
  mount_base = vim.fn.stdpath("cache") .. "/seamless",

  protocols = { "scp", "sftp" },

  unmount = {
    on_exit = true,             -- 退出 Neovim 时卸载全部
    on_idle = nil,              -- 空闲 N 秒后卸载（nil = 禁用）
    on_buffer_orphan = true,    -- 主机最后一个 buffer 关闭时卸载
  },

  sshfs_args = {
    "-o", "reconnect",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=15",
  },

  notify = {
    on_connect = true,          -- 挂载成功时通知
    on_disconnect = false,      -- 卸载时通知（默认关闭，减少噪音）
    on_error = true,            -- 连接失败时通知
  },

  ssh = {
    binary = "ssh",
    preflight_check = true,
    preflight_timeout = 5,
    force_mount_on_preflight_fail = false,
  },

  sshfs_binary = "sshfs",

  log_level = "warn",  -- "debug" | "info" | "warn" | "error"
})
```

## 🔧 命令

| 命令 | 说明 |
|------|------|
| `:SeamlessConnect myserver:/var/www` | 手动连接到远程主机 |
| `:SeamlessDisconnect myserver` | 手动断开主机 |
| `:SeamlessStatus` | 显示当前挂载状态 |

## 🩺 健康检查

```vim
:checkhealth seamless
```

检查项：`ssh`、`sshfs`、卸载工具、`$SSH_AUTH_SOCK`、`~/.ssh/config`、FUSE（macOS: fuse-t，Linux: 内核）、挂载缓存目录、Neovim 版本。

## ❓ 常见问题

**为什么必须 `lazy = false`？**
插件在启动时注册 `BufReadCmd` autocmd。如果延迟加载，netrw 可能先处理 URI 并失败。

**支持文件树插件吗？**
完全支持。挂载后远程文件就是本地文件，nvim-tree、neo-tree、oil.nvim 全部原生可用。

**密码认证的服务器怎么办？**
seamless.nvim 将所有认证委托给 SSH/sshfs。推荐使用 SSH 密钥获得最佳体验。仅支持密码的服务器，可用 `sshpass`包装 sshfs，或使用 SSH `ControlMaster` 预认证。

**sshfs 没安装怎么办？**
预检机制会捕获并显示清晰的安装指引。

**远程服务器需要安装什么？**
什么都不需要。sshfs 基于标准 SSH 工作 — 远程服务器只需运行 SSH 服务。

## 🔌 工作原理

```
nvim scp://myserver//etc/nginx/nginx.conf
                │
                ▼
┌── BufReadCmd (scp://*) ────────────────┐
│  1. 解析 URI                           │
│     → {host:"myserver",               │
│        path:"/etc/nginx/nginx.conf"}   │
│                                        │
│  2. 预检: ssh myserver echo ok         │
│                                        │
│  3. 挂载: sshfs myserver:/             │
│     → ~/.cache/seamless/myserver/      │
│                                        │
│  4. 用本地路径打开 buffer               │
└────────────────────────────────────────┘
                │
                ▼
      正常编辑（treesitter、LSP、文件树全部可用）
                │
                ▼
┌── VimLeavePre / BufWipeout ────────────┐
│  引用计数-- → 归零? → fusermount -u     │
└────────────────────────────────────────┘
```

## 📋 依赖

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `ssh` 客户端
- `sshfs` 客户端
- 远程服务器：无需安装任何东西（只需 SSH）

## 🙏 致谢

灵感来自 [remote-sshfs.nvim](https://github.com/nixrajput/remote-sshfs.nvim) 和无数与 netrw 斗争的经历。

基于 [sshfs/libfuse](https://github.com/libfuse/sshfs) 和 [fuse-t](https://github.com/macos-fuse-t/fuse-t) 构建。

## 📜 许可证

MIT
