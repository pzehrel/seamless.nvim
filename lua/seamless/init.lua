---seamless.nvim — Edit remote files as if they were local, via SSHFS.
---
---Usage:
---  require("seamless").setup({})  -- uses defaults
---
---  nvim scp://myserver//etc/nginx/nginx.conf

local config = require("seamless.config")
local uri = require("seamless.uri")
local mount = require("seamless.mount")
local path = require("seamless.path")
local notify = require("seamless.notify")

local M = {}

---@type seamless.Config
local opts = {}

---Autocmd group name.
local AUGROUP = "SeamlessNvim"

---Map of buffer number → host, for tracking refcounts.
---@type table<integer, string>
local buffer_hosts = {}

---Main setup. Must be called before opening scp:// URIs.
---@param user_opts? table
function M.setup(user_opts)
  opts = config.merge(user_opts)

  -- Propagate config to sub-modules
  mount.setup(opts)
  notify.setup(opts)
  M._set_log_level()

  -- Clean up stale mounts from crashed sessions
  mount.cleanup_stale()

  -- Create augroup
  local augroup = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  -- Remove netrw's BufReadCmd handlers for our protocols (netrw registers
  -- them in the "Network" augroup). Must be done inside the Network augroup
  -- context because nvim_clear_autocmds/autocmd! cannot target other groups
  -- from outside.
  vim.cmd([[
    augroup Network
      silent! autocmd! BufReadCmd scp://*
      silent! autocmd! BufReadCmd sftp://*
    augroup END
  ]])

  -- Register BufReadCmd for each protocol
  for _, proto in ipairs(opts.protocols) do
    vim.api.nvim_create_autocmd("BufReadCmd", {
      group = augroup,
      pattern = proto .. "://*",
      callback = function(args)
        -- args.file contains the actual URI (e.g. "scp://myserver//etc/hosts")
        -- args.match contains the pattern that matched (e.g. "scp://*")
        M._handle_remote_uri(args.file)
      end,
      desc = "seamless: handle " .. proto .. ":// URIs",
    })
  end

  -- Cleanup hooks
  if opts.unmount.on_exit then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = augroup,
      callback = function()
        mount.unmount_all()
      end,
      desc = "seamless: unmount all on exit",
    })
  end

  -- Track buffer focus for idle timer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      local host = buffer_hosts[args.buf]
      if host then
        mount.track_activity(host)
      end
    end,
    desc = "seamless: track buffer activity for idle unmount",
  })

  -- Start idle unmount timer if configured
  if opts.unmount.on_idle then
    mount.start_idle_timer()
  end

  -- Track buffer wipe to decrement refcount
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      local buf = args.buf
      local host = buffer_hosts[buf]
      if host then
        buffer_hosts[buf] = nil
        mount.ref_dec(host)
      end
    end,
    desc = "seamless: release mount on buffer wipe",
  })

  -- User commands
  vim.api.nvim_create_user_command("SeamlessConnect", function(cmd_args)
    M._cmd_connect(cmd_args.args)
  end, {
    nargs = 1,
    desc = "Manually connect to a remote host (e.g. :SeamlessConnect myserver:/var/www)",
    complete = "file",
  })

  vim.api.nvim_create_user_command("SeamlessDisconnect", function(cmd_args)
    local host = cmd_args.args
    if host == "" then
      vim.notify("Usage: SeamlessDisconnect <host>", vim.log.levels.WARN)
      return
    end
    mount.unmount(host)
    -- Clean up buffer_hosts entries for this host so stale refcounts
    -- are not later decremented when those buffers are wiped.
    for buf, h in pairs(buffer_hosts) do
      if h == host then
        buffer_hosts[buf] = nil
      end
    end
  end, {
    nargs = 1,
    desc = "Manually disconnect a remote host",
  })

  vim.api.nvim_create_user_command("SeamlessStatus", function()
    M._cmd_status()
  end, {
    desc = "Show current mount status",
  })

  notify.debug("seamless.nvim setup complete")
end

---Handle a remote URI when BufReadCmd fires.
---This is the core entry point — called automatically when a scp:// or sftp://
---buffer is opened.
---
---@param raw_uri string The original URI (e.g. "scp://myserver//etc/hostname")
function M._handle_remote_uri(raw_uri)
  notify.debug("handle_remote_uri: " .. raw_uri)

  -- 1. Parse URI
  local parsed, err = uri.parse(raw_uri)
  if not parsed then
    notify.error("Failed to parse URI: " .. (err or "unknown error"))
    return
  end

  local key = uri.host_key(parsed)

  -- 2. Mount (or reuse existing)
  local mount_path, mount_err = mount.mount(parsed)
  if not mount_path then
    notify.error("Failed to mount " .. parsed.host .. ": " .. (mount_err or "unknown error"))
    return
  end

  -- 3. Convert remote path to local (mount_path already includes hostname)
  local local_path = mount_path .. parsed.path
  notify.debug("local path: " .. local_path)

  -- 4. Read file into current buffer
  local current_buf = vim.api.nvim_get_current_buf()

  -- Use :edit to let Neovim handle the path (detects file vs directory).
  -- This avoids NFS stat issues with fuse-t. For directories, netrw or
  -- the user's file-tree plugin will take over automatically.
  local edit_ok, edit_err = pcall(function()
    vim.cmd("edit " .. vim.fn.fnameescape(local_path))
  end)
  if not edit_ok then
    notify.error("Failed to open " .. local_path .. ": " .. tostring(edit_err))
    mount.ref_dec(key)
    return
  end

  -- :edit may replace the buffer; track whichever is now current
  local target_buf = vim.api.nvim_get_current_buf()
  buffer_hosts[target_buf] = key

  -- If it's a directory, switch file-tree to show it
  if vim.fn.isdirectory(local_path) == 1 then
    vim.cmd("cd " .. vim.fn.fnameescape(local_path))
    pcall(function()
      local nvim_tree_api = require("nvim-tree.api")
      nvim_tree_api.tree.change_root(local_path)
    end)
  else
    -- Ensure filetype detection runs
    vim.api.nvim_buf_call(target_buf, function()
      vim.cmd("filetype detect")
    end)
  end
end

---Handler for :SeamlessConnect <host>:/path
---@param arg string e.g. "myserver:/etc/nginx"
function M._cmd_connect(arg)
  -- Normalize: accept "host:/path" or "host " without scheme
  if not arg:match("://") then
    arg = "scp://" .. arg
  end
  M._handle_remote_uri(arg)
end

---Handler for :SeamlessStatus
function M._cmd_status()
  local mounts = mount.status()
  if vim.tbl_isempty(mounts) then
    vim.notify("No active remote mounts.", vim.log.levels.INFO)
    return
  end

  local lines = { "# seamless.nvim — Active Mounts" }
  for _, m in ipairs(mounts) do
    table.insert(lines, "")
    table.insert(lines, "## " .. m.host)
    table.insert(lines, "  Mount path: " .. m.mount_path)
    table.insert(lines, "  Refcount:   " .. m.refcount)
  end

  -- Show in a new scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_set_current_buf(buf)
end

---Set log level from config.
function M._set_log_level()
  vim.g.seamless_log_level = opts.log_level or "warn"
end

---Expose parsed URI for Lua callers who want to do custom handling.
---@param raw_uri string
---@return seamless.Uri|nil
---@return string|nil error
function M.parse_uri(raw_uri)
  return uri.parse(raw_uri)
end

---Manually handle a remote URI (public entry point).
---@param raw_uri string
function M.open(raw_uri)
  M._handle_remote_uri(raw_uri)
end

return M
