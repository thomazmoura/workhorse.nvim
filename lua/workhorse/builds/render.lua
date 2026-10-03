local M = {}

local builds_api = require("workhorse.api.builds")
local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_builds")
local pips_ns = vim.api.nvim_create_namespace("workhorse_builds_pips")

-- A view is { lines = {...}, hls = { {line, col_start, col_end, group} }, virt = { [line] = chunks }, items = { [line] = item } }
-- Lines are 1-based in `items`/`virt` keys and 0-based in `hls`, matching the APIs they feed.
local function new_view()
  return { lines = {}, hls = {}, virt = {}, items = {} }
end

-- Append a line built from { text, hl } segments; returns its 1-based line number
local function add_line(view, segments, item, virt)
  local text = ""
  local lnum = #view.lines
  for _, seg in ipairs(segments) do
    if seg[2] then
      table.insert(view.hls, { lnum, #text, #text + #seg[1], seg[2] })
    end
    text = text .. seg[1]
  end
  table.insert(view.lines, text)
  view.items[lnum + 1] = item
  view.virt[lnum + 1] = virt
  return lnum + 1
end

local function short_branch(ref)
  return (ref or ""):gsub("^refs/heads/", "")
end

local function duration_virt(record)
  local d = builds_api.format_duration(record.startTime or record.start_time, record.finishTime or record.finish_time)
  if d == "" then
    return nil
  end
  return { { d, "WorkhorseBuildMeta" } }
end

-- Stage pips (✓-✓-!) for a run, as virtual text chunks
function M.stage_pips(records)
  local chunks = {}
  for i, stage in ipairs(builds_api.stages(records)) do
    if i > 1 then
      table.insert(chunks, { "-", "WorkhorseBuildMeta" })
    end
    local icon, hl = builds_api.status_icon(stage.state, stage.result)
    table.insert(chunks, { icon, hl })
  end
  return chunks
end

function M.render_runs(definition_name, runs)
  local view = new_view()
  add_line(view, { { definition_name, "WorkhorseBuildHeader" } })
  add_line(view, { { "" } })
  for _, run in ipairs(runs) do
    local icon, hl = builds_api.status_icon(run.status, run.result)
    local sha = (run.source_version or ""):sub(1, 7)
    add_line(view, {
      { icon, hl },
      { " #" .. (run.build_number or run.id), "WorkhorseBuildTitle" },
      { " • " .. ((run.message or ""):gsub("\n.*", "")) },
      { "  ⎇ " .. short_branch(run.source_branch), "WorkhorseBuildMeta" },
      { " " .. sha, "WorkhorseBuildMeta" },
    }, { kind = "run", run = run })
  end
  if #runs == 0 then
    add_line(view, { { "No runs found", "WorkhorseBuildMeta" } })
  end
  return view
end

function M.render_stages(run, records)
  local view = new_view()
  local icon, hl = builds_api.status_icon(run.status, run.result)
  add_line(view, { { icon, hl }, { " #" .. (run.build_number or run.id), "WorkhorseBuildHeader" } }, nil, duration_virt(run))
  add_line(view, { { (run.message or ""):gsub("\n.*", ""), "WorkhorseBuildMeta" } })
  for _, stage in ipairs(builds_api.stages(records)) do
    add_line(view, { { "" } })
    local jobs = builds_api.jobs_of_stage(records, stage)
    local s_icon, s_hl = builds_api.status_icon(stage.state, stage.result)
    add_line(view, { { s_icon, s_hl }, { " " .. stage.name, "WorkhorseBuildTitle" } },
      { kind = "stage", record = stage, first_job = jobs[1] }, duration_virt(stage))
    for _, job in ipairs(jobs) do
      local j_icon, j_hl = builds_api.status_icon(job.state, job.result)
      add_line(view, { { "    " }, { j_icon, j_hl }, { " " .. job.name } }, { kind = "job", record = job }, duration_virt(job))
    end
  end
  return view
end

function M.render_steps(run, job, steps)
  local view = new_view()
  local icon, hl = builds_api.status_icon(job.state, job.result)
  add_line(view, { { icon, hl }, { " " .. job.name, "WorkhorseBuildHeader" } }, nil, duration_virt(job))
  add_line(view, { { "#" .. (run.build_number or run.id), "WorkhorseBuildMeta" } })
  add_line(view, { { "" } })
  for _, step in ipairs(steps) do
    local s_icon, s_hl = builds_api.status_icon(step.state, step.result)
    local name_hl = not step.log and "WorkhorseBuildPending" or nil
    add_line(view, { { "  " }, { s_icon, s_hl }, { " " .. step.name, name_hl } }, { kind = "step", record = step }, duration_virt(step))
  end
  if #steps == 0 then
    add_line(view, { { "No steps", "WorkhorseBuildMeta" } })
  end
  return view
end

local log_markers = {
  { "##%[error%]", "WorkhorseLogError" },
  { "##%[warning%]", "WorkhorseLogWarning" },
  { "##%[section%]", "WorkhorseLogSection" },
  { "##%[command%]", "WorkhorseLogCommand" },
  { "##%[debug%]", "WorkhorseLogDebug" },
  { "##%[group%]", "WorkhorseLogSection" },
}

-- Render raw log lines (no header, so line N in the buffer is log line N)
function M.render_log(raw_lines)
  local view = new_view()
  local strip = config.get().builds.strip_timestamps
  for _, raw in ipairs(raw_lines) do
    local text = strip and raw:gsub("^%d+%-%d+%-%d+T[%d:%.]+Z ", "", 1) or raw
    local group
    for _, marker in ipairs(log_markers) do
      if text:find(marker[1]) then
        group = marker[2]
        break
      end
    end
    add_line(view, { { text, group } })
  end
  return view
end

local function apply_decorations(bufnr, view, first_line)
  first_line = first_line or 0
  for _, h in ipairs(view.hls) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, first_line + h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  for lnum, chunks in pairs(view.virt) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, first_line + lnum - 1, 0, { virt_text = chunks, virt_text_pos = "right_align" })
  end
end

-- Replace the whole buffer content with a view
function M.apply(bufnr, view)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, view.lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, pips_ns, 0, -1)
  apply_decorations(bufnr, view)
end

-- Append a view at the end of the buffer (used for streaming logs)
function M.append(bufnr, view)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local empty = count == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
  local first = empty and 0 or count
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, first, -1, false, view.lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  apply_decorations(bufnr, view, first)
end

-- Set the stage pips of one run line
function M.set_pips(bufnr, lnum, chunks)
  if not vim.api.nvim_buf_is_valid(bufnr) or lnum > vim.api.nvim_buf_line_count(bufnr) or #chunks == 0 then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, pips_ns, lnum - 1, lnum)
  vim.api.nvim_buf_set_extmark(bufnr, pips_ns, lnum - 1, 0, { virt_text = chunks, virt_text_pos = "right_align" })
end

return M
