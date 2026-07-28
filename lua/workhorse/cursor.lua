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

-- Get the work item id under the cursor in the current buffer (nil if none).
-- Also returns the cursor line, usable as an `expected_line` baseline.
function M.capture()
  local module, bufnr = M.get_module()
  if not module then
    return nil
  end

  local item, line = module.get_item_at_cursor(bufnr)
  if not item then
    return nil
  end
  return item.id, line
end

-- Move the cursor to the line holding work item `id`, if present.
-- When `expected_line` is given, the jump is skipped unless the cursor is still
-- there: moving away is a deliberate act and must not be undone.
-- Returns the line the cursor ended up on, or nil when it did not move.
function M.focus(bufnr, id, expected_line)
  if not id or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local module = M.get_module(bufnr)
  if not module or not module.find_line_by_id then
    return nil
  end

  local line = module.find_line_by_id(bufnr, id)
  if not line then
    return nil
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]

  -- The user navigated away on purpose: leave them alone
  if expected_line and current_line ~= expected_line then
    return nil
  end

  -- Already there: leave the column untouched
  if current_line == line then
    return line
  end

  local ok = pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  if not ok then
    return nil
  end

  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! ^")
  end)
  return line
end

-- Same as focus(), but deferred so it runs after the buffer is displayed.
-- The expected_line guard is evaluated when the jump actually happens.
function M.focus_deferred(bufnr, id, expected_line)
  if not id then
    return
  end
  vim.schedule(function()
    M.focus(bufnr, id, expected_line)
  end)
end

return M
