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

-- Live watching (global): run tree and log views follow the latest step's log
local live = false

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

-- Width available for a view's lines (used to trim titles and size the separator).
-- Remembered on the view so a resize only re-renders when the width really changed.
local function view_width(bufnr)
  local win = windows_of(bufnr)[1]
  local width = win and vim.api.nvim_win_get_width(win) or vim.o.columns
  if views[bufnr] then
    views[bufnr].width = width
  end
  return width
end

-- Put the cursor of the current window on the line whose item has `key`
local function focus_key(bufnr, key)
  local state = views[bufnr]
  for lnum, item in pairs(state and state.items or {}) do
    if item.kind ~= "nav" and item_key(item) == key then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return true
    end
  end
  return false
end

-- Pinned header ---------------------------------------------------------------

-- Every view starts with its header (pipeline > run > stage > job > step). Once it
-- scrolls out of view, a copy of it (state.header_buf) is pinned over the top of
-- the window in a non-focusable float, the way nvim-treesitter-context does.
-- View window -> the float pinning its header
local pinned = {}

local function close_pinned(win)
  local float = pinned[win]
  pinned[win] = nil
  if float and vim.api.nvim_win_is_valid(float) then
    vim.api.nvim_win_close(float, true)
  end
end

-- Statuscolumn of a pinned header, filled by M._pinned_number
local PINNED_NUMBER = "%{%v:lua.require'workhorse.builds'._pinned_number()%}"

-- Give the pinned header the gutter width of the log window under it, so its lines
-- stay in the same columns as the real header lines
local function set_pinned_gutter(float, textoff)
  local gutter = textoff > 0
  vim.wo[float].number = gutter
  vim.wo[float].relativenumber = false
  vim.wo[float].numberwidth = math.min(math.max(textoff, 1), 20)
  vim.wo[float].statuscolumn = gutter and PINNED_NUMBER or ""
end

-- Show the pinned header over `win` while its own header is scrolled away
local function pin_header(win)
  local state = views[vim.api.nvim_win_get_buf(win)]
  local height = state and state.header_buf and vim.api.nvim_buf_line_count(state.header_buf)
  local info = vim.fn.getwininfo(win)[1]
  -- At the top the real (actionable) header lines show; tiny windows keep the log visible
  if not height or info.topline <= 1 or info.height <= height + 1 then
    return close_pinned(win)
  end
  local float_config = {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = info.width,
    height = height,
    focusable = false,
    zindex = 20,
  }
  local float = pinned[win]
  if float and vim.api.nvim_win_is_valid(float) then
    if vim.api.nvim_win_get_buf(float) ~= state.header_buf then
      vim.api.nvim_win_set_buf(float, state.header_buf)
    end
    vim.api.nvim_win_set_config(float, float_config)
    set_pinned_gutter(float, info.textoff)
    return
  end
  float_config.style = "minimal"
  float_config.noautocmd = true
  float = vim.api.nvim_open_win(state.header_buf, false, float_config)
  vim.wo[float].wrap = false
  vim.wo[float].winhighlight = "NormalFloat:Normal"
  -- Opaque even with a global 'winblend': the log behind must not show through
  vim.wo[float].winblend = 0
  set_pinned_gutter(float, info.textoff)
  pinned[win] = float
end

-- Refresh the pinned copy of a view's header from the view just rendered
local function update_pinned(bufnr, view)
  render.apply(views[bufnr].header_buf, render.pinned(view))
  for _, win in ipairs(windows_of(bufnr)) do
    pin_header(win)
  end
end

-- Relative numbers change with the cursor of the view window, which does not redraw the float
local function redraw_pinned_numbers(win)
  local float = pinned[win]
  if float and vim.api.nvim_win_is_valid(float) and vim.wo[win].relativenumber and vim.api.nvim__redraw then
    vim.api.nvim__redraw({ win = float, statuscolumn = true })
  end
end

