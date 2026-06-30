local harness = require("plenary.test_harness")

describe("path", function()
  local path
  local MOUNT_BASE = "/tmp/seamless-test-mount"

  before_each(function()
    path = require("seamless.path")
  end)

  after_each(function()
    -- Clean up any test directories created during tests
    if vim.fn.isdirectory(MOUNT_BASE) == 1 then
      vim.fn.system({ "rm", "-rf", MOUNT_BASE })
    end
  end)

  describe("host_mount_path", function()
    it("returns mount_base/hostname", function()
      local parsed = { host = "myserver" }
      local result = path.host_mount_path(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/myserver", result)
    end)

    it("works with dotted hostnames", function()
      local parsed = { host = "my.host.name" }
      local result = path.host_mount_path(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/my.host.name", result)
    end)

    it("works with dash-separated hostnames", function()
      local parsed = { host = "my-server-01" }
      local result = path.host_mount_path(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/my-server-01", result)
    end)

    it("includes user@ in mount path when user is present", function()
      local parsed = { host = "myserver", user = "john", port = "2222" }
      local result = path.host_mount_path(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/john@myserver", result)
    end)
  end)

  describe("remote_to_local", function()
    it("converts scp://myserver//etc/nginx to local path", function()
      local parsed = {
        host = "myserver",
        path = "/etc/nginx",
        user = nil,
        port = nil,
      }
      local result = path.remote_to_local(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/myserver/etc/nginx", result)
    end)

    it("converts scp://myserver//etc/nginx/nginx.conf to local path", function()
      local parsed = {
        host = "myserver",
        path = "/etc/nginx/nginx.conf",
      }
      local result = path.remote_to_local(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/myserver/etc/nginx/nginx.conf", result)
    end)

    it("includes user@ in local path when user is present in URI", function()
      local parsed = {
        host = "myserver",
        path = "/home/user/file.txt",
        user = "john",
      }
      local result = path.remote_to_local(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/john@myserver/home/user/file.txt", result)
    end)

    it("works when path is root", function()
      local parsed = {
        host = "myserver",
        path = "/",
      }
      local result = path.remote_to_local(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/myserver/", result)
    end)

    it("works with hostname containing dots", function()
      local parsed = {
        host = "server.internal.net",
        path = "/var/log/app.log",
      }
      local result = path.remote_to_local(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/server.internal.net/var/log/app.log", result)
    end)

    it("preserves the entire remote path including subdirectories", function()
      local parsed = {
        host = "myserver",
        path = "/a/b/c/d/e/f/g/file.txt",
      }
      local result = path.remote_to_local(parsed, MOUNT_BASE)
      assert.are.same(MOUNT_BASE .. "/myserver/a/b/c/d/e/f/g/file.txt", result)
    end)
  end)

  describe("local_to_remote", function()
    it("reverses remote_to_local for a simple path", function()
      local parsed = { host = "myserver", path = "/etc/nginx" }
      local local_path = path.remote_to_local(parsed, MOUNT_BASE)
      local host, remote_path = path.local_to_remote(local_path, MOUNT_BASE)
      assert.are.same("myserver", host)
      assert.are.same("/etc/nginx", remote_path)
    end)

    it("extracts host and remote path from a full file path", function()
      local local_path = MOUNT_BASE .. "/myserver/etc/nginx/nginx.conf"
      local host, remote_path = path.local_to_remote(local_path, MOUNT_BASE)
      assert.are.same("myserver", host)
      assert.are.same("/etc/nginx/nginx.conf", remote_path)
    end)

    it("returns nil for paths outside mount_base", function()
      local host, remote_path = path.local_to_remote("/some/other/path/file.txt", MOUNT_BASE)
      assert.is.Nil(host)
      assert.is.Nil(remote_path)
    end)

    it("returns nil when local_path equals mount_base", function()
      local host, remote_path = path.local_to_remote(MOUNT_BASE, MOUNT_BASE)
      assert.is.Nil(host)
      assert.is.Nil(remote_path)
    end)

    it("returns nil when local_path is mount_base without trailing separator", function()
      -- mount_base = "/tmp/seamless", local_path = "/tmp/seamless"  (same)
      local host, remote_path = path.local_to_remote(MOUNT_BASE, MOUNT_BASE)
      assert.is.Nil(host)
      assert.is.Nil(remote_path)
    end)

    it("handles mount_base with trailing slash", function()
      local local_path = MOUNT_BASE .. "/myserver/etc/hosts"
      local host, remote_path = path.local_to_remote(local_path, MOUNT_BASE .. "/")
      assert.are.same("myserver", host)
      assert.are.same("/etc/hosts", remote_path)
    end)

    it("handles a path that is just the host directory (no file)", function()
      -- local_path = mount_base/host with nothing after
      local local_path = MOUNT_BASE .. "/myserver"
      local host, remote_path = path.local_to_remote(local_path, MOUNT_BASE)
      assert.is.Nil(host)
      assert.is.Nil(remote_path)
    end)

    it("handles deeply nested paths preserving all components", function()
      local local_path = MOUNT_BASE .. "/myserver/a/b/c/d/e/file.txt"
      local host, remote_path = path.local_to_remote(local_path, MOUNT_BASE)
      assert.are.same("myserver", host)
      assert.are.same("/a/b/c/d/e/file.txt", remote_path)
    end)

    it("works with hostnames containing dots", function()
      local local_path = MOUNT_BASE .. "/server.internal.net/var/log/app.log"
      local host, remote_path = path.local_to_remote(local_path, MOUNT_BASE)
      assert.are.same("server.internal.net", host)
      assert.are.same("/var/log/app.log", remote_path)
    end)

    it("returns nil for path in a different mount base", function()
      -- local_path is in a different base directory entirely
      local host, remote_path = path.local_to_remote("/tmp/other/base/host/path", MOUNT_BASE)
      assert.is.Nil(host)
      assert.is.Nil(remote_path)
    end)

    it("returns nil for path that partially matches mount_base prefix", function()
      -- mount_base has a prefix of the actual path but is not exactly the base
      local host, remote_path = path.local_to_remote(MOUNT_BASE .. "-extra/host/path", MOUNT_BASE)
      assert.is.Nil(host)
      assert.is.Nil(remote_path)
    end)
  end)

  describe("ensure_parent_dir", function()
    local test_root

    before_each(function()
      test_root = vim.fn.tempname() .. "_seamless_test"
    end)

    after_each(function()
      if vim.fn.isdirectory(test_root) == 1 then
        vim.fn.system({ "rm", "-rf", test_root })
      end
    end)

    it("creates parent directory for a file path", function()
      local filepath = test_root .. "/subdir/deep/file.txt"
      path.ensure_parent_dir(filepath)
      assert.is.True(vim.fn.isdirectory(test_root .. "/subdir/deep") == 1)
    end)

    it("creates deeply nested directory structure", function()
      local filepath = test_root .. "/a/b/c/d/e/f/g/file.txt"
      path.ensure_parent_dir(filepath)
      assert.is.True(vim.fn.isdirectory(test_root .. "/a/b/c/d/e/f/g") == 1)
    end)

    it("does not error when parent directory already exists", function()
      vim.fn.mkdir(test_root .. "/existing/subdir", "p")
      local filepath = test_root .. "/existing/subdir/file.txt"
      -- Should not throw
      path.ensure_parent_dir(filepath)
      assert.is.True(vim.fn.isdirectory(test_root .. "/existing/subdir") == 1)
    end)

    it("creates parent for a single-level path", function()
      local filepath = test_root .. "/file.txt"
      path.ensure_parent_dir(filepath)
      assert.is.True(vim.fn.isdirectory(test_root) == 1)
    end)

    it("creates parent for a path with a dotfile parent", function()
      local filepath = test_root .. "/.hidden/config"
      path.ensure_parent_dir(filepath)
      assert.is.True(vim.fn.isdirectory(test_root .. "/.hidden") == 1)
    end)
  end)
end)
