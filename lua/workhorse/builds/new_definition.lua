-- "New pipeline" form: creates a YAML pipeline (build definition) from a file of an Azure
-- Repos Git repository, one "name: value" line per field. Built on the form engine of the
-- "Run new build" form (builds/form.lua): <Tab>/<S-Tab> move between the values, typing in a
-- field shows its choices (folders, repositories, branches, YAML files, agent queues), and
-- <CR> (normal mode) or <leader><leader> creates the pipeline after a confirmation.
local M = {}

local builds_api = require("workhorse.api.builds")
local forms = require("workhorse.builds.form")
local fields = require("workhorse.builds.definition_fields")

local ns = vim.api.nvim_create_namespace("workhorse_new_definition")

local FIELDS = fields.FIELDS
local FIELD_BY_KEY = fields.FIELD_BY_KEY
local short_branch = fields.short_branch

-- Form state (see forms.get): the field state of builds/definition_fields.lua (repos, folders,
-- queues, branches, yaml, local_yaml) plus prev, repo_id, repo_default, creating, on_done,
-- created, cancelled

-- Form lines, with the values of `initial` ({ [field id] = value }) over the defaults
local function build_lines(initial)
  local lines = { "New pipeline" }
  for _, field in ipairs(FIELDS) do
    table.insert(lines, field.key .. ": " .. ((initial or {})[field.id] or field.value))
  end
  table.insert(lines, "")
  return lines
end

--- Parse the form lines (the title first) into { [field id] = value, lnums = { [field id] = lnum },
--- unknown = { "line" } }
function M.parse_lines(lines)
  return fields.parse_lines(lines, 2)
end

-- Completion ------------------------------------------------------------------

-- Choices of the field on line `lnum` ({} while they load), nil for the name
local function field_choices(bufnr, lnum)
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  return fields.choices(forms.get(bufnr), parsed, fields.field_at(parsed, lnum))
end

-- Decoration ------------------------------------------------------------------

local function decorate(bufnr)
  local form = forms.get(bufnr)
  if not form then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = M.parse_lines(lines)
  local hints = fields.hints(form, parsed)
  for lnum, line in ipairs(lines) do
    local row = lnum - 1
    if lnum == 1 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    elseif line:match("^#") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseRunHint" })
    else
      local key = line:match("^([^:#][^:]*):")
      if key then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #key + 1, hl_group = "WorkhorseRunKey" })
        local id = FIELD_BY_KEY[vim.trim(key):lower()]
        if id and hints[id] and #hints[id] > 0 and parsed.lnums[id] == lnum then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = hints[id] })
        end
      end
    end
  end
end

-- Picking a repository puts its default branch in the branch field, unless a branch other
-- than the previous repository's default was typed
local function on_change(bufnr)
  local form = forms.get(bufnr)
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local repo = fields.find_by_name(form.repos, parsed.repository)
  if not repo or repo.id == form.repo_id then
    return
  end
  local default = short_branch(repo.default_branch)
  local lnum = parsed.lnums.branch
  if lnum and default ~= "" and (parsed.branch == "" or parsed.branch == form.repo_default) then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { "Branch: " .. default })
    parsed.branch = default
  end
  form.repo_id, form.repo_default = repo.id, default
  fields.repo_changed(form, parsed)
end

-- Submit ----------------------------------------------------------------------

-- What to send to create the pipeline, or a list of errors
local function collect(form, parsed)
  local errors = {}
  for _, line in ipairs(parsed.unknown) do
    table.insert(errors, "Not a 'name: value' line: " .. line)
  end
  local values = {}
  for _, id in ipairs({ "repository", "branch", "yaml", "queue" }) do
    local value, err = fields.resolve(form, parsed, id)
    if err then
      table.insert(errors, err)
    end
    values[id] = value
  end
  if #errors > 0 then
    return nil, errors
  end
  local repo = values.repository
  return {
    name = (parsed.name or "") ~= "" and parsed.name or repo.name,
    folder = fields.resolve(form, parsed, "folder"),
    repository = { id = repo.id, name = repo.name },
    branch = values.branch,
    yaml_file = values.yaml,
    queue_id = values.queue and values.queue.id,
  }
