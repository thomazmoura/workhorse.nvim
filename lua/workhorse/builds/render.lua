local M = {}

local builds_api = require("workhorse.api.builds")
local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_builds")
local pips_ns = vim.api.nvim_create_namespace("workhorse_builds_pips")

-- A view is { lines = {...}, hls = { {line, col_start, col_end, group} }, virt = { [line] = chunks },
-- overlay = { [line] = chunks }, items = { [line] = item } }. `virt` is right-aligned virtual
-- text, `overlay` is drawn over the line from column 0.
-- Lines are 1-based in `items`/`virt`/`overlay` keys and 0-based in `hls`, matching the APIs they feed.
local function new_view()
  return { lines = {}, hls = {}, virt = {}, overlay = {}, items = {} }
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

-- Stage pips (one status icon per stage, dash-separated) for a run, as virtual text chunks
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

-- Each tree level is indented by two more spaces
local function indent(level)
  return string.rep("  ", level)
end

-- Columns kept free on the right for the pips/duration virtual text
local RIGHT_RESERVE = 12
local MIN_TITLE_WIDTH = 20

-- Cut text to `max` display columns, marking the cut with an ellipsis
local function truncate(text, max)
  if max < 2 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= max then
    return text
  end
  local chars = vim.fn.strchars(text)
  local out = text
  while chars > 0 and vim.fn.strdisplaywidth(out) > max - 1 do
    chars = chars - 1
    out = vim.fn.strcharpart(text, 0, chars)
  end
  return out .. "…"
end

-- Run line: status, branch (date), author and title; the title is trimmed to fit `width`
local function run_segments(run, level, width)
  local icon, hl = builds_api.status_icon(run.status, run.result)
  local segments = {
    { indent(level) },
    { icon, hl },
    { " " .. short_branch(run.source_branch), "WorkhorseBuildBranch" },
    { " (" .. builds_api.format_date(run.queue_time or run.start_time) .. ")", "WorkhorseBuildDate" },
    { "  " .. (run.requested_for or ""), "WorkhorseBuildAuthor" },
    { "  " },
  }
  local used = 0
  for _, seg in ipairs(segments) do
    used = used + vim.fn.strdisplaywidth(seg[1])
  end
  local title = (run.message or ""):gsub("\n.*", "")
  if title == "" then
    title = "#" .. (run.build_number or run.id)
  end
  -- Never trim the title away entirely; in narrow windows the line overflows instead
  local room = math.max(width - used - RIGHT_RESERVE, MIN_TITLE_WIDTH)
  table.insert(segments, { truncate(title, room), "WorkhorseBuildMessage" })
  return segments
end

-- Stage/job/step line at a tree level
-- Header path line (stage/job/step); the name is trimmed so the line never wraps
local function record_segments(record, level, width)
  local icon, hl = builds_api.status_icon(record.state, record.result)
  local used = vim.fn.strdisplaywidth(indent(level) .. icon .. " ")
  local name = truncate(record.name or "", math.max(width - used - RIGHT_RESERVE, MIN_TITLE_WIDTH))
  return { { indent(level) }, { icon, hl }, { " " .. name } }
end

-- View each header path level links back to: stage and job -> the run tree, step -> log
local path_targets = { "stages", "stages", "log" }

-- Markview-style horizontal rule: "───── ◇ ─────" across the window, drawn as an
-- overlay on an empty line so it never ends up in yanks or searches, then a blank
-- line before the content. The log view has none: its header sits in its own window.
local function add_separator(view, width)
  local side = math.max(math.floor((width - 3) / 2), 1)
  local lnum = add_line(view, { { "" } })
  view.overlay[lnum] = {
    { string.rep("─", side), "WorkhorseBuildSeparator" },
    { " ◇ ", "WorkhorseBuildSeparator" },
    { string.rep("─", width - 3 - side), "WorkhorseBuildSeparator" },
  }
  add_line(view, { { "" } })
