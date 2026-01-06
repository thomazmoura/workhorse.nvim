local M = {}

local config = require("workhorse.config")

-- Show state change menu for a work item
function M.show(work_item, on_select)
  local cfg = config.get()
  local states = cfg.available_states[work_item.type]

  if not states or #states == 0 then
    vim.notify("Workhorse: No states configured for type: " .. work_item.type, vim.log.levels.WARN)
    return
  end

  -- Build menu content
  local lines = {
    "Change state for #" .. work_item.id,
    "Current: " .. work_item.state,
    "",
  }

  for i, state in ipairs(states) do
    local prefix = (state == work_item.state) and "> " or "  "
    table.insert(lines, prefix .. i .. ". " .. state)
  end

  table.insert(lines, "")
  table.insert(lines, "[1-9] select / [q] cancel")

  -- Calculate window dimensions
  local width = 40
  for _, line in ipairs(lines) do
    if #line > width - 4 then
      width = #line + 4
    end
  end
  local height = #lines

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Calculate position (center of editor)
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Change State ",
    title_pos = "center",
  })

  -- Set window options
  vim.wo[win].cursorline = false

  -- Set up keymaps
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function select_state(index)
    local state = states[index]
    if state then
      close()
      if on_select then
        on_select(state)
      end
    end
  end

  local opts = { buffer = buf, silent = true, nowait = true }

  -- Number keys to select state
  for i = 1, 9 do
    vim.keymap.set("n", tostring(i), function()
      select_state(i)
    end, opts)
  end

  -- Close keys
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

-- Show work item actions menu (state change is one option)
function M.show_actions(work_item, opts)
  opts = opts or {}

  local actions = {
    { key = "s", label = "Change state", action = "state" },
    { key = "o", label = "Open in browser", action = "open" },
    { key = "r", label = "Refresh", action = "refresh" },
  }

  local lines = {
    "Actions for #" .. work_item.id,
    work_item.title,
    "",
  }

  for _, action in ipairs(actions) do
    table.insert(lines, "  [" .. action.key .. "] " .. action.label)
  end

  table.insert(lines, "")
  table.insert(lines, "[q] cancel")

  -- Calculate window dimensions
  local width = 40
  for _, line in ipairs(lines) do
    if #line > width - 4 then
      width = #line + 4
    end
  end
  local height = #lines

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Calculate position
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Work Item Actions ",
    title_pos = "center",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local keymap_opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", "s", function()
    close()
    if opts.on_state then
      M.show(work_item, opts.on_state)
    end
  end, keymap_opts)

  vim.keymap.set("n", "o", function()
    close()
    if opts.on_open then
      opts.on_open()
    end
  end, keymap_opts)

  vim.keymap.set("n", "r", function()
    close()
    if opts.on_refresh then
      opts.on_refresh()
    end
  end, keymap_opts)

  vim.keymap.set("n", "q", close, keymap_opts)
  vim.keymap.set("n", "<Esc>", close, keymap_opts)
end

return M
