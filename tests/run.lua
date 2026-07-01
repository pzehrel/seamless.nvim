local harness = require("plenary.test_harness")

-- Use cwd-based path: <sfile> is unreliable with luafile.
local test_dir = vim.fn.getcwd() .. "/tests"

harness.test_directory(test_dir, {
	minimal_init = test_dir .. "/minimal_init.lua",
})
