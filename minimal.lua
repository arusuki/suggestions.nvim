vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h"))
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.laststatus = 3
vim.opt.cmdheight = 0
vim.opt.showmode = false
require("suggestions").setup()
