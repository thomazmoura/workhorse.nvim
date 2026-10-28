-- Variables section of the library screen (libraries_screen/library.lua): one "name: value"
-- line per variable, sorted by name, edited freely:
--
--   ApiUrl: https://example.com
--   Password (secret):
--
-- A secret's value is never sent by the server: its line shows it empty, which keeps it; typing
-- a value replaces it. " (secret)" after a name makes a variable secret (with the value typed);
-- taking it off makes it a plain one again (with the value typed, empty by default). A new line
-- adds a variable, deleting one removes it. Line breaks of a value show as \n. Saving (of the
-- whole screen) lists the changes, then replaces the library's variables with the lines' (a
-- library needs at least one). A library linked to Azure Key Vault is read-only here.
local M = {}

local library_screen = require("workhorse.libraries_screen.library")
local libraries_api = require("workhorse.api.libraries")

local ns = vim.api.nvim_create_namespace("workhorse_library_variables")

local notify = library_screen.notify

local SECTION = "variables"
local SECRET = "(secret)"

-- Per-buffer state: { group (shared with the screen), loading, loaded, saving }
local buffers = {}

local function section(bufnr)
  local lines, offset = library_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

local function escape(value)
  return ((value or ""):gsub("\r?\n", "\\n"))
end

-- Line of a variable (without the section's indent)
local function line_of(name, var)
  return name .. (var.secret and " " .. SECRET or "") .. ": " .. (var.secret and "" or escape(var.value))
end

local function sorted_names(variables)
  local names = vim.tbl_keys(variables)
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  return names
end

local function render(bufnr)
  local state = buffers[bufnr]
  local lines = {}
  for _, name in ipairs(sorted_names(state.group.variables)) do
    table.insert(lines, line_of(name, state.group.variables[name]))
  end
  library_screen.set_section(bufnr, SECTION, lines)
  state.loaded = true
  library_screen.update_modified(bufnr)
  library_screen.decorate(bufnr)
end

-- Parsing and changes ---------------------------------------------------------

-- Variables of the section's `lines` (line i being buffer line offset + i): { { name, secret,
-- value, lnum } }, plus errors
local function parse(lines, offset)
  local entries, errors = {}, {}
  for i, line in ipairs(lines) do
    if not line:match("^%s*$") then
      local lnum = offset + i
      local key, value = line:match("^%s*([^:]*):%s*(.-)$")
      if not key then
        table.insert(errors, ("Line %d: not a 'name: value' line"):format(lnum))
      else
        key = vim.trim(key)
        local base = key:match("^(.-)%s*%(%s*[Ss][Ee][Cc][Rr][Ee][Tt]%s*%)$")
        local entry = { name = base or key, secret = base ~= nil, value = value, lnum = lnum }
        if entry.name == "" then
          table.insert(errors, ("Line %d: variable without a name"):format(lnum))
        else
          table.insert(entries, entry)
        end
      end
    end
  end
  return entries, errors
end

-- Name (as stored) of the variable `name`, case aside (variable names are case-insensitive)
local function original_name(variables, name)
  if variables[name] then
    return name
  end
  for n in pairs(variables) do
    if n:lower() == name:lower() then
      return n
    end
  end
end

