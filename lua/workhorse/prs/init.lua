local M = {}

local prs_api = require("workhorse.api.pullrequests")
local builds_api = require("workhorse.api.builds")
local render = require("workhorse.builds.render")
local diff = require("workhorse.prs.diff")
local cache = require("workhorse.cache")
local config = require("workhorse.config")
local pinned = require("workhorse.ui.pinned")
local choices = require("workhorse.ui.choices")
local reviewers = require("workhorse.prs.reviewers")
local work_items = require("workhorse.prs.work_items")

local uv = vim.uv or vim.loop
-- Status of the builds on the Overview tab, drawn apart so the elapsed time ticks without re-rendering
local builds_ns = vim.api.nvim_create_namespace("workhorse_prs_builds")
local BUILDS_TICK = 1000

-- Per-buffer view state: { key, kind = "list"|"pr", ctx, items, width, header_lines (the
-- header ends at its rule; it stays frozen at the top while scrolling, see ui/pinned.lua) }
local views = {}
-- View key -> bufnr, so reopening a list or pull request reuses its buffer
local buffers_by_key = {}

local TABS = { "overview", "changes" }
local TAB_LABELS = { overview = "Overview", changes = "Changes" }
-- Tabs of earlier versions (`prs.default_tab`), now sections of the Overview or renamed
local LEGACY_TABS = { status = "overview", updates = "overview", commits = "overview", files = "changes" }

local function open_url(url)
  require("workhorse.builds").open_url(url)
end

local function windows_of(bufnr)
  return vim.fn.win_findbuf(bufnr)
end

local function view_width(bufnr)
  local win = windows_of(bufnr)[1]
  local width = win and vim.api.nvim_win_get_width(win) or vim.o.columns
  if views[bufnr] then
    views[bufnr].width = width
  end
  return width
end

local function short_branch(ref)
  return ((ref or ""):gsub("^refs/heads/", ""))
end

local function short_sha(sha)
  return (sha or ""):sub(1, 7)
end

local function first_line(text)
  return ((text or ""):gsub("\r", "")):match("^[^\n]*")
end

local function repo_label(repo)
  return repo.project.name .. "/" .. repo.name
end

-- Identity of a line's item, used to keep the cursor on the same thing across re-renders
local function item_key(item)
  if not item then
    return nil
  end
  if item.kind == "pr" then
    return "pr:" .. item.pr.id
  elseif item.kind == "file" or item.kind == "file_header" then
    return item.kind .. ":" .. item.file.path
  elseif item.kind == "diff_line" then
    return "line:" .. item.file.path .. ":" .. (item.old or "") .. ":" .. (item.new or "")
  elseif item.kind == "commit" then
    return "commit:" .. item.commit.id
  elseif item.kind == "thread" then
    return "thread:" .. item.thread.id
  elseif item.kind == "build" then
    return "build:" .. (item.run.origin or "") .. ":" .. (item.run.definition_id or item.run.id)
  elseif item.kind == "check" then
    return "check:" .. item.check.id
  elseif item.kind == "nav" then
    return "nav:" .. item.target
  elseif item.kind == "edit" then
    return "edit:" .. item.section .. ":" .. item.index
  end
end

local function find_line(bufnr, key)
  local state = views[bufnr]
  for lnum, item in pairs(state and state.items or {}) do
    if item_key(item) == key then
      return lnum
    end
  end
end