-- Pin headers over the view windows scrolled past theirs, and drop the floats of
-- windows that were closed or no longer show a view
local function sync_pinned()
  for win in pairs(pinned) do
    local state = vim.api.nvim_win_is_valid(win) and views[vim.api.nvim_win_get_buf(win)]
    if not (state and state.header_buf) then
      close_pinned(win)
    end
  end
  for bufnr, state in pairs(views) do
    if state.header_buf then
      for _, win in ipairs(windows_of(bufnr)) do
        pin_header(win)
      end
    end
  end
end

-- Keep the cursor of `win` off the rows its pinned header covers: `scroll` brings
-- the view down to the cursor (moving up with k), otherwise the cursor moves down
-- into view (scrolling with the wheel or <C-e>)
local function uncover_cursor(win, scroll)
  local float = pinned[win]
  if not (float and vim.api.nvim_win_is_valid(float)) then
    return
  end
  local height = vim.api.nvim_win_get_height(float)
  vim.api.nvim_win_call(win, function()
    -- Step one screen row at a time, so wrapped lines and folds count right
    for _ = 1, height do
      if vim.fn.winline() > height or vim.fn.line("w0") <= 1 then
        return
      end
      vim.cmd(scroll and "normal! \25" or "normal! gj")
    end
  end)
end

local sync_pending = false
local function schedule_sync()
  if not sync_pending then
    sync_pending = true
    vim.schedule(function()
      sync_pending = false
      sync_pinned()
    end)
  end
end

local pin_group = vim.api.nvim_create_augroup("workhorse_builds_log_header", { clear = true })
vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinClosed" }, {
  group = pin_group,
  callback = schedule_sync,
})
-- Build windows have no sign or fold column, leaving the width to the content
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_builds_gutter", { clear = true }),
  callback = function(args)
    if views[args.buf] then
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_option_value("signcolumn", "no", { scope = "local", win = win })
      vim.api.nvim_set_option_value("foldcolumn", "0", { scope = "local", win = win })
    end
  end,
})
-- Scrolling updates right away, so the pinned header never lags a redraw behind
vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
  group = pin_group,
  callback = function()
    sync_pinned()
    for win in pairs(pinned) do
      uncover_cursor(win, false)
    end
  end,
})
vim.api.nvim_create_autocmd("CursorMoved", {
  group = pin_group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if pinned[win] then
      uncover_cursor(win, true)
      redraw_pinned_numbers(win)
    end
  end,
})

local function apply_view(bufnr, view)
  local state = views[bufnr]
  -- A pending focus (set when navigating here) wins over the remembered position
  local focus = state.focus_key
  state.focus_key = nil
  -- Remember what each window showing this buffer was on
  local cursors = {}
  for _, win in ipairs(windows_of(bufnr)) do
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    cursors[win] = { lnum = lnum, key = focus or item_key(state.items and state.items[lnum]) }
  end

  render.apply(bufnr, view)
  state.items = view.items
  update_pinned(bufnr, view)

  for win, pos in pairs(cursors) do
    local target = pos.lnum
    if pos.key then
      for lnum, item in pairs(view.items) do
        if item.kind ~= "nav" and item_key(item) == pos.key then
          target = lnum
          break
        end
      end
    elseif not state.cursor_placed then
      -- First render: start on the first line below the header
      target = math.huge
      for lnum, item in pairs(view.items) do
        if item.kind ~= "nav" then
          target = math.min(target, lnum)
        end
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
  local opts = config.get().builds
  local interval = (live and state.kind ~= "runs") and opts.live_interval or opts.refresh_interval
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

-- Live watching -------------------------------------------------------------

-- Step with a log that started last (the running one, or the last one to finish)
local function latest_logged_step(records)
  local latest, latest_job
  for _, stage in ipairs(builds_api.stages(records)) do
    for _, job in ipairs(builds_api.jobs_of_stage(records, stage)) do
      for _, step in ipairs(builds_api.steps_of_job(records, job)) do
        -- ISO timestamps compare as strings; on ties the later step in order wins
        if step.log and (not latest or (step.startTime or "") >= (latest.startTime or "")) then
          latest, latest_job = step, job
        end
      end
    end
  end
  return latest_job, latest
