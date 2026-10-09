local M = {}

local prs_api = require("workhorse.api.pullrequests")
local builds_api = require("workhorse.api.builds")
local render = require("workhorse.builds.render")
local diff = require("workhorse.prs.diff")
local cache = require("workhorse.cache")
local config = require("workhorse.config")

local uv = vim.uv or vim.loop
-- Status of the builds on the Overview tab, drawn apart so the elapsed time ticks without re-rendering
local builds_ns = vim.api.nvim_create_namespace("workhorse_prs_builds")
local BUILDS_TICK = 1000

-- Per-buffer view state: { key, kind = "list"|"pr", ctx, items, width }
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
    return "build:" .. (item.run.definition_id or item.run.id)
  elseif item.kind == "nav" then
    return "nav:" .. item.target
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

-- Write `view` to the buffer, keeping each window on the item it was on (or `focus`, a key)
local function apply_view(bufnr, view, focus)
  local state = views[bufnr]
  local cursors = {}
  for _, win in ipairs(windows_of(bufnr)) do
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    cursors[win] = { lnum = lnum, key = focus or item_key(state.items and state.items[lnum]) }
  end
  render.apply(bufnr, view)
  state.items = view.items
  for win, pos in pairs(cursors) do
    local target = pos.key and find_line(bufnr, pos.key) or pos.lnum
    vim.api.nvim_win_set_cursor(win, { math.min(target, vim.api.nvim_buf_line_count(bufnr)), 0 })
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
  render.add_line(view, { { "# " .. repo_label(ctx.repo), "WorkhorseBuildHeader" } }, { kind = "nav", target = "repo" })
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
  overview = { "pr", "threads", "iterations", "commits" },
  changes = { "pr", "iterations", "changes", "threads" },
}