-- What a parsed line means for the variable it names: "same", "added" or "changed", and the
-- variable it sets ({ value (nil keeps a secret's), secret, readonly })
local function compare(variables, entry)
  local name = original_name(variables, entry.name)
  local before = name and variables[name]
  if not before then
    return "added", { value = entry.value, secret = entry.secret, readonly = false }
  end
  if before.secret and entry.secret and entry.value == "" then
    return name == entry.name and "same" or "changed", before
  end
  local value = entry.value
  if before.value and before.value:find("\n") then
    -- Line breaks of a value shown as \n
    value = value:gsub("\\n", "\n")
  end
  if name == entry.name and not before.secret and not entry.secret and value == before.value then
    return "same", before
  end
  return "changed", { value = value, secret = entry.secret, readonly = before.readonly }
end

-- Changes of the section: { variables = new map, diffs = { { kind = "added"|"changed"|"removed",
-- name, before, after } } }, plus errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  if not present then
    return { variables = state.group.variables, diffs = {} }, { library_screen.missing_header(SECTION) }
  end
  local entries, errors = parse(lines, offset)
  local variables, diffs, seen = {}, {}, {}
  local current = state.group.variables
  for _, entry in ipairs(entries) do
    local key = entry.name:lower()
    if seen[key] then
      table.insert(errors, ("Line %d: %s appears more than once"):format(entry.lnum, entry.name))
    else
      seen[key] = true
      local kind, var = compare(current, entry)
      variables[entry.name] = var
      if kind ~= "same" then
        local name = original_name(current, entry.name)
        table.insert(diffs, { kind = kind, name = entry.name, before = name and current[name], after = var })
      end
    end
  end
  for _, name in ipairs(sorted_names(current)) do
    if not seen[name:lower()] then
      table.insert(diffs, { kind = "removed", name = name, before = current[name] })
    end
  end
  if #diffs > 0 then
    if state.group.type ~= "Vsts" then
      table.insert(errors, "The library is linked to Azure Key Vault: change its variables on the web (gw)")
    elseif next(variables) == nil then
      table.insert(errors, "A library needs at least one variable")
    end
  end
  return { variables = variables, diffs = diffs }, errors
end

-- Decoration ------------------------------------------------------------------

local function shorten(text)
  text = escape(text)
  return #text > 40 and (text:sub(1, 37) .. "...") or text
end

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines, offset = section(bufnr)
  local entries = parse(lines, offset)
  if #entries == 0 then
    library_screen.header_hint(bufnr, SECTION, "no variables yet: add \"name: value\" lines")
  end
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  local current, seen = state.group.variables, {}
  local key_vault = state.group.type ~= "Vsts"
  for _, entry in ipairs(entries) do
    local line = vim.api.nvim_buf_get_lines(bufnr, entry.lnum - 1, entry.lnum, false)[1]
    local indent = #line:match("^%s*")
    local colon = line:find(":", 1, true)
    mark(entry.lnum, { col = indent, end_col = indent + #entry.name, hl_group = "WorkhorseRunKey" })
    if entry.secret then
      local marker = line:find("(", indent + #entry.name + 1, true)
      if marker then
        mark(entry.lnum, { col = marker - 1, end_col = colon - 1, hl_group = "DiagnosticHint" })
      end
    end
    local kind, var = compare(current, entry)
    local before = current[original_name(current, entry.name) or ""]
    local virt
    if seen[entry.name:lower()] then
      virt = { "  appears more than once", "DiagnosticError" }
    elseif key_vault then
      virt = { "  from Azure Key Vault", "WorkhorseRunHint" }
    elseif kind == "added" then
      virt = { "  [new" .. (entry.secret and " secret" or "") .. "]", "DiagnosticOk" }
    elseif kind == "changed" then
      local was = before.secret and "secret" or shorten(before.value)
      if before.secret and var.secret then
        was = "secret: replaced"
      end
      virt = { "  [was " .. was .. "]", "DiagnosticWarn" }
    elseif var.secret then
      virt = { "  ••••••  type a value to replace it", "WorkhorseRunHint" }
    elseif var.value and var.value:find("\n") then
      virt = { "  line breaks shown as \\n", "WorkhorseRunHint" }
    end
    seen[entry.name:lower()] = true
    if virt then
      mark(entry.lnum, { virt_text = { virt } })
    end
  end
end

-- Loading ---------------------------------------------------------------------

local function load(bufnr)
  local state = buffers[bufnr]
  if not state.group.id then
    -- A draft: nothing on the server yet
    return render(bufnr)
  end
  state.loading = true
  libraries_api.get(state.group.id, function(fresh, err)
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if not fresh then
      notify("Failed to load the library " .. state.group.name .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    library_screen.update_group(bufnr, fresh)
    render(bufnr)
  end)
end

-- Saving ----------------------------------------------------------------------

local function value_text(var)
  return var.secret and "••••••" or shorten(var.value)
end

--- The changes of the section to save: { entries = { { text, hl } } to confirm, apply(callback) }
--- (nil when there are none), or nil and an error
function M.prepare(bufnr)
  local state = buffers[bufnr]
  if not state or (not state.loaded and not state.loading) then
    return nil
  end
  if state.loading then
    return nil, "The variables are still loading"
  end
  if state.saving then
    return nil, "Already saving the variables"
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if #changes.diffs == 0 then
    if not state.group.id then
      return nil, "Add a \"name: value\" line: a library needs at least one variable"
    end
    return nil
  end
  local entries = {}
  for _, diff in ipairs(changes.diffs) do
    local secret = diff.after and diff.after.secret and " (secret)" or ""
    if diff.kind == "added" then
      table.insert(entries, { text = ("+ %s%s: %s"):format(diff.name, secret, value_text(diff.after)),
        hl = "DiagnosticOk" })
    elseif diff.kind == "removed" then
      table.insert(entries, { text = "- " .. diff.name, hl = "DiagnosticError" })
    else
      local after = diff.after.value == nil and "(kept)" or diff.after.secret and "new secret value"
        or value_text(diff.after)
      table.insert(entries, { text = ("~ %s%s: %s → %s"):format(diff.name, secret, value_text(diff.before), after),
        hl = "DiagnosticWarn" })
    end
  end
  local function apply(callback)
    state.saving = true
    local group = vim.tbl_extend("force", state.group, { variables = changes.variables })
    local creating = not group.id
    local send = creating and libraries_api.create or libraries_api.update
    send(group, function(saved, err)
      state.saving = false
      if saved then
        library_screen.update_group(bufnr, saved)
        notify(("%s library %s (%d variable change%s)"):format(creating and "Created" or "Saved", saved.name,
          #changes.diffs, #changes.diffs == 1 and "" or "s"))
      else
        notify(("Failed to %s the library: %s"):format(creating and "create" or "save", tostring(err)),
          vim.log.levels.ERROR)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        if saved then
          render(bufnr)
        else
          library_screen.update_modified(bufnr)
        end
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
  if not state or not state.loaded or state.loading then
    return false
  end
  local changes, errors = detect(bufnr)
  return #changes.diffs > 0 or #errors > 0
end

function M.saving(bufnr)
  return buffers[bufnr] ~= nil and buffers[bufnr].saving == true
end

--- Load the variables again, replacing the section
function M.reload(bufnr)
  load(bufnr)
end

-- No completion: names and values are free text
function M.choices()
  return nil
end

function M.start()
  return nil
end

--- Set up the Variables section of the library screen `bufnr` (loaded by M.reload)
function M.attach(bufnr, group)
  buffers[bufnr] = { group = group }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