-- Write `view` to the buffer, keeping each window on the item it was on (or `focus`, a key);
-- `opts` goes to render.apply (an editable Overview: see render_pr)
local function apply_view(bufnr, view, focus, opts)
  local state = views[bufnr]
  local cursors = {}
  for _, win in ipairs(windows_of(bufnr)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    cursors[win] = { lnum = cursor[1], col = cursor[2], key = focus or item_key(state.items and state.items[cursor[1]]) }
  end
  render.apply(bufnr, view, opts)
  state.items = view.items
  state.header_lines = view.rule or 0
  pinned.refresh(bufnr)
  for win, pos in pairs(cursors) do
    local target = math.min(pos.key and find_line(bufnr, pos.key) or pos.lnum, vim.api.nvim_buf_line_count(bufnr))
    -- Same line (e.g. the one just edited): the column stays too
    vim.api.nvim_win_set_cursor(win, { target, target == pos.lnum and pos.col or 0 })
  end
end

local function current_item(bufnr)
  local state = views[bufnr]
  if not state then
    return nil
  end
  return state.items and state.items[vim.api.nvim_win_get_cursor(0)[1]]
end

-- Pull request line: status, id, title (trimmed to fit), author and branches; the reviewers'
-- votes and the date go on the right
local function pr_line(view, pr, width)
  local icon, hl = prs_api.status_icon(pr)
  local virt = {}
  for _, r in ipairs(pr.reviewers) do
    if r.vote ~= 0 then
      local _, vote_icon, vote_hl = prs_api.vote_display(r.vote)
      table.insert(virt, { vote_icon .. " ", vote_hl })
    end
  end
  local date = builds_api.format_date(pr.status == "active" and pr.creation_date or (pr.closed_date or pr.creation_date))
  table.insert(virt, { date, "WorkhorseBuildDate" })

  local tail = {
    { "  " .. (pr.created_by or ""), "WorkhorseBuildAuthor" },
    { "  " .. short_branch(pr.source_ref) .. " → " .. short_branch(pr.target_ref), "WorkhorseBuildBranch" },
  }
  local used = vim.fn.strdisplaywidth("  " .. icon .. " !" .. pr.id .. " ")
  for _, seg in ipairs(tail) do
    used = used + vim.fn.strdisplaywidth(seg[1])
  end
  local virt_width = 0
  for _, chunk in ipairs(virt) do
    virt_width = virt_width + vim.fn.strdisplaywidth(chunk[1])
  end
  local room = math.max(width - used - virt_width - 2, 20)
  local title = (pr.is_draft and "[Draft] " or "") .. pr.title
  local segments = {
    { "  " },
    { icon, hl },
    { " !" .. pr.id .. " ", "WorkhorseBuildMeta" },
    { render.truncate(title, room), pr.is_draft and "WorkhorsePRDraft" or "WorkhorseBuildTitle" },
  }
  vim.list_extend(segments, tail)
  render.add_line(view, segments, { kind = "pr", pr = pr }, virt)
end

-- List view -------------------------------------------------------------------

local SECTIONS = {
  { status = "active", label = "Active" },
  { status = "completed", label = "Completed" },
  { status = "abandoned", label = "Abandoned" },
}

local function render_list(bufnr, focus)
  local state = views[bufnr]
  local ctx = state.ctx
  local width = view_width(bufnr)
  local view = render.new_view()
  -- <leader>wN only in a clone of the repository (see detect_clone)
  local new_hint = { { "<leader>wn new pull request", "WorkhorseRunHint" } }
  if ctx.remote then
    table.insert(new_hint, { "  <leader>wN push and create", "WorkhorseRunHint" })
  end
  render.add_line(view, { { repo_label(ctx.repo), "WorkhorseBuildHeader" } }, { kind = "nav", target = "repo" },
    new_hint)
  render.add_separator(view, width)
  local any = false
  for _, section in ipairs(SECTIONS) do
    local prs = vim.tbl_filter(function(pr)
      return pr.status == section.status
    end, ctx.prs)
    -- Active and completed always show; abandoned only when there are some
    if #prs > 0 or section.status ~= "abandoned" then
      if any then
        render.add_line(view, { { "" } })
      end
      any = true
      render.add_line(view, { { section.label .. " (" .. #prs .. ")", "WorkhorseRunSection" } })
      for _, pr in ipairs(prs) do
        pr_line(view, pr, width)
      end
      if #prs == 0 then
        render.add_line(view, { { "  None", "WorkhorseBuildMeta" } })
      end
    end
  end
  if not ctx.exhausted then
    render.add_line(view, { { "" } })
    render.add_line(view, { { "  ↓ Load " .. config.get().prs.top .. " more", "WorkhorseBuildRunning" } },
      { kind = "nav", target = "more" })
  end
  apply_view(bufnr, view, focus)
  if not state.cursor_placed then
    state.cursor_placed = true
    for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
      if state.items[lnum] and state.items[lnum].kind == "pr" then
        for _, win in ipairs(windows_of(bufnr)) do
          vim.api.nvim_win_set_cursor(win, { lnum, 0 })
        end
        break
      end
    end
  end
end

-- Load the next page of the list; `reload` fetches every page loaded so far again instead
local function load_list(bufnr, reload)
  local state = views[bufnr]
  if not state or state.loading then
    return
  end
  local ctx = state.ctx
  local top = config.get().prs.top
  local skip, count = #ctx.prs, top
  if reload then
    skip, count = 0, math.max(#ctx.prs, top)
  end
  state.loading = true
  prs_api.list(ctx.repo, skip, count, function(page, err)
    state.loading = false
    if not views[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not page then
      vim.notify("Workhorse: Failed to load pull requests: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    local focus
    if reload then
      ctx.prs = page
    else
      -- New pull requests created meanwhile shift the pages: skip the ones already listed
      local seen = {}
      for _, pr in ipairs(ctx.prs) do
        seen[pr.id] = true
      end
      for _, pr in ipairs(page) do
        if not seen[pr.id] then
          table.insert(ctx.prs, pr)
          focus = focus or ("pr:" .. pr.id)
        end
      end
      if skip == 0 then
        require("workhorse.session").save_last_repo(ctx.repo)
        focus = nil
      end
    end
    ctx.exhausted = #page < count
    render_list(bufnr, focus)
  end)
end

-- Put a pull request fetched again in the list of its repository, if open
local function update_list_entry(repo, pr)
  local bufnr = buffers_by_key["prs:" .. repo.id]
  local state = bufnr and views[bufnr]
  if not state then
    return
  end
  for i, listed in ipairs(state.ctx.prs) do
    if listed.id == pr.id then
      state.ctx.prs[i] = pr
      if vim.api.nvim_buf_is_valid(bufnr) and #windows_of(bufnr) > 0 then
        render_list(bufnr)
      end
      return
    end
  end
end

-- Pull request view: data ----------------------------------------------------

-- What each tab needs loaded before it can render
local NEEDS = {
  overview = { "pr", "threads", "iterations", "commits", "work_items" },
  changes = { "pr", "iterations", "changes", "threads" },
}

local fetchers = {
  pr = function(ctx, cb, opts)
    prs_api.get(ctx.repo, ctx.id, cb, opts)
  end,
  threads = function(ctx, cb, opts)
    prs_api.threads(ctx.repo, ctx.id, cb, opts)
  end,
  iterations = function(ctx, cb, opts)
    prs_api.iterations(ctx.repo, ctx.id, cb, opts)
  end,
  commits = function(ctx, cb, opts)
    prs_api.commits(ctx.repo, ctx.id, cb, opts)
  end,
  work_items = function(ctx, cb, opts)
    work_items.fetch(ctx, cb, opts)
  end,
  -- Files changed by the last push, against the merge base
  changes = function(ctx, cb, opts)
    local last = ctx.data.iterations[#ctx.data.iterations]
    if not last then
      return cb({})
    end
    prs_api.iteration_changes(ctx.repo, ctx.id, last.id, cb, opts)
  end,
}

local rerender

local function builds_running(runs, checks)
  for _, run in ipairs(runs or {}) do
    if not builds_api.is_completed(run.status) then
      return true
    end
  end
  -- A check under way (its build queued or running) passes or fails soon
  for _, check in ipairs(checks or {}) do
    if check.status == "running" or (check.status == "queued" and check.build_id and not check.expired) then
      return true
    end
  end
  return false
end

-- Merge commit of a completed pull request (its merge builds are those run on it)
local function merge_commit(ctx)
  local pr = ctx.data.pr
  return pr and pr.status == "completed" and pr.last_merge_commit or nil
end

-- Fetch the builds of the pull request: those run on its merge ref (its checks, origin "check")
-- and, once completed, those its merge started on the target branch (origin "merge"). They do
-- not hold the Overview tab back: it shows them loading (or failed) in their own section, and a
-- failed refresh keeps what is shown
local function fetch_builds(bufnr)
  local ctx = views[bufnr].ctx
  if ctx.loading.builds then
    return
  end
  ctx.loading.builds = true
  local generation = ctx.generation
  local opts = { silent = ctx.data.builds ~= nil }
  -- The merge commit the builds were fetched for: a pull request completed since (or loaded
  -- after them) fetches them again (builds_tick)
  ctx.builds_merge = merge_commit(ctx) or false
  local results, pending = {}, 2

  local function done()
    ctx.loading.builds = nil
    ctx.builds_fetched = uv.now()
    local check, merge = results.check, results.merge
    if check and not merge then
      -- The merge builds failed (notified): the ones shown stay
      merge = vim.tbl_filter(function(run)
        return run.origin == "merge"
      end, ctx.data.builds or {})
    end
    if check then
      local runs = {}
      for origin, list in pairs({ check = check, merge = merge }) do
        for _, run in ipairs(list) do
          run.origin = origin
          table.insert(runs, run)
        end
      end
      -- The checks first, then the merge builds, each by pipeline name (as listed)
      table.sort(runs, function(a, b)
        if a.origin ~= b.origin then
          return a.origin == "check"
        end
        return (a.definition_name or ""):lower() < (b.definition_name or ""):lower()
      end)
      ctx.data.builds, ctx.errors.builds = runs, nil
    elseif not ctx.data.builds then
      ctx.errors.builds = results.err or "unknown error"
    end
    if ctx.tab == "overview" and vim.api.nvim_buf_is_valid(bufnr) then
      rerender(bufnr)
    end
  end

  local function collect(origin)
    return function(runs, err)
      if not views[bufnr] or ctx.generation ~= generation then
        return
      end
      results[origin] = runs
      results.err = results.err or err
      pending = pending - 1
      if pending == 0 then
        done()
      end
    end
  end

  prs_api.builds(ctx.repo, ctx.id, collect("check"), opts)
  if ctx.data.pr then
    prs_api.merge_builds(ctx.repo, ctx.data.pr, collect("merge"), opts)
  else
    collect("merge")({})
  end
end

-- Fetch the checks of the pull request (the evaluations of its branch policies). Like the builds,
-- they do not hold the Overview back, and a failed refresh keeps what is shown; redraws only when
-- they changed
local function fetch_checks(bufnr)
  local ctx = views[bufnr].ctx
  if ctx.loading.checks then
    return
  end
  ctx.loading.checks = true
  local generation = ctx.generation
  prs_api.checks(ctx.repo, ctx.id, function(checks, err)
    if not views[bufnr] or ctx.generation ~= generation then
      return
    end
    ctx.loading.checks = nil
    local changed = false
    if checks then
      changed = ctx.errors.checks ~= nil or not vim.deep_equal(checks, ctx.data.checks)
      ctx.data.checks, ctx.errors.checks = checks, nil
    elseif not ctx.data.checks then
      changed = ctx.errors.checks == nil
      ctx.errors.checks = err or "unknown error"
    end
    if changed and ctx.tab == "overview" and vim.api.nvim_buf_is_valid(bufnr) then
      rerender(bufnr)
    end
  end, { silent = ctx.data.checks ~= nil })
end

-- Every second while the Overview tab is shown: fetch the builds and checks again once due
-- (running and idle intervals as in the pipelines list) and redraw the status of the builds, so
-- the elapsed time ticks
local function builds_tick(bufnr)
  local state = views[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) or #windows_of(bufnr) == 0 then
    return
  end
  local ctx = state.ctx
  if ctx.tab ~= "overview" then
    return
  end
  local cfg = config.get().pipelines
  local running = builds_running(ctx.data.builds, ctx.data.checks)
  local interval = running and cfg.status_running_interval or cfg.status_idle_interval
  if not ctx.builds_fetched or uv.now() - ctx.builds_fetched >= interval then
    fetch_builds(bufnr)
    fetch_checks(bufnr)
  elseif ctx.builds_merge ~= (merge_commit(ctx) or false) then
    -- Completed since the builds were fetched (or they were fetched before the pull request)
    fetch_builds(bufnr)
  end
  if running then
    M._draw_builds(bufnr)
  end
end

-- Draw the status of each build line of the buffer
function M._draw_builds(bufnr)
  local state = views[bufnr]
  vim.api.nvim_buf_clear_namespace(bufnr, builds_ns, 0, -1)
  for lnum, item in pairs(state.items or {}) do
    if item.kind == "build" then
      -- Why the build ran: as a check of the pull request, or started by its merge
      local origin = item.run.origin == "merge" and { "after merge  ", "WorkhorseBuildBranch" }
        or { "PR check  ", "WorkhorseBuildMeta" }
      vim.api.nvim_buf_set_extmark(bufnr, builds_ns, lnum - 1, 0, {
        virt_text = vim.list_extend({ origin }, render.run_status(item.run, { branch = false })),
        virt_text_pos = "right_align",
      })
    end
  end
end

-- Load the data `tab` needs (in order: `changes` needs `iterations`), re-rendering as each lands
local function ensure(bufnr, tab)
  local state = views[bufnr]
  if not state then
    return
  end
  local ctx = state.ctx
  for _, name in ipairs(NEEDS[tab]) do
    if ctx.data[name] == nil and not ctx.loading[name] and not ctx.errors[name] then
      if name == "changes" and not ctx.data.iterations then
        -- Started again once the iterations land
        goto continue
      end
      ctx.loading[name] = true
      local generation = ctx.generation
      fetchers[name](ctx, function(data, err)
        if not views[bufnr] or ctx.generation ~= generation then
          return
        end
        ctx.loading[name] = nil
        if data == nil then
          ctx.errors[name] = err or "unknown error"
        else
          ctx.data[name] = data
          if name == "pr" then
            update_list_entry(ctx.repo, data)
          end
        end
        ensure(bufnr, ctx.tab)
        rerender(bufnr)
      end)
    end
    ::continue::
  end
  if tab == "overview" and ctx.data.builds == nil and not ctx.errors.builds then
    fetch_builds(bufnr)
  end
  if tab == "overview" and ctx.data.checks == nil and not ctx.errors.checks then
    fetch_checks(bufnr)
  end
  if tab == "changes" and ctx.data.changes and not ctx.files then
    M._load_files(bufnr)
  end
end

local function last_iteration_id(iterations)
  local last = iterations and iterations[#iterations]
  return last and last.id
end

-- Fetch again what is loaded (or failed to load), keeping it shown until the new data lands and
-- when a request fails; redraws only when something changed. A push since also reloads the
-- changed files, coming back to the diff line under the cursor once its new diff is there
local function refresh_pr(bufnr)
  local state = views[bufnr]
  if not state or state.kind ~= "pr" then
    return
  end
  local ctx = state.ctx
  -- Asked again (by an action) while a refresh is under way: its data may predate the action
  if ctx.refreshing then
    ctx.refresh_again = true
    return
  end
  ctx.refreshed = uv.now()
  -- The checks follow the votes, the linked work items and the comments
  if ctx.data.checks ~= nil or ctx.errors.checks then
    fetch_checks(bufnr)
  end
  local names = {}
  for _, name in ipairs({ "pr", "threads", "iterations", "commits", "work_items" }) do
    if (ctx.data[name] ~= nil or ctx.errors[name]) and not ctx.loading[name] then
      table.insert(names, name)
    end
  end
  if #names == 0 then
    return
  end
  ctx.refreshing = true
  local generation = ctx.generation
  local fresh, pending = {}, #names

  local function reload_changes()
    fetchers.changes(ctx, function(changes)
      if not views[bufnr] or ctx.generation ~= generation then
        return
      end
      ctx.changes_stale = changes == nil or nil
      if not changes then
        return
      end
      local item = vim.api.nvim_get_current_buf() == bufnr and ctx.tab == "changes" and current_item(bufnr)
      if item and item.kind == "diff_line" then
        ctx.jump = { path = item.file.path, new = item.new, old = item.old }
      end
      ctx.data.changes, ctx.files = changes, nil
      ensure(bufnr, ctx.tab)
      rerender(bufnr)
    end, { silent = true })
  end

  local function finish()
    ctx.refreshing = nil
    local pushed = fresh.iterations and last_iteration_id(fresh.iterations) ~= last_iteration_id(ctx.data.iterations)
    local changed = false
    for name, data in pairs(fresh) do
      if ctx.errors[name] or not vim.deep_equal(data, ctx.data[name]) then
        ctx.data[name], ctx.errors[name], changed = data, nil, true
        if name == "pr" then
          update_list_entry(ctx.repo, data)
        end
      end
    end
    if (pushed or ctx.changes_stale) and ctx.data.changes ~= nil then
      reload_changes()
    end
    if changed then
      ensure(bufnr, ctx.tab)
      rerender(bufnr)
    end
    if ctx.refresh_again then
      ctx.refresh_again = nil
      refresh_pr(bufnr)
    end
  end

  for _, name in ipairs(names) do
    fetchers[name](ctx, function(data)
      if not views[bufnr] or ctx.generation ~= generation then
        return
      end
      fresh[name] = data
      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end, { silent = true })
  end
end

-- Every second: the builds, and every prs.refresh_interval while shown, the rest of the pull request
local function tick(bufnr)
  builds_tick(bufnr)
  local state = views[bufnr]
  local interval = config.get().prs.refresh_interval
  if state and interval and interval > 0 and vim.api.nvim_buf_is_valid(bufnr) and #windows_of(bufnr) > 0
    and uv.now() - (state.ctx.refreshed or 0) >= interval then
    refresh_pr(bufnr)
  end
end

local render_pending = {}
-- Coalesce the re-renders of files landing in bursts
local function schedule_render(bufnr)
  if render_pending[bufnr] then
    return
  end
  render_pending[bufnr] = true
  vim.defer_fn(function()
    render_pending[bufnr] = nil
    if views[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
      rerender(bufnr)
    end
  end, 50)
end

local function fetch_file(repo, path, sha, callback)
  local key = "pr_file:" .. repo.id .. ":" .. sha .. ":" .. path
  local cached = cache.get(key)
  if cached then
    return callback(cached.text, cached.err)
  end
  prs_api.file_at_commit(repo, path, sha, function(text, err)
    -- A file at a commit never changes; failures other than binaries are retried next time
    if text or err == "binary" then
      cache.set(key, { text = text, err = err })
    end
    callback(text, err)
  end)
end

-- Fetch both sides of every changed file (at most prs.max_concurrent at once) and diff them
function M._load_files(bufnr)
  local ctx = views[bufnr].ctx
  local last = ctx.data.iterations[#ctx.data.iterations] or {}
  local base, head = last.common_commit or last.target_commit, last.source_commit
  local files = {}
  for _, change in ipairs(ctx.data.changes) do
    table.insert(files, { path = change.path, original_path = change.original_path, change_type = change.change_type })
  end
  ctx.files = files
  local generation = ctx.generation
  local queue = vim.list_slice(files)
  local in_flight = 0
  local max_bytes = config.get().prs.max_diff_bytes

  local next_file
  local function done(file, old, new, err)
    in_flight = in_flight - 1
    if not views[bufnr] or ctx.generation ~= generation then
      return
    end
    if err then
      file.error = err
    elseif #(old or "") > max_bytes or #(new or "") > max_bytes then
      file.error = "too_large"
    else
      file.diff = diff.compute(old, new)
    end
    if ctx.tab == "changes" then
      schedule_render(bufnr)
    end
    next_file()
  end

  next_file = function()
    while in_flight < config.get().prs.max_concurrent and #queue > 0 do
      local file = table.remove(queue, 1)
      in_flight = in_flight + 1
      local kind = file.change_type or ""
      local has_old, has_new = not kind:find("add", 1, true), not kind:find("delete", 1, true)
      local old_path = file.original_path or file.path
      local old, new, pending, failure = nil, nil, 0, nil
      local function side_done()
        pending = pending - 1
        if pending == 0 then
          done(file, old, new, failure)
        end
      end
      if has_old and base then
        pending = pending + 1
      end
      if has_new and head then
        pending = pending + 1
      end
      if pending == 0 then
        done(file, nil, nil, "no commits to compare")
      else
        if has_old and base then
          fetch_file(ctx.repo, old_path, base, function(text, err)
            old, failure = text, failure or err
            side_done()
          end)
        end
        if has_new and head then
          fetch_file(ctx.repo, file.path, head, function(text, err)
            new, failure = text, failure or err
            side_done()
          end)
        end
      end
    end
  end
  next_file()
end

-- Pull request view: rendering -----------------------------------------------

-- Shows that the data `names` is loading (or failed); true when it is not all there
local function loading_or_error(view, ctx, names)
  for _, name in ipairs(names) do
    if ctx.errors[name] then
      render.add_line(view, { { "  Failed to load " .. name .. ": " .. ctx.errors[name], "WorkhorseBuildFailed" } })
      return true
    end
  end
  for _, name in ipairs(names) do
    if ctx.data[name] == nil then
      render.add_line(view, { { "  Loading…", "WorkhorseBuildMeta" } })
      return true
    end
  end
  return false
end

-- Title, status and branches of the pull request, at the top of every tab
local function add_pr_header(view, ctx, width)
  local pr = ctx.data.pr or ctx.summary
  local title = pr and pr.title or ""
  render.add_line(view, { { render.truncate("!" .. ctx.id .. " " .. title, math.max(width - 2, 20)), "WorkhorseBuildHeader" } },
    { kind = "nav", target = "list" })
  if pr then
    local icon, hl = prs_api.status_icon(pr)
    local status = pr.status == "active" and (pr.is_draft and "Draft" or "Active")
      or (pr.status == "completed" and "Completed" or "Abandoned")
    local segments = {
      { "  " },
      { icon .. " " .. status, hl },
      { "  " .. short_branch(pr.source_ref) .. " → " .. short_branch(pr.target_ref), "WorkhorseBuildBranch" },
      { "  " .. (pr.created_by or ""), "WorkhorseBuildAuthor" },
    }
    render.add_line(view, segments, nil, { { builds_api.format_date(pr.creation_date), "WorkhorseBuildDate" } })
    if pr.status == "active" and pr.merge_status == "conflicts" then
      render.add_line(view, { { "  Merge conflicts: resolve them before completing", "WorkhorseBuildFailed" } })
    end
    if pr.auto_complete_set_by then
      render.add_line(view, { { "  Auto-complete set by " .. pr.auto_complete_set_by, "WorkhorsePRApproved" } })
    end
  end
  render.add_separator(view, width)
end

-- Separator between the sections of a tab, a blank line after it; the header still ends at its
-- own rule
local function add_section_separator(view, width)
  local rule = view.rule
  render.add_separator(view, width, { gap = true })
  view.rule = rule
end

local function add_text_block(view, text, indent, hl)
  for _, line in ipairs(vim.split((text or ""):gsub("\r", ""), "\n", { plain = true })) do
    render.add_line(view, { { indent .. line, hl } })
  end
end

-- Editable sections ---------------------------------------------------------------
--
-- The Reviewers and Work Items sections of the Overview of an active pull request are editable
-- text (prs/reviewers.lua, prs/work_items.lua), saved with <leader><leader>. The rest of the
-- buffer is still rendered from the data: every render puts back the text of those sections as
-- edited (ctx.edits, captured from the buffer after each change), so the edits survive the
-- refreshes, and an edit anywhere else is undone by the next render.

local EDITABLE = { "reviewers", "work_items" }
local SECTION_MODULES = { reviewers = reviewers, work_items = work_items }
-- Header of the section after each one: where its lines end
local NEXT_HEADER = { reviewers = work_items.HEADER, work_items = "Description" }
-- Data each section lists
local SECTION_DATA = { reviewers = "pr", work_items = "work_items" }

-- Whether the pull request can be edited: active, its Overview loaded
local function pr_editable(ctx)
  return ctx.data.pr ~= nil and ctx.data.pr.status == "active" and ctx.data.threads ~= nil
end

local function overview_editable(ctx)
  return ctx.tab == "overview" and pr_editable(ctx)
end

local function section_editable(ctx, name)
  return overview_editable(ctx) and ctx.data[SECTION_DATA[name]] ~= nil
end

local function has_edits(ctx)
  return next(ctx.edits) ~= nil
end

-- Buffer lines first..last of an editable section (after its header, up to the header of the next
-- one), nil when one of them is gone
local function section_range(bufnr, name)
  local state = views[bufnr]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local header
  for lnum = (state.header_lines or 0) + 1, #lines do
    if not header and lines[lnum] == SECTION_MODULES[name].HEADER then
      header = lnum
    elseif header and lines[lnum] == NEXT_HEADER[name] then
      return header + 1, lnum - 1
    end
  end
end

-- Lines of an editable section in the buffer, without the blank ones at its end, and the buffer
-- line of the first one; nil when its headers are gone
local function section_text(bufnr, name)
  local first, last = section_range(bufnr, name)
  if not first then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return lines, first
end

-- The editable section of buffer line `lnum`, if any
local function editable_section_at(bufnr, lnum)
  local state = views[bufnr]
  if not state or state.kind ~= "pr" or not overview_editable(state.ctx) then
    return nil
  end
  for _, name in ipairs(EDITABLE) do
    if section_editable(state.ctx, name) then
      local first, last = section_range(bufnr, name)
      if first and lnum >= first and lnum <= last then
        return name
      end
    end
  end
end

-- Keep the text of the editable sections in ctx.edits (nil for one as rendered from the data); a
-- section whose header was deleted keeps its previous edits (the render puts the header back)
local function capture_edits(bufnr)
  local state = views[bufnr]
  if not state or state.kind ~= "pr" or not state.items then
    return
  end
  local ctx = state.ctx
  for _, name in ipairs(EDITABLE) do
    if section_editable(ctx, name) then
      local lines = section_text(bufnr, name)
      if lines then
        ctx.edits[name] = not vim.deep_equal(lines, SECTION_MODULES[name].canonical(ctx)) and lines or nil
      end
    end
  end
end

-- An editable section (the data as rendered, or its edits) or, until its data is there, its
-- header and the loading (or error) line
local function render_section(view, ctx, name)
  local module = SECTION_MODULES[name]
  local data = SECTION_DATA[name]
  if ctx.data[data] == nil then
    render.add_line(view, { { module.HEADER, "WorkhorseRunSection" } })
    local err = ctx.errors[data]
    render.add_line(view, { { "  " .. (err and ("Failed to load: " .. err) or "Loading…"),
      err and "WorkhorseBuildFailed" or "WorkhorseBuildMeta" } })
    return
  end
  local editable = section_editable(ctx, name)
  -- The section's lines (after its header) are named by their position, to keep the cursor there
  local first = #view.lines + 2
  module.render(view, ctx, editable and ctx.edits[name] or module.canonical(ctx), editable)
  for lnum = first, #view.lines do
    local item = view.items[lnum]
    if item and item.kind == "edit" then
      item.index = lnum - first + 1
    end
  end
end

-- Builds of the checks to queue again: those waiting for it (expired, failed, never started)
local function requeue_targets(ctx)
  return vim.tbl_filter(prs_api.needs_requeue, ctx.data.checks or {})
end

local function add_check_line(view, check)
  local label, icon, hl = prs_api.check_display(check)
  local virt = {}
  local date = builds_api.format_date(check.completed or check.started)
  if prs_api.needs_requeue(check) then
    table.insert(virt, { "<leader>wq re-queue" .. (date ~= "" and "  " or ""), "WorkhorseRunHint" })
  end
  if date ~= "" then
    table.insert(virt, { date, "WorkhorseBuildDate" })
  end
  render.add_line(view, {
    { "  " },
    { icon, hl },
    { " " .. check.name, "WorkhorseBuildTitle" },
    { "  " .. label, hl },
  }, { kind = "check", check = check }, #virt > 0 and virt or nil)
end

-- Required and optional checks of the pull request (the evaluations of the branch policies of its
-- target branch), with how many of them passed; optional ones only when there are some
local function render_checks(view, ctx)
  local checks = ctx.data.checks
  if ctx.errors.checks or not checks then
    render.add_line(view, { { "Required checks", "WorkhorseRunSection" } })
    render.add_line(view, { { ctx.errors.checks and ("  Failed to load checks: " .. ctx.errors.checks) or "  Loading…",
      ctx.errors.checks and "WorkhorseBuildFailed" or "WorkhorseBuildMeta" } })
    render.add_line(view, { { "" } })
    return
  end
  for _, blocking in ipairs({ true, false }) do
    local group = vim.tbl_filter(function(c)
      return c.blocking == blocking
    end, checks)
    if blocking or #group > 0 then
      local passed = #vim.tbl_filter(function(c)
        return c.status == "approved" and not c.expired
      end, group)
      local title = blocking and "Required checks" or "Optional checks"
      render.add_line(view, { { title, "WorkhorseRunSection" },
        { #group > 0 and ("  " .. passed .. "/" .. #group .. " passed") or "",
          passed == #group and "WorkhorsePRApproved" or "WorkhorseBuildMeta" } })
      if #group == 0 then
        render.add_line(view, { { "  None", "WorkhorseBuildMeta" } })
      end
      for _, check in ipairs(group) do
        add_check_line(view, check)
      end
      render.add_line(view, { { "" } })
    end
  end
end

local function render_status(view, ctx)
  local pr = ctx.data.pr
  render.add_line(view, { { "Actions", "WorkhorseRunSection" } })
  if pr.status == "active" then
    render.add_line(view, { { "  Vote…", "WorkhorseBuildRunning" } }, { kind = "nav", target = "vote" },
      { { "<leader>wv", "WorkhorseRunHint" } })
    if not pr.is_draft then
      render.add_line(view, { { "  Complete…", "WorkhorsePRApproved" } }, { kind = "nav", target = "complete" },
        { { "<leader>wc", "WorkhorseRunHint" } })
    end
    local auto = pr.auto_complete_set_by and "  Cancel auto-complete" or "  Set auto-complete…"
    render.add_line(view, { { auto, "WorkhorseBuildRetry" } }, { kind = "nav", target = "auto_complete" },
      { { "<leader>wa", "WorkhorseRunHint" } })
  end
  render.add_line(view, { { "  Copy URL", "WorkhorseBuildMeta" } }, { kind = "nav", target = "copy_url" },
    { { "<leader>wy", "WorkhorseRunHint" } })
  -- Only when Neovim's working directory is a clone of the pull request's repository
  if ctx.remote then
    render.add_line(view, { { "  Checkout this branch", "WorkhorseBuildBranch" } },
      { kind = "nav", target = "checkout" }, { { "<leader>wk", "WorkhorseRunHint" } })
  end
  local requeue = #requeue_targets(ctx)
  if requeue > 0 then
    render.add_line(view, { { ("  Re-queue %d build%s"):format(requeue, requeue == 1 and "" or "s"), "WorkhorseBuildRetry" } },
      { kind = "nav", target = "requeue" }, { { "<leader>wq", "WorkhorseRunHint" } })
  end
  render.add_line(view, { { "" } })

  render_checks(view, ctx)

  -- Latest build of each pipeline run on the pull request, then of each one its merge started;
  -- their status (and which of the two they are) is drawn by _draw_builds
  render.add_line(view, { { "Builds", "WorkhorseRunSection" } })
  local builds = ctx.data.builds
  if ctx.errors.builds then
    render.add_line(view, { { "  Failed to load builds: " .. ctx.errors.builds, "WorkhorseBuildFailed" } })
  elseif not builds then
    render.add_line(view, { { "  Loading…", "WorkhorseBuildMeta" } })
  elseif #builds == 0 then
    render.add_line(view, { { "  None", "WorkhorseBuildMeta" } })
  end
  for _, run in ipairs(builds or {}) do
    render.add_line(view, {
      { "  " .. (run.definition_name or ("Pipeline " .. (run.definition_id or "?"))), "WorkhorseBuildTitle" },
      { "  #" .. (run.build_number or run.id), "WorkhorseBuildMeta" },
    }, { kind = "build", run = run })
  end
  render.add_line(view, { { "" } })

  render_section(view, ctx, "reviewers")
  render.add_line(view, { { "" } })
  render_section(view, ctx, "work_items")
  render.add_line(view, { { "" } })

  render.add_line(view, { { "Description", "WorkhorseRunSection" } })
  if vim.trim(pr.description) == "" then
    render.add_line(view, { { "  No description", "WorkhorseBuildMeta" } })
  else
    add_text_block(view, pr.description, "  ")
  end
  render.add_line(view, { { "" } })

  local threads = ctx.data.threads
  render.add_line(view, { { "Comments (" .. #threads .. ")", "WorkhorseRunSection" } })
  if #threads == 0 then
    render.add_line(view, { { "  None", "WorkhorseBuildMeta" } })
  end
  for i, t in ipairs(threads) do
    if i > 1 then
      render.add_line(view, { { "" } })
    end
    local where = t.file_path and (t.file_path:gsub("^/", "") .. (t.right_line and (":" .. t.right_line)
      or t.left_line and (":" .. t.left_line) or "")) or "General"
    local status_hl = (t.status == "active" or t.status == "pending") and "WorkhorsePRWaiting" or "WorkhorseBuildMeta"
    local item = { kind = "thread", thread = t }
    render.add_line(view, { { "  " .. where, t.file_path and "WorkhorsePRDiffFile" or "WorkhorseBuildTitle" } }, item,
      t.status and { { t.status, status_hl } } or nil)
    for _, c in ipairs(t.comments) do
      local date = builds_api.format_date(c.date)
      render.add_line(view, { { "    " .. c.author, "WorkhorsePRCommentAuthor" },
        { date ~= "" and (" · " .. date) or "", "WorkhorseBuildDate" } }, item)
      for _, line in ipairs(vim.split(c.content:gsub("\r", ""), "\n", { plain = true })) do
        render.add_line(view, { { "      " .. line } }, item)
      end
    end
  end
end

local function render_files(view, ctx, width)
  local files = ctx.files or {}
  local added, removed, pending = 0, 0, 0
  for _, f in ipairs(files) do
    if f.diff then
      added, removed = added + f.diff.added, removed + f.diff.removed
    elseif not f.error then
      pending = pending + 1
    end
  end
  local summary = #files .. " file" .. (#files == 1 and "" or "s") .. " changed"
  render.add_line(view, { { summary, "WorkhorseRunSection" } }, nil, {
    { "+" .. added, "WorkhorsePRApproved" },
    { " -" .. removed, "WorkhorsePRRejected" },
    pending > 0 and { "  (" .. pending .. " loading)", "WorkhorseBuildMeta" } or nil,
  })
  for _, f in ipairs(files) do
    local label, hl = diff.change_label(f.change_type)
    local counts = f.diff and { { "+" .. f.diff.added, "WorkhorsePRApproved" }, { " -" .. f.diff.removed, "WorkhorsePRRejected" } }
      or { { f.error and "!" or "…", "WorkhorseBuildMeta" } }
    render.add_line(view, { { "  " .. label:sub(1, 1):upper(), hl }, { "  " .. f.path:gsub("^/", "") } },
      { kind = "file", file = f }, counts)
  end
  if #files == 0 then
    render.add_line(view, { { "  No files changed", "WorkhorseBuildMeta" } })
  end
  for _, f in ipairs(files) do
    diff.render(view, f, ctx.data.threads, width)
  end
end

local function render_updates(view, ctx)
  local count = ctx.data.iterations and (" (" .. #ctx.data.iterations .. ")") or ""
  render.add_line(view, { { "Updates" .. count, "WorkhorseRunSection" } })
  if loading_or_error(view, ctx, { "iterations" }) then
    return
  end
  local iterations = ctx.data.iterations
  -- Newest first, as on the web
  for i = #iterations, 1, -1 do
    local it = iterations[i]
    local reason = it.reason and it.reason ~= "push" and (" · " .. it.reason) or ""
    render.add_line(view, { { "" } })
    render.add_line(view, {
      { "  Update " .. it.id, "WorkhorseBuildTitle" },
      { reason, "WorkhorseBuildMeta" },
      { "  " .. (it.author or ""), "WorkhorseBuildAuthor" },
    }, it.source_commit and { kind = "commit", commit = { id = it.source_commit } } or nil, {
      { short_sha(it.source_commit) .. "  ", "WorkhorseBuildMeta" },
      { builds_api.format_date(it.created), "WorkhorseBuildDate" },
    })
    if it.description and it.description ~= "" then
      render.add_line(view, { { "    " .. first_line(it.description), "WorkhorseBuildMessage" } })
    end
    for _, c in ipairs(it.commits or {}) do
      render.add_line(view, { { "    " .. short_sha(c.id), "WorkhorseBuildMeta" }, { "  " .. first_line(c.message) } },
        { kind = "commit", commit = c })
    end
  end
end

local function render_commits(view, ctx, width)
  local commits = ctx.data.commits
  render.add_line(view, { { "Commits" .. (commits and (" (" .. #commits .. ")") or ""), "WorkhorseRunSection" } })
  if loading_or_error(view, ctx, { "commits" }) then
    return
  end
  for _, c in ipairs(commits) do
    local sha = "  " .. short_sha(c.id) .. "  "
    local author = "  " .. (c.author or "")
    local date = builds_api.format_date(c.date)
    local room = math.max(width - vim.fn.strdisplaywidth(sha .. author .. date) - 2, 20)
    render.add_line(view, {
      { sha, "WorkhorseBuildMeta" },
      { render.truncate(first_line(c.message), room) },
      { author, "WorkhorseBuildAuthor" },
    }, { kind = "commit", commit = c }, { { date, "WorkhorseBuildDate" } })
  end
end

-- Returns true when the cursor was moved to a comment thread's line. opts.join: a render right
-- after an edit, joined to its undo block (see render.apply)
local function render_pr(bufnr, focus, opts)
  local jumped = false
  local state = views[bufnr]
  local ctx = state.ctx
  local width = view_width(bufnr)
  local view = render.new_view()
  add_pr_header(view, ctx, width)
  if ctx.tab == "overview" then
    -- Status, then Updates and Commits, each shown as soon as its own data is there
    if not loading_or_error(view, ctx, { "pr", "threads" }) then
      render_status(view, ctx)
      add_section_separator(view, width)
      render_updates(view, ctx)
      add_section_separator(view, width)
      render_commits(view, ctx, width)
    end
  elseif not loading_or_error(view, ctx, NEEDS.changes) then
    render_files(view, ctx, width)
  end
  local editable = overview_editable(ctx)
  local join = opts and opts.join
  apply_view(bufnr, view, focus, editable and {
    editable = true,
    join = join,
    -- Out of the undo history when there is nothing of the user's in it to keep (and when the
    -- buffer showed something else, which undo would bring back)
    forget = not join and (not has_edits(ctx) or not state.was_editable),
  } or nil)
  state.was_editable = editable
  -- Edits kept while another tab shows count too (:q warns)
  if pr_editable(ctx) then
    vim.bo[bufnr].modified = has_edits(ctx)
  end
  state.tick = vim.b[bufnr].changedtick
  M._draw_builds(bufnr)
  -- A thread picked on the Overview tab: land on its line once the file's diff is there (in
  -- the window of the pull request: the jump waits while another one is current)
  if ctx.jump and ctx.tab == "changes" and vim.api.nvim_get_current_buf() == bufnr then
    local jump, header, line = ctx.jump, nil, nil
    for lnum, item in pairs(state.items) do
      if item.file and item.file.path == jump.path then
        if item.kind == "file_header" and (not header or lnum < header) then
          header = lnum
        elseif item.kind == "diff_line" and ((jump.new and item.new == jump.new) or (jump.old and item.old == jump.old)) then
          line = lnum
        end
      end
    end
    if line or header then
      vim.api.nvim_win_set_cursor(0, { line or header, 0 })
      vim.cmd("normal! zz")
      jumped = true
    end
    -- Keep trying while the file is still loading
    local file = header and state.items[header].file
    if line or (file and (file.diff or file.error)) then
      ctx.jump = nil
    end
  end
  vim.cmd.redrawstatus({ bang = true })
  return jumped
end

rerender = function(bufnr)
  local state = views[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if state.kind == "list" then
    render_list(bufnr)
  elseif vim.api.nvim_get_current_buf() == bufnr and vim.fn.mode():match("^[iR]") then
    -- Not while typing (the completion menu would go): leaving insert mode renders
    return
  else
    render_pr(bufnr)
  end
end

-- Tabs ------------------------------------------------------------------------

-- Winbar of a pull request window: the tabs, the current one highlighted (clickable)
function M.winbar()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local state = views[vim.api.nvim_win_get_buf(win)]
  if not state or state.kind ~= "pr" then
    return ""
  end
  local ctx = state.ctx
  local counts = {
    overview = ctx.data.threads and #ctx.data.threads,
    changes = ctx.data.changes and #ctx.data.changes,
  }
  local parts = {}
  for i, tab in ipairs(TABS) do
    local label = TAB_LABELS[tab] .. (counts[tab] and counts[tab] > 0 and (" " .. counts[tab]) or "")
    local hl = tab == ctx.tab and "%#WorkhorsePRTabSel#" or "%#WorkhorsePRTab#"
    table.insert(parts, "%" .. i .. "@v:lua.WorkhorsePRTabClick@" .. hl .. " " .. label .. " %X")
  end
  return table.concat(parts, "%#WorkhorsePRTab#│") .. "%#WorkhorsePRTab#%=%#WorkhorseBuildMeta# !" .. ctx.id .. " "
end

local WINBAR = "%{%v:lua.require'workhorse.prs'.winbar()%}"

function _G.WorkhorsePRTabClick(index)
  local win = vim.fn.getmousepos().winid
  if win and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    M.set_tab(vim.api.nvim_win_get_buf(win), TABS[index])
  end
end

function M.set_tab(bufnr, tab)
  local state = views[bufnr]
  if not state or state.kind ~= "pr" or not tab then
    return
  end
  tab = LEGACY_TABS[tab] or tab
  local ctx = state.ctx
  -- Each tab keeps its own cursor; the Overview its edits
  if state.items then
    ctx.cursor[ctx.tab] = vim.api.nvim_win_get_cursor(0)[1]
    if ctx.tab == "overview" then
      capture_edits(bufnr)
    end
  end
  ctx.tab = tab
  ensure(bufnr, tab)
  if not render_pr(bufnr) then
    local lnum = ctx.cursor[tab] or (state.header_lines + 1)
    vim.api.nvim_win_set_cursor(0, { math.min(lnum, vim.api.nvim_buf_line_count(bufnr)), 0 })
  end
end

local function cycle_tab(bufnr, step)
  local state = views[bufnr]
  for i, tab in ipairs(TABS) do
    if tab == state.ctx.tab then
      return M.set_tab(bufnr, TABS[(i - 1 + step) % #TABS + 1])
    end
  end
end

-- Jump to the next (step 1) or previous (-1) file diff of the Changes tab
local function jump_file(bufnr, step)
  local state = views[bufnr]
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local last = vim.api.nvim_buf_line_count(bufnr)
  local lnum = cursor + step
  while lnum >= 1 and lnum <= last do
    local item = state.items[lnum]
    local prev = state.items[lnum - 1]
    -- The first line of each header (its file name)
    if item and item.kind == "file_header" and not (prev and prev.kind == "file_header") then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.cmd("normal! zt")
      return
    end
    lnum = lnum + step
  end
end

-- Fuzzy-pick a changed file of the pull request, then land on its diff (on the Changes tab)
local function pick_file(bufnr)
  local ctx = views[bufnr].ctx
  local changes = ctx.data.changes
  if not changes or #changes == 0 then
    vim.notify("Workhorse: " .. (changes and "No changed files" or "The changes are still loading"),
      vim.log.levels.INFO)
    return
  end
  require("workhorse.ui.picker").select(changes, {
    prompt = "Files of !" .. ctx.id,
    format_item = function(change)
      return change.path:gsub("^/", "") .. "  (" .. tostring(change.change_type) .. ")"
    end,
  }, function(change)
    local lnum = ctx.tab == "changes" and find_line(bufnr, "file_header:" .. change.path)
    if lnum then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.cmd("normal! zt")
      return
    end
    -- Another tab (or the file is still loading): the render lands on it once it is there
    ctx.jump = { path = change.path }
    M.set_tab(bufnr, "changes")
  end)
end

-- Actions ---------------------------------------------------------------------

local function pr_of(bufnr)
  local state = views[bufnr]
  local pr = state and state.kind == "pr" and state.ctx.data.pr
  if not pr then
    vim.notify("Workhorse: Open a pull request first", vim.log.levels.WARN)
  end
  return pr
end

-- Pick a merge strategy (the configured one first), then whether to delete the source branch
local function choose_completion(pr, action, callback)
  local cfg = config.get().prs
  local strategies = vim.list_slice(prs_api.merge_strategies)
  table.sort(strategies, function(a, b)
    return (a.value == cfg.merge_strategy and 0 or 1) < (b.value == cfg.merge_strategy and 0 or 1)
  end)
  vim.ui.select(strategies, {
    prompt = action .. " !" .. pr.id .. " with",
    format_item = function(s)
      return s.label
    end,
  }, function(strategy)
    if not strategy then
      return
    end
    local branch = short_branch(pr.source_ref)
    local choice = vim.fn.confirm(
      action .. " !" .. pr.id .. " into " .. short_branch(pr.target_ref) .. " (" .. strategy.label .. ")?",
      "&Delete " .. branch .. "\n&Keep " .. branch .. "\n&Cancel",
      cfg.delete_source_branch and 1 or 2
    )
    if choice == 1 or choice == 2 then
      callback({
        merge_strategy = strategy.value,
        delete_source_branch = choice == 1,
        transition_work_items = cfg.transition_work_items,
      })
    end
  end)
end

function M.vote(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pr = pr_of(bufnr)
  if not pr then
    return
  end
  local repo = views[bufnr].ctx.repo
  vim.ui.select(prs_api.votes, {
    prompt = "Vote on !" .. pr.id,
    format_item = function(v)
      local _, icon = prs_api.vote_display(v.value)
      return icon .. " " .. v.label
    end,
  }, function(vote)
    if not vote then
      return
    end
    prs_api.vote(repo, pr.id, vote.value, function(ok, err)
      if not ok then
        vim.notify("Workhorse: Failed to vote: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      vim.notify("Workhorse: Voted " .. vote.label .. " on !" .. pr.id, vim.log.levels.INFO)
      refresh_pr(bufnr)
    end)
  end)
end

function M.complete(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pr = pr_of(bufnr)
  if not pr then
    return
  end
  if pr.status ~= "active" then
    vim.notify("Workhorse: !" .. pr.id .. " is not active", vim.log.levels.INFO)
    return
  elseif pr.is_draft then
    vim.notify("Workhorse: !" .. pr.id .. " is a draft; publish it before completing", vim.log.levels.INFO)
    return
  end
  local repo = views[bufnr].ctx.repo
  choose_completion(pr, "Complete", function(opts)
    -- Completing needs the current head: fetch it, so a push since the view loaded is not lost
    prs_api.get(repo, pr.id, function(fresh, err)
      if not fresh then
        vim.notify("Workhorse: Failed to complete: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      prs_api.complete(repo, fresh, opts, function(ok, err2)
        if not ok then
          vim.notify("Workhorse: Failed to complete: " .. (err2 or "unknown error"), vim.log.levels.ERROR)
          return
        end
        vim.notify("Workhorse: Completing !" .. pr.id, vim.log.levels.INFO)
        refresh_pr(bufnr)
      end)
    end)
  end)
end

function M.auto_complete(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pr = pr_of(bufnr)
  if not pr then
    return
  end
  if pr.status ~= "active" then
    vim.notify("Workhorse: !" .. pr.id .. " is not active", vim.log.levels.INFO)
    return
  end
  local repo = views[bufnr].ctx.repo
  local function done(what)
    return function(ok, err)
      if not ok then
        vim.notify("Workhorse: Failed to " .. what .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      vim.notify("Workhorse: " .. what:gsub("^%l", string.upper) .. " on !" .. pr.id, vim.log.levels.INFO)
      refresh_pr(bufnr)
    end
  end
  if pr.auto_complete_set_by then
    if vim.fn.confirm("Cancel auto-complete of !" .. pr.id .. "?", "&Ok\n&Keep", 1) == 1 then
      prs_api.cancel_auto_complete(repo, pr, done("cancel auto-complete"))
    end
    return
  end
  choose_completion(pr, "Auto-complete", function(opts)
    prs_api.set_auto_complete(repo, pr, opts, done("set auto-complete"))
  end)
end

-- Yanks the web URL of the pull request into "0 and the clipboard ("+)
function M.copy_url(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pr = pr_of(bufnr)
  if not pr then
    return
  end
  local url = prs_api.pr_url(views[bufnr].ctx.repo, pr.id)
  vim.fn.setreg("0", url)
  if not pcall(vim.fn.setreg, "+", url) then
    vim.notify("Workhorse: Copied " .. url .. ' to "0 (no clipboard available)', vim.log.levels.WARN)
    return
  end
  vim.notify("Workhorse: Copied " .. url, vim.log.levels.INFO)
end

-- Queue the build of a check again: the one under the cursor (a build check), or else every build
-- waiting for it (expired, failed, never started; more than one after a confirmation). The builds
-- and checks are fetched again right after
function M.requeue(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pr = pr_of(bufnr)
  if not pr then
    return
  end
  local ctx = views[bufnr].ctx
  local item = ctx.tab == "overview" and current_item(bufnr)
  local targets
  if item and item.kind == "check" then
    if not prs_api.can_requeue(item.check) then
      vim.notify("Workhorse: " .. (item.check.kind == "build" and "This build is already under way"
        or "Only build checks can be queued again"), vim.log.levels.INFO)
      return
    end
    targets = { item.check }
  else
    targets = requeue_targets(ctx)
    if #targets == 0 then
      vim.notify("Workhorse: " .. (ctx.data.checks and "No builds to re-queue on !" .. pr.id
        or "The checks are still loading"), vim.log.levels.INFO)
      return
    end
    if #targets > 1 then
      local names = vim.tbl_map(function(c)
        return "  " .. c.name
      end, targets)
      if vim.fn.confirm(("Re-queue %d builds of !%d?\n%s"):format(#targets, pr.id, table.concat(names, "\n")),
        "&Re-queue\n&Cancel", 1) ~= 1 then
        return
      end
    end
  end
  local pending, failures = #targets, {}
  for _, check in ipairs(targets) do
    prs_api.requeue_check(ctx.repo, check.id, function(ok, err)
      if not ok then
        table.insert(failures, check.name .. ": " .. tostring(err))
      end
      pending = pending - 1
      if pending > 0 then
        return
      end
      if #failures > 0 then
        vim.notify("Workhorse: Failed to re-queue:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
      end
      local queued = #targets - #failures
      if queued > 0 then
        vim.notify(("Workhorse: Re-queued %s on !%d"):format(queued == 1 and targets[1].name
          or (queued .. " builds"), pr.id), vim.log.levels.INFO)
      end
      if views[bufnr] then
        fetch_checks(bufnr)
        fetch_builds(bufnr)
      end
    end)
  end
end

-- Find the git remote of Neovim's working directory that points to the repository of the list or
-- pull request (ctx.remote: "Checkout this branch" and the <leader>wN hint show only with one);
-- redraws when it changes
local function detect_clone(bufnr)
  local state = views[bufnr]
  if not state then
    return
  end
  local ctx = state.ctx
  require("workhorse.repos").remote_of(ctx.repo, function(remote)
    if views[bufnr] ~= state or ctx.remote == remote then
      return
    end
    ctx.remote = remote
    rerender(bufnr)
  end)
end

-- Check out the source branch of the pull request in Neovim's working directory: fetched from the
-- remote that points to the repository, then switched to (a local branch tracking it is created
-- when there is none; an existing one is left as it is, and how far behind it is reported)
function M.checkout(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local pr = pr_of(bufnr)
  if not pr then
    return
  end
  local ctx = views[bufnr].ctx
  if ctx.checking_out then
    vim.notify("Workhorse: The checkout is under way", vim.log.levels.INFO)
    return
  end
  local branch = short_branch(pr.source_ref)
  ctx.checking_out = true
  require("workhorse.repos").remote_of(ctx.repo, function(remote, dir)
    local function finish()
      ctx.checking_out = nil
      if views[bufnr] and ctx.remote ~= remote then
        ctx.remote = remote
        rerender(bufnr)
      end
    end
    if not remote then
      finish()
      vim.notify("Workhorse: " .. dir .. " is not a clone of " .. ctx.repo.name, vim.log.levels.WARN)
      return
    end
    local function git(args, callback)
      -- Never prompts: a remote that needs credentials fails instead (see workhorse/git.lua)
      require("workhorse.git").run(dir, args, callback)
    end
    local function fail(what, stderr)
      finish()
      stderr = vim.trim(stderr or "")
      vim.notify(("Workhorse: Failed to %s: %s"):format(what, stderr ~= "" and stderr or "unknown error"),
        vim.log.levels.ERROR)
    end
    local upstream = remote .. "/" .. branch
    vim.notify("Workhorse: Fetching " .. branch .. " from " .. remote .. "…", vim.log.levels.INFO)
    -- An explicit refspec: the remote-tracking branch exists even when the remote's fetch refspec
    -- leaves it out
    git({ "fetch", remote, "+refs/heads/" .. branch .. ":refs/remotes/" .. upstream }, function(_, err, code)
      if code ~= 0 then
        require("workhorse.git").access(remote, err, function(message)
          fail("fetch " .. branch, message)
        end)
        return
      end
      git({ "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, function(_, _, verify_code)
        local exists = verify_code == 0
        -- No --track: git refuses it when the remote's fetch refspec leaves the branch out (a
        -- single-branch clone); the upstream is set in the branch's config instead
        local args = exists and { "switch", branch } or { "switch", "--create", branch, "--no-track", upstream }
        git(args, function(_, err2, code2)
          if code2 ~= 0 then
            return fail("check out " .. branch, err2)
          end
          -- Buffers of files the switch changed
          vim.cmd("checktime")
          if not exists then
            git({ "config", "branch." .. branch .. ".remote", remote }, function(_, err3, code3)
              if code3 == 0 then
                git({ "config", "branch." .. branch .. ".merge", "refs/heads/" .. branch }, function(_, err4, code4)
                  if code4 ~= 0 then
                    return fail("set the upstream of " .. branch, err4)
                  end
                  finish()
                  vim.notify("Workhorse: Checked out " .. branch .. " (tracking " .. upstream .. ")",
                    vim.log.levels.INFO)
                end)
              else
                fail("set the upstream of " .. branch, err3)
              end
            end)
            return
          end
          finish()
          git({ "rev-list", "--count", branch .. ".." .. upstream }, function(out, _, code3)
            local behind = code3 == 0 and tonumber(vim.trim(out or "")) or 0
            vim.notify("Workhorse: Checked out " .. branch .. (behind > 0
              and (", %d commit%s behind %s: pull to update"):format(behind, behind == 1 and "" or "s", upstream)
              or ""), vim.log.levels.INFO)
          end)
        end)
      end)
    end)
  end)
end

-- New pull request --------------------------------------------------------------

-- Open the form to create a pull request on the repository of the list in `bufnr`. With
-- `script`, the flow of Criar-PullRequest.ps1 (push, link a work item, auto-complete), only in a
-- clone of the repository. Once created, the list reloads and the pull request opens
function M.new_pr(bufnr, script)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = views[bufnr]
  if not state or state.kind ~= "list" then
    vim.notify("Workhorse: Open the pull requests of a repository first", vim.log.levels.WARN)
    return
  end
  local ctx = state.ctx
  local repo = ctx.repo
  require("workhorse.repos").remote_of(repo, function(remote, dir)
    if views[bufnr] == state and ctx.remote ~= remote then
      ctx.remote = remote
      rerender(bufnr)
    end
    if script and not remote then
      vim.notify("Workhorse: " .. dir .. " is not a clone of " .. repo.name
        .. ": <leader>wN pushes its current branch", vim.log.levels.WARN)
      return
    end
    require("workhorse.prs.new_pr").open(repo, {
      mode = script and "script" or "simple",
      remote = remote,
      dir = remote and dir or nil,
      on_created = function(pr)
        if views[bufnr] == state then
          load_list(bufnr, true)
        end
        M.open_pr(repo, pr)
      end,
    })
  end)
end

-- Editing ---------------------------------------------------------------------

local SECTION_LABELS = { reviewers = reviewers.HEADER, work_items = work_items.HEADER }

-- Complete the lines of the Work Items section whose work item is known ("1234" becomes
-- "#1234 | Its title") and look up the others on the server, completing them once found. `join`
-- joins the completions to the edit that typed them (leaving insert mode)
local function resolve_work_items(bufnr, join)
  local state = views[bufnr]
  if not state or not section_editable(state.ctx, "work_items") then
    return
  end
  local lines, first = section_text(bufnr, "work_items")
  if not lines then
    return
  end
  local replace, unknown = work_items.completions(lines)
  for i, text in pairs(replace) do
    if join and vim.api.nvim_get_current_buf() == bufnr then
      pcall(vim.cmd.undojoin)
    end
    vim.api.nvim_buf_set_lines(bufnr, first + i - 2, first + i - 1, false, { text })
  end
  if #unknown > 0 then
    work_items.lookup(unknown, function()
      if not views[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- While typing, leaving insert mode completes them
      if vim.api.nvim_get_current_buf() == bufnr and vim.fn.mode():match("^[iR]") then
        return
      end
      resolve_work_items(bufnr, false)
      capture_edits(bufnr)
      rerender(bufnr)
    end)
  end
end

-- After a change of the text (in normal mode): keep the edits, then render (which takes back
-- any change outside the editable sections and names the lines again)
local function on_text_changed(bufnr)
  local state = views[bufnr]
  if not state or state.kind ~= "pr" or not state.items or vim.b[bufnr].changedtick == state.tick then
    return
  end
  if not overview_editable(state.ctx) then
    return
  end
  capture_edits(bufnr)
  render_pr(bufnr, nil, { join = true })
end

local function on_insert_leave(bufnr)
  local state = views[bufnr]
  if not state or state.kind ~= "pr" or not state.items or not overview_editable(state.ctx) then
    return
  end
  resolve_work_items(bufnr, true)
  capture_edits(bufnr)
  render_pr(bufnr, nil, { join = true })
end

-- What completion needs, loaded on the first insert: the identity cache (reviewers) and the work
-- items of the query (prs.work_items_query)
local function start_completion(bufnr)
  local state = views[bufnr]
  if not state or state.completion_started or not overview_editable(state.ctx) then
    return
  end
  state.completion_started = true
  require("workhorse.identities").get(function(_, err)
    if err then
      vim.notify("Workhorse: Could not load the identity cache: " .. err, vim.log.levels.WARN)
    end
    if views[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
      choices.refresh(bufnr)
      rerender(bufnr)
    end
  end)
  work_items.load_list(function()
    if views[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
      choices.refresh(bufnr)
    end
  end)
end

--- Save the edits of the Reviewers and Work Items sections of the pull request in `bufnr`
--- (default: current): confirms them in a list, then applies them
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = views[bufnr]
  if not state or state.kind ~= "pr" then
    return
  end
  local ctx = state.ctx
  if ctx.saving then
    vim.notify("Workhorse: Already saving", vim.log.levels.WARN)
    return
  end
  if ctx.tab == "overview" then
    capture_edits(bufnr)
  end
  if not pr_editable(ctx) or not has_edits(ctx) then
    vim.bo[bufnr].modified = false
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    return
  end
  -- Reviewers are named from the identity cache
  if ctx.edits.reviewers and not require("workhorse.identities").loaded() then
    require("workhorse.identities").get(function(data, err)
      if data then
        M.save(bufnr)
      else
        vim.notify("Workhorse: Could not load the identity cache: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
    return
  end

  local steps, entries, errors = {}, {}, {}
  for _, name in ipairs(EDITABLE) do
    if ctx.edits[name] and ctx.data[SECTION_DATA[name]] ~= nil then
      local result, err = SECTION_MODULES[name].prepare(ctx, ctx.edits[name])
      if err then
        table.insert(errors, SECTION_LABELS[name] .. ":\n" .. err)
      elseif result then
        table.insert(entries, { text = SECTION_LABELS[name], hl = "WorkhorseBuildHeader" })
        vim.list_extend(entries, result.entries)
        vim.list_extend(steps, result.steps)
      end
    end
  end
  if #errors > 0 then
    vim.notify("Workhorse: " .. table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end
  if #steps == 0 then
    ctx.edits = {}
    rerender(bufnr)
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    return
  end

  require("workhorse.ui.list_confirm").show("Changes to !" .. ctx.id, entries, function(confirmed)
    if not confirmed or not views[bufnr] then
      return
    end
    ctx.saving = true
    local saved = vim.deepcopy(ctx.edits)
    local generation = ctx.generation
    local failures = {}

    -- Fetch again what changed; the edits saved give way to it once it is there (those made
    -- meanwhile stay)
    local function reload()
      local fresh, pending = {}, 2
      for _, name in ipairs({ "pr", "work_items" }) do
        fetchers[name](ctx, function(data)
          fresh[name] = data
          pending = pending - 1
          if pending > 0 or not views[bufnr] or ctx.generation ~= generation then
            return
          end
          for key, value in pairs(fresh) do
            ctx.data[key], ctx.errors[key] = value, nil
          end
          if fresh.pr then
            update_list_entry(ctx.repo, fresh.pr)
          end
          for section, lines in pairs(saved) do
            if vim.deep_equal(ctx.edits[section], lines) then
              ctx.edits[section] = nil
            end
          end
          rerender(bufnr)
        end, { silent = true })
      end
    end

    local function run(index)
      local step = steps[index]
      if step then
        return step.run(function(ok, err)
          if not ok then
            table.insert(failures, step.label .. ": " .. tostring(err))
          end
          run(index + 1)
        end)
      end
      ctx.saving = nil
      local applied = #steps - #failures
      if #failures > 0 then
        vim.notify("Workhorse: Failed to apply:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
      end
      vim.notify(("Workhorse: Applied %d change%s to !%d"):format(applied, applied == 1 and "" or "s", ctx.id),
        vim.log.levels.INFO)
      if views[bufnr] and ctx.generation == generation then
        reload()
      end
    end
    run(1)
  end)
end

-- Buffers ---------------------------------------------------------------------

-- Open a build of the pull request: its run tree (the builds view works on the configured project;
-- builds of other projects open in the browser)
local function open_build(ctx, run)
  local project = config.get().project
  if project == ctx.repo.project.name or project == ctx.repo.project.id then
    require("workhorse.builds").open_run(run, nil, { watch = true })
  elseif run.url then
    open_url(run.url)
  end
end

-- The build of a check, as listed in the Builds section when it is there
local function build_of_check(ctx, check)
  for _, run in ipairs(ctx.data.builds or {}) do
    if run.id == check.build_id then
      return run
    end
  end
end

-- Put the cursor on the first line of the Overview starting with `prefix` (a section header)
local function jump_to_section(bufnr, prefix)
  local state = views[bufnr]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for lnum = (state.header_lines or 0) + 1, #lines do
    if vim.startswith(lines[lnum], prefix) then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return
    end
  end
end

-- Sections the checks other than builds are about
local CHECK_SECTIONS = { min_reviewers = reviewers.HEADER, reviewers = reviewers.HEADER,
  work_items = work_items.HEADER, comments = "Comments (" }

local function browser_url(bufnr)
  local state = views[bufnr]
  local ctx = state.ctx
  local item = current_item(bufnr)
  if item and item.kind == "pr" then
    return item.pr.url
  elseif item and item.kind == "commit" then
    return prs_api.commit_url(ctx.repo, item.commit.id)
  elseif item and item.kind == "build" and item.run.url then
    return item.run.url
  elseif item and item.kind == "check" and item.check.build_id then
    local run = build_of_check(ctx, item.check)
    return run and run.url or prs_api.build_url(ctx.repo, item.check.build_id)
  elseif state.kind == "list" then
    return prs_api.repo_url(ctx.repo) .. "/pullrequests"
  elseif item and item.file then
    return prs_api.pr_url(ctx.repo, ctx.id) .. "?_a=files&path=" .. builds_api.url_encode(item.file.path)
  end
  return prs_api.pr_url(ctx.repo, ctx.id)
end

-- Web page of the view itself: the pull request (on its tab's page); the list is a list, so the
-- pull request under the cursor (the repository's pull requests elsewhere)
local function page_url(bufnr)
  local state = views[bufnr]
  local ctx = state.ctx
  if state.kind == "list" then
    local item = current_item(bufnr)
    return item and item.kind == "pr" and item.pr.url or (prs_api.repo_url(ctx.repo) .. "/pullrequests")
  end
  return prs_api.pr_url(ctx.repo, ctx.id) .. (ctx.tab == "changes" and "?_a=files" or "")
end

local function select_item(bufnr)
  local state = views[bufnr]
  local item = current_item(bufnr)
  if not state or not item then
    return
  end
  local ctx = state.ctx
  if item.kind == "pr" then
    M.open_pr(ctx.repo, item.pr)
  elseif item.kind == "nav" then
    if item.target == "more" then
      load_list(bufnr)
    elseif item.target == "list" then
      M.open_list(ctx.repo, ctx.id)
    elseif item.target == "vote" then
      M.vote(bufnr)
    elseif item.target == "complete" then
      M.complete(bufnr)
    elseif item.target == "auto_complete" then
      M.auto_complete(bufnr)
    elseif item.target == "copy_url" then
      M.copy_url(bufnr)
    elseif item.target == "checkout" then
      M.checkout(bufnr)
    elseif item.target == "requeue" then
      M.requeue(bufnr)
    end
  elseif item.kind == "file" then
    local lnum = find_line(bufnr, "file_header:" .. item.file.path)
    if lnum then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.cmd("normal! zt")
    end
  elseif item.kind == "thread" and item.thread.file_path then
    local t = item.thread
    ctx.jump = { path = t.file_path, new = t.right_line, old = not t.right_line and t.left_line or nil }
    M.set_tab(bufnr, "changes")
  elseif item.kind == "commit" then
    open_url(prs_api.commit_url(ctx.repo, item.commit.id))
  elseif item.kind == "build" then
    open_build(ctx, item.run)
  elseif item.kind == "check" then
    -- A build check: its build, or queued again when it has none to show (expired, outdated, not
    -- started); the others go to the section they are about
    local check = item.check
    if check.kind == "build" then
      if check.build_id and not check.expired and not check.outdated then
        local run = build_of_check(ctx, check)
        if run then
          open_build(ctx, run)
        else
          open_url(prs_api.build_url(ctx.repo, check.build_id))
        end
      elseif prs_api.can_requeue(check) then
        M.requeue(bufnr)
      end
    elseif CHECK_SECTIONS[check.kind] then
      jump_to_section(bufnr, CHECK_SECTIONS[check.kind])
    end
  end
end

local function set_keymaps(bufnr, kind)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true })
  end
  map("<CR>", function()
    select_item(bufnr)
  end)
  for _, lhs in ipairs(config.space_keys()) do
    map(lhs, function()
      select_item(bufnr)
    end)
  end
  map("gw", function()
    open_url(browser_url(bufnr))
  end)
  map("gb", function()
    open_url(page_url(bufnr))
  end)
  require("workhorse.builds").map_yank(bufnr, function()
    open_url(page_url(bufnr))
  end, "the pull request")
  map("<leader>R", function()
    M.refresh(bufnr)
  end)
  map("q", function()
    if vim.bo[bufnr].modified and vim.fn.confirm("Discard the pending changes?", "&Discard\n&Cancel", 2) ~= 1 then
      return
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  if kind == "list" then
    map("<leader>wm", function()
      load_list(bufnr)
    end)
    map("<leader>wn", function()
      M.new_pr(bufnr)
    end)
    map("<leader>wN", function()
      M.new_pr(bufnr, true)
    end)
    -- Fuzzy search of the repositories, to list the pull requests of another one
    map("<M-/>", M.pick)
    return
  end
  -- Fuzzy search of the files the pull request changes
  map("<M-/>", function()
    pick_file(bufnr)
  end)
  local function back()
    local ctx = views[bufnr].ctx
    M.open_list(ctx.repo, ctx.id)
  end
  map("-", back)
  map("<BS>", back)
  map("<Tab>", function()
    cycle_tab(bufnr, 1)
  end)
  map("<S-Tab>", function()
    cycle_tab(bufnr, -1)
  end)
  for i, tab in ipairs(TABS) do
    map("g" .. i, function()
      M.set_tab(bufnr, tab)
    end)
  end
  map("]f", function()
    jump_file(bufnr, 1)
  end)
  map("[f", function()
    jump_file(bufnr, -1)
  end)
  map("<leader>wv", function()
    M.vote(bufnr)
  end)
  map("<leader>wc", function()
    M.complete(bufnr)
  end)
  map("<leader>wa", function()
    M.auto_complete(bufnr)
  end)
  map("<leader>wy", function()
    M.copy_url(bufnr)
  end)
  map("<leader>wk", function()
    M.checkout(bufnr)
  end)
  map("<leader>wq", function()
    M.requeue(bufnr)
  end)
  -- The editable sections of the Overview
  require("workhorse.ui.send").map(bufnr, function()
    M.save(bufnr)
  end, "save the edits of the Overview")
  -- Accept a completion with <CR>; a plain new line otherwise
  vim.keymap.set("i", "<CR>", choices.insert_cr, { buffer = bufnr, silent = true, expr = true,
    desc = "Workhorse: accept the completion" })
end

-- Completion and saving of the editable sections of a pull request's Overview
local function setup_editing(bufnr)
  -- acwrite: :w does nothing (BufWriteCmd); the buffer is modifiable only while editable
  vim.bo[bufnr].buftype = "acwrite"
  choices.attach(bufnr, {
    choices = function(b, lnum)
      local name = editable_section_at(b, lnum)
      if name then
        return SECTION_MODULES[name].choices(vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1] or "")
      end
    end,
    start = function(line, lnum)
      local name = editable_section_at(bufnr, lnum)
      if name then
        return SECTION_MODULES[name].start(line)
      end
    end,
  })
  local group = vim.api.nvim_create_augroup("workhorse_pr_edit_" .. bufnr, { clear = true })
  -- :w does not send (an auto-save plugin must not apply anything): <leader><leader> does
  require("workhorse.ui.send").ignore_write(bufnr, group)
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    buffer = bufnr,
    callback = function()
      on_text_changed(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      start_completion(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      on_insert_leave(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end)
    end,
  })
end

local function open_buffer(key, name, kind, ctx)
  local existing = buffers_by_key[key]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_set_current_buf(existing)
    return existing, false
  end
  local bufnr = vim.api.nvim_create_buf(true, false)
  if not pcall(vim.api.nvim_buf_set_name, bufnr, "Workhorse|" .. name) then
    vim.api.nvim_buf_set_name(bufnr, "Workhorse|" .. name .. "|" .. key)
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-pr"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading..." })
  vim.bo[bufnr].modifiable = false
  views[bufnr] = { key = key, kind = kind, ctx = ctx }
  buffers_by_key[key] = bufnr
  pinned.attach(bufnr, function()
    return views[bufnr] and views[bufnr].header_lines or 0
  end)
  set_keymaps(bufnr, kind)
  if kind == "pr" then
    setup_editing(bufnr)
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      local state = views[bufnr]
      if state and state.builds_timer then
        state.builds_timer:stop()
        state.builds_timer:close()
      end
      if state then
        buffers_by_key[state.key] = nil
        views[bufnr] = nil
      end
    end,
  })
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, true
end

-- Pull request windows show the tabs in their winbar, and no sign or fold column; the winbar
-- is taken off again when the window moves on to another buffer
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_prs_winbar", { clear = true }),
  callback = function(args)
    local win = vim.api.nvim_get_current_win()
    local state = views[args.buf]
    local function set(option, value)
      vim.api.nvim_set_option_value(option, value, { scope = "local", win = win })
    end
    if state then
      set("signcolumn", "no")
      set("foldcolumn", "0")
      set("wrap", false)
    end
    if state and state.kind == "pr" then
      set("winbar", WINBAR)
    elseif vim.wo[win].winbar == WINBAR then
      set("winbar", "")
    end
  end,
})

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
  group = vim.api.nvim_create_augroup("workhorse_prs_resize", { clear = true }),
  callback = function()
    for bufnr, state in pairs(views) do
      if vim.api.nvim_buf_is_valid(bufnr) and #windows_of(bufnr) > 0 and state.items then
        local previous = state.width
        if view_width(bufnr) ~= previous then
          rerender(bufnr)
        end
      end
    end
  end,
})

local function check_config()
  if not config.is_valid() then
    vim.notify(
      "Workhorse: Plugin not configured. Please call require('workhorse').setup() with server_url and project.",
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

-- Public API --------------------------------------------------------------------

-- Fuzzy-pick a repository, then list its pull requests
function M.pick()
  if not check_config() then
    return
  end
  require("workhorse.telescope.prs").pick()
end

-- Pull requests of `repo` ({ id, name, project = { id, name }, web_url }); `focus_id` puts
-- the cursor on that pull request
function M.open_list(repo, focus_id)
  if not check_config() then
    return
  end
  local bufnr, created = open_buffer("prs:" .. repo.id, "PRs|" .. repo_label(repo):gsub("[%s|]+", "_"), "list", {
    repo = repo,
    prs = {},
  })
  if created then
    load_list(bufnr)
    detect_clone(bufnr)
  elseif focus_id then
    local lnum = find_line(bufnr, "pr:" .. focus_id)
    if lnum then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
  end
  return bufnr
end

-- Open a pull request (a list entry, or its id) of `repo`
function M.open_pr(repo, pr)
  local id = type(pr) == "table" and pr.id or tonumber(pr)
  local bufnr, created = open_buffer("pr:" .. repo.id .. ":" .. id, "PR|" .. repo.name:gsub("[%s|]+", "_") .. "|!" .. id,
    "pr", {
      repo = repo,
      id = id,
      summary = type(pr) == "table" and pr or nil,
      tab = config.get().prs.default_tab,
      cursor = {},
      data = {},
      -- Text of the editable sections as edited (see capture_edits)
      edits = {},
      errors = {},
      loading = {},
      generation = 0,
      refreshed = uv.now(),
    })
  if created then
    vim.api.nvim_set_option_value("winbar", WINBAR, { scope = "local", win = vim.api.nvim_get_current_win() })
    M.set_tab(bufnr, views[bufnr].ctx.tab)
    detect_clone(bufnr)
    local timer = uv.new_timer()
    views[bufnr].builds_timer = timer
    timer:start(BUILDS_TICK, BUILDS_TICK, vim.schedule_wrap(function()
      tick(bufnr)
    end))
  end
  return bufnr
end

-- Reopen the pull requests of the last opened repository, skipping the picker
function M.resume()
  local last = require("workhorse.session").get_last_repo()
  if not last or type(last.project) ~= "table" then
    vim.notify("Workhorse: No previous repository to resume", vim.log.levels.WARN)
    return
  end
  return M.open_list(last)
end

-- Reload the list or pull request in `bufnr` (default: current buffer); false when it is
-- not one of these views
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = views[bufnr]
  if not state then
    return false
  end
  if state.kind == "list" then
    load_list(bufnr, true)
    detect_clone(bufnr)
    return true
  end
  local ctx = state.ctx
  if ctx.saving then
    vim.notify("Workhorse: Wait for the save to finish", vim.log.levels.WARN)
    return true
  end
  if ctx.tab == "overview" then
    capture_edits(bufnr)
  end
  if has_edits(ctx) and vim.fn.confirm("Discard the pending changes and reload?", "&Discard\n&Cancel", 2) ~= 1 then
    return true
  end
  ctx.edits = {}
  work_items.reset_list()
  state.completion_started = nil
  -- Responses of the previous generation are dropped when they land
  ctx.generation = ctx.generation + 1
  ctx.data, ctx.errors, ctx.loading, ctx.files, ctx.builds_fetched, ctx.builds_merge = {}, {}, {}, nil, nil, nil
  ctx.refreshing, ctx.refresh_again, ctx.changes_stale, ctx.refreshed = nil, nil, nil, uv.now()
  M.set_tab(bufnr, ctx.tab)
  -- The working directory may have changed since
  detect_clone(bufnr)
  return true
end

function M.is_pr_buffer(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

return M
