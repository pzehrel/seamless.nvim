---@class seamless.Config
---@field mount_base string Base directory for sshfs mount points
---@field protocols string[] Protocols to intercept (scp, sftp)
---@field unmount table Unmount strategies
---@field sshfs_args string[] Extra arguments passed to sshfs
---@field notify table Notification settings
---@field ssh table SSH connection settings
---@field sshfs_binary string Path to sshfs binary
---@field log_level string Log level: debug, info, warn, error

local M = {}

---@type seamless.Config
M.defaults = {
  mount_base = vim.fn.stdpath("cache") .. "/seamless",

  protocols = { "scp", "sftp" },

  unmount = {
    on_exit = true,
    on_idle = nil, -- nil = disabled
    on_buffer_orphan = true,
  },

  sshfs_args = {
    "-o", "reconnect",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=15",
  },

  notify = {
    on_connect = true,
    on_disconnect = false,
    on_error = true,
  },

  ssh = {
    binary = "ssh",
    preflight_check = true,
    preflight_timeout = 5,
    force_mount_on_preflight_fail = false,
  },

  sshfs_binary = "sshfs",

  log_level = "warn",
}

---Merge user config with defaults (shallow merge for top-level, deep for nested tables)
---@param user_opts? table
---@return seamless.Config
function M.merge(user_opts)
  local config = vim.deepcopy(M.defaults)
  if not user_opts then
    return config
  end

  -- Deep-merge known sub-tables; shallow for the rest
  local sub_tables = { "unmount", "notify", "ssh" }
  for _, key in ipairs(sub_tables) do
    if user_opts[key] then
      config[key] = vim.tbl_deep_extend("force", config[key], user_opts[key])
      user_opts[key] = nil
    end
  end

  -- Merge remaining top-level keys
  for k, v in pairs(user_opts) do
    config[k] = v
  end

  return config
end

return M
