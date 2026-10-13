-- Confirmation of a list of changes in a float (the saves of the repository screen). <CR>, y or :w
-- confirms; <C-c>, q, <Esc>, n or leaving the float cancels.
local M = {}

local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_list_confirm")

--- Ask to apply `entries` ({ { text, hl } }, hl optional) under the heading `title`;
--- on_result(true) to apply them, on_result(false) to cancel, called exactly once
function M.show(title, entries, on_result)
  local lines = { "# " .. title, "" }
  for _, entry in ipairs(entries) do
    table.insert(lines, entry.text)
  end
  vim.list_extend(lines, { "", "<CR>/y/:w apply   <C-c>/q/<Esc>/n cancel" })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|confirm|" .. bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false

  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_col = #lines[1], hl_group = "WorkhorseBuildHeader" })
  for i, entry in ipairs(entries) do
    if entry.hl then
      vim.api.nvim_buf_set_extmark(bufnr, ns, i + 1, 0, { end_col = #entry.text, hl_group = entry.hl })
    end
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, #lines - 1, 0, { end_col = #lines[#lines], hl_group = "WorkhorseRunHint" })

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - vim.o.cmdheight - 4)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = config.get().builds.run_form.border,
    title = " Workhorse: apply changes ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_cursor(win, { math.min(3, #lines), 0 })

  local answered = false
  local function finish(confirmed)
    if answered then
      return
    end
    answered = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    -- Run after the float is gone, so what follows happens in the window below
    vim.schedule(function()
      on_result(confirmed)
    end)
  end

  local opts = { buffer = bufnr, silent = true, nowait = true }
  for _, lhs in ipairs({ "<CR>", "y" }) do
    vim.keymap.set("n", lhs, function()
      finish(true)
    end, opts)
  end
  for _, lhs in ipairs({ "<C-c>", "q", "<Esc>", "n" }) do
    vim.keymap.set("n", lhs, function()
      finish(false)
    end, opts)
  end

  local group = vim.api.nvim_create_augroup("workhorse_list_confirm_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      finish(true)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        finish(false)
      end)
    end,
  })
end

return M
