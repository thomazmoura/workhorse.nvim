local M = {}

-- Pattern for existing work items: #1234 | Work item title
local EXISTING_PATTERN = "^#(%d+)%s*|%s*(.+)$"

-- Parse a single line
-- Returns: { id = number|nil, title = string } or nil for empty/invalid lines
function M.parse_line(line)
  -- Skip empty lines
  if not line or line:match("^%s*$") then
    return nil
  end

  -- Try to match existing work item pattern
  local id, title = line:match(EXISTING_PATTERN)
  if id then
    return {
      id = tonumber(id),
      title = vim.trim(title),
    }
  end

  -- Check if it's a new item (doesn't start with #number)
  local trimmed = vim.trim(line)
  if trimmed ~= "" and not trimmed:match("^#%d+") then
    return {
      id = nil,
      title = trimmed,
    }
  end

  -- Invalid line format (e.g., "#123" without title)
  return nil
end

-- Parse all buffer lines
function M.parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}

  for i, line in ipairs(lines) do
    local item = M.parse_line(line)
    if item then
      item.line_number = i
      table.insert(items, item)
    end
  end

  return items
end

-- Get work item ID from a specific line
function M.get_id_at_line(bufnr, line_num)
  local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
  if not line then
    return nil
  end

  local item = M.parse_line(line)
  return item and item.id
end

-- Format a line for a work item
function M.format_line(id, title)
  return string.format("#%d | %s", id, title)
end

return M