end

-- Switch the window showing `bufnr` to the latest step's log, unless it already
-- shows it. Returns true when it switched.
local function follow_latest(bufnr, records)
  local state = views[bufnr]
  local win = windows_of(bufnr)[1]
  local job, step = latest_logged_step(records)
  if not win or not step or (state.kind == "log" and state.ctx.step.id == step.id) then
    return false
  end
  local run = state.ctx.run
  vim.api.nvim_win_call(win, function()
    M.open_log(run, job, step)
  end)
  return true
end

-- Runs view -----------------------------------------------------------------

-- Line of a run in the rendered runs view
local function run_line(state, run_id)
  for lnum, item in pairs(state.items or {}) do
    if item.kind == "run" and item.run.id == run_id then
      return lnum
    end
  end
end

-- Render the runs list from ctx.runs and restore the stage pips already known
local function render_runs(bufnr)
  local state = views[bufnr]
  local ctx = state.ctx
  local name = ctx.definition_name or ("Pipeline " .. ctx.definition_id)
  apply_view(bufnr, render.render_runs(name, ctx.runs, view_width(bufnr)))
  for run_id, chunks in pairs(ctx.pips) do
    local lnum = run_line(state, run_id)
    if lnum then
      render.set_pips(bufnr, lnum, chunks)
    end
  end
end

