---Thin wrapper around vim.notify that respects user notification preferences.
---Automatically adapts to nvim-notify, snacks.nvim, or falls back to vim.notify.

local M = {}

local config = {}

---Initialize with user config
---@param opts seamless.Config
function M.setup(opts)
  config = opts.notify or {}
end

---@param msg string
---@param level? integer vim.log.levels
---@param opts? table
local function notify(msg, level, opts)
  opts = opts or {}
  opts.title = opts.title or "seamless.nvim"
  vim.notify(msg, level, opts)
end

---Connection success notification
---@param host string
function M.connected(host)
  if not config.on_connect then
    return
  end
  notify("✅ Connected: " .. host, vim.log.levels.INFO)
end

---Disconnect notification
---@param host string
function M.disconnected(host)
  if not config.on_disconnect then
    return
  end
  notify("🔌 Disconnected: " .. host, vim.log.levels.INFO)
end

---Error notification (always shown regardless of config)
---@param msg string
---@param title? string
function M.error(msg, title)
  notify(
    msg,
    vim.log.levels.ERROR,
    { title = title or "seamless.nvim" }
  )
end

---Warning notification
---@param msg string
function M.warn(msg)
  notify("⚠️ " .. msg, vim.log.levels.WARN)
end

---Connecting notification (shown before blocking operations)
---@param host string
function M.connecting(host)
  vim.notify("🔗 Connecting to " .. host .. " ...", vim.log.levels.INFO, {
    title = "seamless.nvim",
    timeout = 15000,
  })
  -- Force redraw so the notification is visible before blocking on jobwait
  vim.cmd("redraw")
end

---Debug log (only when log_level is "debug")
---@param msg string
function M.debug(msg)
  if vim.g.seamless_log_level ~= "debug" then
    return
  end
  vim.notify("[debug] " .. msg, vim.log.levels.DEBUG, { title = "seamless" })
end

return M
