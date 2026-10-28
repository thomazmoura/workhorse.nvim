-- Security section of the library screen (libraries_screen/library.lua): the role of each user
-- and group on the library, like its Security dialog on the web, groups first:
--
--   [GTI]\Project Administrators: Administrator (inherited)
--   [GTI]\Release Managers: User
--   Thomaz Moura: Administrator
--
-- A role is Reader (see and use the library), User (use it in pipelines) or Administrator (edit
-- it and its security). "(inherited)" marks a role that comes from the project's Library
-- security: writing another role over it assigns that one here. A new line ("name: role", the
-- name completed from the identity cache, or picked with <leader>wa) assigns a role, deleting a
-- line removes the role assigned here (an inherited one cannot be removed). Saving (of the whole
-- screen) lists the changes, then applies them.
local M = {}

local library_screen = require("workhorse.libraries_screen.library")
local libraries_api = require("workhorse.api.libraries")
local identities = require("workhorse.identities")

local ns = vim.api.nvim_create_namespace("workhorse_library_security")

local notify = library_screen.notify

local SECTION = "security"
local INHERITED = " (inherited)"
local ROLES = libraries_api.ROLES

-- Per-buffer state: { group, project_id, baseline = { [lowercase name] = { id, name, role,
-- inherited } }, loading, loaded, saving }
local buffers = {}

local function section(bufnr)
  local lines, offset = library_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

local function display(assignment)
  return assignment.role .. (assignment.inherited and INHERITED or "")
end

-- Groups ("[Project]\Name") first, then users, each by name
local function sort(assignments)
  table.sort(assignments, function(a, b)
    local ga, gb = a.name:sub(1, 1) == "[", b.name:sub(1, 1) == "["
    if ga ~= gb then
      return ga
    end
    return a.name:lower() < b.name:lower()
  end)
  return assignments
end

local function render(bufnr)
  local state = buffers[bufnr]
  local lines = {}
  for _, a in ipairs(sort(vim.tbl_values(state.baseline))) do
    table.insert(lines, a.name .. ": " .. display(a))
  end
  library_screen.set_section(bufnr, SECTION, lines)
  state.loaded = true
  library_screen.update_modified(bufnr)
  library_screen.decorate(bufnr)
end

-- Parsing and changes ---------------------------------------------------------

-- Role of a typed value ("user", "Reader (inherited)"): the role's name and whether it is marked
-- inherited, nil when it is not a role
local function canonical(value)
  local text = vim.trim(value or ""):gsub("%s+", " ")
  local base, inherited = text:match("^(.-)%s*%(inherited%)$"), false
  if base then
    text, inherited = base, true
  end
  for _, role in ipairs(ROLES) do
    if role:lower() == text:lower() then
      return role, inherited
    end
  end
end

-- The section's lines (line i being buffer line offset + i): { { name, role, inherited, lnum,
-- assignment (baseline) | identity (from the cache) } }, plus errors
local function parse(state, lines, offset)
  local entries, errors = {}, {}
  for i, line in ipairs(lines) do
    local text = vim.trim(line)
    if text ~= "" then
      local lnum = offset + i
      -- The last ":" ends the name (a role has none)
      local name, value = text:match("^(.*):%s*(.-)$")
      if not name then
        table.insert(errors, ("Line %d: not a 'user or group: role' line"):format(lnum))
      else
        name = vim.trim(name)
        local role, inherited = canonical(value)
        local entry = { name = name, role = role, inherited = inherited, lnum = lnum,
          assignment = state.baseline[name:lower()] }
        if not entry.assignment then
          entry.identity = identities.by_name(name)
        end
        if not role then
          table.insert(errors, ("Line %d: the role of %s is %s"):format(lnum, name, table.concat(ROLES, ", ", 1, 2)
            .. " or " .. ROLES[3]))
        end
        table.insert(entries, entry)
      end
    end
  end
  return entries, errors
end

