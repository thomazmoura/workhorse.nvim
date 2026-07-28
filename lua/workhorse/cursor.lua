local M = {}

-- Resolve which buffer module owns a buffer (tree or flat)
function M.get_module(bufnr)
  local buffer_tree = require("workhorse.buffer_tree")
  local buffer_flat = require("workhorse.buffer")
  local target = bufnr or vim.api.nvim_get_current_buf()

  if buffer_tree.is_tree_buffer(target) then
    return buffer_tree, target
  end
  if buffer_flat.is_workhorse_buffer(target) then
    return buffer_flat, target
  end
  return nil, nil
end

-- Get the work item id under the cursor in the current buffer (nil if none)
function M.capture()
  local module, bufnr = M.get_module()
  if not module then
    return nil
  end

  local item = module.get_item_at_cursor(bufnr)
  return item and item.id or nil
end

-- Move the cursor to the line holding work item `id`, if present.
-- Returns true when the cursor was moved, false otherwise.
function M.focus(bufnr, id)
  if not id or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local module = M.get_module(bufnr)
  if not module or not module.find_line_by_id then
    return false
  end

  local line = module.find_line_by_id(bufnr, id)
  if not line then
    return false
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return false
  end

  -- Already there: leave the column untouched
  if vim.api.nvim_win_get_cursor(win)[1] == line then
    return true
  end

  local ok = pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  if not ok then
    return false
  end

  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! ^")
  end)
  return true
end

-- Same as focus(), but deferred so it runs after the buffer is displayed
function M.focus_deferred(bufnr, id)
  if not id then
    return
  end
  vim.schedule(function()
    M.focus(bufnr, id)
  end)
end

return M
