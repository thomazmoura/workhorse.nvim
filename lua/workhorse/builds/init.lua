local M = {}

local builds_api = require("workhorse.api.builds")
local render = require("workhorse.builds.render")
local cache = require("workhorse.cache")
local config = require("workhorse.config")

-- Per-buffer view state: { key, kind, ctx, items, timer, loading }
local views = {}
-- View key -> bufnr, so reopening a level reuses its buffer
local buffers_by_key = {}

local loaders = {}

local function open_url(url)
  if not url then
    vim.notify("Workhorse: No URL for this line", vim.log.levels.WARN)
    return
  end
  if vim.ui.open then
    vim.ui.open(url)
  else
    local cmd = vim.fn.has("mac") == 1 and "open" or "xdg-open"
    vim.fn.jobstart({ cmd, url }, { detach = true })
  end
end

-- Identity of a line's item, used to keep the cursor on the same record across re-renders
local function item_key(item)
  if not item then
    return nil
  end
  return item.run and item.run.id or (item.record and item.record.id)
end

local function windows_of(bufnr)
  return vim.fn.win_findbuf(bufnr)
end

local function apply_view(bufnr, view)
  local state = views[bufnr]
  -- Remember what each window showing this buffer was on
  local cursors = {}
  for _, win in ipairs(windows_of(bufnr)) do
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    cursors[win] = { lnum = lnum, key = item_key(state.items and state.items[lnum]) }
  end

  render.apply(bufnr, view)
  state.items = view.items

  for win, pos in pairs(cursors) do
    local target = pos.lnum
    if pos.key then
      for lnum, item in pairs(view.items) do
        if item_key(item) == pos.key then
          target = lnum
          break
        end
      end
    elseif not state.cursor_placed then
      -- First render: start on the first selectable line
      target = math.huge
      for lnum in pairs(view.items) do
        target = math.min(target, lnum)
      end
      if target == math.huge then
        target = 1
      end
    end
    target = math.min(target, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end
  state.cursor_placed = true
end

-- Timeline of a run, served from cache once the run has completed
local function fetch_timeline(run, callback, opts)
  local key = "build_timeline:" .. run.id
  local cached = cache.get(key)
  if cached then
    callback(cached)
    return
  end
  builds_api.get_timeline(run.id, function(records, err)
    if records and builds_api.is_completed(run.status) then
      cache.set(key, records)
    end
    callback(records, err)
  end, opts)
end

local function stop_timer(state)
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

-- Keep refreshing the view while `running` is true; stop once it reports done
local function set_polling(bufnr, running)
  local state = views[bufnr]
  if not state then
    return
  end
  if not running then
    stop_timer(state)
    return
  end
  if state.timer then
    return
  end
  local interval = config.get().builds.refresh_interval
  state.timer = (vim.uv or vim.loop).new_timer()
  state.timer:start(interval, interval, vim.schedule_wrap(function()
    -- Skip ticks while hidden or mid-request; the timer resumes when visible again
    if not views[bufnr] or state.loading or #windows_of(bufnr) == 0 then
      return
    end
    loaders[state.kind](bufnr, { polling = true })
  end))
end

-- Run a loader step, tracking in-flight state so polling never overlaps
local function begin(bufnr)
  local state = views[bufnr]
  if not state or state.loading then
    return nil
  end
  state.loading = true
  return state
end

local function finish(bufnr)
  if views[bufnr] then
    views[bufnr].loading = false
  end
  return vim.api.nvim_buf_is_valid(bufnr) and views[bufnr] ~= nil
end

local function load_error(bufnr, what, err, opts)
  if not finish(bufnr) then
    return
  end
  if not (opts and opts.polling) then
    vim.notify("Workhorse: Failed to load " .. what .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
  end
end

-- Runs view -----------------------------------------------------------------

-- Fill stage pips for each run line, at most `max_concurrent` timelines in flight.
-- Completed runs come from the cache, so re-renders only hit the API for running ones.
local function load_pips(bufnr, view)
  local queue = {}
  for lnum, item in pairs(view.items) do
    if item.kind == "run" then
      table.insert(queue, { lnum = lnum, run = item.run })
    end
  end
  table.sort(queue, function(a, b)
    return a.lnum < b.lnum
  end)

  local in_flight = 0
  local function next_request()
    while in_flight < config.get().builds.max_concurrent and #queue > 0 do
      local job = table.remove(queue, 1)
      in_flight = in_flight + 1
      fetch_timeline(job.run, function(records)
        in_flight = in_flight - 1
        local state = views[bufnr]
        -- Drop results for a view that has since been re-rendered with other runs
        if state and state.items == view.items and records then
          render.set_pips(bufnr, job.lnum, render.stage_pips(records))
        end
        if state and state.items == view.items then
          next_request()
        end
      end, { silent = true })
    end
  end
  next_request()
end

loaders.runs = function(bufnr, opts)
  local state = begin(bufnr)
  if not state then
    return
  end
  local ctx = state.ctx
  builds_api.list_runs(ctx.definition_id, function(runs, err)
    if err or not runs then
      return load_error(bufnr, "runs", err, opts)
    end
    if not finish(bufnr) then
      return
    end
    local previous = state.items
    if not ctx.definition_name and runs[1] then
      ctx.definition_name = runs[1].definition_name
    end
    local view = render.render_runs(ctx.definition_name or ("Pipeline " .. ctx.definition_id), runs)
    apply_view(bufnr, view)
    load_pips(bufnr, view)

    local any_running = false
    for _, run in ipairs(runs) do
      if not builds_api.is_completed(run.status) then
        any_running = true
      end
    end
    set_polling(bufnr, any_running)
    if opts and opts.polling then
      return
    end
    if not previous then
      vim.notify("Workhorse: Loaded " .. #runs .. " runs", vim.log.levels.INFO)
    end
  end, opts and opts.polling and { silent = true } or nil)
end

-- Stages/jobs view ------------------------------------------------------------

-- Refresh ctx.run (status/result change while running), then the timeline
local function load_run_and_timeline(bufnr, opts, on_loaded)
  local state = begin(bufnr)
  if not state then
    return
  end
  local ctx = state.ctx
  local silent = opts and opts.polling and { silent = true } or nil

  local function with_run(run)
    ctx.run = run
    fetch_timeline(run, function(records, err)
      if err or not records then
        return load_error(bufnr, "timeline", err, opts)
      end
      if not finish(bufnr) then
        return
      end
      on_loaded(run, records)
      set_polling(bufnr, not builds_api.is_completed(run.status))
    end, silent)
  end

  if builds_api.is_completed(ctx.run.status) then
    with_run(ctx.run)
  else
    builds_api.get_build(ctx.run.id, function(run, err)
      if err or not run then
        return load_error(bufnr, "run", err, opts)
      end
      with_run(run)
    end, silent)
  end
end

loaders.stages = function(bufnr, opts)
  load_run_and_timeline(bufnr, opts, function(run, records)
    apply_view(bufnr, render.render_stages(run, records))
  end)
end

loaders.steps = function(bufnr, opts)
  load_run_and_timeline(bufnr, opts, function(run, records)
    local ctx = views[bufnr].ctx
    ctx.job = builds_api.find(records, ctx.job.id) or ctx.job
    apply_view(bufnr, render.render_steps(run, ctx.job, builds_api.steps_of_job(records, ctx.job)))
  end)
end

-- Log view ------------------------------------------------------------------

-- Fetch only the lines past what is already shown, following the tail when the
-- cursor sits on the last line
local function append_log(bufnr, opts, done)
  local state = views[bufnr]
  local ctx = state.ctx
  builds_api.get_log(ctx.run.id, ctx.log_id, function(lines, err)
    if not finish(bufnr) then
      return
    end
    if err or not lines then
      -- Logs of a running step may not be uploaded yet; keep polling quietly
      if not (opts and opts.polling) and done then
        vim.notify("Workhorse: Failed to load log: " .. (err or "unknown error"), vim.log.levels.ERROR)
      end
      set_polling(bufnr, not done)
      return
    end

    local following = {}
    local last = vim.api.nvim_buf_line_count(bufnr)
    for _, win in ipairs(windows_of(bufnr)) do
      following[win] = vim.api.nvim_win_get_cursor(win)[1] >= last
    end

    if #lines > 0 then
      local view = render.render_log(lines)
      if ctx.loaded == 0 then
        render.apply(bufnr, view)
      else
        render.append(bufnr, view)
      end
      ctx.loaded = ctx.loaded + #lines
      local new_last = vim.api.nvim_buf_line_count(bufnr)
      for win, follow in pairs(following) do
        if follow and ctx.loaded > #lines then
          vim.api.nvim_win_set_cursor(win, { new_last, 0 })
        end
      end
    elseif ctx.loaded == 0 and done then
      render.apply(bufnr, { lines = { "(empty log)" }, hls = {}, virt = {}, items = {} })
    end
    set_polling(bufnr, not done)
  end, { start_line = ctx.loaded + 1, silent = opts and opts.polling })
end

loaders.log = function(bufnr, opts)
  local state = begin(bufnr)
  if not state then
    return
  end
  local ctx = state.ctx
  if ctx.step_done then
    -- A finished step's log never changes; reopening only re-shows it
    if ctx.loaded > 0 then
      finish(bufnr)
      return
    end
    return append_log(bufnr, opts, true)
  end
  -- Check the step state first, so the final fetch after completion gets the tail
  builds_api.get_timeline(ctx.run.id, function(records, err)
    if err or not records then
      return load_error(bufnr, "timeline", err, opts)
    end
    local step = builds_api.find(records, ctx.step.id) or ctx.step
    ctx.step = step
    ctx.step_done = builds_api.is_completed(step.state)
    if step.log then
      ctx.log_id = step.log.id
    end
    append_log(bufnr, opts, ctx.step_done)
  end, { silent = opts and opts.polling })
end

-- Buffer lifecycle ----------------------------------------------------------

local function current_item(bufnr)
  local state = views[bufnr]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state and state.items and state.items[lnum]
end

local function select_item(bufnr)
  local state = views[bufnr]
  local item = current_item(bufnr)
  if not state or not item then
    return
  end
  local ctx = state.ctx
  if item.kind == "run" then
    M.open_run(item.run)
  elseif item.kind == "stage" then
    if item.first_job then
      M.open_job(ctx.run, item.first_job)
    end
  elseif item.kind == "job" then
    M.open_job(ctx.run, item.record)
  elseif item.kind == "step" then
    if not item.record.log then
      vim.notify("Workhorse: No log for this step yet", vim.log.levels.INFO)
      return
    end
    M.open_log(ctx.run, ctx.job, item.record)
  end
end

local function go_parent(bufnr)
  local state = views[bufnr]
  if not state then
    return
  end
  local ctx = state.ctx
  if state.kind == "stages" then
    M.open_runs(ctx.run.definition_id, ctx.run.definition_name)
  elseif state.kind == "steps" then
    M.open_run(ctx.run)
  elseif state.kind == "log" then
    M.open_job(ctx.run, ctx.job)
  end
end

local function browser_url(bufnr)
  local state = views[bufnr]
  local ctx = state.ctx
  local item = current_item(bufnr)
  if item and item.kind == "run" then
    return item.run.url
  end
  local run_url = ctx.run and ctx.run.url
  if not run_url then
    return nil
  end
  local record = (item and item.record) or ctx.step or ctx.job
  if not record or record.type == "Stage" then
    return run_url
  end
  if record.type == "Task" then
    return run_url .. "&view=logs&j=" .. record.parentId .. "&t=" .. record.id
  end
  return run_url .. "&view=logs&j=" .. record.id
end

local function setup_buffer(bufnr)
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "<CR>", function()
    select_item(bufnr)
  end, opts)
  vim.keymap.set("n", "-", function()
    go_parent(bufnr)
  end, opts)
  vim.keymap.set("n", "<BS>", function()
    go_parent(bufnr)
  end, opts)
  vim.keymap.set("n", "<leader>R", function()
    M.refresh(bufnr)
  end, opts)
  vim.keymap.set("n", "gw", function()
    open_url(browser_url(bufnr))
  end, opts)
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end, opts)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      local state = views[bufnr]
      if state then
        stop_timer(state)
        buffers_by_key[state.key] = nil
        views[bufnr] = nil
      end
    end,
  })
