local M = {}

local HEADER_PATTERN = "^══ %[(.+)%] ══$"

local function parse_indent(line)
  local cfg = require("workhorse.config").get()
  local unit = cfg.tree_indent or { "└── " }
  local level = 0
  local rest = line or ""

  -- First, try to match tree indent characters
  if type(unit) == "string" then
    local unit_len = #unit
    if unit_len > 0 then
      while rest:sub(1, unit_len) == unit do
        level = level + 1
        rest = rest:sub(unit_len + 1)
      end
    end
  else
    local max = #unit
    if max > 0 then
      while true do
        local idx = math.min(level + 1, max)
        local prefix = unit[idx] or unit[max]
        if not prefix or prefix == "" then
          break
        end
        local plen = #prefix
        if rest:sub(1, plen) == prefix then
          level = level + 1
          rest = rest:sub(plen + 1)
        else
          break
        end
      end
    end
  end

  -- If no tree characters matched, check for whitespace-based indentation
  -- This supports users typing new items with regular indentation (spaces/tabs)
  if level == 0 then
    local leading_ws = rest:match("^(%s+)")
    if leading_ws then
      -- Use shiftwidth or default to 2 spaces per level
      local indent_width = vim.bo.shiftwidth
      if indent_width == 0 then
        indent_width = vim.bo.tabstop or 2
      end
      -- Convert tabs to spaces for counting
      local expanded = leading_ws:gsub("\t", string.rep(" ", indent_width))
      level = math.floor(#expanded / indent_width)
      rest = rest:gsub("^%s+", "")
    end
  else
    -- Strip any remaining whitespace after tree characters
    rest = rest:gsub("^%s+", "")
  end

  return level, rest
end

-- Pattern for existing work items: [Type] #1234 | Work item title
local EXISTING_PATTERN = "^.-%s*#(%d+)%s*|%s*(.+)$"

-- Check if line is a section header
function M.parse_header(line)
  if not line then
    return nil
  end
  local section = line:match(HEADER_PATTERN)
  return section
end

-- Parse a single line with indentation
function M.parse_line(line)
  if not line or line:match("^%s*$") then
    return nil
  end

  local level, rest = parse_indent(line)
  local id, title = rest:match(EXISTING_PATTERN)
  if id then
    return {
      id = tonumber(id),
      title = vim.trim(title),
      level = level,
    }
  end

  local trimmed = vim.trim(rest)
  if trimmed ~= "" and not trimmed:match("#%d+%s*|") then
    return {
      id = nil,
      title = trimmed,
      level = level,
    }
  end

  return nil
end

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

-- Parse buffer with section tracking (for column-grouped rendering)
function M.parse_buffer_with_sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}
  local current_section = nil

  for i, line in ipairs(lines) do
    local header = M.parse_header(line)
    if header then
      current_section = header
    else
      local item = M.parse_line(line)
      if item then
        item.line_number = i
        item.current_section = current_section
        table.insert(items, item)
      end
    end
  end

  return items
end

return M