-- Fill stage pips for each run, at most `max_concurrent` timelines in flight.
-- Pips are kept per run id in ctx.pips, so re-renders (e.g. on resize) restore them.
-- Completed runs come from the cache, so reloads only hit the API for running ones.
local function load_pips(bufnr)
  local ctx = views[bufnr].ctx
  local runs = ctx.runs
  local queue = vim.list_slice(runs)

  local in_flight = 0
  local function next_request()
    while in_flight < config.get().builds.max_concurrent and #queue > 0 do
      local run = table.remove(queue, 1)
      in_flight = in_flight + 1
      fetch_timeline(run, function(records)
        in_flight = in_flight - 1
        local state = views[bufnr]
        -- Stop once a newer runs list replaced the one this queue was built from
        if not state or state.ctx.runs ~= runs then
          return
        end
        if records then
          ctx.pips[run.id] = render.stage_pips(records)
          local lnum = run_line(state, run.id)
          if lnum then
            render.set_pips(bufnr, lnum, ctx.pips[run.id])
          end
        end
        next_request()
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
    if not previous then
      require("workhorse.session").save_last_build(ctx.definition_id, ctx.definition_name)
    end
    ctx.runs = runs
    ctx.pips = ctx.pips or {}
    render_runs(bufnr)
    load_pips(bufnr)

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

-- Re-render the run tree from the timeline already in ctx (no request)
local function render_tree(bufnr)
  local ctx = views[bufnr].ctx
  apply_view(bufnr, render.render_stages(ctx.run, ctx.records, view_width(bufnr), ctx.expanded, live))
end

-- Expand every ancestor of the record about to be focused, so it is visible
local function reveal(ctx, records, id)
  local record = id and builds_api.find(records, id)
  while record and record.parentId do
    ctx.expanded[record.parentId] = true
    record = builds_api.find(records, record.parentId)
  end
end

loaders.stages = function(bufnr, opts)
  load_run_and_timeline(bufnr, opts, function(_, records)
    local state = views[bufnr]
    state.ctx.records = records
    -- Opening a running build with live watching on jumps straight to its latest log
    local follow_now = state.ctx.follow_once
    state.ctx.follow_once = nil
    if live and ((opts and opts.polling) or follow_now) and follow_latest(bufnr, records) then
      return
    end
    reveal(state.ctx, records, state.focus_key)
    render_tree(bufnr)
  end)
end

-- Expand or collapse the level below a stage/job line
local function toggle(bufnr, item)
  local ctx = views[bufnr].ctx
  if not item.has_children or not ctx.records then
    return
  end
  ctx.expanded[item.record.id] = not ctx.expanded[item.record.id] or nil
  render_tree(bufnr)
end

-- Log view ------------------------------------------------------------------

local function render_header(bufnr)
  local state = views[bufnr]
  local ctx = state.ctx
  local width = view_width(bufnr)
  local stage = ctx.stage or ctx.job
  local header = render.render_log_header(ctx.run, stage, ctx.job, ctx.step, width, live)
  render.replace(bufnr, header, 0, state.head_count)
  state.head_count = #header.lines
  state.items = header.items
  -- The header may have changed height (e.g. the Cancel line went away)
  update_pinned(bufnr, header)
end

-- A finished step's log keeps polling only until the run itself completes, so
-- the header picks up its final status (and live watching the next step)
local function keep_polling(bufnr, done)
  return not done or not builds_api.is_completed(views[bufnr].ctx.run.status)
end

-- Refresh ctx.run while it is still going; its status lags behind the timeline
-- (e.g. a cancelled run stays "cancelling" after its last step finished)
local function refresh_run(bufnr, opts, callback)
  local ctx = views[bufnr].ctx
  if builds_api.is_completed(ctx.run.status) then
    return callback()
  end
  builds_api.get_build(ctx.run.id, function(run)
    if run and views[bufnr] then
      views[bufnr].ctx.run = run
    end
    callback()
  end, { silent = opts and opts.polling })
end

-- Fetch only the lines past what is already shown, following the tail when the
-- cursor sits on the last line. The header is redrawn with every batch.
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
      set_polling(bufnr, keep_polling(bufnr, done))
      return
    end

    local following = {}
    local last = vim.api.nvim_buf_line_count(bufnr)
    for _, win in ipairs(windows_of(bufnr)) do
      following[win] = vim.api.nvim_win_get_cursor(win)[1] >= last
    end

    render_header(bufnr)
    if #lines > 0 then
      if ctx.loaded == 0 then
        render.replace(bufnr, render.render_log(lines), state.head_count, -1)
        -- Live watching starts on the tail (and keeps following it); otherwise on the first log line
        local target = live and vim.api.nvim_buf_line_count(bufnr) or state.head_count + 1
        for _, win in ipairs(windows_of(bufnr)) do
          vim.api.nvim_win_set_cursor(win, { target, 0 })
        end
      else
        render.append(bufnr, render.render_log(lines))
      end
      ctx.loaded = ctx.loaded + #lines
      local new_last = vim.api.nvim_buf_line_count(bufnr)
      for win, follow in pairs(following) do
        if follow and ctx.loaded > #lines then
          vim.api.nvim_win_set_cursor(win, { new_last, 0 })
        end
      end
    elseif ctx.loaded == 0 then
      render.replace(bufnr, render.render_log({ done and "(empty log)" or "Waiting for log..." }), state.head_count, -1)
    end
    set_polling(bufnr, keep_polling(bufnr, done))
  end, { start_line = ctx.loaded + 1, silent = opts and opts.polling })
end

loaders.log = function(bufnr, opts)
  local state = begin(bufnr)
  if not state then
    return
  end
  local ctx = state.ctx
  refresh_run(bufnr, opts, function()
    if not views[bufnr] then
      return
    end
    -- Live ticks always check the timeline, to catch the next step starting
    local follow = live and opts and opts.polling
    if ctx.step_done and not follow then
      -- A finished step's log never changes; reopening only re-shows it (and the run status)
      if ctx.loaded > 0 then
        if finish(bufnr) then
          render_header(bufnr)
          set_polling(bufnr, keep_polling(bufnr, true))
        end
        return
      end
      return append_log(bufnr, opts, true)
    end
    -- Check the step state first, so the final fetch after completion gets the tail
    builds_api.get_timeline(ctx.run.id, function(records, err)
      if err or not records then
        return load_error(bufnr, "timeline", err, opts)
      end
      if follow then
        if not finish(bufnr) then
          return
        end
        if follow_latest(bufnr, records) then
          return
        end
        begin(bufnr)
      end
      local step = builds_api.find(records, ctx.step.id) or ctx.step
      ctx.step = step
      ctx.job = builds_api.find(records, ctx.job.id) or ctx.job
      ctx.stage = builds_api.stage_of(records, ctx.job)
      ctx.step_done = builds_api.is_completed(step.state)
      if step.log then
        ctx.log_id = step.log.id
      end
      append_log(bufnr, opts, ctx.step_done)
    end, { silent = opts and opts.polling })
  end)
