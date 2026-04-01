-- tests/minimal_init.lua
vim.opt.rtp:prepend(".")

local lazy = vim.fn.stdpath("data") .. "/lazy"
for _, dep in ipairs({ "plenary.nvim", "nvim-nio", "neotest", "nvim-treesitter" }) do
    vim.opt.rtp:prepend(lazy .. "/" .. dep)
end

vim.filetype.add({ extension = { al = "al" } })
