---@class seamless.Uri
---@field scheme string Protocol scheme (scp, sftp)
---@field user? string SSH user
---@field host string Remote hostname
---@field port? string SSH port
---@field path string Absolute remote path
---@field raw string Original URI string

local M = {}

---Parse a scp:// or sftp:// URI into structured components.
---
---Supported formats:
---   scp://host//absolute/path
---   scp://host/relative/path
---   scp://user@host//absolute/path
---   scp://user@host:port//absolute/path
---   sftp://host//absolute/path
---
---@param uri string The raw URI string (e.g. "scp://myserver//etc/nginx/nginx.conf")
---@return seamless.Uri|nil parsed URI table, or nil on failure
---@return string|nil error message
function M.parse(uri)
  if not uri or type(uri) ~= "string" then
    return nil, "URI must be a non-empty string"
  end

  -- Lua patterns do not support alternation, so validate scheme first
  local scheme = uri:match("^(%a+)://")
  if not scheme or (scheme ~= "scp" and scheme ~= "sftp") then
    return nil, "unsupported protocol: " .. (scheme or "none")
  end

  -- Strip scheme:// prefix
  local rest = uri:sub(#scheme + 4)

  -- Extract optional user@
  -- (Lua patterns cannot make capture groups optional with ? after a group,
  --  so we handle it with string search instead)
  local user = nil
  local at_pos = rest:find("@")
  if at_pos then
    user = rest:sub(1, at_pos - 1)
    if user == "" then
      user = nil
    end
    rest = rest:sub(at_pos + 1)
  end

  -- Split host:port from path at the first '/'
  local path_start = rest:find("/")
  if not path_start then
    return nil, "path is required"
  end

  local path = rest:sub(path_start)
  local authority = rest:sub(1, path_start - 1)

  -- Strip trailing colon from authority for host:port:/path format
  authority = authority:gsub(":$", "")

  -- Extract host and optional port
  local host, port = authority:match("^([^:]+):?(%d*)$")
  if not host or host == "" then
    return nil, "hostname is required"
  end

  if port == "" then
    port = nil
  end

  -- Strip leading ':' from path when port is followed by ':'
  -- e.g. scp://host:2222:/path → path becomes /path
  if path:sub(1, 1) == ":" then
    path = path:sub(2)
  end

  -- Normalize path:
  --   //absolute/path → /absolute/path
  --   /relative/path  → relative to remote root (in sshfs mount of host:/)
  --   /               → / (root)
  if path:sub(1, 2) == "//" then
    path = path:sub(2) -- remove one leading slash → absolute path
  end
  -- Single-slash paths are relative to root in the sshfs mount — kept as-is

  return {
    scheme = scheme,
    user = user,
    host = host,
    port = port,
    path = path,
    raw = uri,
  }
end

---Generate a host key for mount tracking and path construction.
---Includes the user component when present, so that alice@server and
---bob@server produce different keys and are treated as distinct mounts.
---@param uri seamless.Uri
---@return string key
function M.host_key(uri)
  if uri.user then
    return uri.user .. "@" .. uri.host
  end
  return uri.host
end

return M
