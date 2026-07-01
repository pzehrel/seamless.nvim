---SSHFS mount/unmount management with refcount tracking.

local path = require("seamless.path")
local notify = require("seamless.notify")
local uri_mod = require("seamless.uri")

local M = {}

---@class seamless.MountEntry
---@field mount_path string Local mount point
---@field refcount integer Number of active buffers referencing this mount
---@field host string Remote host identifier
---@field last_activity integer Monotonic timestamp of last buffer activity (vim.loop.now)

---@type table<string, seamless.MountEntry>
local mounts = {}

---Set of host keys whose mount operation is currently in flight.
---Used to prevent concurrent sshfs processes for the same host.
---@type table<string, boolean>
local mount_in_progress = {}

---@type seamless.Config
local config = {}

---Initialize with user config.
---@param opts seamless.Config
function M.setup(opts)
  config = opts
end

---Check if a host is already mounted.
---@param uri seamless.Uri
---@return boolean
function M.is_mounted(uri)
  return mounts[uri_mod.host_key(uri)] ~= nil
end

---Get the mount entry for a host.
---@param host string
---@return seamless.MountEntry|nil
function M.get(host)
  return mounts[host]
end

---Run SSH preflight check to verify connectivity.
---Uses ssh with BatchMode=yes to test connectivity without blocking on password prompts.
---@param uri seamless.Uri
---@return boolean ok
---@return string message Diagnostic message on failure
function M.preflight(uri)
  local ssh_bin = config.ssh.binary or "ssh"
  local timeout = config.ssh.preflight_timeout or 5

  local target = uri.host
  if uri.user then
    target = uri.user .. "@" .. uri.host
  end

  -- Build shell-safe command with stderr redirection for error classification
  local port_flag = uri.port and (" -p " .. vim.fn.shellescape(uri.port)) or ""
  local cmd = string.format(
    "%s -o BatchMode=yes -o ConnectTimeout=%d -o StrictHostKeyChecking=accept-new %s %s echo ok 2>&1",
    ssh_bin,
    timeout,
    port_flag,
    vim.fn.shellescape(target)
  )

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code == 0 and output:find("ok") then
    return true, ""
  end

  -- Classify the error
  output = vim.trim(output:gsub("\n", " "))

  if output:find("[Hh]ost key verification failed") then
    return false, "Host key verification failed for " .. uri.host
      .. ".\nRun: ssh " .. uri.host .. " to accept the host key first."
  elseif output:find("[Pp]ermission denied") then
    return false, "Authentication failed for " .. uri.host
      .. ".\nCheck your SSH keys or ~/.ssh/config."
  elseif output:find("[Cc]onnection refused") then
    return false, "Connection refused: " .. uri.host
      .. ".\nCheck hostname and port."
  elseif output:find("[Cc]ould not resolve") then
    return false, "Could not resolve hostname: " .. uri.host
  elseif output:find("[Cc]onnection timed out") or output:find("connect to host") then
    return false, "Connection timed out: " .. uri.host
  elseif exit_code ~= 0 then
    return false, "SSH error (" .. uri.host .. "): " .. output
  end

  return false, output
end