end

-- Buffer lifecycle ----------------------------------------------------------

local function current_item(bufnr)
  local state = views[bufnr]
  if not state then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return state.items and state.items[lnum]
end

local function select_item(bufnr)
  local state = views[bufnr]
  local item = current_item(bufnr)
  if not state or not item then
    return
  end
  local ctx = state.ctx
  if item.kind == "nav" then
    -- Header line: jump back to the buffer of that level (no-op on the current one)
    if item.target == "live" then
      M.toggle_live()
    elseif item.target == "cancel" then
      M.cancel(bufnr)
    elseif item.target == "new_run" then
      M.new_run(nil, bufnr)
    elseif item.target == state.kind then
      return
    elseif item.target == "runs" then
      M.open_runs(ctx.run.definition_id, ctx.run.definition_name, ctx.run.id)
    elseif item.target == "stages" then
      M.open_run(ctx.run, item.record and item.record.id)
    end
  elseif item.kind == "run" then
    M.open_run(item.run, nil, { watch = true })
  elseif item.kind == "stage" or item.kind == "job" then
    toggle(bufnr, item)
  elseif item.kind == "step" then
    if not item.record.log then
      vim.notify("Workhorse: No log for this step yet", vim.log.levels.INFO)
      return
    end
    M.open_log(ctx.run, item.job, item.record)
  end
end

local function go_parent(bufnr)
  local state = views[bufnr]
  if not state then
    return
  end
  local ctx = state.ctx
  if state.kind == "stages" then
    M.open_runs(ctx.run.definition_id, ctx.run.definition_name, ctx.run.id)
  elseif state.kind == "log" then
    M.open_run(ctx.run, ctx.step.id)
  end
end

local function browser_url(bufnr)
  local state = views[bufnr]
  local ctx = state.ctx
  local item = current_item(bufnr)
  if item and item.run then
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

local function set_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true }
  -- Enter and Space both activate: toggle a stage/job, open a step's log, follow a header link
  vim.keymap.set("n", "<CR>", function()
    select_item(bufnr)
  end, opts)
  vim.keymap.set("n", "<Space>", function()
    select_item(bufnr)
  end, opts)
  vim.keymap.set("n", "-", function()
    go_parent(bufnr)
  end, opts)
  vim.keymap.set("n", "<BS>", function()
    go_parent(bufnr)
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    go_parent(bufnr)
  end, opts)
  vim.keymap.set("n", "<leader>R", function()
    M.refresh(bufnr)
  end, opts)
  vim.keymap.set("n", "<leader>wu", M.toggle_live, opts)
  vim.keymap.set("n", "<leader>wx", function()
    M.cancel(bufnr)
  end, opts)
  vim.keymap.set("n", "<leader>wn", function()
    M.new_run(nil, bufnr)
  end, opts)
  vim.keymap.set("n", "gw", function()
    open_url(browser_url(bufnr))
  end, opts)
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end, opts)
end

local function setup_buffer(bufnr)
  set_keymaps(bufnr)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      local state = views[bufnr]
      if state then
        stop_timer(state)
        buffers_by_key[state.key] = nil
        views[bufnr] = nil
        local header_buf = state.header_buf
        if header_buf then
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(header_buf) then
              vim.api.nvim_buf_delete(header_buf, { force = true })
            end
          end)
        end
      end
    end,
  })
end