-- Changes of the section: { sets = { { id, name, role, before } }, removes = { assignment } },
-- plus errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  local entries, errors = parse(state, lines, offset)
  local changes = { sets = {}, removes = {} }
  if not present then
    table.insert(errors, library_screen.missing_header(SECTION))
    return changes, errors
  end
  local seen = {}
  for _, entry in ipairs(entries) do
    local a = entry.assignment
    local id = a and a.id or (entry.identity and entry.identity.id)
    if not id then
      table.insert(errors, ("Line %d: unknown user or group %s (<leader>wR updates the identity cache)"):format(
        entry.lnum, entry.name))
    elseif seen[id] then
      table.insert(errors, ("Line %d: %s appears more than once"):format(entry.lnum, entry.name))
    elseif entry.role then
      seen[id] = true
      if entry.inherited then
        if not a or not a.inherited or a.role ~= entry.role then
          table.insert(errors, ("Line %d: only the role inherited from the project is marked (inherited): write %s"):format(
            entry.lnum, entry.role))
        end
      elseif not a or a.inherited or a.role ~= entry.role then
        table.insert(changes.sets, { id = id, name = a and a.name or entry.identity.name, role = entry.role,
          before = a and display(a) })
      end
    end
  end
  for _, a in pairs(state.baseline) do
    if not seen[a.id] then
      if a.inherited then
        table.insert(errors, ("%s: its role is inherited from the project, it cannot be removed here"):format(a.name))
      else
        table.insert(changes.removes, a)
      end
    end
  end
  sort(changes.removes)
  return changes, errors
end

