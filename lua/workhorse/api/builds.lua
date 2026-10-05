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

-- Get a definition with what queuing a run needs: its repository (id, type,
-- default branch), YAML file (nil for classic pipelines) and the variables that
-- can be set at queue time (allowOverride), as { name, value, secret }
function M.get_definition(definition_id, callback)
  client.get(project_path("definitions/" .. definition_id .. "?api-version=7.1"), {
    on_success = function(data)
      data = strip_nulls(data or {})
      local repo = data.repository or {}
      local process = data.process or {}
      local variables = {}
      for name, v in pairs(type(data.variables) == "table" and data.variables or {}) do
        strip_nulls(v)
        if v.allowOverride then
          table.insert(variables, { name = name, value = v.value or "", secret = v.isSecret == true })
        end
      end
      table.sort(variables, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      callback({
        id = data.id,
        name = data.name,
        repository = { id = repo.id, type = repo.type, name = repo.name, default_branch = repo.defaultBranch },
        yaml_file = process.yamlFilename ~= vim.NIL and process.yamlFilename or nil,
        variables = variables,
      })
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Percent-encode a query string value (slashes kept, as in file paths)
local function url_encode(text)
  return (text:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

-- Content of a file of an Azure Repos Git repository at a branch
function M.get_file(repository_id, path, branch, callback)
  local url = "/" .. config.get().project .. "/_apis/git/repositories/" .. repository_id .. "/items?path="
    .. url_encode("/" .. path:gsub("^/", ""))
    .. "&versionDescriptor.version=" .. url_encode((branch:gsub("^refs/heads/", "")))
    .. "&versionDescriptor.versionType=branch&includeContent=true&api-version=7.1"
  client.get(url, {
    silent = true,
    on_success = function(data)
      callback(data and data.content or "")
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Branch names (without refs/heads/) of an Azure Repos Git repository
function M.list_branches(repository_id, callback)
  client.get("/" .. config.get().project .. "/_apis/git/repositories/" .. repository_id
    .. "/refs?filter=heads/&api-version=7.1", {
    silent = true,
    on_success = function(data)
      local branches = {}
      for _, ref in ipairs(data and data.value or {}) do
        table.insert(branches, (ref.name:gsub("^refs/heads/", "")))
      end
      callback(branches)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

local function sort_ci(list)
  table.sort(list, function(a, b)
    return a:lower() < b:lower()
  end)
  return list
end

-- Git repositories of the project: callback({ { id, name, default_branch } }) sorted by name,
-- disabled ones left out
function M.list_repositories(callback)
  client.get("/" .. config.get().project .. "/_apis/git/repositories?api-version=7.1", {
    silent = true,
    on_success = function(data)
      local repos = {}
      for _, r in ipairs(data and data.value or {}) do
        strip_nulls(r)
        if not r.isDisabled then
          table.insert(repos, { id = r.id, name = r.name, default_branch = r.defaultBranch })
        end
      end
      table.sort(repos, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      callback(repos)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Paths (without the leading slash) of the YAML files of an Azure Repos Git repository at a
-- branch, sorted
function M.list_yaml_files(repository_id, branch, callback)
  client.get("/" .. config.get().project .. "/_apis/git/repositories/" .. repository_id
    .. "/items?scopePath=/&recursionLevel=Full"
    .. "&versionDescriptor.version=" .. url_encode((branch:gsub("^refs/heads/", "")))
    .. "&versionDescriptor.versionType=branch&api-version=7.1", {
    silent = true,
    on_success = function(data)
      local files = {}
      for _, item in ipairs(data and data.value or {}) do
        local path = type(item.path) == "string" and item.path or ""
        if item.isFolder ~= true and path:lower():match("%.ya?ml$") then
          table.insert(files, (path:gsub("^/", "")))
        end
      end
      callback(sort_ci(files))
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Agent queues of the project: callback({ { id, name } }) sorted by name
function M.list_queues(callback)
  client.get("/" .. config.get().project .. "/_apis/distributedtask/queues?api-version=7.1-preview.1", {
    silent = true,
    on_success = function(data)
      local queues = {}
      for _, q in ipairs(data and data.value or {}) do
        table.insert(queues, { id = q.id, name = q.name })
      end
      table.sort(queues, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      callback(queues)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Create a YAML pipeline (build definition). opts: { name, folder = "\\...", repository =
-- { id, name }, branch = "refs/heads/...", yaml_file, queue_id (optional) };
-- callback({ id, name }) or callback(nil, err)
function M.create_definition(opts, callback)
  local body = {
    name = opts.name,
    path = opts.folder,
    type = "build",
    quality = "definition",
    repository = {
      id = opts.repository.id,
      name = opts.repository.name,
      type = "TfsGit",
      defaultBranch = opts.branch,
    },
    -- 2 = YAML process
    process = { type = 2, yamlFilename = opts.yaml_file },
    -- Without a trigger in the definition the YAML's `trigger:` is ignored; settingsSourceType
    -- 2 makes it follow the YAML file
    triggers = {
      {
        triggerType = "continuousIntegration",
        settingsSourceType = 2,
        branchFilters = {},
        pathFilters = {},
        batchChanges = false,
        maxConcurrentBuildsPerBranch = 1,
      },
    },
  }
  if opts.queue_id then
    body.queue = { id = opts.queue_id }
  end
  client.post(project_path("definitions?api-version=7.1"), body, {
    on_success = function(data)
      callback(data and { id = data.id, name = data.name })
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Deployment environments of the project with the tags of their resources (VMs):
-- callback({ { name, tags = { "WEB", ... } } }) sorted by name, environments sharing a
-- name merged
function M.list_environments(callback)
  local base = "/" .. config.get().project .. "/_apis/distributedtask/environments"
  client.get(base .. "?$top=1000&api-version=7.1-preview.1", {
    silent = true,
    on_success = function(data)
      local envs = data and data.value or {}
      local by_name, pending = {}, #envs
      local function done()
        local result = {}
        for name, tags in pairs(by_name) do
          table.insert(result, { name = name, tags = sort_ci(vim.tbl_keys(tags)) })
        end
        table.sort(result, function(a, b)
          return a.name:lower() < b.name:lower()
        end)
        callback(result)
      end
      if pending == 0 then
        return done()
      end
      for _, env in ipairs(envs) do
        by_name[env.name] = by_name[env.name] or {}
        -- One request per environment: the list does not include the resources
        client.get(base .. "/" .. env.id .. "?expands=resourceReferences&api-version=7.1-preview.1", {
          silent = true,
          on_success = function(detail)
            for _, resource in ipairs(detail and detail.resources or {}) do
              for _, tag in ipairs(resource.tags or {}) do
                by_name[env.name][tag] = true
              end
            end
            pending = pending - 1
            if pending == 0 then
              done()
            end
          end,
          on_error = function()
            pending = pending - 1
            if pending == 0 then
              done()
            end
          end,
        })
      end
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Queue a run of a definition. opts: { branch = "refs/heads/...", variables = { name = value },
-- parameters = { name = value } } (parameters are the YAML runtime parameters)
function M.queue_build(definition_id, opts, callback)
  local body = { definition = { id = definition_id }, sourceBranch = opts.branch }
  if opts.variables and next(opts.variables) then
    -- The Build API takes queue-time variables as a JSON string
    body.parameters = vim.json.encode(opts.variables)
  end
  if opts.parameters and next(opts.parameters) then
    body.templateParameters = opts.parameters
  end
  client.post(project_path("builds?api-version=7.1"), body, {
    on_success = function(data)
      callback(data and map_run(data))
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Request cancellation of a running build; the run moves to "cancelling", then completes as canceled
function M.cancel_build(build_id, callback)
  client.request({
    path = project_path("builds/" .. build_id .. "?api-version=7.1"),
    method = "PATCH",
    body = { status = "cancelling" },
    on_success = function(data)
      callback(data and map_run(data))
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

-- Top-level ancestor of a record (its stage, or top-level phase in classic pipelines)
function M.stage_of(records, record)
  local current = record
  while current and current.parentId do
    local parent = M.find(records, current.parentId)
    if not parent then
      break
    end
    current = parent
  end
  return current
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

-- Local date of a timestamp, e.g. "03/10/26 00:06"
function M.format_date(iso)
  local t = parse_time(iso)
  if not t then
    return ""
  end
  -- parse_time and utc_now both read UTC fields as local time, so the difference
  -- between the real clock and utc_now is the local UTC offset
  local offset = os.time() - utc_now()
  return os.date("%d/%m/%y %H:%M", math.floor(t + offset))
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

-- Nerd Font circle icons: outlined for success/warning, solid for failure.
-- Font Awesome 4 has no outlined exclamation circle, so the warning uses Material Design
local CHECK = "" -- nf-fa-check_circle_o
local WARN = "󰗖" -- nf-md-alert_circle_outline
local FAIL = "" -- nf-fa-times_circle
local SKIP = "" -- nf-fa-minus_circle
local RUNNING = "" -- nf-fa-play_circle
local PENDING = "" -- nf-fa-circle_o

local icons = {
  succeeded = { CHECK, "WorkhorseBuildSucceeded" },
  partiallySucceeded = { WARN, "WorkhorseBuildWarning" },
  succeededWithIssues = { WARN, "WorkhorseBuildWarning" },
  failed = { FAIL, "WorkhorseBuildFailed" },
  canceled = { SKIP, "WorkhorseBuildCanceled" },
  abandoned = { SKIP, "WorkhorseBuildCanceled" },
  skipped = { SKIP, "WorkhorseBuildCanceled" },
  running = { RUNNING, "WorkhorseBuildRunning" },
  pending = { PENDING, "WorkhorseBuildPending" },
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
