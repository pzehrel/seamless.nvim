local harness = require("plenary.test_harness")

local test_dir = vim.fn.expand("<sfile>:p:h")

harness.test_directory(test_dir, {
	minimal_init = test_dir .. "/minimal_init.lua",
})
