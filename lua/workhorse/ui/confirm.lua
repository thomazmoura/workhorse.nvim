local M = {}

local changes_mod = require("workhorse.buffer.changes")

-- Show confirmation dialog for pending changes
function M.show(changes, on_confirm, on_cancel)
  -- Build content
  local lines = { "Pending changes:", "" }

  local formatted = changes_mod.format_for_display(changes)
  for _, line in ipairs(formatted) do
    table.insert(lines, line)
  end

  table.insert(lines, "")
  table.insert(lines, "Apply changes? [y]es / [n]o")

  -- Calculate window dimensions
  local width = 60
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
    title = " Confirm Changes ",
    title_pos = "center",
  })

  -- Set window options
  vim.wo[win].cursorline = false
  vim.wo[win].wrap = true

  -- Set up keymaps
  local function close_and_confirm()
    vim.api.nvim_win_close(win, true)
    if on_confirm then
      on_confirm()
    end
  end

  local function close_and_cancel()
    vim.api.nvim_win_close(win, true)
    if on_cancel then
      on_cancel()
    end
  end

  local opts = { buffer = buf, silent = true, nowait = true }

  vim.keymap.set("n", "y", close_and_confirm, opts)
  vim.keymap.set("n", "Y", close_and_confirm, opts)
  vim.keymap.set("n", "<CR>", close_and_confirm, opts)

  vim.keymap.set("n", "n", close_and_cancel, opts)
  vim.keymap.set("n", "N", close_and_cancel, opts)
  vim.keymap.set("n", "q", close_and_cancel, opts)
  vim.keymap.set("n", "<Esc>", close_and_cancel, opts)
end

return M
