---Health check for :checkhealth seamless

local M = {}

function M.check()
  vim.health.start("seamless.nvim")

  -- 1. Check ssh binary
  local ssh = vim.fn.executable("ssh")
  if ssh == 1 then
    local version = vim.fn.system({ "ssh", "-V" })
    vim.health.ok("ssh: " .. vim.trim(version:gsub("\n", " ")))
  else
    vim.health.error("ssh not found in $PATH")
  end

  -- 2. Check sshfs binary
  local sshfs = vim.fn.executable("sshfs")
  if sshfs == 1 then
    local version = vim.fn.system({ "sshfs", "--version" })
    vim.health.ok("sshfs: " .. vim.trim(version:match("([^\n]+)")))
  else
    vim.health.error(
      "sshfs not found in $PATH",
      {
        "macOS:  brew install --cask macfuse && brew install sshfs",
        "Debian: sudo apt install sshfs",
        "Arch:   sudo pacman -S sshfs",
      }
    )
  end

  -- 3. Check mount/unmount utilities
  local has_fusermount = vim.fn.executable("fusermount") == 1
  local has_umount = vim.fn.executable("umount") == 1

  if has_fusermount then
    vim.health.ok("fusermount available (Linux unmount)")
  elseif has_umount then
    vim.health.ok("umount available (macOS/BSD unmount)")
  else
    vim.health.warn("No unmount utility found — may not be able to clean up mounts")
  end

  -- 4. Check SSH agent
  local ssh_auth_sock = os.getenv("SSH_AUTH_SOCK")
  if ssh_auth_sock and ssh_auth_sock ~= "" then
    vim.health.ok("SSH agent: " .. ssh_auth_sock)
  else
    vim.health.info("$SSH_AUTH_SOCK not set — key-based auth from ~/.ssh/ still works if keys are present")
  end

  -- 5. Check ~/.ssh/config
  local ssh_config = vim.fn.expand("~/.ssh/config")
  if vim.fn.filereadable(ssh_config) == 1 then
    vim.health.ok("SSH config: " .. ssh_config)
  else
    vim.health.info("No ~/.ssh/config — using default SSH settings")
  end

  -- 6. Check mount base directory
  local mount_base = vim.fn.stdpath("cache") .. "/seamless"
  if vim.fn.isdirectory(mount_base) == 1 then
    vim.health.ok("Mount cache directory: " .. mount_base)
  else
    vim.health.info("Mount cache directory will be created at: " .. mount_base)
  end

  -- 7. macOS-specific: check for macFUSE
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    local macfuse_paths = {
      "/Library/Filesystems/macfuse.fs",
      "/usr/local/lib/libfuse.2.dylib",
      "/opt/homebrew/lib/libfuse.2.dylib",
    }
    local found = false
    for _, p in ipairs(macfuse_paths) do
      if vim.fn.filereadable(p) == 1 or vim.fn.isdirectory(p) == 1 then
        vim.health.ok("macFUSE: " .. p)
        found = true
        break
      end
    end
    if not found then
      vim.health.warn(
        "macFUSE may not be installed — sshfs requires it on macOS",
        { "Install: brew install --cask macfuse" }
      )
    end
  end

  -- 8. Check Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim version: " .. vim.fn.execute("version"):match("NVIM v([^\n]+)"))
  else
    vim.health.error("Neovim >= 0.9 required (current: " .. vim.version().major .. "." .. vim.version().minor .. ")")
  end

  -- Summary
  if ssh == 1 and sshfs == 1 and (has_fusermount or has_umount) then
    vim.health.ok("seamless.nvim is ready ✓")
  else
    vim.health.warn("Install missing dependencies to use seamless.nvim")
  end
end

return M
