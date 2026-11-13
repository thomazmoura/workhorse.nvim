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
local variable_lines = require("workhorse.ui.variable_lines")

local ns = vim.api.nvim_create_namespace("workhorse_library_variables")

local notify = library_screen.notify

local SECTION = "variables"
local FLAGS = { "secret" }

-- Per-buffer state: { group (shared with the screen), loading, loaded, saving }
local buffers = {}

local function section(bufnr)
  local lines, offset = library_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

local function render(bufnr)
  local state = buffers[bufnr]
  library_screen.set_section(bufnr, SECTION, variable_lines.render(state.group.variables, FLAGS))
  state.loaded = true
  library_screen.update_modified(bufnr)
  library_screen.decorate(bufnr)
end

-- Parsing and changes ---------------------------------------------------------

-- Changes of the section: { variables = new map, diffs = { { kind = "added"|"changed"|"removed",
-- name, before, after } } }, plus errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  if not present then
    return { variables = state.group.variables, diffs = {} }, { library_screen.missing_header(SECTION) }
  end
  local entries, errors = variable_lines.parse(lines, offset, FLAGS)
  local changes, detect_errors = variable_lines.detect(state.group.variables, entries)
  vim.list_extend(errors, detect_errors)
  if #changes.diffs > 0 then
    if state.group.type ~= "Vsts" then
      table.insert(errors, "The library is linked to Azure Key Vault: change its variables on the web (gw)")
    elseif next(changes.variables) == nil then
      table.insert(errors, "A library needs at least one variable")
    end
  end
  return changes, errors
end

-- Decoration ------------------------------------------------------------------

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines, offset = section(bufnr)
  local entries = variable_lines.parse(lines, offset, FLAGS)
  if #entries == 0 then
    library_screen.header_hint(bufnr, SECTION, "no variables yet: add \"name: value\" lines")
  end
  local key_vault = state.group.type ~= "Vsts"
  variable_lines.decorate(bufnr, ns, entries, state.group.variables, {
    flags = FLAGS,
    override = key_vault and function()
      return { "  from Azure Key Vault", "WorkhorseRunHint" }
    end or nil,
  })
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
  local entries = variable_lines.confirm_entries(changes.diffs, FLAGS)
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
