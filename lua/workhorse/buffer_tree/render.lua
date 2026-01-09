local M = {}

local ns = vim.api.nvim_create_namespace("workhorse_tree")
local hl_ns = vim.api.nvim_create_namespace("workhorse_tree_hl")
local deco_ns = vim.api.nvim_create_namespace("workhorse_tree_deco")

-- Get display text for a work item type
local function get_type_text(work_item_type)
  local cfg = require("workhorse.config").get()
  local display = cfg.work_item_type_display and cfg.work_item_type_display[work_item_type]
  if display and display.text then
    return display.text
  end
  return "[" .. (work_item_type or "Item") .. "]"
end

-- Get highlight group for title based on work item type and tags
-- Returns nil if no matching config found
local function get_tag_title_highlight(work_item_type, tags_string)
  local cfg = require("workhorse.config").get()
  local type_config = cfg.tag_title_colors and cfg.tag_title_colors[work_item_type]
  if not type_config then
    return nil
  end

  -- Parse tags (semicolon-separated, may have spaces)
  for tag in (tags_string or ""):gmatch("[^;]+") do
    tag = vim.trim(tag)
    if type_config[tag] then
      return type_config[tag]
    end
  end

  return nil
end

-- Get decoration highlight groups for a work item type
local function get_type_decorations(work_item_type)
  local cfg = require("workhorse.config").get()
  local decorations = cfg.work_item_type_decorations and cfg.work_item_type_decorations[work_item_type]
  return decorations or {}
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

-- Sort nodes by stack rank (lower rank = higher priority)
local function sort_by_stack_rank(nodes)
  table.sort(nodes, function(a, b)
    local rank_a = a.item.stack_rank or math.huge
    local rank_b = b.item.stack_rank or math.huge
    if rank_a == rank_b then
      return (a.item.id or 0) < (b.item.id or 0)
    end
    return rank_a < rank_b
  end)
end

-- Build children map from nodes
local function build_children_map(nodes, parent_by_id)
  local children_map = {}
  for _, node in ipairs(nodes) do
    local parent_id = parent_by_id[node.item.id]
    if parent_id then
      children_map[parent_id] = children_map[parent_id] or {}
      table.insert(children_map[parent_id], node)
    end
  end
  -- Sort children by stack rank
  for _, children in pairs(children_map) do
    sort_by_stack_rank(children)
  end
  return children_map
end

-- Recursively render a node and its children
local function render_node_recursive(node, children_map, lines, line_map, current_section)
  local item = node.item
  local level = node.level or 0
  local type_text = get_type_text(item.type)
  local prefix = indent_prefix(level)
  local line = string.format("%s%s #%d | %s", prefix, type_text, item.id, item.title)
  table.insert(lines, line)
  line_map[#lines] = {
    type = "item",
    item = item,
    level = level,
    prefix_len = #prefix,
    section = current_section,
  }

  -- Render children recursively
  local children = children_map[item.id] or {}
  for _, child in ipairs(children) do
    render_node_recursive(child, children_map, lines, line_map, current_section)
  end
end

