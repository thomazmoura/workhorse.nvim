-- Pipelines section of the library screen (libraries_screen/library.lua): which pipelines may
-- use the library (its pipeline permissions), one per line, by folder and name:
--
--   Open access: off
--   CI\my-pipeline
--   other-pipeline
--
-- "Open access: on" lets every pipeline of the project use it. A new line (completed from the
-- project's pipelines, those of the repository cache) authorizes a pipeline, deleting one revokes it; a pipeline the project no
-- longer has shows as #id. Saving (of the whole screen) lists the changes, then applies them.
local M = {}

local library_screen = require("workhorse.libraries_screen.library")
local libraries_api = require("workhorse.api.libraries")

local ns = vim.api.nvim_create_namespace("workhorse_library_pipelines")

local notify = library_screen.notify

local SECTION = "pipelines"
local OPEN_ACCESS = "Open access"
local ON_OFF = { "on", "off" }

-- Per-buffer state: { group, all (open access), authorized = { [definition id] = { authorized_by,
-- authorized_on } }, definitions = { by_id, by_name (lowercase), names }, listed (the server's
-- pipelines were listed), loading, loaded, saving }
local buffers = {}

local function section(bufnr)
  local lines, offset = library_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

-- "Folder\Sub\name" of a pipeline (just its name at the root)
local function full_name(definition)
  local path = (definition.path or "\\"):gsub("^\\+", ""):gsub("\\+$", "")
  return path == "" and definition.name or (path .. "\\" .. definition.name)
end

local function name_of(state, id)
  local definition = state.definitions.by_id[id]
  return definition and full_name(definition) or ("#" .. id)
end

local function render(bufnr)
  local state = buffers[bufnr]
  local names = {}
  for id in pairs(state.authorized) do
    table.insert(names, name_of(state, id))
  end
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  table.insert(names, 1, OPEN_ACCESS .. ": " .. (state.all and "on" or "off"))
  library_screen.set_section(bufnr, SECTION, names)
  state.loaded = true
  library_screen.update_modified(bufnr)
  library_screen.decorate(bufnr)
end

-- Parsing and changes ---------------------------------------------------------

-- The section's lines (line i being buffer line offset + i): { all = { value, lnum } | nil,
-- pipelines = { { name, id, lnum } } (id nil when unknown) }, plus errors
local function parse(state, lines, offset)
  local result, errors = { pipelines = {} }, {}
  for i, line in ipairs(lines) do
    local text = vim.trim(line)
    if text ~= "" then
      local lnum = offset + i
      local key, value = text:match("^([^:]+):%s*(.-)%s*$")
      if key and vim.trim(key):lower() == OPEN_ACCESS:lower() then
        value = value:lower()
        if not vim.tbl_contains(ON_OFF, value) then
          table.insert(errors, ("Line %d: %s is on or off"):format(lnum, OPEN_ACCESS))
        end
        result.all = { value = value == "on", lnum = lnum }
      else
        local id = tonumber(text:match("^#(%d+)$"))
        local definition = state.definitions.by_name[text:lower()]
        table.insert(result.pipelines, { name = text, id = id or (definition and definition.id), lnum = lnum })
      end
    end
  end
  return result, errors
end

-- Changes of the section: { all = bool|nil, authorize = { id }, revoke = { id } }, plus errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  local parsed, errors = parse(state, lines, offset)
  local changes = { authorize = {}, revoke = {} }
  if not present then
    table.insert(errors, library_screen.missing_header(SECTION))
    return changes, errors
  end
  local seen = {}
  for _, p in ipairs(parsed.pipelines) do
    if not p.id then
      table.insert(errors, ("Line %d: no pipeline %s in the project"):format(p.lnum, p.name))
    elseif seen[p.id] then
      table.insert(errors, ("Line %d: %s appears more than once"):format(p.lnum, p.name))
    else
      seen[p.id] = true
      if not state.authorized[p.id] then
        table.insert(changes.authorize, p.id)
      end
    end
  end
  for id in pairs(state.authorized) do
    if not seen[id] then
      table.insert(changes.revoke, id)
    end
  end
  if parsed.all and parsed.all.value ~= state.all then
    changes.all = parsed.all.value
  end
  return changes, errors
