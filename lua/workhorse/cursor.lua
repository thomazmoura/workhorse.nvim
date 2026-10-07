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

-- Describe the work item under the cursor as a focus descriptor:
--   { id = number|nil, title = string|nil, expected_line = number }
-- A line that has not been saved yet carries no id, so its title text is kept
-- instead: after the save round-trip the item is found by matching that text.
-- Returns nil outside a workhorse buffer, or on a header/blank line.
function M.capture_focus()
  local module, bufnr = M.get_module()
  if not module or not module.get_entry_at_line then
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entry = module.get_entry_at_line(bufnr, line)
  if not entry then
    return nil
  end

  return {
    id = entry.id,
    title = (not entry.id) and entry.title or nil,
    expected_line = line,
  }
end

-- Get the work item id under the cursor in the current buffer (nil if none).
-- Also returns the cursor line, usable as an `expected_line` baseline.
function M.capture()
  local focus = M.capture_focus()
  if not focus or not focus.id then
    return nil
  end
  return focus.id, focus.expected_line
end

-- Locate the line a focus descriptor points at, id first and title as fallback
local function resolve_line(module, bufnr, focus)
  if focus.id and module.find_line_by_id then
    local line = module.find_line_by_id(bufnr, focus.id)
    if line then
      return line
    end
  end
  if focus.title and module.find_line_by_title then
    return module.find_line_by_title(bufnr, focus.title)
  end
  return nil
end

-- Move the cursor to the line holding the work item described by `focus`
-- ({ id, title, expected_line }), if present.
-- When `focus.expected_line` is given, the jump is skipped unless the cursor is
-- still there: moving away is a deliberate act and must not be undone.
-- Returns the line the cursor ended up on, or nil when it did not move.
function M.focus(bufnr, focus)
  if not focus or (not focus.id and not focus.title) then
    return nil
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local module = M.get_module(bufnr)
  if not module then
    return nil
  end

  local line = resolve_line(module, bufnr, focus)
  if not line then
    return nil
  end

  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil
  end

  local current_line = vim.api.nvim_win_get_cursor(win)[1]

  -- The user navigated away on purpose: leave them alone
  if focus.expected_line and current_line ~= focus.expected_line then
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
    -- zv: open the folds hiding the line
    vim.cmd("normal! ^zv")
  end)
  return line
end

-- Same as focus(), but deferred so it runs after the buffer is displayed.
-- The expected_line guard is evaluated when the jump actually happens.
function M.focus_deferred(bufnr, focus)
  if not focus or (not focus.id and not focus.title) then
    return
  end
  vim.schedule(function()
    M.focus(bufnr, focus)
  end)
end

return M
