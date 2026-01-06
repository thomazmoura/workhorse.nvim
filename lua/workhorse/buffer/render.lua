local M = {}

local ns = vim.api.nvim_create_namespace("workhorse")

-- Highlight groups for different states
local STATE_HL = {
  ["New"] = "WorkhorseStateNew",
  ["Active"] = "WorkhorseStateActive",
  ["Resolved"] = "WorkhorseStateResolved",
  ["Closed"] = "WorkhorseStateClosed",
  ["Removed"] = "WorkhorseStateRemoved",
}

local function get_state_hl(state)
  return STATE_HL[state] or "WorkhorseState"
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
      local line = string.format("#%d | %s", item.id, item.title)
      table.insert(lines, line)
      line_map[#lines] = { type = "item", state = state, item = item }
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

return M