-- Scratch buffer holding the copy of a view's header pinned while scrolling
local function create_header_buf()
  local header_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[header_buf].filetype = "workhorse-build"
  vim.bo[header_buf].modifiable = false
  return header_buf
end

-- Open (or switch to) the buffer for a view and (re)load it
-- `focus` is the id of the record/run to put the cursor on
local function open_view(key, name, kind, ctx, focus)
  local existing = buffers_by_key[key]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_set_current_buf(existing)
    if focus then
      focus_key(existing, focus)
      views[existing].focus_key = focus
    end
    loaders[kind](existing)
    return existing
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  -- Steps of different jobs can share a name; the view key keeps their buffers apart
  if not pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|" .. name) then
    vim.api.nvim_buf_set_name(bufnr, "Workhorse|" .. name .. "|" .. key)
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = kind == "log" and "workhorse-build-log" or "workhorse-build"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading..." })
  vim.bo[bufnr].modifiable = false

  views[bufnr] = { key = key, kind = kind, ctx = ctx, focus_key = focus }
  buffers_by_key[key] = bufnr
  setup_buffer(bufnr)

  views[bufnr].header_buf = create_header_buf()
  vim.api.nvim_set_current_buf(bufnr)
  if kind == "log" then
    views[bufnr].head_count = 0
    render_header(bufnr)
  end
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

-- Resize ------------------------------------------------------------------

-- Redraw a view from the data it already holds (no request), so trimmed titles
-- and the separator follow the new width
local function rerender(bufnr)
  local state = views[bufnr]
  if not state.items then
    return -- still loading; the first render will use the current width
  end
  if state.kind == "runs" and state.ctx.runs then
    render_runs(bufnr)
  elseif state.kind == "stages" and state.ctx.records then
    render_tree(bufnr)
  elseif state.kind == "log" then
    render_header(bufnr)
  end
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = vim.api.nvim_create_augroup("workhorse_builds_resize", { clear = true }),
  callback = function()
    for bufnr, state in pairs(views) do
      if vim.api.nvim_buf_is_valid(bufnr) and #windows_of(bufnr) > 0 then
        local previous = state.width
        if view_width(bufnr) ~= previous then
          rerender(bufnr)
        end
      end
    end
  end,
})

-- Public API ----------------------------------------------------------------

-- Fuzzy-pick a pipeline definition, then open its runs
function M.pick()
  if not check_config() then
    return
  end
  require("workhorse.telescope.builds").pick()
end

function M.open_runs(definition_id, definition_name, focus_run_id)
  if not check_config() then
    return
  end
  definition_id = tonumber(definition_id) or definition_id
  local buf_label = (definition_name or tostring(definition_id)):gsub("[%s/\\|]+", "_")
  return open_view("runs:" .. definition_id, "builds|" .. buf_label, "runs", {
    definition_id = definition_id,
    definition_name = definition_name,
  }, focus_run_id)
end

-- opts.watch: enable live watching when the run is still going (builds.live_on_running).
-- Set when a run is opened from the runs list or right after queuing it, never when
-- navigating back up from a log, so turning live watching off there sticks.
function M.open_run(run, focus_id, opts)
  local watch = opts and opts.watch and config.get().builds.live_on_running
    and not builds_api.is_completed(run.status)
  if watch then
    live = true
    local existing = buffers_by_key["stages:" .. run.id]
    if existing and views[existing] then
      views[existing].ctx.follow_once = true
    end
  end
  return open_view("stages:" .. run.id, "build|" .. run.id, "stages", { run = run, expanded = {}, follow_once = watch or nil },
    focus_id)
end

function M.open_log(run, job, step)
  return open_view("log:" .. run.id .. ":" .. step.id, "build|" .. run.id .. "|log|" .. step.name:gsub("[%s/\\|]+", "_"),
    "log", { run = run, job = job, step = step, log_id = step.log.id, loaded = 0 })
end

