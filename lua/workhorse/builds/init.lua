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
  apply_view(bufnr, render.render_stages(ctx.run, ctx.records, view_width(bufnr), ctx.expanded))
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

local function log_header(bufnr)
  local ctx = views[bufnr].ctx
  return render.render_log_header(ctx.run, ctx.stage or ctx.job, ctx.job, ctx.step, view_width(bufnr))
end

-- Fetch only the lines past what is already shown, following the tail when the
-- cursor sits on the last line. The header (run > stage > job > step) is drawn
-- with the first batch and refreshed in place afterwards.
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

    local header = log_header(bufnr)
    if #lines > 0 then
      if ctx.loaded == 0 then
        -- render_log appends into the header view, so measure the header first
        local header_len = #header.lines
        render.apply(bufnr, render.render_log(lines, header))
        state.items = header.items -- header links; log lines carry no items
        -- Start on the first log line, below the header
        for _, win in ipairs(windows_of(bufnr)) do
          vim.api.nvim_win_set_cursor(win, { header_len + 1, 0 })
        end
      else
        render.replace_top(bufnr, header)
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
      render.apply(bufnr, render.render_log({ done and "(empty log)" or "Waiting for log..." }, header))
      state.items = header.items
    else
      render.replace_top(bufnr, header)
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
    ctx.job = builds_api.find(records, ctx.job.id) or ctx.job
    ctx.stage = builds_api.stage_of(records, ctx.job)
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
  if item.kind == "nav" then
    -- Header line: jump back to the buffer of that level (no-op on the current one)
    if item.target == state.kind then
      return
    elseif item.target == "runs" then
      M.open_runs(ctx.run.definition_id, ctx.run.definition_name, ctx.run.id)
    elseif item.target == "stages" then
      M.open_run(ctx.run, item.record and item.record.id)
    end
  elseif item.kind == "run" then
    M.open_run(item.run)
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

local function setup_buffer(bufnr)
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
  vim.api.nvim_buf_set_name(bufnr, "Workhorse|" .. name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = kind == "log" and "workhorse-build-log" or "workhorse-build"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading..." })
  vim.bo[bufnr].modifiable = false

  views[bufnr] = { key = key, kind = kind, ctx = ctx, focus_key = focus }
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
    render.replace_top(bufnr, log_header(bufnr))
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

function M.open_run(run, focus_id)
  return open_view("stages:" .. run.id, "build|" .. run.id, "stages", { run = run, expanded = {} }, focus_id)
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

function M.is_build_buffer(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

return M