---Mount a remote host via sshfs.
---Returns the local mount path on success, or nil + error on failure.
---@param uri seamless.Uri
---@return string|nil mount_path
---@return string|nil error_message
function M.mount(uri)
  local key = uri_mod.host_key(uri)

  -- Already mounted → bump refcount
  if mounts[key] then
    mounts[key].refcount = mounts[key].refcount + 1
    notify.debug("reusing mount: " .. key .. " (refcount=" .. mounts[key].refcount .. ")")
    return mounts[key].mount_path
  end

  -- Check for concurrent mount in progress for the same host key.
  -- Two BufReadCmd events can interleave; the second caller should wait
  -- for the first to finish rather than launching a second sshfs process.
  if mount_in_progress[key] then
    notify.debug("mount already in progress for " .. key .. ", waiting...")
    local wait_ok = vim.wait(10000, function()
      return mounts[key] ~= nil
    end, 100, false)
    if wait_ok and mounts[key] then
      mounts[key].refcount = mounts[key].refcount + 1
      notify.debug("mount completed after wait for " .. key .. " (refcount=" .. mounts[key].refcount .. ")")
      return mounts[key].mount_path
    end
    return nil, "mount is already in progress for " .. key .. " but did not complete within the timeout"
  end

  -- Mark as in progress — subsequent concurrent callers will wait above
  mount_in_progress[key] = true

  -- Prepare environment for sshfs job. Copy existing env and add helpers.
  local env = vim.fn.environ()

  -- Preflight check: test key auth quickly.
  local sshpass_cmd = nil
  if config.ssh.preflight_check then
    local ok, msg = M.preflight(uri)
    if not ok then
      -- Key auth failed — prompt for password so sshfs can authenticate
      local prompt = "SSH password for "
      if uri.user then
        prompt = prompt .. uri.user .. "@"
      end
      prompt = prompt .. uri.host .. ": "
      local pass = vim.fn.inputsecret(prompt)
      if pass == "" then
        mount_in_progress[key] = nil
        return nil, ""  -- user cancelled, not an error
      end
      -- Use sshpass to provide the password to sshfs
      sshpass_cmd = { "sshpass", "-e", "--" }
      -- Store in SSHPASS env var (safer than -p which leaks in /proc)
      env["SSHPASS"] = pass
      pass = nil -- clear from Lua memory
    else
      notify.debug("preflight OK for " .. key)
    end
  end

  -- Create mount point (recursive, like mkdir -p)
  local mount_path = path.host_mount_path(uri, config.mount_base)
  vim.fn.mkdir(mount_path, "p")

  -- Build sshfs target once (doesn't change on retry)
  local sshfs_bin = config.sshfs_binary or "sshfs"
  local target = ""
  if uri.user then
    target = uri.user .. "@"
  end
  target = target .. uri.host .. ":/"

  -- Set SSH_ASKPASS as a fallback GUI password prompt on macOS.
  local askpass = vim.fn.expand("~/.local/bin/ssh-askpass-seamless")
  if vim.fn.filereadable(askpass) == 1 then
    env["SSH_ASKPASS"] = askpass
  end

  -- Retry loop: password preflight validates the password, then sshfs
  -- runs in foreground mode (-f) because macFUSE daemon mode is known to
  -- hang on macOS 27 (see macfuse/macfuse#1003).
  while true do
    -- If using password, validate via a quick SSH preflight before
    -- launching sshfs. This lets us re-prompt on wrong password without
    -- waiting for sshfs to fail. vim.fn.system() doesn't share jobstart's
    -- env table, so we pass the password via -p (brief, one-shot).
    if sshpass_cmd then
      local pw_check_cmd = {
        "sshpass", "-p", env["SSHPASS"],
        config.ssh.binary or "ssh",
        "-o", "BatchMode=no",
        "-o", "ConnectTimeout=" .. (config.ssh.preflight_timeout or 5),
        "-o", "StrictHostKeyChecking=accept-new",
      }
      if uri.port then
        table.insert(pw_check_cmd, "-p")
        table.insert(pw_check_cmd, uri.port)
      end
      table.insert(pw_check_cmd, target:sub(1, -3))  -- strip trailing ":/"
      table.insert(pw_check_cmd, "echo ok")
      local pw_output = vim.fn.system(pw_check_cmd)
      local pw_exit = vim.v.shell_error

      if pw_exit == 5 then
        -- sshpass exit 5 = incorrect password
        local host_label = uri.user and (uri.user .. "@" .. uri.host) or uri.host
        local pass = vim.fn.inputsecret("Incorrect password. SSH password for "
          .. host_label .. ": ")
        if pass == "" then
          mount_in_progress[key] = nil
          return nil, ""  -- user cancelled, not an error
        end
        env["SSHPASS"] = pass
        pass = nil
        -- loop back to re-validate with new password
        goto continue
      elseif pw_exit ~= 0 then
        mount_in_progress[key] = nil
        return nil, "SSH authentication failed: " .. vim.trim(pw_output)
      end
      -- Password is valid — proceed to mount
    end

    -- Build args with -f (foreground). sshfs won't daemonize, so we
    -- detach the job and poll the mount table ourselves.
    local args = {}
    if sshpass_cmd then
      for _, a in ipairs(sshpass_cmd) do
        table.insert(args, a)
      end
    end
    table.insert(args, sshfs_bin)
    table.insert(args, "-f")
    table.insert(args, target)
    table.insert(args, mount_path)
    for _, arg in ipairs(config.sshfs_args or {}) do
      table.insert(args, arg)
    end
    -- macOS creates ._ (Apple Double) files on non-native filesystems.
    -- noappledouble tells macFUSE to ignore them entirely.
    if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
      table.insert(args, "-o")
      table.insert(args, "noappledouble")
    end
    if uri.port then
      table.insert(args, "-p")
      table.insert(args, uri.port)
    end

    notify.debug("sshfs mount: " .. table.concat(args, " "))
    notify.connecting(key)

    local job_id = vim.fn.jobstart(args, {
      env = env,
      detach = true,
    })

    if job_id <= 0 then
      mount_in_progress[key] = nil
      return nil, "failed to start sshfs process"
    end

    -- Poll mount table. macFUSE mount is synchronous — the mount should
    -- appear as soon as the SSH + SFTP session is established.
    local mounted = vim.wait(15000, function()
      local output = vim.fn.system({ "mount" })
      return output:find(mount_path, 1, true) ~= nil
    end, 200, false)

    if mounted then
      break
    end

    -- Mount didn't appear. If using password, the preflight passed so
    -- this is an unexpected failure — don't re-prompt.
    vim.fn.jobstop(job_id)
    mount_in_progress[key] = nil
    if sshpass_cmd then
      notify.warn("Mount verification failed for " .. key .. " — sshfs did not establish the mount")
      return nil, ""
    else
      return nil, "sshfs failed to establish mount"
    end
    ::continue::
  end

  -- Record mount
  mounts[key] = {
    mount_path = mount_path,
    refcount = 1,
    host = key,
    last_activity = vim.loop.now(),
    used_password = sshpass_cmd ~= nil,
  }

  mount_in_progress[key] = nil

  return mount_path
end

---Increment reference count for a host.
---@param host string
function M.ref_inc(host)
  if mounts[host] then
    mounts[host].refcount = mounts[host].refcount + 1
    notify.debug("refcount++ " .. host .. " → " .. mounts[host].refcount)
  end
end

---Decrement reference count for a host.
---If refcount reaches 0 and on_buffer_orphan is enabled, unmount —
---unless a directory was ever opened for this host, in which case
---unmount is deferred to Neovim exit (on_exit).
---@param host string
function M.ref_dec(host)
  local m = mounts[host]
  if not m then
    return
  end
  m.refcount = math.max(0, m.refcount - 1)
  notify.debug("refcount-- " .. host .. " → " .. m.refcount)

  if m.refcount == 0 and config.unmount.on_buffer_orphan and not m.has_directory then
    M.unmount(host)
  end
end

---Mark a host as having had a directory opened. Once marked, the
---host will not be auto-unmounted on buffer-orphan — it survives
---until Neovim exit (on_exit).
---@param host string
function M.mark_directory(host)
  local m = mounts[host]
  if m then
    m.has_directory = true
  end
end

---Unmount a specific host.
---@param host string
---@return boolean success
function M.unmount(host)
  local m = mounts[host]
  if not m then
    return true
  end

  notify.debug("unmounting: " .. host)

  -- If CWD is inside the mount, switch away before unmounting.
  -- Otherwise cwd() returns nil and the statusline crashes.
  local cwd = vim.fn.getcwd()
  if cwd:find(m.mount_path, 1, true) == 1 then
    pcall(vim.fn.chdir, vim.fn.expand("~"))
  end

  -- Try platform-specific unmount commands
  local cmds = {
    { "umount", "-f", m.mount_path },        -- macOS (force, close open fds)
    { "umount", m.mount_path },              -- macOS fallback
    { "fusermount", "-u", m.mount_path },   -- Linux
  }

  local ok = false
  for _, cmd in ipairs(cmds) do
    local sys_ok, _ = pcall(vim.fn.system, cmd)
    if sys_ok and vim.v.shell_error == 0 then
      ok = true
      break
    end
  end

  if ok then
    -- Clean up mount directory
    vim.loop.fs_rmdir(m.mount_path)
    if config.notify.on_disconnect then
      notify.disconnected(host)
    end
    mounts[host] = nil
  else
    notify.warn("Failed to unmount " .. host .. " (" .. m.mount_path .. ")")
  end

  return ok
end

---Unmount all active mounts. Called on VimLeavePre.
function M.unmount_all()
  M.stop_idle_timer()
  for host, _ in pairs(mounts) do
    M.unmount(host)
  end
end

---Record activity for a host (resets idle timer).
---Call when user interacts with a buffer backed by this host.
---@param host string
function M.track_activity(host)
  local m = mounts[host]
  if m then
    m.last_activity = vim.loop.now()
  end
end

-- Idle timer handle (libuv)
local idle_timer = nil

---Start the idle check timer. Calls unmount on hosts that have been
---inactive for longer than opts.unmount.on_idle seconds.
function M.start_idle_timer()
  local idle_sec = config.unmount.on_idle
  if not idle_sec or idle_sec <= 0 then
    return
  end

  if idle_timer then
    return -- already running
  end

  -- Check every (idle_sec / 2) seconds, minimum 10s
  local interval = math.max(10000, (idle_sec * 1000) / 2)
  local idle_ns = idle_sec * 1e9

  idle_timer = vim.loop.new_timer()
  idle_timer:start(interval, interval, vim.schedule_wrap(function()
    if not idle_timer then
      return -- timer was stopped
    end
    local now = vim.loop.now()
    for host, m in pairs(mounts) do
      if m.last_activity and (now - m.last_activity) >= idle_ns then
        notify.debug("idle-unmount: " .. host)
        M.unmount(host)
      end
    end
  end))
end

---Stop the idle check timer.
function M.stop_idle_timer()
  if idle_timer then
    idle_timer:stop()
    idle_timer:close()
    idle_timer = nil
  end
end

---Get all active mount info for status display.
---@return table[] mounts list of {host, mount_path, refcount}
function M.status()
  local result = {}
  for host, m in pairs(mounts) do
    table.insert(result, {
      host = host,
      mount_path = m.mount_path,
      refcount = m.refcount,
    })
  end
  return result
end

---Clean up stale mount directories from previous sessions.
---Called once during setup().
function M.cleanup_stale()
  local base = config.mount_base
  if vim.fn.isdirectory(base) == 0 then
    return
  end

  local handle = vim.loop.fs_scandir(base)
  if not handle then
    return
  end

  while true do
    local name, fs_type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if fs_type == "directory" then
      local full_path = base .. "/" .. name
      -- Try to unmount first (stale mount from crashed session).
      -- pcalled because fusermount may not exist on macOS.
      for _, cmd in ipairs({
        { "umount", "-f", full_path },
        { "fusermount", "-u", full_path },
      }) do
        local ok, _ = pcall(vim.fn.system, cmd)
        if ok and vim.v.shell_error == 0 then
          break
        end
      end
      -- Remove directory if it's empty
      pcall(vim.loop.fs_rmdir, full_path)
    end
  end
end

return M
