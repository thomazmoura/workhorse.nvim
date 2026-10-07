-- Confirmation of the pipeline deletions of a save of the pipelines list: a float listing all
-- of them. <CR>, y or :w deletes them; <C-c>, q, <Esc>, n or leaving the float cancels.
local M = {}

local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_pipelines_confirm")

--- Ask to delete `deletes` ({ { id, name, path } }); on_result(true) to delete them,
--- on_result(false) to cancel, called exactly once
function M.show(deletes, on_result)
  local lines = { ("# Delete %d pipeline%s?"):format(#deletes, #deletes == 1 and "" or "s"), "" }
  for _, d in ipairs(deletes) do
    table.insert(lines, ("- #%d %s  (%s)"):format(d.id, d.name, d.path))
  end
  vim.list_extend(lines, { "", "Their runs are deleted too.", "<CR>/y/:w delete   <C-c>/q/<Esc>/n cancel" })

  local bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|delete-pipelines")
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false

  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, { end_col = #lines[1], hl_group = "WorkhorseBuildHeader" })
  for row = 2, #deletes + 1 do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #lines[row + 1], hl_group = "DiagnosticError" })
  end
  for row = #lines - 2, #lines - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #lines[row + 1], hl_group = "WorkhorseRunHint" })
  end

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
    title = " Workhorse: delete pipelines ",
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
    -- Run after the float is gone, so what follows happens in the pipelines window
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

  local group = vim.api.nvim_create_augroup("workhorse_pipelines_confirm_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      finish(true)
    end,
  })
  -- Leaving the float (or it being closed some other way) cancels
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
