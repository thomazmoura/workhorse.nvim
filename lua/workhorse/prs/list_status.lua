-- Status "slots" of the pull request list, loaded after the list itself through a rate-limited
-- queue (`prs.max_concurrent` requests at a time, a progress indicator until it is empty):
-- - active: the required work item, each required build and each required reviewer's vote. The
--   reviewers come with the list; the work item and builds from the checks of each pull request
--   (policy evaluations), shown as loading slots meanwhile when the policies of its target branch
--   (one request per branch) say they are required
-- - completed: the builds its merge started (those of the merge commit), the latest per pipeline
local M = {}

local prs_api = require("workhorse.api.pullrequests")
local builds_api = require("workhorse.api.builds")
local config = require("workhorse.config")

local LOADING = vim.fn.nr2char(0xf110) -- nf-fa-spinner
local PROGRESS_TITLE = "Loading the pull request checks"

-- Status of the list of `ctx`: { by_pr = { [id] = { status, checks } | { status, runs } },
-- policies = { [target_ref] = { work_items, builds } }, runner (the queue of the last load) }
local function status_of(ctx)
  ctx.list_status = ctx.list_status or { by_pr = {}, policies = {} }
  return ctx.list_status
end

-- Ask for a re-render once a burst of results has landed
local function notify_update(status)
  if status.render_scheduled or not status.on_update then
    return
  end
  status.render_scheduled = true
  vim.defer_fn(function()
    status.render_scheduled = false
    if status.on_update then
      status.on_update()
    end
  end, 50)
end

-- Run the tasks of `runner` up to the concurrency limit; the progress ends with the last one
local function pump(runner)
  if runner.stopped then
    return
  end
  local limit = math.max(1, config.get().prs.max_concurrent or 4)
  while runner.in_flight < limit and #runner.queue > 0 do
    local task = table.remove(runner.queue, 1)
    runner.in_flight = runner.in_flight + 1
    task(function()
      runner.in_flight = runner.in_flight - 1
      pump(runner)
    end)
  end
  if runner.in_flight == 0 and #runner.queue == 0 and runner.done then
    runner.done(runner.failures > 0)
    runner.done = nil
    if runner.failures > 0 then
      vim.notify(("Workhorse: Failed to load the checks of %d pull request%s"):format(runner.failures,
        runner.failures == 1 and "" or "s"), vim.log.levels.WARN)
      runner.failures = 0
    end
  end
end

local function enqueue(runner, task)
  table.insert(runner.queue, task)
  if not runner.done then
    runner.done = require("workhorse.progress").start(PROGRESS_TITLE)
  end
end

--- Stop the queue of the list (its buffer is gone, or a reload replaces it)
function M.stop(ctx)
  local status = ctx.list_status
  local runner = status and status.runner
  if runner then
    runner.stopped = true
    runner.queue = {}
    if runner.done then
      runner.done(false)
      runner.done = nil
    end
    status.runner = nil
  end
end

