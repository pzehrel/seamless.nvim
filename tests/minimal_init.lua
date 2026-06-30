vim.cmd([[set runtimepath=$VIMRUNTIME]])

local root = vim.fn.getcwd()
vim.opt.rtp:append(root)

-- Try to find plenary.nvim in common locations
local plenary_paths = {
  root .. "/.deps/plenary.nvim",
  root .. "/deps/plenary.nvim",
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/packer/opt/plenary.nvim",
  os.getenv("HOME") .. "/.local/share/nvim/lazy/plenary.nvim",
}
for _, p in ipairs(plenary_paths) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.rtp:append(p)
    break
  end
end
