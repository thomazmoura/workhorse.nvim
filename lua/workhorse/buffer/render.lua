local M = {}

local ns = vim.api.nvim_create_namespace("workhorse")
local hl_ns = vim.api.nvim_create_namespace("workhorse_highlights")

-- Default highlight groups for different states (fallback if not in config)
local STATE_HL = {
  ["New"] = "WorkhorseStateNew",
  ["Active"] = "WorkhorseStateActive",
  ["Resolved"] = "WorkhorseStateResolved",
  ["Closed"] = "WorkhorseStateClosed",
  ["Removed"] = "WorkhorseStateRemoved",
}

-- Default highlight groups for work item types
local TYPE_HL = {
  ["Epic"] = "WorkhorseTypeEpic",
  ["Feature"] = "WorkhorseTypeFeature",
  ["User Story"] = "WorkhorseTypeUserStory",
  ["Bug"] = "WorkhorseTypeBug",
  ["Task"] = "WorkhorseTypeTask",
}

local function get_state_hl(state)
  return STATE_HL[state] or "WorkhorseState"
end

-- Get display text for a work item type
local function get_type_text(work_item_type)
  local cfg = require("workhorse.config").get()
  local display = cfg.work_item_type_display and cfg.work_item_type_display[work_item_type]
  if display and display.text then
    return display.text
  end
  -- Fallback: [Type]
  return "[" .. (work_item_type or "Item") .. "]"
end

-- Get highlight group for a work item type
local function get_type_hl(work_item_type)
  local cfg = require("workhorse.config").get()
  local display = cfg.work_item_type_display and cfg.work_item_type_display[work_item_type]
  if display and display.color then
    return display.color
  end
  -- Fallback to defaults
  return TYPE_HL[work_item_type] or "Comment"
end

-- Header pattern for sections
M.HEADER_PATTERN = "^══ %[(.+)%] ══$"

-- Create a header line for a state section
local function make_header(state)
  return "══ [" .. state .. "] ══"
end

-- Group work items by state
local function group_by_state(work_items)
  local groups = {}
  for _, item in ipairs(work_items) do
    local state = item.state or "Unknown"
    if not groups[state] then
      groups[state] = {}
    end
    table.insert(groups[state], item)
  end
  return groups
end

-- Render work items grouped by state with headers
-- Returns: lines (array), line_map (line_num -> { type = "header"|"item", state, item })
function M.render_grouped_lines(work_items, available_states)
  local lines = {}
  local line_map = {}
  local groups = group_by_state(work_items)

  for _, state in ipairs(available_states) do
    -- Add header line
    table.insert(lines, make_header(state))
    line_map[#lines] = { type = "header", state = state }

    -- Add work items in this state
    local items = groups[state] or {}
    for _, item in ipairs(items) do
      local type_text = get_type_text(item.type)
      local line = string.format("%s #%d | %s", type_text, item.id, item.title)
      table.insert(lines, line)
      line_map[#lines] = { type = "item", state = state, item = item, type_text = type_text }
    end

    -- Add empty line after section (except last)
    table.insert(lines, "")
    line_map[#lines] = { type = "empty", state = state }
  end

  -- Remove trailing empty line
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
    line_map[#lines + 1] = nil
  end

  return lines, line_map
end

-- Render work items to buffer lines (simple format, for backwards compatibility)
-- Format: #1234 | Work item title
function M.render_lines(work_items)
  local lines = {}
  for _, item in ipairs(work_items) do
    local line = string.format("#%d | %s", item.id, item.title)
    table.insert(lines, line)
  end
  return lines
end

-- Add virtual text for pending state changes
function M.add_pending_move_markers(bufnr, pending_moves)
  -- pending_moves: { [line_num] = new_state }
  for line_num, new_state in pairs(pending_moves) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, line_num - 1, 0, {
      virt_text = {
        { " [→ ", "Comment" },
        { new_state, get_state_hl(new_state) },
        { "]", "Comment" },
      },
      virt_text_pos = "eol",
    })
  end
end

-- Clear all virtual text
function M.clear_virtual_text(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Add virtual text showing state at end of each line (legacy)
function M.add_virtual_text(bufnr, work_items)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for i, item in ipairs(work_items) do
    if item.state and item.state ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
        virt_text = {
          { " [", "Comment" },
          { item.state, get_state_hl(item.state) },
          { "]", "Comment" },
        },
        virt_text_pos = "eol",
      })
    end
  end
end

-- Apply line highlights for state headers and work item type prefixes
function M.apply_line_highlights(bufnr, line_map)
  local cfg = require("workhorse.config").get()

  -- Clear previous line highlights
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)

  for line_num, info in pairs(line_map) do
    if info.type == "header" then
      -- Apply state color to entire header line
      local hl = (cfg.state_colors and cfg.state_colors[info.state]) or get_state_hl(info.state)
      vim.api.nvim_buf_add_highlight(bufnr, hl_ns, hl, line_num - 1, 0, -1)
    elseif info.type == "item" and info.item then
      -- Apply state color to everything before the | separator
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1]
      local pipe_pos = line:find("|")
      if pipe_pos then
        local hl = (cfg.state_colors and cfg.state_colors[info.state]) or get_state_hl(info.state)
        vim.api.nvim_buf_add_highlight(bufnr, hl_ns, hl, line_num - 1, 0, pipe_pos - 1)
      end
    end
  end
end

return M