-- Reopen the runs of the last opened pipeline, skipping the picker
function M.resume()
  local last = require("workhorse.session").get_last_build()
  if not last then
    vim.notify("Workhorse: No previous pipeline to resume", vim.log.levels.WARN)
    return
  end
  return M.open_runs(last.id, last.name)
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

-- Toggle live watching: visible run tree and log views jump to the latest step's
-- log, and every tick (builds.live_interval) follows it as steps start and finish
function M.toggle_live()
  live = not live
  vim.notify("Workhorse: Live watching " .. (live and "enabled" or "disabled"), vim.log.levels.INFO)
  -- Snapshot first: following a log opens new views, and cached timelines answer synchronously
  local visible = {}
  for bufnr, state in pairs(views) do
    -- Timers restart with the interval of the new mode on the next load
    stop_timer(state)
    if vim.api.nvim_buf_is_valid(bufnr) and #windows_of(bufnr) > 0 then
      table.insert(visible, bufnr)
    end
  end
  for _, bufnr in ipairs(visible) do
    local state = views[bufnr]
    if state then
      rerender(bufnr)
      loaders[state.kind](bufnr, { polling = true })
    end
  end
end

-- Open the "Run new build" form of a pipeline; without an id, of the pipeline
-- shown in build view `bufnr` (default: current buffer)
function M.new_run(definition_id, bufnr)
  if not check_config() then
    return
  end
  if not definition_id then
    local state = views[bufnr or vim.api.nvim_get_current_buf()]
    local ctx = state and state.ctx
    definition_id = ctx and (ctx.definition_id or (ctx.run and ctx.run.definition_id))
    if not definition_id then
      vim.notify("Workhorse: Not in a build buffer (use :Workhorse builds new <id>)", vim.log.levels.WARN)
      return
    end
    local name = ctx.definition_name or (ctx.run and ctx.run.definition_name)
    return require("workhorse.builds.new_run").open(definition_id, name)
  end
  require("workhorse.builds.new_run").open(definition_id)
end

-- Cancel the run of a build view (on the runs list: the run under the cursor), after confirming
function M.cancel(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = views[bufnr]
  if not state then
    return
  end
  local item = current_item(bufnr)
  local run = (item and item.run) or state.ctx.run
  if not run then
    vim.notify("Workhorse: No run under the cursor", vim.log.levels.WARN)
    return
  end
  if builds_api.is_completed(run.status) or run.status == "cancelling" then
    vim.notify("Workhorse: Run #" .. (run.build_number or run.id) .. " is not running", vim.log.levels.INFO)
    return
  end
  local prompt = "Cancel run #" .. (run.build_number or run.id) .. " of " .. (run.definition_name or "this pipeline") .. "?"
  if vim.fn.confirm(prompt, "&Cancel build\n&Keep running", 2) ~= 1 then
    return
  end
  builds_api.cancel_build(run.id, function(updated, err)
    if err then
      vim.notify("Workhorse: Failed to cancel run: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Workhorse: Cancelling run #" .. (run.build_number or run.id), vim.log.levels.INFO)
    if updated and views[bufnr] and views[bufnr].ctx.run and views[bufnr].ctx.run.id == updated.id then
      views[bufnr].ctx.run = updated
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.refresh(bufnr)
    end
  end)
end

-- Number column of a pinned header: the numbers the log window shows on those lines
function M._pinned_number()
  -- The statuscolumn is evaluated with the window being drawn as the current one
  local float = vim.api.nvim_get_current_win()
  for win, f in pairs(pinned) do
    if f == float and vim.api.nvim_win_is_valid(win) then
      local lnum = vim.v.lnum
      local number = lnum
      if vim.wo[win].relativenumber then
        local cursor = vim.api.nvim_win_get_cursor(win)[1]
        number = (cursor == lnum and vim.wo[win].number) and lnum or math.abs(cursor - lnum)
      end
      return "%#LineNrAbove#" .. string.format("%" .. (vim.wo[float].numberwidth - 1) .. "d ", number)
    end
  end
  return ""
end

function M.is_build_buffer(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

return M