end

-- Shared header: "# Definition", then the path from the run down to the current
-- level (path = { stage, job, step }, each one level deeper). Every header line is
-- a "nav" item linking back to the buffer of its level.
local function add_header(view, definition_name, run, path, width, live)
  local title = "# " .. definition_name
  add_line(view, { { title, "WorkhorseBuildHeader" } }, { kind = "nav", target = "runs" })
  if run then
    add_line(view, run_segments(run, 1, width), { kind = "nav", target = "stages", run = run }, duration_virt(run))
  end
  for i, record in ipairs(path or {}) do
    add_line(view, record_segments(record, i + 1, width), { kind = "nav", target = path_targets[i], record = record },
      duration_virt(record))
  end
  -- Live watching status of a run, right-aligned on its own line; <CR> anywhere on it toggles it
  if run then
    local status = live and { " Live watching enabled", "WorkhorseBuildLive" }
      or { " Live watching disabled", "WorkhorseBuildMeta" }
    add_line(view, { { "" } }, { kind = "nav", target = "live" }, { status })
  end
end

local function definition_of(run)
  return run.definition_name or ("Pipeline " .. (run.definition_id or "?"))
end

function M.render_runs(definition_name, runs, width)
  local view = new_view()
  add_header(view, definition_name, nil, nil, width)
  add_separator(view, width)
  for _, run in ipairs(runs) do
    add_line(view, run_segments(run, 1, width), { kind = "run", run = run })
  end
  if #runs == 0 then
    add_line(view, { { indent(1) .. "No runs found", "WorkhorseBuildMeta" } })
  end
  return view
end

-- Tree line: the fold marker sits in the two columns before the icon, so children
-- (indented two more) line up their marker under the parent's icon
local function tree_segments(record, level, children_count, expanded, name_hl)
  local marker = children_count == 0 and "  " or (expanded and "▾ " or "▸ ")
  local icon, hl = builds_api.status_icon(record.state, record.result)
  return { { indent(level) }, { marker, "WorkhorseBuildMeta" }, { icon, hl }, { " " .. record.name, name_hl } }
end

-- Run tree: stages > jobs > steps. `expanded` is a set of record ids whose
-- children are shown; everything starts collapsed to the stage level.
function M.render_stages(run, records, width, expanded, live)
  local view = new_view()
  add_header(view, definition_of(run), run, nil, width, live)
  add_separator(view, width)
  for _, stage in ipairs(builds_api.stages(records)) do
    local jobs = builds_api.jobs_of_stage(records, stage)
    local stage_open = expanded[stage.id]
    add_line(view, tree_segments(stage, 2, #jobs, stage_open, "WorkhorseBuildTitle"),
      { kind = "stage", record = stage, has_children = #jobs > 0 }, duration_virt(stage))
    if stage_open then
      for _, job in ipairs(jobs) do
        local steps = builds_api.steps_of_job(records, job)
        local job_open = expanded[job.id]
        add_line(view, tree_segments(job, 3, #steps, job_open),
          { kind = "job", record = job, has_children = #steps > 0 }, duration_virt(job))
        if job_open then
          for _, step in ipairs(steps) do
            local name_hl = not step.log and "WorkhorseBuildPending" or nil
            add_line(view, tree_segments(step, 4, 0, false, name_hl), { kind = "step", record = step, job = job },
              duration_virt(step))
          end
        end
      end
    end
  end
  return view
end

-- Header of the log view, pinned in its own window above the log
function M.render_log_header(run, stage, job, step, width, live)
  local view = new_view()
  add_header(view, definition_of(run), run, { stage, job, step }, width, live)
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

-- Render raw log lines, appended to `view` when given (e.g. a header)
function M.render_log(raw_lines, view)
  view = view or new_view()
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
  for lnum, chunks in pairs(view.overlay or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, first_line + lnum - 1, 0, { virt_text = chunks, virt_text_pos = "overlay" })
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