end

-- Open (or switch to) the buffer for a view and (re)load it
local function open_view(key, name, kind, ctx)
  local existing = buffers_by_key[key]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_set_current_buf(existing)
    loaders[kind](existing)
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "Workhorse|" .. name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = kind == "log" and "workhorse-build-log" or "workhorse-build"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading..." })
  vim.bo[bufnr].modifiable = false

  views[bufnr] = { key = key, kind = kind, ctx = ctx }
  buffers_by_key[key] = bufnr
  setup_buffer(bufnr)

  vim.api.nvim_set_current_buf(bufnr)
  loaders[kind](bufnr)
  return bufnr
end

local function check_config()
  if not config.is_valid() then
    vim.notify(
      "Workhorse: Plugin not configured. Please call require('workhorse').setup() with server_url, pat, and project.",
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

-- Public API ----------------------------------------------------------------

-- Fuzzy-pick a pipeline definition, then open its runs
function M.pick()
  if not check_config() then
    return
  end
  require("workhorse.telescope.builds").pick()
end

function M.open_runs(definition_id, definition_name)
  if not check_config() then
    return
  end
  definition_id = tonumber(definition_id) or definition_id
  local buf_label = (definition_name or tostring(definition_id)):gsub("[%s/\\|]+", "_")
  return open_view("runs:" .. definition_id, "builds|" .. buf_label, "runs", {
    definition_id = definition_id,
    definition_name = definition_name,
  })
end

function M.open_run(run)
  return open_view("stages:" .. run.id, "build|" .. run.id, "stages", { run = run })
end

function M.open_job(run, job)
  return open_view("steps:" .. run.id .. ":" .. job.id, "build|" .. run.id .. "|" .. job.name:gsub("[%s/\\|]+", "_"),
    "steps", { run = run, job = job })
end

function M.open_log(run, job, step)
  return open_view("log:" .. run.id .. ":" .. step.id, "build|" .. run.id .. "|log|" .. step.name:gsub("[%s/\\|]+", "_"),
    "log", { run = run, job = job, step = step, log_id = step.log.id, loaded = 0 })
end

-- Reload the build view in `bufnr` (default: current buffer)
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = views[bufnr]
  if not state then
    return false
  end
  if state.kind == "log" then
    -- Re-read the whole log from the start
    state.ctx.loaded = 0
    state.ctx.step_done = false
  elseif state.ctx.run then
    cache.invalidate("build_timeline:" .. state.ctx.run.id)
  end
  loaders[state.kind](bufnr)
  return true
end

function M.is_build_buffer(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

return M
