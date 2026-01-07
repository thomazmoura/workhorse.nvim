local M = {}

local render = require("workhorse.buffer.render")

-- Pattern for existing work items: [Type] #1234 | Work item title
-- The type prefix is optional for backwards compatibility
local EXISTING_PATTERN = "^.-%s*#(%d+)%s*|%s*(.+)$"

-- Check if a line is a section header
function M.is_header(line)
  if not line then
    return false, nil
  end
  local state = line:match(render.HEADER_PATTERN)
  return state ~= nil, state
end

-- Parse a single line
-- Returns: { id = number|nil, title = string } or nil for empty/invalid/header lines
function M.parse_line(line)
  -- Skip empty lines
  if not line or line:match("^%s*$") then
    return nil
  end

  -- Skip header lines
  if M.is_header(line) then
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

  -- Check if it's a new item (doesn't contain #number | pattern)
  local trimmed = vim.trim(line)
  if trimmed ~= "" and not trimmed:match("#%d+%s*|") then
    return {
      id = nil,
      title = trimmed,
    }
  end

  -- Invalid line format (e.g., "#123" without title)
  return nil
end

-- Parse all buffer lines (simple, without section tracking)
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

-- Parse buffer with section (state/column) tracking
-- Returns: items with current_section and current_state fields based on which section they're in
function M.parse_buffer_with_sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}
  local current_section = nil

  for i, line in ipairs(lines) do
    -- Check if this is a header line
    local is_hdr, section = M.is_header(line)
    if is_hdr then
      current_section = section
    else
      -- Try to parse as work item
      local item = M.parse_line(line)
      if item then
        item.line_number = i
        item.current_section = current_section  -- Generic: could be state or column
        item.current_state = current_section    -- For backwards compatibility
        table.insert(items, item)
      end
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

-- Get the section state at a specific line
function M.get_section_at_line(bufnr, line_num)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_num, false)
  local current_section = nil

  for _, line in ipairs(lines) do
    local is_hdr, state = M.is_header(line)
    if is_hdr then
      current_section = state
    end
  end

  return current_section
end

-- Format a line for a work item
function M.format_line(id, title)
  return string.format("#%d | %s", id, title)
end

return M
