-- Status of the latest run of each pipeline in the pipelines list, as right-aligned virtual
-- text (icon, branch, queue date and, while running, the elapsed time). Only the pipelines
-- shown in a window are fetched: off-screen lines and those inside a closed fold wait until
-- they come into view. A pipeline is fetched again once its status is older than the running
-- interval (latest run in progress) or the idle interval (finished); a tick every second
-- picks up the due ones, all in one request.
local M = {}

local builds_api = require("workhorse.api.builds")
local config = require("workhorse.config")
local render = require("workhorse.builds.render")
local tree = require("workhorse.pipelines.tree")

local ns = vim.api.nvim_create_namespace("workhorse_pipelines_status")
local uv = vim.uv or vim.loop

local TICK = 1000
-- Definitions per request, keeping the URL short
local BATCH = 50

-- [definition_id] = { run (nil when it has no runs), fetched (uv.now()), failed (never fetched) }, shared by every
-- pipelines buffer and kept across reloads
local statuses = {}
-- [bufnr] = { timer, fetching }
local buffers = {}

local function pipeline_id(line)
  local item = tree.parse({ line })[1]
  return item and item.kind == "pipeline" and item.id or nil
end

--- Draw the known statuses on the pipeline lines of the buffer
function M.render(bufnr)
  if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local id = pipeline_id(line)
    local status = id and statuses[id]
    if status and not status.failed then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        virt_text = render.run_status(status.run),
        virt_text_pos = "right_align",
      })
    end
  end
end

-- Ids of the pipelines shown in the windows of the buffer, skipping the closed folds
local function visible_ids(bufnr)
  local ids = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.api.nvim_win_call(win, function()
      local lnum, last = vim.fn.line("w0"), vim.fn.line("w$")
      while lnum <= last do
        local fold_end = vim.fn.foldclosedend(lnum)
        if fold_end ~= -1 then
          lnum = fold_end + 1
        else
          local id = pipeline_id(vim.fn.getline(lnum))
          if id then
            ids[id] = true
          end
          lnum = lnum + 1
        end
      end
    end)
  end
  return ids
end

local function is_due(id, now)
  local status = statuses[id]
  if not status then
    return true
  end
  local cfg = config.get().pipelines
  local running = status.run and not builds_api.is_completed(status.run.status)
  return now - status.fetched >= (running and cfg.status_running_interval or cfg.status_idle_interval)
end

-- Fetch the due visible pipelines, then draw them
local function tick(bufnr)
  local state = buffers[bufnr]
  if not state or state.fetching or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local now = uv.now()
  local due = {}
  for id in pairs(visible_ids(bufnr)) do
    if is_due(id, now) then
      table.insert(due, id)
    end
  end
  if #due == 0 then
    return
  end
  table.sort(due)

  local batches = {}
  for i = 1, #due, BATCH do
    table.insert(batches, vim.list_slice(due, i, i + BATCH - 1))
  end
  state.fetching = #batches
  for _, ids in ipairs(batches) do
    builds_api.latest_runs(ids, function(latest)
      local fetched = uv.now()
      for _, id in ipairs(ids) do
        if latest then
          statuses[id] = { run = latest[id], fetched = fetched }
        elseif statuses[id] then
          -- Failed: keep what is shown and try again after the interval
          statuses[id].fetched = fetched
        else
          statuses[id] = { failed = true, fetched = fetched }
        end
      end
      state.fetching = state.fetching - 1
      if state.fetching == 0 then
        state.fetching = nil
        M.render(bufnr)
      end
    end, { silent = true })
  end
end

--- Forget every status: they are fetched again as their pipelines come into view
function M.reset()
  statuses = {}
end

local function stop(bufnr)
  local state = buffers[bufnr]
  if state then
    state.timer:stop()
    state.timer:close()
    buffers[bufnr] = nil
  end
end

--- Start showing the statuses on a pipelines buffer (until it is wiped out)
function M.attach(bufnr)
  if buffers[bufnr] or not config.get().pipelines.status then
    return
  end
  local timer = uv.new_timer()
  buffers[bufnr] = { timer = timer }
  timer:start(0, TICK, vim.schedule_wrap(function()
    tick(bufnr)
  end))
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("workhorse_pipelines_status_" .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function()
      stop(bufnr)
    end,
  })
end

return M
