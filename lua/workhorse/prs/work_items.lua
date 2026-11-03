-- Work Items section of the pull request Overview (prs/init.lua): the work items linked to the
-- pull request, editable as text on an active one, in the format of the work item buffers:
--
--   Work Items
--     #1234 | Login page                        📖 Active
--
-- A new line links a work item: completed from the work items of a saved query
-- (prs.work_items_query, else the last query opened, the one :Workhorse resume reopens); an id
-- typed by hand ("1234" or "#1234") is looked up on the server when leaving insert mode and its
-- line completed (M.lookup). Deleting a line removes the link. Links are "Pull Request" artifact
-- links on the work items (api/workitems.lua link_artifact).
local M = {}

local render = require("workhorse.builds.render")
local prs_api = require("workhorse.api.pullrequests")
local workitems_api = require("workhorse.api.workitems")
local config = require("workhorse.config")

M.HEADER = "Work Items"

local INDENT = "  "
local LINK_NAME = "Pull Request"

-- Work items seen this session (linked, in the completion list or looked up): [id] = { id,
-- title, state, type }
local known = {}
-- Ids looked up and not found: [id] = true
local missing = {}
-- Ids being looked up: [id] = true
local fetching = {}
-- Completion list of the query: { query, entries = { "#id | title" }, loading, callbacks }
local list = nil

local function remember(items)
  for _, item in ipairs(items or {}) do
    known[item.id] = item
    missing[item.id] = nil
  end
end

--- Text of a work item's line (without the indent)
local function text_of(item)
  return ("#%d | %s"):format(item.id, item.title)
end

-- Work items linked to the pull request: { { id, title, state, type } } by id (those the PAT can't
-- read keep their id, with an empty title)
function M.fetch(ctx, callback, opts)
  prs_api.work_items(ctx.repo, ctx.id, function(ids, err)
    if not ids then
      return callback(nil, err)
    end
    workitems_api.get_by_ids(ids, function(items, err2)
      if not items then
        return callback(nil, err2)
      end
      remember(items)
      local result = {}
      for _, id in ipairs(ids) do
        -- Not readable with the PAT: known all the same, so its line is not looked up again
        known[id] = known[id] or { id = id, title = "", state = "", type = "", hidden = true }
        table.insert(result, known[id])
      end
      table.sort(result, function(a, b)
        return a.id < b.id
      end)
      callback(result)
    end)
  end, opts)
end

local function baseline(ctx)
  return ctx.data.work_items or {}
end

--- Lines of the section for the pull request as it is
function M.canonical(ctx)
  return vim.tbl_map(function(item)
    return INDENT .. text_of(item)
  end, baseline(ctx))
end