local fetchers = {
  pr = function(ctx, cb)
    prs_api.get(ctx.repo, ctx.id, cb)
  end,
  threads = function(ctx, cb)
    prs_api.threads(ctx.repo, ctx.id, cb)
  end,
  iterations = function(ctx, cb)
    prs_api.iterations(ctx.repo, ctx.id, cb)
  end,
  commits = function(ctx, cb)
    prs_api.commits(ctx.repo, ctx.id, cb)
  end,
  -- Files changed by the last push, against the merge base
  changes = function(ctx, cb)
    local last = ctx.data.iterations[#ctx.data.iterations]
    if not last then
      return cb({})
    end
    prs_api.iteration_changes(ctx.repo, ctx.id, last.id, cb)
  end,
}

local rerender

local function builds_running(runs)
  for _, run in ipairs(runs or {}) do
    if not builds_api.is_completed(run.status) then
      return true
    end
  end
  return false
end

-- Fetch the builds of the pull request. They do not hold the Overview tab back: it shows them
-- loading (or failed) in their own section, and a failed refresh keeps what is shown
local function fetch_builds(bufnr)
  local ctx = views[bufnr].ctx
  if ctx.loading.builds then
    return
  end
  ctx.loading.builds = true
  local generation = ctx.generation
  prs_api.builds(ctx.repo, ctx.id, function(runs, err)
    if not views[bufnr] or ctx.generation ~= generation then
      return
    end
    ctx.loading.builds = nil
    ctx.builds_fetched = uv.now()
    if runs then
      ctx.data.builds, ctx.errors.builds = runs, nil
    elseif not ctx.data.builds then
      ctx.errors.builds = err or "unknown error"
    end
    if ctx.tab == "overview" and vim.api.nvim_buf_is_valid(bufnr) then
      rerender(bufnr)
    end
  end, { silent = ctx.data.builds ~= nil })
end

-- Every second while the Overview tab is shown: fetch the builds again once due (running and idle
-- intervals as in the pipelines list) and redraw their status, so the elapsed time ticks
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
  local running = builds_running(ctx.data.builds)
  local interval = running and cfg.status_running_interval or cfg.status_idle_interval
  if not ctx.builds_fetched or uv.now() - ctx.builds_fetched >= interval then
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
      vim.api.nvim_buf_set_extmark(bufnr, builds_ns, lnum - 1, 0, {
        virt_text = render.run_status(item.run, { branch = false }),
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
  if tab == "changes" and ctx.data.changes and not ctx.files then
    M._load_files(bufnr)
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
  render.add_line(view, { { render.truncate("# !" .. ctx.id .. " " .. title, math.max(width - 2, 20)), "WorkhorseBuildHeader" } },
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

-- Separator between the sections of a tab; the header still ends at its own rule
local function add_section_separator(view, width)
  local rule = view.rule
  render.add_separator(view, width)
  view.rule = rule
end

local function add_text_block(view, text, indent, hl)
  for _, line in ipairs(vim.split((text or ""):gsub("\r", ""), "\n", { plain = true })) do
    render.add_line(view, { { indent .. line, hl } })
  end
end

local function render_status(view, ctx)
  local pr = ctx.data.pr
  if pr.status == "active" then
    render.add_line(view, { { "Actions", "WorkhorseRunSection" } })
    render.add_line(view, { { "  Vote…", "WorkhorseBuildRunning" } }, { kind = "nav", target = "vote" },
      { { "<leader>wv", "WorkhorseRunHint" } })
    if not pr.is_draft then
      render.add_line(view, { { "  Complete…", "WorkhorsePRApproved" } }, { kind = "nav", target = "complete" },
        { { "<leader>wc", "WorkhorseRunHint" } })
    end
    local auto = pr.auto_complete_set_by and "  Cancel auto-complete" or "  Set auto-complete…"
    render.add_line(view, { { auto, "WorkhorseBuildRetry" } }, { kind = "nav", target = "auto_complete" },
      { { "<leader>wa", "WorkhorseRunHint" } })
    render.add_line(view, { { "" } })
  end

  -- Latest build of each pipeline run on the pull request; their status is drawn by _draw_builds
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

  render.add_line(view, { { "Reviewers", "WorkhorseRunSection" } })
  if #pr.reviewers == 0 then
    render.add_line(view, { { "  None", "WorkhorseBuildMeta" } })
  end
  local reviewers = vim.list_slice(pr.reviewers)
  table.sort(reviewers, function(a, b)
    if a.required ~= b.required then
      return a.required
    end
    return a.name:lower() < b.name:lower()
  end)
  for _, r in ipairs(reviewers) do
    local label, icon, hl = prs_api.vote_display(r.vote)
    local segments = { { "  " }, { icon, hl }, { " " .. r.name }, { "  " .. label, hl } }
    if r.required then
      table.insert(segments, { "  (required)", "WorkhorseRunRequired" })
    end
    render.add_line(view, segments)
  end
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

-- Returns true when the cursor was moved to a comment thread's line
local function render_pr(bufnr, focus)
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
  state.header_lines = view.rule or 0
  apply_view(bufnr, view, focus)
  M._draw_builds(bufnr)
  -- A thread picked on the Overview tab: land on its line once the file's diff is there
  if ctx.jump and ctx.tab == "changes" then
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
  -- Each tab keeps its own cursor
  if state.items then
    ctx.cursor[ctx.tab] = vim.api.nvim_win_get_cursor(0)[1]
  end
  ctx.tab = tab
  ensure(bufnr, tab)
  if not render_pr(bufnr) then
    local lnum = ctx.cursor[tab] or (state.header_lines + 2)
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

-- Actions ---------------------------------------------------------------------

-- Fetch the pull request again (after an action) and redraw
local function reload_pr(bufnr)
  local state = views[bufnr]
  if not state then
    return
  end
  state.ctx.data.pr = nil
  state.ctx.errors.pr = nil
  ensure(bufnr, state.ctx.tab)
end

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
      reload_pr(bufnr)
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
        reload_pr(bufnr)
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
      reload_pr(bufnr)
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

-- Buffers ---------------------------------------------------------------------

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
  elseif state.kind == "list" then
    return prs_api.repo_url(ctx.repo) .. "/pullrequests"
  elseif item and item.file then
    return prs_api.pr_url(ctx.repo, ctx.id) .. "?_a=files&path=" .. builds_api.url_encode(item.file.path)
  end
  return prs_api.pr_url(ctx.repo, ctx.id)
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
    -- The builds view works on the configured project; builds of other projects open in the browser
    local project = config.get().project
    if project == ctx.repo.project.name or project == ctx.repo.project.id then
      require("workhorse.builds").open_run(item.run, nil, { watch = true })
    elseif item.run.url then
      open_url(item.run.url)
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
  map("<Space>", function()
    select_item(bufnr)
  end)
  map("gw", function()
    open_url(browser_url(bufnr))
  end)
  map("<leader>R", function()
    M.refresh(bufnr)
  end)
  map("q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  if kind == "list" then
    map("<leader>wm", function()
      load_list(bufnr)
    end)
    return
  end
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
  set_keymaps(bufnr, kind)
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
      "Workhorse: Plugin not configured. Please call require('workhorse').setup() with server_url, pat, and project.",
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
      errors = {},
      loading = {},
      generation = 0,
    })
  if created then
    vim.api.nvim_set_option_value("winbar", WINBAR, { scope = "local", win = vim.api.nvim_get_current_win() })
    M.set_tab(bufnr, views[bufnr].ctx.tab)
    local timer = uv.new_timer()
    views[bufnr].builds_timer = timer
    timer:start(BUILDS_TICK, BUILDS_TICK, vim.schedule_wrap(function()
      builds_tick(bufnr)
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
    return true
  end
  local ctx = state.ctx
  -- Responses of the previous generation are dropped when they land
  ctx.generation = ctx.generation + 1
  ctx.data, ctx.errors, ctx.loading, ctx.files, ctx.builds_fetched = {}, {}, {}, nil, nil
  M.set_tab(bufnr, ctx.tab)
  return true
end

function M.is_pr_buffer(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

return M
