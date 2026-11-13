-- Settings tab of the screen of a pipeline (pipeline_screen/init.lua): the fields of the "New
-- pipeline" form as "Key: value" lines, completed like the form's (builds/definition_fields.lua):
--
--   Name: MyApp-CI
--   Folder: \Infra
--   Repository: Infra
--   Branch: main
--   YAML file: pipelines/ci.yml
--   Queue: Default
--
-- A changed value shows what it was ("[was ...]"); a missing line keeps the setting as it is.
-- The repository of a pipeline built from another source (GitHub...) and the YAML file of a
-- classic pipeline cannot be changed here (gw opens the pipeline on the web). Saving lists the
-- changes, then puts the definition back with them (api/builds.lua update_definition).
local M = {}

local screen = require("workhorse.pipeline_screen")
local builds_api = require("workhorse.api.builds")
local fields = require("workhorse.builds.definition_fields")

local ns = vim.api.nvim_create_namespace("workhorse_pipeline_settings")

local notify = screen.notify
local short_branch = fields.short_branch

-- Per-buffer state: { definition (shared with the screen), fields (definition_fields state),
-- repo_id, repo_default (of the repository typed last), loading, loaded, saving }
local buffers = {}

-- Values -----------------------------------------------------------------------

-- The values of the definition, as the lines show them
local function originals(definition)
  local repo = definition.repository or {}
  return {
    name = definition.name or "",
    folder = definition.path or "\\",
    repository = repo.name or "",
    branch = short_branch(repo.default_branch),
    yaml = definition.yaml_file or "",
    queue = definition.queue and definition.queue.name or "",
  }
end

local function is_git(definition)
  return (definition.repository or {}).type == "TfsGit"
end

-- Typed value of field `id` and its original, in the form they compare
local function comparable(id, value)
  value = value or ""
  if id == "folder" then
    return fields.normalize_folder(value):lower()
  elseif id == "yaml" then
    return (value:gsub("^/", ""))
  elseif id == "repository" or id == "queue" then
    return value:lower()
  elseif id == "branch" then
    return short_branch(value)
  end
  return value
end

local function changed(definition, parsed, id)
  return parsed.lnums[id] ~= nil
    and comparable(id, parsed[id]) ~= comparable(id, originals(definition)[id])
end

local function parse(bufnr)
  return fields.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), select(2, screen.content_lines(bufnr)) + 1)
end

local function render(bufnr)
  local state = buffers[bufnr]
  local values = originals(state.definition)
  local lines = {}
  for _, field in ipairs(fields.FIELDS) do
    table.insert(lines, field.key .. ": " .. values[field.id])
  end
  screen.set_content(bufnr, lines)
  local repo = fields.find_by_name(state.fields.repos, values.repository)
  state.repo_id, state.repo_default = repo and repo.id, values.branch
  state.loaded = true
  fields.repo_changed(state.fields, values)
  screen.update_modified(bufnr)
  screen.decorate(bufnr)
end

-- Changes ------------------------------------------------------------------------

-- The changes of the tab: { [field id] = { before, after (shown), value (to send) } } in field
-- order as a list, plus errors
local function detect(bufnr)
  local state = buffers[bufnr]
  local definition = state.definition
  local parsed = parse(bufnr)
  local errors, changes = {}, {}
  for i, line in ipairs(parsed.unknown) do
    table.insert(errors, ("Line %d: not a setting: %s"):format(parsed.unknown_lnums[i], vim.trim(line)))
  end
  for _, lnum in ipairs(parsed.duplicates or {}) do
    table.insert(errors, ("Line %d: a setting given twice"):format(lnum))
  end
  local before = originals(definition)
  for _, field in ipairs(fields.FIELDS) do
    local id = field.id
    if changed(definition, parsed, id) then
      local value, err = fields.resolve(state.fields, parsed, id)
      if id == "name" and value == "" then
        err = "The name cannot be emptied"
      elseif id == "repository" and not is_git(definition) then
        err = "The pipeline builds a " .. ((definition.repository or {}).type or "non Azure Repos")
          .. " repository: change it on the web (gw)"
      elseif id == "yaml" and not definition.yaml_file then
        err = "A classic pipeline has no YAML file: change its tasks on the web (gw)"
      end
      if err then
        table.insert(errors, err)
      else
        table.insert(changes, { id = id, key = field.key, before = before[id], after = parsed[id], value = value })
      end
    end
  end
  return changes, errors