end

local function count(changes)
  return #changes.authorize + #changes.revoke + (changes.all ~= nil and 1 or 0)
end

-- Decoration ------------------------------------------------------------------

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not state.group.id then
    library_screen.header_hint(bufnr, SECTION, "set once the library is created")
    return
  end
  if not state.loaded then
    return
  end
  local lines, offset = section(bufnr)
  local parsed = parse(state, lines, offset)
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  if parsed.all then
    local line = vim.api.nvim_buf_get_lines(bufnr, parsed.all.lnum - 1, parsed.all.lnum, false)[1]
    local indent = #line:match("^%s*")
    mark(parsed.all.lnum, { col = indent, end_col = indent + #OPEN_ACCESS + 1, hl_group = "WorkhorseRunKey" })
    if parsed.all.value ~= state.all then
      mark(parsed.all.lnum, { virt_text = { { "  [was " .. (state.all and "on" or "off") .. "]", "DiagnosticWarn" } } })
    elseif state.all then
      mark(parsed.all.lnum, { virt_text = { { "  every pipeline of the project may use it", "WorkhorseRunHint" } } })
    end
  end
  local seen = {}
  for _, p in ipairs(parsed.pipelines) do
    local virt
    if not p.id then
      virt = { "  no such pipeline", "DiagnosticError" }
    elseif seen[p.id] then
      virt = { "  appears more than once", "DiagnosticError" }
    elseif not state.authorized[p.id] then
      virt = { "  [new]", "DiagnosticOk" }
    else
      local by = state.authorized[p.id]
      local date = by.authorized_on and require("workhorse.api.builds").format_date(by.authorized_on)
      local text = table.concat(vim.tbl_filter(function(part)
        return part ~= nil and part ~= ""
      end, { by.authorized_by, date }), ", ")
      if text ~= "" then
        virt = { "  " .. text, "WorkhorseBuildMeta" }
      end
    end
    if p.id then
      seen[p.id] = true
    end
    if virt then
      mark(p.lnum, { virt_text = { virt } })
    end
  end
end

-- Loading ---------------------------------------------------------------------

-- The project's pipelines, for naming the authorized ones and completing those to add
local function set_definitions(state, definitions)
  local by_id, by_name, names = {}, {}, {}
  for _, d in ipairs(definitions) do
    local name = full_name(d)
    by_id[d.id], by_name[name:lower()] = d, d
    table.insert(names, name)
  end
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  state.definitions = { by_id = by_id, by_name = by_name, names = names }
end

-- Whether the pipelines known miss one of `authorized` (created since they were cached)
local function stale(state, authorized)
  if not state.definitions.names then
    return true
  end
  for id in pairs(authorized) do
    if not state.definitions.by_id[id] then
      return true
    end
  end
  return false
end

-- Read the pipelines of the project from the repository cache (once per screen) and fetch the
-- library's permissions, then render. The server's pipelines are listed only when the cache
-- misses one the library authorizes (the cache learns them); a failed listing names it by id
local function load(bufnr)
  local state = buffers[bufnr]
  if not state.group.id then
    -- A draft: nothing to authorize yet
    library_screen.set_section(bufnr, SECTION, {})
    library_screen.decorate(bufnr)
    return
  end
  state.loading = true
  local pending, failed = 2, nil
  local permissions
  local function valid()
    return buffers[bufnr] ~= nil and vim.api.nvim_buf_is_valid(bufnr)
  end
  local function done()
    state.loading = false
    state.all, state.authorized = permissions.all, permissions.pipelines
    render(bufnr)
    -- While typing a pipeline line, offer the pipelines that just arrived
    require("workhorse.ui.choices").refresh(bufnr)
  end
  local function joined()
    pending = pending - 1
    if pending > 0 or not valid() then
      return
    end
    if failed then
      state.loading = false
      notify("Failed to load the pipelines of " .. state.group.name .. ": " .. failed, vim.log.levels.ERROR)
      return
    end
    if not stale(state, permissions.pipelines) or state.listed then
      return done()
    end
    state.listed = true
    require("workhorse.api.builds").list_definitions_full(function(definitions)
      if definitions then
        set_definitions(state, definitions)
        require("workhorse.repos").learn_definitions(definitions, true)
      end
      if valid() then
        done()
      end
    end)
  end
  libraries_api.pipeline_permissions(state.group.id, function(result, err)
    permissions = result
    failed = failed or (not result and tostring(err)) or nil
    joined()
  end)
  if state.definitions.names then
    return joined()
  end
  require("workhorse.repos").get(function(cache)
    if cache and type(cache.definitions) == "table" then
      set_definitions(state, cache.definitions)
    end
    joined()
  end)
end

-- Saving ----------------------------------------------------------------------

--- The changes of the section to save: { entries = { { text, hl } } to confirm, apply(callback) }
--- (nil when there are none), or nil and an error
function M.prepare(bufnr)
  local state = buffers[bufnr]
  if not state or not state.group.id or (not state.loaded and not state.loading) then
    return nil
  end
  if state.loading then
    return nil, "The pipelines are still loading"
  end
  if state.saving then
    return nil, "Already saving the pipelines"
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if count(changes) == 0 then
    return nil
  end
  local entries = {}
  if changes.all ~= nil then
    table.insert(entries, {
      text = OPEN_ACCESS .. ": " .. (changes.all and "on (every pipeline of the project may use it)" or "off"),
      hl = "DiagnosticWarn",
    })
  end
  for _, id in ipairs(changes.authorize) do
    table.insert(entries, { text = "+ " .. name_of(state, id) .. ": authorize", hl = "DiagnosticOk" })
  end
  for _, id in ipairs(changes.revoke) do
    table.insert(entries, { text = "- " .. name_of(state, id) .. ": revoke", hl = "DiagnosticError" })
  end
  local function apply(callback)
    state.saving = true
    local pipelines = {}
    for _, id in ipairs(changes.authorize) do
      table.insert(pipelines, { id = id, authorized = true })
    end
    for _, id in ipairs(changes.revoke) do
      table.insert(pipelines, { id = id, authorized = false })
    end
    libraries_api.set_pipeline_permissions(state.group.id, { all = changes.all, pipelines = pipelines }, function(ok, err)
      state.saving = false
      if ok then
        notify(("Applied %d pipeline permission change%s to %s"):format(count(changes), count(changes) == 1 and "" or "s",
          state.group.name))
      else
        notify("Failed to change the pipeline permissions: " .. tostring(err), vim.log.levels.ERROR)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        load(bufnr)
      end
      callback()
    end)
  end
  return { entries = entries, apply = apply }
end

-- Buffer ----------------------------------------------------------------------

--- Whether the section has changes (or errors) to save
function M.pending(bufnr)
  local state = buffers[bufnr]
  if not state or not state.group.id or not state.loaded or state.loading then
    return false
  end
  local changes, errors = detect(bufnr)
  return count(changes) > 0 or #errors > 0
end

function M.saving(bufnr)
  return buffers[bufnr] ~= nil and buffers[bufnr].saving == true
end

--- Load the permissions again, replacing the section
function M.reload(bufnr)
  load(bufnr)
end

-- Completion: on or off on the Open access line, the project's pipelines on the others
function M.choices(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if line:find(":", 1, true) then
    return ON_OFF
  end
  local state = buffers[bufnr]
  return state and state.definitions.names or {}
end

function M.start(line)
  if not line:find(":", 1, true) then
    return #line:match("^%s*")
  end
end

--- Set up the Pipelines section of the library screen `bufnr` (loaded by M.reload)
function M.attach(bufnr, group)
  buffers[bufnr] = { group = group, authorized = {}, definitions = { by_id = {}, by_name = {} } }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
