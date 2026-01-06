-- Prevent loading twice
if vim.g.loaded_workhorse then
  return
end
vim.g.loaded_workhorse = true

-- User commands
vim.api.nvim_create_user_command("Workhorse", function(opts)
  local args = opts.fargs
  local cmd = args[1]

  if cmd == "query" then
    if args[2] then
      require("workhorse").open_query(args[2])
    else
      require("workhorse").pick_query()
    end
  elseif cmd == "refresh" then
    require("workhorse").refresh()
  elseif cmd == "state" then
    require("workhorse").change_state()
  else
    -- No command or unknown command, show help
    vim.notify([[
Workhorse commands:
  :Workhorse query [id]  - Open saved query (or picker if no id)
  :Workhorse refresh     - Refresh current buffer
  :Workhorse state       - Change state of item under cursor
]], vim.log.levels.INFO)
  end
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local parts = vim.split(cmd_line, "%s+")
    if #parts <= 2 then
      return vim.tbl_filter(function(item)
        return item:find(arg_lead, 1, true) == 1
      end, { "query", "refresh", "state" })
    end
    return {}
  end,
})

-- Highlight groups
local function setup_highlights()
  -- Default highlight groups (can be overridden by colorscheme)
  local highlights = {
    WorkhorseState = { link = "Comment" },
    WorkhorseStateNew = { link = "DiagnosticInfo" },
    WorkhorseStateActive = { link = "DiagnosticHint" },
    WorkhorseStateResolved = { link = "DiagnosticOk" },
    WorkhorseStateClosed = { link = "DiagnosticOk" },
    WorkhorseStateRemoved = { link = "DiagnosticError" },
  }

  for name, opts in pairs(highlights) do
    -- Only set if not already defined
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, opts)
    end
  end
end

setup_highlights()

-- Re-apply highlights on colorscheme change
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("workhorse_highlights", { clear = true }),
  callback = setup_highlights,
})
