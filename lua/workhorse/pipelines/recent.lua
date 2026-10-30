-- Recent tab of the pipelines screen: the pipelines that ran most recently, newest first, without
-- their folders, `pipelines.recent_top` at a time (`↓ Load N more` at the end loads the next
-- ones). They are found by paging the project's runs (newest first) until enough distinct
-- pipelines show up; the run found for each is its latest, so it seeds the status column
-- (pipelines/status.lua), which then keeps the visible ones up to date. The repository cache
-- learns the pipelines found (a new one is added to it).
local M = {}

local builds_api = require("workhorse.api.builds")
local config = require("workhorse.config")
local status = require("workhorse.pipelines.status")
local tabs = require("workhorse.pipelines.tabs")
local header = require("workhorse.ui.header")

local ns = vim.api.nvim_create_namespace("workhorse_pipelines_recent")

-- Runs per request, and requests per load at most (pipelines that ran long ago take many runs to
-- reach; the next load carries on from there)
local PAGE = 100
local MAX_PAGES = 10

-- [bufnr] = { pipelines = { { id, name } }, seen = { [id] = true }, seen_runs, max_time,
-- exhausted, loading, generation, items = { [lnum] = { kind = "pipeline", id, name } | { kind = "more" } } }
local buffers = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

function M.is_recent_buffer(bufnr)
  return buffers[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

-- Header of the tab: searching the pipelines and reloading them
local HEADER = header.new("Recent pipelines", nil, {
  { "\u{f002} Search pipelines", function() -- nf-fa-search
    require("workhorse.builds").pick()
  end },
  { "\u{f021} Reload", function(bufnr) -- nf-fa-refresh
    M.refresh(bufnr)
  end, "WorkhorseBuildMeta" },
})

-- Replace the lines below the header with `lines`
local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header.with(HEADER, lines))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
end