end

-- Change `data` (the definition as the server sent it) with `changes`
local function apply_changes(data, changes)
  for _, change in ipairs(changes) do
    local value = change.value
    if change.id == "name" then
      data.name = value
    elseif change.id == "folder" then
      data.path = value
    elseif change.id == "repository" then
      local repo = type(data.repository) == "table" and data.repository or {}
      repo.id, repo.name, repo.type = value.id, value.name, "TfsGit"
      -- The URL and clone URL of the old repository: the server fills in the new ones
      repo.url = nil
      if type(repo.properties) == "table" then
        repo.properties.cloneUrl = nil
        repo.properties.fullName = value.name
        repo.properties.safeRepository = value.id
      end
      data.repository = repo
    elseif change.id == "branch" then
      if type(data.repository) == "table" then
        data.repository.defaultBranch = value
      end
    elseif change.id == "yaml" then
      if type(data.process) == "table" then
        data.process.yamlFilename = value
      end
    elseif change.id == "queue" then
      data.queue = value and { id = value.id, name = value.name } or vim.NIL
    end
  end
  -- A new repository gets the typed branch, even when the Branch line did not change
  if changes.repository_changed and changes.branch_value and type(data.repository) == "table" then
    data.repository.defaultBranch = changes.branch_value
  end
end

