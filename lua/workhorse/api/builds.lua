local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")

local function project_path(rest)
  return "/" .. config.get().project .. "/_apis/build/" .. rest
end

-- vim.json.decode turns JSON null into vim.NIL, which is truthy and ~= nil.
-- Timeline records use null heavily (parentId of stages, log of pending steps),
-- so drop those keys to make plain nil checks work.
local function strip_nulls(tbl)
  for k, v in pairs(tbl) do
    if v == vim.NIL then
      tbl[k] = nil
    end
  end
  return tbl
end

local function map_run(b)
  strip_nulls(b)
  local trigger = b.triggerInfo or {}
  return {
    id = b.id,
    build_number = b.buildNumber,
    definition_id = b.definition and b.definition.id,
    definition_name = b.definition and b.definition.name,
    status = b.status,
    result = b.result,
    source_branch = b.sourceBranch,
    source_version = b.sourceVersion,
    reason = b.reason,
    requested_for = b.requestedFor and b.requestedFor.displayName,
    message = trigger["ci.message"],
    queue_time = b.queueTime,
    start_time = b.startTime,
    finish_time = b.finishTime,
    url = b._links and b._links.web and b._links.web.href,
  }
end

-- List build (pipeline) definitions of the project
function M.list_definitions(callback)
  client.get(project_path("definitions?queryOrder=definitionNameAscending&api-version=7.1"), {
    on_success = function(data)
      local defs = {}
      for _, d in ipairs(data and data.value or {}) do
        table.insert(defs, { id = d.id, name = d.name, path = d.path or "\\" })
      end
      callback(defs)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- List the most recent runs of a definition
function M.list_runs(definition_id, callback)
  local top = config.get().builds.top
  local path = project_path(
    "builds?definitions=" .. definition_id .. "&$top=" .. top .. "&queryOrder=queueTimeDescending&api-version=7.1"
  )
  client.get(path, {
    on_success = function(data)
      local runs = {}
      for _, b in ipairs(data and data.value or {}) do
        table.insert(runs, map_run(b))
      end
      callback(runs)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Get a single run. opts.silent suppresses error notifications (used while polling)
function M.get_build(build_id, callback, opts)
  client.get(project_path("builds/" .. build_id .. "?api-version=7.1"), {
    silent = opts and opts.silent,
    on_success = function(data)
      callback(map_run(data))
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Get the timeline (stages, phases, jobs, tasks) of a run as a flat record list
function M.get_timeline(build_id, callback, opts)
  client.get(project_path("builds/" .. build_id .. "/timeline?api-version=7.1"), {
    silent = opts and opts.silent,
    on_success = function(data)
      local records = data and data.records
      if type(records) ~= "table" then
        records = {}
      end
      for _, r in ipairs(records) do
        strip_nulls(r)
      end
      callback(records)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Get log lines of a run.
-- opts.start_line is 1-based and inclusive (nil = from the beginning); opts.silent as in get_build
function M.get_log(build_id, log_id, callback, opts)
  opts = opts or {}
  local path = "builds/" .. build_id .. "/logs/" .. log_id .. "?api-version=7.1"
  if opts.start_line then
    path = path .. "&startLine=" .. opts.start_line
  end
  client.get(project_path(path), {
    silent = opts.silent,
    on_success = function(data)
      callback(data and data.value or {})
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Timeline helpers ---------------------------------------------------------

local function by_order(a, b)
  return (a.order or math.huge) < (b.order or math.huge)
end

-- Direct children of a record, optionally filtered by type, sorted by order
function M.children(records, parent_id, record_type)
  local result = {}
  for _, r in ipairs(records) do
    if r.parentId == parent_id and (not record_type or r.type == record_type) then
      table.insert(result, r)
    end
  end
  table.sort(result, by_order)
  return result
end

-- Top-level stages. Classic (non-YAML) pipelines have no Stage records, so
-- their top-level phases stand in for stages.
function M.stages(records)
  local stages = M.children(records, nil, "Stage")
  if #stages == 0 then
    stages = M.children(records, nil, "Phase")
  end
  return stages
end

-- Jobs of a stage, flattening the Phase level in between. A phase that never
-- produced jobs (e.g. skipped) is listed itself so the stage is not empty.
function M.jobs_of_stage(records, stage)
  local jobs = {}
  local phases = stage.type == "Phase" and { stage } or M.children(records, stage.id, "Phase")
  for _, phase in ipairs(phases) do
    local phase_jobs = M.children(records, phase.id, "Job")
    if #phase_jobs == 0 then
      table.insert(jobs, phase)
    else
      vim.list_extend(jobs, phase_jobs)
    end
  end
  return jobs
end

-- Steps (tasks) of a job
function M.steps_of_job(records, job)
  return M.children(records, job.id, "Task")
end

-- Find a record by id
function M.find(records, id)
  for _, r in ipairs(records) do
    if r.id == id then
      return r
    end
  end
end

-- Formatting helpers -------------------------------------------------------

-- Parse an ISO-8601 UTC timestamp into seconds. The value is interpreted as
-- local time by os.time, which is fine because we only ever take differences
-- against values parsed the same way (see utc_now).
local function parse_time(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, frac = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)")
  if not y then
    return nil
  end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  if frac ~= "" then
    t = t + tonumber("0." .. frac)
  end
  return t
end

local function utc_now()
  local now = os.date("!*t")
  now.isdst = false
  return os.time(now)
end

-- Duration between two timestamps; a missing finish means "still running"
function M.format_duration(start_iso, finish_iso)
  local start = parse_time(start_iso)
  if not start then
    return ""
  end
  local finish = parse_time(finish_iso) or utc_now()
  local secs = math.max(0, finish - start)
  if secs < 1 then
    return "<1s"
  end
  secs = math.floor(secs)
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if h > 0 then
    return string.format("%dh %dm", h, m)
  elseif m > 0 then
    return string.format("%dm %ds", m, s)
  end
  return s .. "s"
end

local icons = {
  succeeded = { "✓", "WorkhorseBuildSucceeded" },
  partiallySucceeded = { "!", "WorkhorseBuildWarning" },
  succeededWithIssues = { "!", "WorkhorseBuildWarning" },
  failed = { "✗", "WorkhorseBuildFailed" },
  canceled = { "○", "WorkhorseBuildCanceled" },
  abandoned = { "○", "WorkhorseBuildCanceled" },
  skipped = { "○", "WorkhorseBuildCanceled" },
  running = { "◷", "WorkhorseBuildRunning" },
  pending = { "·", "WorkhorseBuildPending" },
}

-- Icon and highlight for a run (status/result) or timeline record (state/result)
function M.status_icon(status, result)
  if status == "completed" and result and icons[result] then
    return icons[result][1], icons[result][2]
  elseif status == "inProgress" or status == "cancelling" then
    return icons.running[1], icons.running[2]
  end
  return icons.pending[1], icons.pending[2]
end

-- Whether a run or record is finished
function M.is_completed(status)
  return status == "completed"
end

return M
