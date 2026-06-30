# seamless.nvim

> Edit remote files as if they were local — via SSHFS, transparently.
>
> [📖 中文文档](README.zh-CN.md)

## ✨ Features

- **Path-first workflow**: `nvim scp://myserver//etc/nginx/nginx.conf` just works
- **Auto-mount**: sshfs mount/unmount managed automatically behind the scenes
- **Refcount tracking**: multiple files on the same host share one mount
- **Preflight check**: tests SSH connectivity before mounting, with clear error messages
- **Zero remote footprint**: nothing installed on the server — just SSH
- **Transparent editing**: nvim-tree, neo-tree, treesitter, LSP all work natively
- **Auto-cleanup**: unmounts on buffer close or Neovim exit

## 📦 Installation

### System dependencies

Two FUSE implementations are supported on macOS:

**Option A: macFUSE (recommended)**

macFUSE requires a kernel extension. On Apple Silicon, you must enable
reduced security in Recovery Mode **before** installing:

1. Shut down, then hold the power button to enter Recovery Mode
2. **Utilities → Startup Security Utility** → select your disk → **Security Policy**
3. Choose **Reduced Security** and enable "Allow user management of kernel extensions"

Then install:

```bash
brew install --cask macfuse
brew install sshfs
```

After installing, open **System Settings → Privacy & Security** and click
"Allow" next to the macFUSE kernel extension, then restart.

> macOS 27 is currently in beta and requires **macFUSE ≥ 5.3.1**
> (pre-release). Homebrew's stable `macfuse` cask (5.2.0) does not
> support it yet — use `brew install --cask macfuse@dev` instead.

To uninstall: `brew uninstall --cask macfuse; brew uninstall sshfs`

**Option B: fuse-t**

Pure userspace, no kernel extension — no Recovery Mode or reduced
security needed.

```bash
brew tap macos-fuse-t/cask
brew install --cask fuse-t
brew trust macos-fuse-t/cask
brew install --cask fuse-t-sshfs
```

> ⚠️ **Known issue**: fuse-t-sshfs may fail silently with password authentication
> (`short read on fuse device`). Publickey auth works reliably. Use macFUSE if
> you need password auth.
>
> To uninstall: `brew uninstall --cask fuse-t fuse-t-sshfs; brew untap macos-fuse-t/cask`

**Linux:**

| 发行版 | 命令 |
|--------|------|
| Debian/Ubuntu | `sudo apt install sshfs` |
| Arch | `sudo pacman -S sshfs` |

### Plugin

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "pzehrel/seamless.nvim",
  lazy = false,   -- REQUIRED: autocmds must be registered at startup
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  opts = {
    -- your configuration overrides here
  },
}
```

> **Why `lazy = false`?** The plugin intercepts `scp://` URIs via `BufReadCmd` autocmds.
> If the autocmd isn't registered before the URI is opened, netrw takes over and fails.

## ⚡️ Quick Start

```bash
nvim scp://myserver//etc/nginx/nginx.conf
nvim sftp://user@devbox//var/www/index.html
nvim scp://myserver:2222//home/user/.bashrc
```

The `//` after the hostname means an absolute path on the remote.

## ⚙️ Configuration

Default configuration with all options:

```lua
require("seamless").setup({
  mount_base = vim.fn.stdpath("cache") .. "/seamless",

  protocols = { "scp", "sftp" },

  unmount = {
    on_exit = true,             -- unmount all on Neovim exit
    on_idle = nil,              -- unmount after N idle seconds (nil = disabled)
    on_buffer_orphan = true,    -- unmount when last buffer for a host closes
  },

  sshfs_args = {
    "-o", "reconnect",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=15",
  },

  notify = {
    on_connect = true,          -- notify on successful mount
    on_disconnect = false,      -- notify on unmount (off by default for less noise)
    on_error = true,            -- notify on connection failure
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

## 🔧 Commands

| Command | Description |
|---------|-------------|
| `:SeamlessConnect myserver:/var/www` | Manually connect and open a path |
| `:SeamlessDisconnect myserver` | Manually unmount a host |
| `:SeamlessStatus` | Show active mounts |

## 🩺 Health Check

```vim
:checkhealth seamless
```

Checks: `ssh`, `sshfs`, unmount utilities, `$SSH_AUTH_SOCK`, `~/.ssh/config`, FUSE (fuse-t on macOS, kernel on Linux), mount cache directory, Neovim version.

## ❓ FAQ

**Why `lazy = false`?**
The plugin registers `BufReadCmd` autocmds at startup. If lazy-loaded, netrw may handle the URI first and fail.

**Does it work with file explorers?**
Yes — after mounting, remote files are local. nvim-tree, neo-tree, and oil.nvim all work natively.

**What about password-protected servers?**
seamless.nvim delegates all authentication to SSH/sshfs. Use SSH keys for the smoothest experience. For password-only servers, use `sshpass` (wrapping sshfs) or SSH `ControlMaster` pre-authentication. See `:help seamless-auth`.

**What if sshfs is not installed?**
The preflight check catches this and displays clear installation instructions.

**Is anything installed on the remote server?**
No. sshfs works over standard SSH — the remote server only needs an SSH daemon.

## 🔌 How It Works

```
nvim scp://myserver//etc/nginx/nginx.conf
                │
                ▼
┌── BufReadCmd (scp://*) ────────────────┐
│  1. Parse URI                          │
│     → {host:"myserver",               │
│        path:"/etc/nginx/nginx.conf"}   │
│                                        │
│  2. Preflight: ssh myserver echo ok    │
│                                        │
│  3. Mount: sshfs myserver:/            │
│           ~/.cache/seamless/myserver/  │
│                                        │
│  4. Open local path in buffer          │
└────────────────────────────────────────┘
                │
                ▼
    Edit normally (treesitter, LSP, file trees all work)
                │
                ▼
┌── VimLeavePre / BufWipeout ────────────┐
│  refcount-- → 0? → fusermount -u       │
└────────────────────────────────────────┘
```

## 📋 Requirements

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `ssh` (client)
- `sshfs` (client)
- Nothing on the remote server (just SSH)

## 🙏 Credits

Inspired by [remote-sshfs.nvim](https://github.com/nixrajput/remote-sshfs.nvim) and the countless hours spent fighting netrw.

Built on the shoulders of [sshfs/libfuse](https://github.com/libfuse/sshfs) and [fuse-t](https://github.com/macos-fuse-t/fuse-t).

## 📜 License

MIT
