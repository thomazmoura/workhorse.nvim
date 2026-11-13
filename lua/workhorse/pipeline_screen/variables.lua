-- Variables tab of the screen of a pipeline (pipeline_screen/init.lua): one "name: value" line per
-- variable of the definition, sorted by name, edited freely (see ui/variable_lines.lua):
--
--   ApiUrl: https://example.com
--   Password (secret):
--   Environment (settable): dev
--
-- "(secret)" after a name makes the variable secret: its value is never sent by the server, so
-- its line shows it empty, which keeps it; typing a value replaces it. "(settable)" lets it be
-- set at queue time (the "Run new build" form offers it). Both go in one parenthesis:
-- "(secret, settable)". A new line adds a variable, deleting one removes it. Saving lists the
-- changes, then puts the definition back with the lines' variables.
local M = {}

local screen = require("workhorse.pipeline_screen")
local builds_api = require("workhorse.api.builds")
local variable_lines = require("workhorse.ui.variable_lines")

local ns = vim.api.nvim_create_namespace("workhorse_pipeline_variables")

local notify = screen.notify

local FLAGS = { "secret", "settable" }
local FLAG_CHOICES = { "(secret): ", "(settable): ", "(secret, settable): " }

-- Per-buffer state: { definition (shared with the screen), loading, loaded, saving }
local buffers = {}

local function current(state)
  return state.definition.variables or {}
end

local function render(bufnr)
  local state = buffers[bufnr]
  screen.set_content(bufnr, variable_lines.render(current(state), FLAGS))
  state.loaded = true
  screen.update_modified(bufnr)
  screen.decorate(bufnr)
end

-- Changes ------------------------------------------------------------------------

local function entries_of(bufnr)
  local lines, offset = screen.content_lines(bufnr)
  return variable_lines.parse(lines, offset, FLAGS)
end

-- Changes of the tab: { variables = new map, diffs }, plus errors
local function detect(bufnr)
  local entries, errors = entries_of(bufnr)
  local changes, detect_errors = variable_lines.detect(current(buffers[bufnr]), entries)
  vim.list_extend(errors, detect_errors)
  return changes, errors
end

-- The definition's "variables" JSON field for `variables`: a secret kept as it is goes without a
-- value (the server keeps the stored one)
local function variables_body(variables)
  if next(variables) == nil then
    return vim.empty_dict()
  end
  local body = {}
  for name, var in pairs(variables) do
    body[name] = {
      value = var.value,
      isSecret = var.secret == true,
      allowOverride = var.settable == true,
    }
  end
  return body
end

-- Decoration ---------------------------------------------------------------------

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local entries = entries_of(bufnr)
  if #entries == 0 then
    local _, offset = screen.content_lines(bufnr)
    screen.line_hint(bufnr, offset + 1, "no variables yet: add \"name: value\" lines, \"name (secret): value\" for a secret")
  end
  variable_lines.decorate(bufnr, ns, entries, current(state), { flags = FLAGS })
end

-- Loading ------------------------------------------------------------------------

local function load(bufnr)
  local state = buffers[bufnr]
  state.loading = true
  builds_api.get_definition_full(state.definition.id, function(fresh, err)
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if not fresh then
      notify("Failed to load the pipeline " .. state.definition.name .. ": " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    screen.update_definition(state.definition.id, fresh)
    render(bufnr)
  end)
end

-- Saving -------------------------------------------------------------------------

--- The changes of the tab to save: { entries = { { text, hl } } to confirm, apply(callback) } (nil
--- when there are none), or nil and an error
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
    return nil
  end
  local entries = variable_lines.confirm_entries(changes.diffs, FLAGS)
  local definition = state.definition
  local function apply(callback)
    state.saving = true
    builds_api.update_definition(definition.id, function(data)
      data.variables = variables_body(changes.variables)
    end, function(updated, err)
      state.saving = false
      if updated then
        notify(("Saved the variables of %s (%d change%s)"):format(updated.name or definition.name, #changes.diffs,
          #changes.diffs == 1 and "" or "s"))
      else
        notify("Failed to save the variables: " .. tostring(err), vim.log.levels.ERROR)
      end
      if vim.api.nvim_buf_is_valid(bufnr) and buffers[bufnr] then
        if updated then
          load(bufnr)
        else
          screen.update_modified(bufnr)
        end
      end
      callback()
    end)
  end
  return { entries = entries, apply = apply }
end

-- Buffer -------------------------------------------------------------------------

--- Whether the tab has changes (or errors) to save
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

--- Load the variables again, replacing the tab's lines
function M.reload(bufnr)
  load(bufnr)
end

-- Column (0-based) where the flags of a name being typed start: after "Name " on a line still
-- without its ":", nil elsewhere
local function flags_start(line)
  if line:find(":", 1, true) then
    return nil
  end
  local col = line:match("^%s*[^%s(]+%s+()%(?[^)]*$")
  return col and col - 1
end

-- Completion: the flags after a name; names and values are free text
function M.choices(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return flags_start(line) and FLAG_CHOICES or nil
end

function M.start(line)
  return flags_start(line)
end

--- Set up the Variables tab `bufnr` of pipeline `definition` (loaded by M.reload)
function M.attach(bufnr, definition)
  buffers[bufnr] = { definition = definition }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
