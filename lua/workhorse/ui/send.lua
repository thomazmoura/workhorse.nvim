-- The keys that send (save / submit) a Workhorse screen:
--   <leader><leader>  normal mode, on every screen (buffer-local: it overrides the global
--                     mapping that saves all buffers)
--   <C-CR>            insert mode only
--   <CR>              normal mode, on popup screens only (the forms, see M.map_enter)
--
-- :w never sends: the screens are acwrite buffers whose BufWriteCmd does nothing (an auto-save
-- plugin must not apply anything), see M.ignore_write.
local M = {}

--- Map the send keys of `bufnr` (<leader><leader> in normal mode, <C-CR> in insert mode) to `fn`;
--- insert mode is left first, so the confirmation that follows opens from normal mode
function M.map(bufnr, fn, desc)
  local opts = { buffer = bufnr, silent = true, nowait = true, desc = "Workhorse: " .. desc }
  vim.keymap.set("n", "<leader><leader>", fn, opts)
  vim.keymap.set("i", "<C-CR>", function()
    vim.cmd("stopinsert")
    fn()
  end, opts)
end

--- <CR> in normal mode sends too (popup screens, where it has no other job)
function M.map_enter(bufnr, fn, desc)
  vim.keymap.set("n", "<CR>", fn, { buffer = bufnr, silent = true, nowait = true, desc = "Workhorse: " .. desc })
end

--- Make :w (e.g. an auto-save plugin's) do nothing on `bufnr`: 'modified' keeps tracking the
--- pending changes. The buffer has to be 'acwrite', or :w would write a file
function M.ignore_write(bufnr, group)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function() end,
  })
end

return M