end

--- Create the pipeline described by the current form, after a confirmation
function M.submit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms.get(bufnr)
  if not form then
    return
  end
  if form.creating then
    vim.notify("Workhorse: Already creating this pipeline", vim.log.levels.INFO)
    return
  end
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local opts, errors = collect(form, parsed)
  if not opts then
    vim.notify("Workhorse: Cannot create the pipeline:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
    return
  end

  local prompt = ("Create pipeline %s from %s/%s (%s)?"):format(
    (opts.folder == "\\" and "" or opts.folder .. "\\") .. opts.name,
    opts.repository.name,
    opts.yaml_file,
    short_branch(opts.branch)
  )
  local choice = vim.fn.confirm(prompt, "&Yes\n&No", 1)
  if choice ~= 1 then
    -- Opened by a save of the pipelines list: <C-c>/<Esc> on the prompt stops that save
    if choice == 0 and form.on_done then
      M.cancel(bufnr)
    end
    return
  end

  form.creating = true
  local done = require("workhorse.progress").start("Creating pipeline")
  builds_api.create_definition(opts, function(definition, err)
    done(err ~= nil or not definition)
    if forms.get(bufnr) then
      forms.get(bufnr).creating = false
    end
    if err or not definition then
      vim.notify("Workhorse: Failed to create pipeline: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    vim.notify("Workhorse: Created pipeline " .. (definition.name or opts.name) .. " (#" .. definition.id .. ")", vim.log.levels.INFO)
    if form.on_done then
      -- Reported to the caller by on_close
      form.created = {
        id = definition.id,
        name = definition.name or opts.name,
        path = definition.path or opts.folder,
      }
      forms.close(bufnr)
      return
    end
    forms.close(bufnr)
    require("workhorse.builds").open_runs(definition.id, definition.name or opts.name)
  end)
end

--- Close the form without creating, marking it cancelled (see M.open's on_done)
function M.cancel(bufnr)
  local form = forms.get(bufnr)
  if form then
    form.cancelled = true
  end
  vim.cmd("stopinsert")
  forms.close(bufnr)
end

-- Open ------------------------------------------------------------------------

local spec = {
  title = " Workhorse: new pipeline ",
  submit_desc = "create the pipeline",
  choices = field_choices,
  decorate = decorate,
  on_change = on_change,
  submit = function(bufnr)
    M.submit(bufnr)
  end,
  keymaps = function(bufnr, with_desc)
    vim.keymap.set({ "n", "i" }, "<C-c>", function()
      M.cancel(bufnr)
    end, with_desc("cancel"))
  end,
  on_close = function(form)
    if not form.on_done then
      return
    end
    if form.created then
      form.on_done("created", form.created)
    else
      form.on_done(form.cancelled and "cancelled" or "skipped")
    end
  end,
}

--- Open the form to create a YAML pipeline. opts (optional):
---   name, folder  initial values of those fields
---   on_done(result, definition)  called once the form closes: result "created" (with the
---     definition { id, name, path }; the runs view is not opened then), "skipped" (closed
---     without creating) or "cancelled" (<C-c>)
function M.open(opts)
  opts = opts or {}
  local bufnr
  local form
  form = fields.new_state(function()
    return bufnr ~= nil and forms.get(bufnr) == form
  end, function()
    decorate(bufnr)
    forms.refresh_completion(bufnr)
  end)
  form.prev, form.on_done = vim.api.nvim_get_current_buf(), opts.on_done
  fields.local_yaml(form)
  local lines = build_lines({ name = opts.name, folder = opts.folder })
  bufnr = forms.create(spec, form, "Workhorse|new-pipeline", lines)
  -- Start on the name value, or the repository when the name is given
  local row = (opts.name and opts.name ~= "") and 4 or 2
  forms.show(bufnr, { row, #lines[row] })

  -- What the fields offer, fetched in parallel
  fields.load_lists(form, function()
    on_change(bufnr)
    decorate(bufnr)
    forms.refresh_completion(bufnr)
  end)
end

return M
