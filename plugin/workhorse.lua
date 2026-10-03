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
  elseif cmd == "builds" and args[2] == "resume" or cmd == "resume-build" then
    require("workhorse").resume_build()
  elseif cmd == "builds" then
    if args[2] then
      require("workhorse").open_builds(args[2])
    else
      require("workhorse").pick_build()
    end
  elseif cmd == "live" then
    require("workhorse").toggle_build_live()
  elseif cmd == "refresh" then
    require("workhorse").refresh()
  elseif cmd == "state" then
    require("workhorse").change_state()
  elseif cmd == "apply" then
    require("workhorse").apply()
  elseif cmd == "resume" then
    require("workhorse").resume()
  elseif cmd == "test" then
    require("workhorse.api.client").test()
  else
    -- No command or unknown command, show help
    vim.notify([[
Workhorse commands:
  :Workhorse query [id]  - Open saved query (or picker if no id)
  :Workhorse resume      - Reopen the last query
  :Workhorse builds [id] - Browse pipeline runs (or picker if no id)
  :Workhorse resume-build - Reopen the last pipeline (also :Workhorse builds resume)
  :Workhorse live        - Toggle live watching of build logs
  :Workhorse apply       - Apply changes to Azure DevOps
  :Workhorse refresh     - Refresh current buffer
  :Workhorse state       - Change state of item under cursor
  :Workhorse test        - Test connection to Azure DevOps
]], vim.log.levels.INFO)
  end
end, {
  nargs = "*",
  complete = function(arg_lead, cmd_line, cursor_pos)
    local parts = vim.split(cmd_line, "%s+")
    if #parts <= 2 then
      return vim.tbl_filter(function(item)
        return item:find(arg_lead, 1, true) == 1
      end, { "apply", "builds", "live", "query", "refresh", "resume", "resume-build", "state", "test" })
    end
    if #parts == 3 and parts[2] == "builds" then
      return vim.tbl_filter(function(item)
        return item:find(arg_lead, 1, true) == 1
      end, { "resume" })
    end
    return {}
  end,
})

-- Highlight groups
local function setup_highlights()
  -- Default highlight groups (can be overridden by colorscheme)
  local highlights = {
    -- State highlights (for headers and virtual text)
    WorkhorseState = { link = "Comment" },
    WorkhorseStateNew = { link = "DiagnosticInfo" },
    WorkhorseStateActive = { link = "DiagnosticHint" },
    WorkhorseStateResolved = { link = "DiagnosticOk" },
    WorkhorseStateClosed = { link = "DiagnosticOk" },
    WorkhorseStateRemoved = { link = "DiagnosticError" },
    -- Work item type highlights
    WorkhorseTypeEpic = { link = "Special" },
    WorkhorseTypeFeature = { link = "Function" },
    WorkhorseTypeUserStory = { link = "String" },
    WorkhorseTypeBug = { link = "DiagnosticError" },
    WorkhorseTypeTask = { link = "Identifier" },
    -- Build (pipeline) views
    WorkhorseBuildSucceeded = { link = "DiagnosticOk" },
    WorkhorseBuildWarning = { link = "DiagnosticWarn" },
    WorkhorseBuildFailed = { link = "DiagnosticError" },
    WorkhorseBuildRunning = { link = "DiagnosticInfo" },
    WorkhorseBuildCanceled = { link = "Comment" },
    WorkhorseBuildPending = { link = "Comment" },
    WorkhorseBuildHeader = { link = "Title" },
    WorkhorseBuildTitle = { bold = true },
    WorkhorseBuildMeta = { link = "Comment" },
    WorkhorseBuildSeparator = { link = "Comment" },
    WorkhorseBuildLive = { link = "DiagnosticOk" },
    WorkhorseBuildBranch = { link = "Function" },
    WorkhorseBuildDate = { link = "Constant" },
    WorkhorseBuildAuthor = { link = "NonText" },
    WorkhorseBuildMessage = { link = "Comment" },
    WorkhorseLogError = { link = "DiagnosticError" },
    WorkhorseLogWarning = { link = "DiagnosticWarn" },
    WorkhorseLogSection = { link = "Title" },
    WorkhorseLogCommand = { link = "Function" },
    WorkhorseLogDebug = { link = "Comment" },
    -- Decoration-only highlights (for composability - no colors, only styles)
    WorkhorseBold = { bold = true },
    WorkhorseItalic = { italic = true },
    WorkhorseUnderline = { underline = true },
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

-- Global keymaps
vim.keymap.set("n", "<leader>wQ", function()
  require("workhorse").resume()
end, { silent = true, desc = "Workhorse: Resume last query" })

vim.keymap.set("n", "<leader>wb", function()
  require("workhorse").pick_build()
end, { silent = true, desc = "Workhorse: Pick pipeline" })

vim.keymap.set("n", "<leader>wB", function()
  require("workhorse").resume_build()
end, { silent = true, desc = "Workhorse: Resume last pipeline" })