-- A line split into its parts: { indent, id_text, rest, id (number|nil), title }; nil for a blank
-- line
local function split(line)
  if line:match("^%s*$") then
    return nil
  end
  local indent, id_text, rest = line:match("^(%s*)(#?%d+)(.*)$")
  if not indent then
    indent = line:match("^%s*")
    return { indent = indent, id_text = "", rest = line:sub(#indent + 1) }
  end
  local title = rest:match("^%s*|%s*(.-)%s*$") or (rest:match("^%s*$") and "") or nil
  return { indent = indent, id_text = id_text, rest = rest, id = tonumber((id_text:gsub("#", ""))), title = title }
end

local function type_display(work_item_type)
  local display = (config.get().work_item_type_display or {})[work_item_type]
  return display and display.text or work_item_type, display and display.color or "WorkhorseBuildMeta"
end

--- Add the section (its header, then `lines`, the edited ones or M.canonical) to `view`; with
--- `editable`, hints show what saving would change
function M.render(view, ctx, lines, editable)
  local hint = nil
  if editable and #lines == 0 then
    hint = { { "o links a work item", "WorkhorseRunHint" } }
  end
  render.add_line(view, { { M.HEADER, "WorkhorseRunSection" } }, nil, hint)
  if not editable and #lines == 0 then
    render.add_line(view, { { INDENT .. "None", "WorkhorseBuildMeta" } })
    return
  end
  local linked = {}
  for _, item in ipairs(baseline(ctx)) do
    linked[item.id] = true
  end
  local seen = {}
  for _, line in ipairs(lines) do
    local parts = split(line)
    if not parts then
      render.add_line(view, { { line } })
    else
      local virt = {}
      local item = parts.id and known[parts.id]
      if not parts.id then
        table.insert(virt, { "not a '#id | title' line", "DiagnosticError" })
      elseif fetching[parts.id] then
        table.insert(virt, { "looking up…", "WorkhorseRunHint" })
      elseif missing[parts.id] then
        table.insert(virt, { "work item not found", "DiagnosticError" })
      elseif item and item.hidden then
        table.insert(virt, { "not readable with this PAT", "WorkhorseRunHint" })
      elseif item then
        local text, hl = type_display(item.type)
        if text and text ~= "" then
          table.insert(virt, { text .. " ", hl })
        end
        local state_hl = (config.get().state_colors or {})[item.state] or "WorkhorseBuildMeta"
        table.insert(virt, { item.state, state_hl })
      end
      if parts.id and editable then
        if seen[parts.id] then
          table.insert(virt, { "  listed twice", "DiagnosticError" })
        elseif not linked[parts.id] and not missing[parts.id] then
          table.insert(virt, { "  [new]", "DiagnosticOk" })
        end
        seen[parts.id] = true
      end
      render.add_line(view, {
        { parts.indent },
        { parts.id_text, "WorkhorseBuildMeta" },
        { parts.rest, item and "WorkhorseBuildTitle" or nil },
      }, { kind = "edit", section = "work_items" }, #virt > 0 and virt or nil)
    end
  end
end

--- The changes of `lines` to save: { entries = { { text, hl } } to confirm, steps = { { label,
--- run(cb) } } } (nil when there are none), or nil and an error
function M.prepare(ctx, lines)
  local errors, seen, adds = {}, {}, {}
  for _, line in ipairs(lines) do
    local parts = split(line)
    if parts then
      if not parts.id then
        table.insert(errors, ("'%s' is not a '#id | title' line"):format(vim.trim(line)))
      elseif fetching[parts.id] then
        table.insert(errors, ("#%d is still being looked up"):format(parts.id))
      elseif missing[parts.id] then
        table.insert(errors, ("#%d: work item not found"):format(parts.id))
      elseif seen[parts.id] then
        table.insert(errors, ("#%d is listed twice"):format(parts.id))
      else
        seen[parts.id] = true
        table.insert(adds, parts.id)
      end
    end
  end
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  local linked = {}
  for _, item in ipairs(baseline(ctx)) do
    linked[item.id] = item
  end
  local url = prs_api.artifact_url(ctx.repo, ctx.id)
  local entries, steps = {}, {}
  local function label(id)
    return known[id] and text_of(known[id]) or ("#" .. id)
  end
  for _, id in ipairs(adds) do
    if not linked[id] then
      table.insert(entries, { text = "  + " .. label(id), hl = "DiagnosticOk" })
      table.insert(steps, { label = "#" .. id, run = function(cb)
        workitems_api.link_artifact(id, url, LINK_NAME, cb)
      end })
    end
  end
  for _, item in ipairs(baseline(ctx)) do
    if not seen[item.id] then
      table.insert(entries, { text = "  - " .. label(item.id), hl = "DiagnosticError" })
      table.insert(steps, { label = "#" .. item.id, run = function(cb)
        workitems_api.unlink_artifact(item.id, url, cb)
      end })
    end
  end
  if #steps == 0 then
    return nil
  end
  return { entries = entries, steps = steps }
end

-- Completion ------------------------------------------------------------------

local function query_id()
  local configured = config.get().prs.work_items_query
  if configured and configured ~= "" then
    return configured
  end
  local last = require("workhorse.session").get_last_query()
  return last and last.id or nil
end

--- Load the completion list (the work items of the query) once; on_ready() when it changes
function M.load_list(on_ready)
  local id = query_id()
  if not id then
    return
  end
  if list and list.query == id then
    if list.loading then
      table.insert(list.callbacks, on_ready)
    end
    return
  end
  list = { query = id, entries = {}, loading = true, callbacks = { on_ready } }
  local current = list
  require("workhorse.api.queries").execute(id, function(result, err)
    local function finish()
      current.loading = false
      for _, cb in ipairs(current.callbacks) do
        cb()
      end
    end
    if not result then
      vim.notify("Workhorse: Could not load the work items of the query to complete: " .. tostring(err),
        vim.log.levels.WARN)
      if list == current then
        list = nil
      end
      return finish()
    end
    workitems_api.get_by_ids(result.ids, function(items)
      remember(items)
      local by_id = {}
      for _, item in ipairs(items or {}) do
        by_id[item.id] = item
      end
      -- In the query's order
      for _, wid in ipairs(result.ids) do
        if by_id[wid] then
          table.insert(current.entries, text_of(by_id[wid]))
        end
      end
      finish()
    end)
  end)
end

--- Forget the completion list (loaded again on the next M.load_list)
function M.reset_list()
  list = nil
end

--- Completion: the work items of the query (the whole line is the value)
function M.choices()
  return list and list.entries or {}
end

function M.start(line)
  return #line:match("^%s*")
end

-- Lookup of typed ids -------------------------------------------------------------

--- Lines of `lines` to complete: { [i] = new line } for those whose work item is known but whose
--- text is not its "#id | title", plus the ids to look up (not known, missing or being fetched)
function M.completions(lines)
  local replace, unknown, asked = {}, {}, {}
  for i, line in ipairs(lines) do
    local parts = split(line)
    if parts and parts.id then
      local item = known[parts.id]
      if item and item.title ~= "" then
        local text = parts.indent .. text_of(item)
        if text ~= line then
          replace[i] = text
        end
      elseif not item and not missing[parts.id] and not fetching[parts.id] and not asked[parts.id] then
        asked[parts.id] = true
        table.insert(unknown, parts.id)
      end
    end
  end
  return replace, unknown
end

--- Look up `ids` on the server; on_done() once they are known (or missing)
function M.lookup(ids, on_done)
  for _, id in ipairs(ids) do
    fetching[id] = true
  end
  workitems_api.get_by_ids(ids, function(items)
    for _, id in ipairs(ids) do
      fetching[id] = nil
    end
    -- A failed request leaves them unknown (asked again on the next lookup)
    if items then
      remember(items)
      local found = {}
      for _, item in ipairs(items) do
        found[item.id] = true
      end
      for _, id in ipairs(ids) do
        if not found[id] then
          missing[id] = true
        end
      end
    end
    on_done()
  end)
end

return M