local function render(bufnr)
  local state = buffers[bufnr]
  -- `items` is keyed by buffer line: the lines come below the header
  local offset = HEADER.size
  local lines, items = {}, {}
  for _, p in ipairs(state.pipelines) do
    table.insert(lines, ("#%d | %s"):format(p.id, p.name))
    items[offset + #lines] = { kind = "pipeline", id = p.id, name = p.name }
  end
  if #lines == 0 then
    table.insert(lines, state.exhausted and "No pipeline has run yet" or "No pipeline ran recently")
  end
  if not state.exhausted then
    table.insert(lines, "")
    table.insert(lines, "  ↓ Load " .. config.get().pipelines.recent_top .. " more")
    items[offset + #lines] = { kind = "more" }
  end
  state.items = items
  set_lines(bufnr, lines)

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for i, line in ipairs(lines) do
    local lnum = offset + i
    local item = items[lnum]
    if item and item.kind == "pipeline" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { end_col = line:find("|", 1, true), hl_group = "Comment" })
    elseif item and item.kind == "more" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { end_col = #line, hl_group = "WorkhorseBuildRunning" })
    elseif not item and line ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { end_col = #line, hl_group = "WorkhorseBuildMeta" })
    end
  end
  status.render(bufnr)
end

-- Find `count` more pipelines (fewer once the runs run out), then render. The first new one gets
-- the cursor when `focus_new`
local function load(bufnr, count, focus_new)
  local state = buffers[bufnr]
  if not state or state.loading then
    return
  end
  state.loading = true
  local generation = state.generation
  local first_new = #state.pipelines + 1
  local found, pages = 0, 0
  -- The pipelines found, for the repository cache
  local learned = {}

  local function done()
    state.loading = false
    render(bufnr)
    if #learned > 0 then
      require("workhorse.repos").learn_definitions(learned)
    end
    if focus_new and state.pipelines[first_new] then
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        vim.api.nvim_win_set_cursor(win, { HEADER.size + first_new, 0 })
      end
    end
  end

  local function step()
    pages = pages + 1
    builds_api.recent_builds(state.max_time, PAGE, function(runs, err)
      if not buffers[bufnr] or state.generation ~= generation or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if not runs then
        state.loading = false
        notify("Failed to list the recent pipelines: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
        if #state.pipelines == 0 then
          set_lines(bufnr, { "Failed to list the recent pipelines (<leader>R to retry)" })
        end
        return
      end
      -- Stop at the count: the next load carries on from the last run looked at (maxTime keeps
      -- runs queued at that same time, already seen ones are skipped)
      local consumed = 0
      for _, run in ipairs(runs) do
        if found >= count then
          break
        end
        consumed = consumed + 1
        if not state.seen_runs[run.id] then
          state.seen_runs[run.id] = true
          local id = run.definition_id
          if id and not state.seen[id] then
            state.seen[id] = true
            table.insert(state.pipelines, { id = id, name = run.definition_name or tostring(id) })
            if run.definition_name then
              table.insert(learned, { id = id, name = run.definition_name, path = run.definition_path,
                repository_id = run.repository_id })
            end
            -- The newest run of the pipeline: its status needs no request of its own
            status.seed(id, run)
            found = found + 1
          end
        end
        state.max_time = run.queue_time or state.max_time
      end
      state.exhausted = #runs < PAGE and consumed == #runs
      if found < count and not state.exhausted and pages < MAX_PAGES then
        step()
      else
        done()
      end
    end)
  end
  step()
end

local function reset(bufnr)
  local state = buffers[bufnr]
  state.generation = state.generation + 1
  state.pipelines, state.seen, state.seen_runs, state.max_time = {}, {}, {}, nil
  state.exhausted, state.loading = false, false
end

local function current_item(bufnr)
  local state = buffers[bufnr]
  return state.items and state.items[vim.api.nvim_win_get_cursor(0)[1]]
end

local function setup_keymaps(bufnr)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  local function load_more()
    load(bufnr, config.get().pipelines.recent_top, true)
  end
  map("<CR>", function()
    local action = header.action(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    if action then
      return action(bufnr)
    end
    local item = current_item(bufnr)
    if item and item.kind == "pipeline" then
      require("workhorse.builds").open_runs(item.id, item.name)
    elseif item and item.kind == "more" then
      load_more()
    end
  end, "open the runs of the pipeline (or the header action)")
  local function open_in_browser()
    local item = current_item(bufnr)
    if item and item.kind == "pipeline" then
      require("workhorse.builds").open_definition_in_browser(item.id)
    else
      notify("No pipeline on this line", vim.log.levels.WARN)
    end
  end
  map("gw", open_in_browser, "open the pipeline in the browser")
  map("gb", open_in_browser, "open the pipeline in the browser")
  require("workhorse.builds").map_yank(bufnr, open_in_browser, "the pipeline")
  map("<leader>wm", load_more, "load more recent pipelines")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the recent pipelines")
  tabs.setup_buffer(bufnr)
end

--- Show the Recent tab in the current window (created and loaded the first time)
function M.open()
  for bufnr in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_win_set_buf(0, bufnr)
      return bufnr
    end
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "Workhorse|pipelines|recent")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-pipelines"
  set_lines(bufnr, { "Loading recent pipelines..." })
  buffers[bufnr] = { generation = 0 }
  reset(bufnr)
  setup_keymaps(bufnr)
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("workhorse_pipelines_recent_" .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
  status.attach(bufnr)
  vim.api.nvim_win_set_buf(0, bufnr)
  header.attach(bufnr, HEADER)
  header.focus_content(bufnr)
  load(bufnr, config.get().pipelines.recent_top)
  return bufnr
end

--- Reload the Recent tab: as many pipelines as listed (opts.hard: back to the first page, cursor
--- on top). Returns false when `bufnr` (default: current) is not the Recent tab
function M.refresh(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return false
  end
  local top = config.get().pipelines.recent_top
  local count = (opts and opts.hard) and top or math.max(#state.pipelines, top)
  reset(bufnr)
  if opts and opts.hard then
    set_lines(bufnr, { "Loading recent pipelines..." })
    header.focus_content(bufnr)
  end
  load(bufnr, count)
  return true
end

return M