local function count(changes)
  return #changes.sets + #changes.removes
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
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  for _, entry in ipairs(parse(state, lines, offset)) do
    local line = vim.api.nvim_buf_get_lines(bufnr, entry.lnum - 1, entry.lnum, false)[1]
    local indent = #line:match("^%s*")
    local colon = indent + #entry.name
    mark(entry.lnum, { col = indent, end_col = colon, hl_group = "WorkhorseBuildTitle" })
    if entry.inherited then
      mark(entry.lnum, { col = colon + 1, end_col = #line, hl_group = "WorkhorseRepoInherited" })
    elseif entry.role then
      mark(entry.lnum, { col = colon + 1, end_col = #line, hl_group = "WorkhorseRepoAllow" })
    end
    local a = entry.assignment
    local virt
    if not a and not entry.identity then
      virt = { "  unknown user or group", "DiagnosticError" }
    elseif not entry.role then
      virt = { "  " .. table.concat(ROLES, ", "), "WorkhorseRunRequired" }
    elseif not a then
      virt = { "  [new]", "DiagnosticOk" }
    elseif display(a) ~= entry.role .. (entry.inherited and INHERITED or "") then
      virt = { "  [was " .. display(a) .. "]", "DiagnosticWarn" }
    end
    if virt then
      mark(entry.lnum, { virt_text = { virt } })
    end
  end
end

-- Loading ---------------------------------------------------------------------

local function load(bufnr)
  local state = buffers[bufnr]
  if not state.group.id then
    library_screen.set_section(bufnr, SECTION, {})
    library_screen.decorate(bufnr)
    return
  end
  state.loading = true
  local pending, failed, assignments = 2, nil, nil
  local function joined()
    pending = pending - 1
    if pending > 0 or not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if failed then
      notify("Failed to load the security of " .. state.group.name .. ": " .. failed, vim.log.levels.ERROR)
      return
    end
    state.baseline = {}
    for _, a in ipairs(assignments) do
      -- The name of the identity cache when it knows it (the one completion offers)
      local known = identities.by_id(a.id)
      a.name = known and known.name or a.name
      state.baseline[a.name:lower()] = a
    end
    render(bufnr)
  end
  -- For naming the users and groups, and completing those to add
  identities.get(function(_, err)
    if err then
      notify("Could not load the identity cache: " .. err, vim.log.levels.WARN)
    end
    joined()
  end)
  libraries_api.project_id(function(project_id, err)
    if not project_id then
      failed = tostring(err)
      return joined()
    end
    state.project_id = project_id
    libraries_api.role_assignments(project_id, state.group.id, function(result, roles_err)
      assignments = result
      failed = not result and tostring(roles_err) or nil
      joined()
    end)
  end)
end

-- Pick a user or group from the identity cache and add it, as a Reader, at the end of the section
local function add_identity(bufnr)
  local state = buffers[bufnr]
  if not state.loaded or not state.group.id then
    return
  end
  identities.get(function(data, err)
    if not data then
      notify("Could not load the users and groups: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.ui.select(data.identities, {
      prompt = "Add a user or group to " .. state.group.name,
      format_item = function(i)
        return ("%s  (%s%s)"):format(i.name, i.kind, i.email and (", " .. i.email) or "")
      end,
    }, function(identity)
      if not identity or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local lines, offset, present = section(bufnr)
      if not present then
        notify(library_screen.missing_header(SECTION), vim.log.levels.WARN)
        return
      end
      local last = offset + #lines
      while last > offset and lines[last - offset]:match("^%s*$") do
        last = last - 1
      end
      local text = identity.name .. ": " .. ROLES[1]
      vim.api.nvim_buf_set_lines(bufnr, last, last, false, library_screen.indent({ text }))
      -- On the role, to change it
      vim.api.nvim_win_set_cursor(0, { last + 1, #library_screen.indent({ text })[1] - #ROLES[1] })
      library_screen.update_modified(bufnr)
    end)
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
    return nil, "The security is still loading"
  end
  if state.saving then
    return nil, "Already saving the security"
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if count(changes) == 0 then
    return nil
  end
  local entries = {}
  for _, set in ipairs(changes.sets) do
    table.insert(entries, {
      text = ("%s: %s%s"):format(set.name, set.role, set.before and ("  (was " .. set.before .. ")") or "  (new)"),
      hl = set.before and "DiagnosticWarn" or "DiagnosticOk",
    })
  end
  for _, a in ipairs(changes.removes) do
    table.insert(entries, { text = ("%s: remove the role %s"):format(a.name, a.role), hl = "DiagnosticError" })
  end
  local function apply(callback)
    state.saving = true
    local failures = {}
    local function finish()
      state.saving = false
      if #failures > 0 then
        notify("Failed to change the security of " .. state.group.name .. ":\n" .. table.concat(failures, "\n"),
          vim.log.levels.ERROR)
      else
        notify(("Applied %d security change%s to %s"):format(count(changes), count(changes) == 1 and "" or "s",
          state.group.name))
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        load(bufnr)
      end
      callback()
    end
    local function removes()
      if #changes.removes == 0 then
        return finish()
      end
      local ids = vim.tbl_map(function(a)
        return a.id
      end, changes.removes)
      libraries_api.remove_roles(state.project_id, state.group.id, ids, function(ok, err)
        if not ok then
          table.insert(failures, "removing roles: " .. tostring(err))
        end
        finish()
      end)
    end
    if #changes.sets == 0 then
      return removes()
    end
    libraries_api.set_roles(state.project_id, state.group.id, changes.sets, function(ok, err)
      if not ok then
        table.insert(failures, "assigning roles: " .. tostring(err))
      end
      removes()
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

--- Load the roles again, replacing the section
function M.reload(bufnr)
  load(bufnr)
end

-- Completion: the users and groups before the ":", the roles after it
function M.choices(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if line:find(":", 1, true) then
    return ROLES
  end
  return vim.tbl_map(function(name)
    return name .. ": "
  end, identities.names())
end

function M.start(line)
  if not line:find(":", 1, true) then
    return #line:match("^%s*")
  end
  -- After the last ":" (group names may hold one)
  local colon = line:match(".*():")
  return colon + #(line:sub(colon + 1):match("^%s*"))
end

function M.keymaps(bufnr, map)
  map("<leader>wa", function()
    add_identity(bufnr)
  end, "add a user or group to the library's security")
end

--- Set up the Security section of the library screen `bufnr` (loaded by M.reload)
function M.attach(bufnr, group)
  buffers[bufnr] = { group = group, baseline = {} }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
