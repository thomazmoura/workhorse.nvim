-- Feedback while waiting for Azure DevOps, shown like the progress of language servers: in
-- noice.nvim's LSP progress view (spinner, title, "workhorse") when noice shows it,
-- otherwise as a Neovim progress message (0.12+: message area and terminal progress bar).
-- Tasks with the same title share one indicator, shown until the last of them ends.
local M = {}

local NAME = "workhorse"

-- Indicators shown, by title: { count, failed, finish }
local shown = {}

--- Show a running task in noice's LSP progress view, built from its own message,
--- format and spinner (noice has no API for progress outside the LSP)
---@param title string
---@return function|nil finish finish(failed), nil when noice does not show LSP progress
local function noice(title)
  if not package.loaded["noice"] then
    return nil
  end
  local ok, Config = pcall(require, "noice.config")
  if not ok or not Config.is_running() or not vim.tbl_get(Config.options, "lsp", "progress", "enabled") then
    return nil
  end
  local Format = require("noice.text.format")
  local Manager = require("noice.message.manager")
  local Message = require("noice.message")
  local Router = require("noice.message.router")
  local settings = Config.options.lsp.progress

  local message = Message("lsp", "progress")
  message.opts.progress = { client = NAME, title = title, kind = "begin" }

  -- Redrawn on a timer for the spinner to turn; a redraw queued before the end is dropped
  local finished = false
  local timer = vim.uv.new_timer()
  timer:start(
    0,
    settings.throttle,
    vim.schedule_wrap(function()
      if not finished then
        Manager.add(Format.format(message, settings.format))
      end
    end)
  )

  return function()
    finished = true
    timer:stop()
    timer:close()
    message.opts.progress.kind = "end"
    Manager.add(Format.format(message, settings.format_done))
    vim.defer_fn(function()
      Router.update()
      Manager.remove(message)
    end, 100)
  end
end

--- Show a running task as a Neovim progress message
---@param title string
---@return function|nil finish finish(failed), nil before Neovim 0.12
local function native(title)
  if vim.fn.has("nvim-0.12") == 0 then
    return nil
  end
  local opts = { kind = "progress", source = NAME, title = NAME, status = "running" }
  opts.id = vim.api.nvim_echo({ { title } }, false, opts)
  return function(failed)
    opts.status = failed and "failed" or "success"
    vim.api.nvim_echo({ { failed and title or title .. " ✔" } }, false, opts)
  end
end

--- Show a task as running until the returned function is called
---@param title string What is being done ("Loading query")
---@return function done done(failed): the task ended (more calls are ignored)
function M.start(title)
  -- Headless: nobody to show it to
  if #vim.api.nvim_list_uis() == 0 then
    return function() end
  end

  local indicator = shown[title]
  if indicator then
    indicator.count = indicator.count + 1
  else
    indicator = { count = 1, failed = false, finish = noice(title) or native(title) or function() end }
    shown[title] = indicator
  end

  local ended = false
  local function done(failed)
    if ended then
      return
    end
    -- Ended from a libuv callback: the API is not callable there
    if vim.in_fast_event() then
      return vim.schedule(function()
        done(failed)
      end)
    end
    ended = true
    indicator.failed = indicator.failed or failed == true
    indicator.count = indicator.count - 1
    if indicator.count == 0 then
      shown[title] = nil
      indicator.finish(indicator.failed)
    end
  end
  return done
end

return M
