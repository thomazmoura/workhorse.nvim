-- Entry point of bin/nvim-vault (run by nvim -l): the vault module of this repo
local root = vim.fn.fnamemodify(arg[0], ":p:h:h")
dofile(vim.fn.glob(root .. "/lua/*/vault.lua", false, true)[1]).main(arg)
