local M = {}

local HEADER_PATTERN = "^══ %[(.+)%] ══$"

-- Glyph prefixes the tree buffers used to write in their text (the `tree_indent` option, when
-- still set), read back so lines pasted from an older version keep their level
local LEGACY_INDENT = { "└─", "──", "──", "──" }

local function parse_indent(line)
  local rest = line or ""

  -- Spaces (or tabs), one level per guides width (see buffer_tree/guides.lua)
  local leading_ws = rest:match("^%s+")
  if leading_ws then
    local width = require("workhorse.buffer_tree.guides").width()
    local expanded = leading_ws:gsub("\t", string.rep(" ", width))
    return math.floor(#expanded / width), rest:sub(#leading_ws + 1)
  end

  local unit = require("workhorse.config").get().tree_indent or LEGACY_INDENT
  local level = 0
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
        local prefix = unit[math.min(level + 1, max)]
        if not prefix or prefix == "" or rest:sub(1, #prefix) ~= prefix then
          break
        end
        level = level + 1
        rest = rest:sub(#prefix + 1)
      end
    end
  end
  return level, (rest:gsub("^%s+", ""))
end

-- Indent level and the text after the indent of a line (spaces, or legacy glyph prefixes)
M.parse_indent = parse_indent

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
