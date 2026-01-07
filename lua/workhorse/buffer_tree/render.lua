local M = {}

local ns = vim.api.nvim_create_namespace("workhorse_tree")
local hl_ns = vim.api.nvim_create_namespace("workhorse_tree_hl")

-- Get display text for a work item type
local function get_type_text(work_item_type)
  local cfg = require("workhorse.config").get()
  local display = cfg.work_item_type_display and cfg.work_item_type_display[work_item_type]
  if display and display.text then
    return display.text
  end
  return "[" .. (work_item_type or "Item") .. "]"
end

local function indent_prefix(level)
  local cfg = require("workhorse.config").get()
  local unit = cfg.tree_indent or { "└── " }
  level = level or 0
  if level <= 0 then
    return ""
  end
  if type(unit) == "string" then
    local prefix = string.rep(unit, level)
    if prefix ~= "" and not prefix:match("%s$") then
      prefix = prefix .. " "
    end
    return prefix
  end
  local parts = {}
  local last = unit[#unit]
  for idx = 1, level do
    parts[idx] = unit[idx] or last or ""
  end
  local prefix = table.concat(parts)
  if prefix ~= "" and not prefix:match("%s$") then
    prefix = prefix .. " "
  end
  return prefix
end

function M.get_prefix_len(level)
  return #indent_prefix(level)
end

-- Render tree items with indentation
-- items: [{ item = work_item, level = number }]
function M.render(items)
  local lines = {}
  local line_map = {}

  for _, node in ipairs(items or {}) do
    local item = node.item
    local level = node.level or 0
    local type_text = get_type_text(item.type)
    local prefix = indent_prefix(level)
    local line = string.format("%s%s #%d | %s", prefix, type_text, item.id, item.title)
    table.insert(lines, line)
    line_map[#lines] = { type = "item", item = item, level = level, prefix_len = #prefix }
  end

  return lines, line_map
end

function M.clear_virtual_text(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

function M.apply_column_virtual_text(bufnr, line_map, column_map, column_colors)
  M.clear_virtual_text(bufnr)

  for line_num, info in pairs(line_map or {}) do
    if info.type == "item" and info.item then
      local col = column_map and column_map[info.item.id] or info.item.board_column
      if col and col ~= "" then
        local hl = column_colors and column_colors[col] or "Comment"
        vim.api.nvim_buf_set_extmark(bufnr, ns, line_num - 1, 0, {
          virt_text = {
            { " [", "Comment" },
            { col, hl },
            { "]", "Comment" },
          },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

function M.apply_indent_highlights(bufnr, line_map, hl_group)
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
  if not hl_group or hl_group == "" then
    return
  end

  for line_num, info in pairs(line_map or {}) do
    if info.type == "item" and info.prefix_len and info.prefix_len > 0 then
      vim.api.nvim_buf_add_highlight(bufnr, hl_ns, hl_group, line_num - 1, 0, info.prefix_len)
    end
  end
end

return M