--- Load the slots of `prs` (those not loaded yet; all of them with opts.reload, whose results
--- replace the shown ones as they land). `on_update` is called (coalesced) as they land
function M.load(ctx, prs, on_update, opts)
  local status = status_of(ctx)
  status.on_update = on_update
  local reload = opts and opts.reload
  if reload then
    M.stop(ctx)
  end
  local runner = status.runner
  if not runner then
    runner = { queue = {}, in_flight = 0, failures = 0, requested = {}, policies = {} }
    status.runner = runner
  end

  local active, completed = {}, {}
  for _, pr in ipairs(prs) do
    local known = status.by_pr[pr.id]
    local wanted = reload or not known or known.status ~= pr.status
    if wanted and not runner.requested[pr.id] then
      if pr.status == "active" then
        table.insert(active, pr)
      elseif pr.status == "completed" then
        table.insert(completed, pr)
      end
    end
  end

  -- The policies of the target branches first: they turn into loading slots right away
  for _, pr in ipairs(active) do
    local ref = pr.target_ref
    if ref and not runner.policies[ref] and (reload or not status.policies[ref]) then
      runner.policies[ref] = true
      enqueue(runner, function(finish)
        prs_api.required_policies(ctx.repo, ref, function(required)
          if runner.stopped then
            return
          end
          if required then
            status.policies[ref] = required
            notify_update(status)
          end
          finish()
        end)
      end)
    end
  end

  for _, pr in ipairs(active) do
    runner.requested[pr.id] = true
    enqueue(runner, function(finish)
      prs_api.checks(ctx.repo, pr.id, function(checks)
        if runner.stopped then
          return
        end
        runner.requested[pr.id] = nil
        if checks then
          status.by_pr[pr.id] = { status = "active", checks = checks }
        else
          runner.failures = runner.failures + 1
          -- Shown before (a reload): kept; else no loading slots left spinning
          status.by_pr[pr.id] = status.by_pr[pr.id] or { status = "active", failed = true }
        end
        notify_update(status)
        finish()
      end, { silent = true })
    end)
  end

  for _, pr in ipairs(completed) do
    runner.requested[pr.id] = true
    enqueue(runner, function(finish)
      prs_api.merge_builds(ctx.repo, pr, function(runs)
        if runner.stopped then
          return
        end
        runner.requested[pr.id] = nil
        if runs then
          status.by_pr[pr.id] = { status = "completed", runs = runs }
          notify_update(status)
        else
          runner.failures = runner.failures + 1
        end
        finish()
      end, { silent = true })
    end)
  end

  pump(runner)
end

--- Checks of an active pull request fetched elsewhere (its screen): true when they changed
function M.set_checks(ctx, id, checks)
  local status = status_of(ctx)
  local known = status.by_pr[id]
  if known and known.status == "active" and vim.deep_equal(known.checks, checks) then
    return false
  end
  status.by_pr[id] = { status = "active", checks = checks }
  return true
end

-- Slot of a required build check: pending (not started), running (running, or its build queued
-- and waiting), warning (expired: must be queued again), failed and succeeded
local function build_slot(check)
  local status, result
  if check.status == "running" then
    status = "inProgress"
  elseif check.status == "rejected" or check.status == "broken" then
    status, result = "completed", "failed"
  elseif check.expired or (check.outdated and check.status ~= "approved") then
    status, result = "completed", "partiallySucceeded"
  elseif check.status == "approved" then
    status, result = "completed", "succeeded"
  elseif check.status == "queued" and check.build_id then
    status = "inProgress"
  else
    status = "notStarted"
  end
  return builds_api.status_icon(status, result)
end

local function slot(chunks, icon, hl)
  table.insert(chunks, { icon .. " ", hl })
end

--- Virtual text chunks of the slots of `pr`, to show before its date
function M.slots(ctx, pr)
  local status = status_of(ctx)
  local loaded = status.by_pr[pr.id]
  local chunks = {}
  if pr.status == "active" then
    local checks = loaded and loaded.status == "active" and loaded.checks
    if checks then
      -- Work item requirement: pending until a work item is linked
      for _, check in ipairs(checks) do
        if check.kind == "work_items" and check.blocking then
          slot(chunks, builds_api.status_icon(check.status == "approved" and "completed" or "notStarted",
            check.status == "approved" and "succeeded" or nil))
        end
      end
      for _, check in ipairs(checks) do
        if check.kind == "build" and check.blocking then
          slot(chunks, build_slot(check))
        end
      end
    elseif not (loaded and loaded.failed) then
      -- Still loading: what the policies of the target branch require, as loading slots
      local required = status.policies[pr.target_ref]
      if required then
        for _ = 1, (required.work_items and 1 or 0) + required.builds do
          slot(chunks, LOADING, "WorkhorseBuildPending")
        end
      end
    end
    -- Required reviewers (a reviewer who declined is left out): their vote, from the list itself
    for _, r in ipairs(pr.reviewers) do
      if r.required and not r.declined then
        local _, icon, hl = prs_api.vote_display(r.vote)
        slot(chunks, icon, hl)
      end
    end
  elseif pr.status == "completed" and loaded and loaded.runs then
    -- Builds started by the merge
    for _, run in ipairs(loaded.runs) do
      slot(chunks, builds_api.status_icon(run.status, run.result))
    end
  end
  return chunks
end

return M
