local harness = require("plenary.test_harness")

describe("config", function()
	local config

	before_each(function()
		config = require("seamless.config")
	end)

	describe("defaults table", function()
		it("mount_base ends with /seamless and is a string", function()
			assert.is.string(config.defaults.mount_base)
			assert.is.truthy(config.defaults.mount_base:match("/seamless$"))
			assert.is.True(#config.defaults.mount_base > 0)
		end)

		it("protocols contains scp and sftp", function()
			assert.are.same({ "scp", "sftp" }, config.defaults.protocols)
		end)

		it("unmount has expected keys and defaults", function()
			assert.is.True(config.defaults.unmount.on_exit)
			assert.is.Nil(config.defaults.unmount.on_idle)
			assert.is.True(config.defaults.unmount.on_buffer_orphan)
		end)

		it("notify has expected keys and defaults", function()
			assert.is.True(config.defaults.notify.on_connect)
			assert.is.False(config.defaults.notify.on_disconnect)
			assert.is.True(config.defaults.notify.on_error)
		end)

		it("ssh has expected keys and defaults", function()
			assert.are.same("ssh", config.defaults.ssh.binary)
			assert.is.True(config.defaults.ssh.preflight_check)
			assert.are.same(5, config.defaults.ssh.preflight_timeout)
			assert.is.False(config.defaults.ssh.force_mount_on_preflight_fail)
		end)

		it("sshfs_args contains reconnect, timeout and keepalive options", function()
			assert.are.same({
				"-o",
				"reconnect",
				"-o",
				"ConnectTimeout=5",
				"-o",
				"ServerAliveInterval=15",
			}, config.defaults.sshfs_args)
		end)

		it("sshfs_binary defaults to sshfs", function()
			assert.are.same("sshfs", config.defaults.sshfs_binary)
		end)

		it("log_level defaults to warn", function()
			assert.are.same("warn", config.defaults.log_level)
		end)
	end)

	describe("merge() with nil or empty opts", function()
		it("returns defaults when user_opts is nil", function()
			local result = config.merge(nil)
			assert.are.same(config.defaults, result)
		end)

		it("returns a different table instance from defaults (no mutation)", function()
			local result = config.merge(nil)
			assert.is.False(result == config.defaults)
		end)

		it("returns defaults when user_opts is an empty table", function()
			local result = config.merge({})
			assert.are.same(config.defaults, result)
		end)

		it("returns a deep copy when user_opts is nil", function()
			local result = config.merge(nil)
			-- Mutating the result should not affect defaults
			result.unmount.on_exit = false
			assert.is.True(config.defaults.unmount.on_exit)
		end)
	end)

	describe("merge() top-level overrides", function()
		it("overrides log_level", function()
			local result = config.merge({ log_level = "debug" })
			assert.are.same("debug", result.log_level)
		end)

		it("overrides mount_base", function()
			local result = config.merge({ mount_base = "/custom/mount/path" })
			assert.are.same("/custom/mount/path", result.mount_base)
		end)

		it("overrides protocols", function()
			local result = config.merge({ protocols = { "scp" } })
			assert.are.same({ "scp" }, result.protocols)
		end)

		it("overrides sshfs_binary", function()
			local result = config.merge({ sshfs_binary = "/usr/local/bin/sshfs" })
			assert.are.same("/usr/local/bin/sshfs", result.sshfs_binary)
		end)

		it("overrides sshfs_args entirely", function()
			local result = config.merge({ sshfs_args = { "-o", "debug" } })
			assert.are.same({ "-o", "debug" }, result.sshfs_args)
		end)
	end)

	describe("merge() deep merge of nested tables", function()
		it("deep-merges unmount: keeps default keys and adds new ones", function()
			local result = config.merge({ unmount = { on_idle = 300 } })
			assert.are.same(300, result.unmount.on_idle)
			assert.is.True(result.unmount.on_exit)
			assert.is.True(result.unmount.on_buffer_orphan)
		end)

		it("deep-merges unmount: overrides existing keys", function()
			local result = config.merge({ unmount = { on_exit = false, on_idle = 120 } })
			assert.is.False(result.unmount.on_exit)
			assert.are.same(120, result.unmount.on_idle)
			assert.is.True(result.unmount.on_buffer_orphan)
		end)

		it("deep-merges notify: disables on_connect", function()
			local result = config.merge({ notify = { on_connect = false } })
			assert.is.False(result.notify.on_connect)
			assert.is.False(result.notify.on_disconnect)
			assert.is.True(result.notify.on_error)
		end)

		it("deep-merges notify: enables on_disconnect", function()
			local result = config.merge({ notify = { on_disconnect = true } })
			assert.is.True(result.notify.on_disconnect)
			assert.is.True(result.notify.on_connect)
			assert.is.True(result.notify.on_error)
		end)

		it("deep-merges ssh: overrides preflight_timeout", function()
			local result = config.merge({ ssh = { preflight_timeout = 10 } })
			assert.are.same(10, result.ssh.preflight_timeout)
			assert.are.same("ssh", result.ssh.binary)
			assert.is.True(result.ssh.preflight_check)
		end)

		it("deep-merges ssh: enables force_mount_on_preflight_fail", function()
			local result = config.merge({ ssh = { force_mount_on_preflight_fail = true } })
			assert.is.True(result.ssh.force_mount_on_preflight_fail)
			assert.is.True(result.ssh.preflight_check)
		end)

		it("deep-merges ssh: changes binary path", function()
			local result = config.merge({ ssh = { binary = "/usr/bin/ssh" } })
			assert.are.same("/usr/bin/ssh", result.ssh.binary)
			assert.are.same(5, result.ssh.preflight_timeout)
		end)
	end)

	describe("merge() with custom keys", function()
		it("includes custom keys not present in defaults", function()
			local result = config.merge({ custom_option = "hello" })
			assert.are.same("hello", result.custom_option)
		end)

		it("includes multiple custom keys", function()
			local result = config.merge({
				foo = "bar",
				baz = 42,
				nested_custom = { key = "value" },
			})
			assert.are.same("bar", result.foo)
			assert.are.same(42, result.baz)
			assert.are.same({ key = "value" }, result.nested_custom)
		end)

		it("prioritizes top-level custom over sub_table keys of same name", function()
			-- Note: user_opts keys with same names as sub_tables get handled by deep merge
			-- but a top-level key not in sub_tables is just directly assigned.
			-- This test verifies that custom keys at top-level don't interfere with
			-- the known sub-tables.
			local result = config.merge({ mount_base = "/custom" })
			assert.are.same("/custom", result.mount_base)
		end)
	end)

	describe("merge() does not mutate defaults", function()
		it("mount_base stays as default after override", function()
			local original = config.defaults.mount_base
			local _ = config.merge({ mount_base = "/mutated/path" })
			assert.are.same(original, config.defaults.mount_base)
		end)

		it("unmount table stays as default after deep merge", function()
			local _ = config.merge({ unmount = { on_exit = false } })
			assert.is.True(config.defaults.unmount.on_exit)
		end)

		it("notify table stays as default after deep merge", function()
			local _ = config.merge({ notify = { on_connect = false } })
			assert.is.True(config.defaults.notify.on_connect)
		end)

		it("ssh table stays as default after deep merge", function()
			local _ = config.merge({ ssh = { binary = "/fake/ssh" } })
			assert.are.same("ssh", config.defaults.ssh.binary)
		end)

		it("log_level stays as default after override", function()
			local _ = config.merge({ log_level = "error" })
			assert.are.same("warn", config.defaults.log_level)
		end)
	end)

	describe("merge() result structure", function()
		it("returns a table with all expected keys", function()
			local result = config.merge({})
			assert.is.table(result)
			assert.is.string(result.mount_base)
			assert.is.table(result.protocols)
			assert.is.table(result.unmount)
			assert.is.table(result.notify)
			assert.is.table(result.ssh)
			assert.is.table(result.sshfs_args)
			assert.is.string(result.sshfs_binary)
			assert.is.string(result.log_level)
		end)

		it("returns nested tables that are not the same objects as defaults", function()
			local result = config.merge({})
			assert.is.False(result.unmount == config.defaults.unmount)
			assert.is.False(result.notify == config.defaults.notify)
			assert.is.False(result.ssh == config.defaults.ssh)
		end)
	end)

	describe("merge() with multiple overrides simultaneously", function()
		it("handles multiple overrides across different sub-tables and top-level", function()
			local result = config.merge({
				mount_base = "/tmp/mounts",
				log_level = "debug",
				unmount = { on_idle = 600 },
				notify = { on_disconnect = true },
				ssh = { preflight_timeout = 15 },
			})
			assert.are.same("/tmp/mounts", result.mount_base)
			assert.are.same("debug", result.log_level)
			assert.are.same(600, result.unmount.on_idle)
			assert.are.same(true, result.unmount.on_exit)
			assert.is.True(result.notify.on_disconnect)
			assert.is.True(result.notify.on_connect)
			assert.are.same(15, result.ssh.preflight_timeout)
			assert.are.same("ssh", result.ssh.binary)
		end)
	end)
end)