-- Decoration ---------------------------------------------------------------------

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local definition = state.definition
  local parsed = parse(bufnr)
  local hints = fields.hints(state.fields, parsed, { edit = true })
  if not is_git(definition) then
    hints.repository = { fields.hint(((definition.repository or {}).type or "other") .. " repository: change it on the web (gw)") }
  end
  if not definition.yaml_file then
    hints.yaml = { fields.hint("classic pipeline: no YAML file") }
  end
  local before = originals(definition)
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  for id, lnum in pairs(parsed.lnums) do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local colon = line:find(":", 1, true)
    mark(lnum, { col = #line:match("^%s*"), end_col = colon, hl_group = "WorkhorseRunKey" })
    if id == "branch" then
      mark(lnum, { col = colon, end_col = #line, hl_group = "WorkhorseBuildBranch" })
    end
    local virt = {}
    if changed(definition, parsed, id) then
      table.insert(virt, { "  [was " .. (before[id] ~= "" and before[id] or "none") .. "]", "DiagnosticWarn" })
      -- Only the hints flagging a problem
      for _, chunk in ipairs(hints[id] or {}) do
        if chunk[2] == "WorkhorseRunRequired" then
          table.insert(virt, chunk)
        end
      end
    else
      virt = hints[id] or {}
    end
    if id == "name" and (parsed.name or "") == "" then
      virt = { fields.hint("cannot be emptied", "WorkhorseRunRequired") }
    end
    if #virt > 0 then
      mark(lnum, { virt_text = virt })
    end
  end
  for _, lnum in ipairs(parsed.unknown_lnums) do
    mark(lnum, { virt_text = { { "  not a setting", "DiagnosticError" } } })
  end
  for _, lnum in ipairs(parsed.duplicates or {}) do
    mark(lnum, { virt_text = { { "  given twice", "DiagnosticError" } } })
  end
end

-- Picking another repository puts its default branch in the Branch line, unless a branch other
-- than the previous repository's default was typed
function M.on_change(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  local parsed = parse(bufnr)
  local repo = fields.find_by_name(state.fields.repos, parsed.repository)
  if not repo or repo.id == state.repo_id then
    return
  end
  local default = short_branch(repo.default_branch)
  local lnum = parsed.lnums.branch
  if lnum and default ~= "" and ((parsed.branch or "") == "" or parsed.branch == state.repo_default) then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { fields.KEY_OF.branch .. ": " .. default })
    parsed.branch = default
  end
  state.repo_id, state.repo_default = repo.id, default
  fields.repo_changed(state.fields, parsed)
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
    return nil, "The pipeline is still loading"
  end
  if state.saving then
    return nil, "Already saving the settings"
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if #changes == 0 then
    return nil
  end
  local entries = {}
  for _, change in ipairs(changes) do
    changes.repository_changed = changes.repository_changed or change.id == "repository"
    table.insert(entries, {
      text = ("%s: %s → %s"):format(change.key, change.before ~= "" and change.before or "(none)",
        change.after ~= "" and change.after or "(none)"),
      hl = "DiagnosticWarn",
    })
  end
  -- A new repository is set with the typed branch
  local parsed = parse(bufnr)
  local branch = fields.resolve(state.fields, parsed, "branch")
  changes.branch_value = branch or nil
  local definition = state.definition
  local old_name, old_path = definition.name, definition.path
  local function apply(callback)
    state.saving = true
    builds_api.update_definition(definition.id, function(data)
      apply_changes(data, changes)
    end, function(updated, err)
      state.saving = false
      if updated then
        notify(("Saved the settings of %s (%d change%s)"):format(updated.name or definition.name, #changes,
          #changes == 1 and "" or "s"))
      else
        notify("Failed to save the settings: " .. tostring(err), vim.log.levels.ERROR)
      end
      if vim.api.nvim_buf_is_valid(bufnr) and buffers[bufnr] then
        if updated then
          -- Reloaded from the server: the definition (shared with the Variables tab) follows
          builds_api.get_definition_full(definition.id, function(fresh)
            if fresh then
              screen.update_definition(definition.id, fresh)
              if fresh.name ~= old_name or fresh.path ~= old_path then
                screen.renamed(definition)
              end
            end
            if buffers[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
              render(bufnr)
            end
          end)
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
  return #changes > 0 or #errors > 0
end

function M.saving(bufnr)
  return buffers[bufnr] ~= nil and buffers[bufnr].saving == true
end

--- Load the pipeline again, replacing the tab's lines
function M.reload(bufnr)
  load(bufnr)
end

-- Completion: the field's choices; the keys of the missing fields on a line without its ":"
function M.choices(bufnr, lnum)
  local state = buffers[bufnr]
  if not state then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local parsed = parse(bufnr)
  if not line:find(":", 1, true) then
    local keys = {}
    for _, field in ipairs(fields.FIELDS) do
      if not parsed.lnums[field.id] then
        table.insert(keys, field.key .. ": ")
      end
    end
    return keys
  end
  return fields.choices(state.fields, parsed, fields.field_at(parsed, lnum))
end

function M.start(line)
  if not line:find(":", 1, true) then
    return #line:match("^%s*")
  end
end

--- Set up the Settings tab `bufnr` of pipeline `definition` (loaded by M.reload)
function M.attach(bufnr, definition)
  local state = { definition = definition }
  state.fields = fields.new_state(function()
    return buffers[bufnr] == state and vim.api.nvim_buf_is_valid(bufnr)
  end, function()
    screen.decorate(bufnr)
    require("workhorse.ui.choices").refresh(bufnr)
  end)
  buffers[bufnr] = state
  fields.local_yaml(state.fields)
  fields.load_lists(state.fields, function()
    if state.loaded then
      -- The repository's branches and YAML files, now that it can be found
      local values = originals(definition)
      if not state.repo_id then
        local repo = fields.find_by_name(state.fields.repos, values.repository)
        state.repo_id = repo and repo.id
      end
      fields.repo_changed(state.fields, parse(bufnr))
      screen.decorate(bufnr)
    end
    require("workhorse.ui.choices").refresh(bufnr)
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
