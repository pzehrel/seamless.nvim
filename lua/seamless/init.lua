---seamless.nvim — Edit remote files as if they were local, via SSHFS.
---
---Usage:
---  require("seamless").setup({})  -- uses defaults
---
---  nvim scp://myserver//etc/nginx/nginx.conf

local config = require("seamless.config")
local uri = require("seamless.uri")
local mount = require("seamless.mount")
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

-- Prevent re-entrant BufReadCmd: nvim_buf_set_name triggers BufFilePost
-- which may cause a second BufReadCmd for the same URI.
local pending_uris = {}

---Handle a remote URI when BufReadCmd fires.
---This is the core entry point — called automatically when a scp:// or sftp://
---buffer is opened.
---
---@param raw_uri string The original URI (e.g. "scp://myserver//etc/hostname")
function M._handle_remote_uri(raw_uri)
  if pending_uris[raw_uri] then return end
  pending_uris[raw_uri] = true
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
    if mount_err and mount_err ~= "" then
      notify.error("Failed to mount " .. parsed.host .. ": " .. mount_err)
    end
    return
  end

  -- 3. Convert remote path to local (mount_path already includes hostname)
  local local_path = mount_path .. parsed.path
  notify.debug("local path: " .. local_path)

  local mnt = mount.get(key)

  -- 4. For password auth: verify the mount root is actually serving
  --    content (scandir finds entries). This is shallower than checking
  --    the full local_path, so it completes sooner and catches true
  --    mount failures (e.g. fuse-t + password). Key auth skips this.
  if mnt and mnt.used_password then
    local root_ready = vim.wait(5000, function()
      local h = vim.loop.fs_scandir(mount_path)
      if h then
        local entry, _ = vim.loop.fs_scandir_next(h)
        return entry ~= nil
      end
      return false
    end, 50, false)
    if not root_ready then
      mount.ref_dec(key)
      notify.warn("Mount verification failed for " .. key .. " — mount is not responding")
      return
    end
  end

  -- Notify connected for new mounts (not reuse).
  if mnt and mnt.refcount == 1 then
    notify.connected(key)
  end

  -- 5. Three-way branch: directory, existing file, or new file.
  local current_buf = vim.api.nvim_get_current_buf()

  if vim.fn.isdirectory(local_path) == 1 then
    -- Directory: cd + on_open, no buffer takeover.
    buffer_hosts[current_buf] = key
    mount.mark_directory(key)
    if opts.on_open then opts.on_open(local_path, true) end
    local original_cwd = vim.fn.getcwd()
    pcall(vim.fn.chdir, local_path)
    pcall(vim.fn.chdir, original_cwd)
    vim.defer_fn(function()
      pcall(vim.fn.chdir, local_path)
    end, 100)
  elseif vim.fn.filereadable(local_path) == 1 then
    -- Existing file: read content directly.
    local lines = vim.fn.readfile(local_path)
    vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, lines)
    vim.bo[current_buf].buftype = ""
    vim.bo[current_buf].modified = false
    vim.api.nvim_buf_set_name(current_buf, local_path)
    buffer_hosts[current_buf] = key
    if opts.on_open then opts.on_open(local_path, false) end
    vim.api.nvim_buf_call(current_buf, function()
      vim.cmd("filetype detect")
    end)
  else
    -- Path doesn't exist. Ask user to create.
    -- Strip trailing slash: filereadable on "dir/" returns false even if
    -- "dir" exists as a file.
    local clean_path = local_path:gsub("/$", "")
    if vim.fn.filereadable(clean_path) == 1 then
      notify.warn("A file with this name already exists on " .. key .. " — cannot create directory.")
      mount.ref_dec(key)
      pending_uris[raw_uri] = nil
      return
    end
    local choice = vim.fn.confirm("Path does not exist: " .. key .. parsed.path .. "\nCreate it?", "&Yes\n&No", 2)
    if choice ~= 1 then
      mount.ref_dec(key)
      pending_uris[raw_uri] = nil
      return
    end
    local is_dir_uri = parsed.path:sub(-1) == "/"
    if is_dir_uri then
      -- Creating a directory: mkdir and done.
      vim.fn.mkdir(local_path, "p")
    else
      -- Creating a file: mkdir parent, rename buffer, write to anchor.
      local parent = vim.fn.fnamemodify(local_path, ":h")
      if vim.fn.isdirectory(parent) ~= 1 then
        vim.fn.mkdir(parent, "p")
      end
      vim.api.nvim_buf_set_name(current_buf, local_path)
      vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, { "" })
      vim.bo[current_buf].buftype = ""
      vim.bo[current_buf].modified = false
      vim.cmd("silent write")
    end
    buffer_hosts[current_buf] = key
    if opts.on_open then opts.on_open(local_path, is_dir_uri) end
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
