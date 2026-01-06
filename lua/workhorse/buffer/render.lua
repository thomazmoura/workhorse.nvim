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

-- Render work items to buffer lines
-- Format: #1234 | Work item title
function M.render_lines(work_items)
  local lines = {}
  for _, item in ipairs(work_items) do
    local line = string.format("#%d | %s", item.id, item.title)
    table.insert(lines, line)
  end
  return lines
end

-- Add virtual text showing state at end of each line
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

-- Clear virtual text
function M.clear_virtual_text(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

-- Update virtual text for a specific line
function M.update_line_virtual_text(bufnr, line_num, state)
  -- Clear existing extmark on this line
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, { line_num - 1, 0 }, { line_num - 1, -1 }, {})
  for _, mark in ipairs(extmarks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns, mark[1])
  end

  -- Add new extmark
  if state and state ~= "" then
    vim.api.nvim_buf_set_extmark(bufnr, ns, line_num - 1, 0, {
      virt_text = {
        { " [", "Comment" },
        { state, get_state_hl(state) },
        { "]", "Comment" },
      },
      virt_text_pos = "eol",
    })
  end
end

return M
