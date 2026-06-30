---Path translation: remote URI ↔ local mount path.

local uri = require("seamless.uri")

local M = {}

---Convert a remote URI to its local cache path.
---
---  scp://myserver//etc/nginx/nginx.conf
---  → ~/.cache/nvim/seamless/myserver/etc/nginx/nginx.conf
---
---@param uri seamless.Uri Parsed URI table
---@param mount_base string Base directory for mounts
---@return string local_path
function M.remote_to_local(uri, mount_base)
  local host_dir = M.host_mount_path(uri, mount_base)
  return host_dir .. uri.path
end

---Get the mount root path for a host.
---@param uri seamless.Uri
---@param mount_base string
---@return string mount_path
function M.host_mount_path(uri_, mount_base)
  return mount_base .. "/" .. uri.host_key(uri_)
end

---Ensure the local directory structure exists for a given path.
---@param filepath string Full local file path
function M.ensure_parent_dir(filepath)
  local parent = vim.fn.fnamemodify(filepath, ":h")
  vim.fn.mkdir(parent, "p")
end

---Given a local path inside a mount, extract the remote URI components.
---@param local_path string
---@param mount_base string
---@return string|nil host
---@return string|nil remote_path
function M.local_to_remote(local_path, mount_base)
  -- Normalize mount_base (strip trailing slash)
  mount_base = mount_base:gsub("/$", "")
  -- local_path must be inside mount_base
  local prefix = mount_base .. "/"
  if not local_path:find(prefix, 1, true) then
    return nil, nil
  end
  local remainder = local_path:sub(#prefix + 1)
  -- remainder = "hostname/etc/path"
  local host, remote_path_part = remainder:match("^([^/]+)/(.*)$")
  if not host then
    return nil, nil
  end
  return host, "/" .. remote_path_part
end

return M