-- Render tree items grouped by board column (top-level only)
-- nodes: [{ item = work_item, level = number }]
-- column_order: ordered list of column names
-- parent_by_id: map of child_id -> parent_id
function M.render_grouped_by_column(nodes, column_order, parent_by_id)
  local lines = {}
  local line_map = {}

  -- Separate top-level (level 0) from children
  local roots = {}
  local all_nodes_by_id = {}
  for _, node in ipairs(nodes or {}) do
    all_nodes_by_id[node.item.id] = node
    if node.level == 0 then
      table.insert(roots, node)
    end
  end

  -- Build children map for recursive rendering
  local children_map = build_children_map(nodes, parent_by_id or {})

  -- Group top-level items by board_column
  local by_column = {}
  for _, node in ipairs(roots) do
    local col = node.item.board_column or "Unknown"
    if col == "" then
      col = "Unknown"
    end
    by_column[col] = by_column[col] or {}
    table.insert(by_column[col], node)
  end

  -- Sort each column group by stack_rank
  for _, group in pairs(by_column) do
    sort_by_stack_rank(group)
  end

  -- Render in column order
  local rendered_columns = {}
  for _, col_name in ipairs(column_order or {}) do
    local group = by_column[col_name]
    if group and #group > 0 then
      -- Add header
      local header = string.format("══ [%s] ══", col_name)
      table.insert(lines, header)
      line_map[#lines] = { type = "header", section = col_name }

      -- Render each root and its children
      for _, node in ipairs(group) do
        render_node_recursive(node, children_map, lines, line_map, col_name)
      end

      -- Add empty line after section
      table.insert(lines, "")
      line_map[#lines] = { type = "empty" }

      rendered_columns[col_name] = true
    end
  end

  -- Render "Unknown" column (items with no board_column)
  local unknown_group = by_column["Unknown"]
  if unknown_group and #unknown_group > 0 and not rendered_columns["Unknown"] then
    local header = "══ [Unknown] ══"
    table.insert(lines, header)
    line_map[#lines] = { type = "header", section = "Unknown" }

    for _, node in ipairs(unknown_group) do
      render_node_recursive(node, children_map, lines, line_map, "Unknown")
    end

    table.insert(lines, "")
    line_map[#lines] = { type = "empty" }
  end

  -- Remove trailing empty line
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
    line_map[#lines + 1] = nil
  end

  return lines, line_map
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

function M.apply_header_highlights(bufnr, line_map, column_colors)
  for line_num, info in pairs(line_map or {}) do
    if info.type == "header" and info.section then
      local hl = column_colors and column_colors[info.section] or "Title"
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
      if line then
        vim.api.nvim_buf_add_highlight(bufnr, hl_ns, hl, line_num - 1, 0, #line)
      end
    end
  end
end

-- Apply column-based coloring to the text before the | separator (after indent)
-- Uses the item's own board_column (same as virtual text), not the section header
function M.apply_column_line_highlights(bufnr, line_map, column_map, column_colors)
  if not column_colors then
    return
  end

  for line_num, info in pairs(line_map or {}) do
    if info.type == "item" and info.item then
      local col = column_map and column_map[info.item.id] or info.item.board_column
      if col and col ~= "" then
        local hl = column_colors[col]
        if hl then
          local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
          if line then
            local pipe_pos = line:find("|")
            if pipe_pos then
              local start_col = info.prefix_len or 0
              vim.api.nvim_buf_add_highlight(bufnr, hl_ns, hl, line_num - 1, start_col, pipe_pos - 1)
            end
          end
        end
      end
    end
  end
end

function M.apply_tag_title_highlights(bufnr, line_map)
  for line_num, info in pairs(line_map or {}) do
    if info.type == "item" and info.item then
      local title_hl = get_tag_title_highlight(info.item.type, info.item.tags)
      if title_hl then
        local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
        if line then
          local pipe_pos = line:find("|")
          if pipe_pos then
            vim.api.nvim_buf_add_highlight(bufnr, hl_ns, title_hl, line_num - 1, pipe_pos + 1, -1)
          end
        end
      end
    end
  end
end

-- Apply decoration extmarks for work item types
function M.apply_type_decorations(bufnr, line_map)
  vim.api.nvim_buf_clear_namespace(bufnr, deco_ns, 0, -1)

  for line_num, info in pairs(line_map or {}) do
    if info.type == "item" and info.item then
      local decorations = get_type_decorations(info.item.type)
      for _, deco_hl in ipairs(decorations) do
        local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
        local line_len = line and #line or 0
        vim.api.nvim_buf_set_extmark(bufnr, deco_ns, line_num - 1, 0, {
          end_row = line_num - 1,
          end_col = line_len,
          hl_group = deco_hl,
          priority = 200,
        })
      end
    end
  end
end

return M
