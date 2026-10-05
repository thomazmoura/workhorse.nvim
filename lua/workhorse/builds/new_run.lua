-- "Run new build" form: a buffer with the branch, the YAML runtime parameters and
-- the variables settable at queue time of a pipeline, one "name: value" line each.
-- <Tab>/<S-Tab> move between the values, typing in the branch or a field with choices
-- shows them, and <CR>, <leader><leader> (or :w) queues the run after a confirmation.
-- Only values that differ from the pipeline's defaults are sent. The form engine (completion,
-- navigation, window) is builds/form.lua.
local M = {}

local builds_api = require("workhorse.api.builds")
local yaml = require("workhorse.builds.yaml")
local forms = require("workhorse.builds.form")

local ns = vim.api.nvim_create_namespace("workhorse_new_run")

-- Section headers; "Branch:" sits above them
local PARAMETERS = "## Parameters"
local VARIABLES = "## Variables"

-- Form state (see forms.get): { definition, params, params_error, branches, environments,
-- all_tags, queuing, prev }

-- Text shown for a parameter value: defaults of object parameters become one-line JSON,
-- newlines in strings are shown as \n
local function display_value(value)
  if value == nil or value == vim.NIL then
    return ""
  elseif type(value) == "table" then
    return yaml.encode(value)
  end
  return (tostring(value):gsub("\n", "\\n"))
end

local function short_branch(ref)
  return (ref or ""):gsub("^refs/heads/", "")
end

-- Lines of the form, with the values of `values` ({ branch, params = {}, variables = {} })
-- winning over the defaults
local function build_lines(form, values)
  values = values or { params = {}, variables = {} }
  local lines = {
    "# Run new build: " .. form.definition.name,
    "Branch: " .. (values.branch or short_branch(form.definition.repository.default_branch)),
  }
  if form.params_error then
    vim.list_extend(lines, { "", PARAMETERS, "# Could not read the runtime parameters: " .. form.params_error })
  elseif #form.params > 0 then
    vim.list_extend(lines, { "", PARAMETERS })
    for _, p in ipairs(form.params) do
      table.insert(lines, p.name .. ": " .. (values.params[p.name] or display_value(p.default)))
    end
  end
  if #form.definition.variables > 0 then
    vim.list_extend(lines, { "", VARIABLES })
    for _, v in ipairs(form.definition.variables) do
      table.insert(lines, v.name .. ": " .. (values.variables[v.name] or v.value))
    end
  end
  table.insert(lines, "")
  return lines
end

--- Parse the form lines into { branch, params = { [name] = value }, variables = {...},
--- lnums = { [section .. name] = lnum }, unknown = { "line" } }
function M.parse_lines(lines)
  local result = { params = {}, variables = {}, lnums = {}, unknown = {} }
  local section
  for lnum, line in ipairs(lines) do
    if line == PARAMETERS then
      section = "params"
    elseif line == VARIABLES then
      section = "variables"
    elseif not line:match("^%s*$") and not line:match("^#") then
      local key, value = line:match("^([^:]+):%s?(.*)$")
      key = key and vim.trim(key)
      value = value and vim.trim(value)
      if not key then
        table.insert(result.unknown, line)
      elseif not section and key:lower() == "branch" then
        result.branch = value
        result.lnums.branch = lnum
      elseif section then
        result[section][key] = value
        result.lnums[section .. ":" .. key] = lnum
      else
        table.insert(result.unknown, line)
      end
    end
  end
  return result
end

local function param_by_name(form, name)
  for _, p in ipairs(form.params) do
    if p.name == name then
      return p
    end
  end
end

local function variable_by_name(form, name)
  for _, v in ipairs(form.definition.variables) do
    if v.name == name then
      return v
    end
  end
end

-- Deployment environment fields, by name: "<prefix>environment_name" picks an environment,
-- "<prefix>environment_tags" filters its VMs by tag (e.g. sql_environment_name/_tags)
local function env_field(name)
  local prefix = name:match("^(.-)environment_name$")
  if prefix then
    return "name", prefix
  end
  prefix = name:match("^(.-)environment_tags$")
  if prefix then
    return "tags", prefix
  end
end

local function environment_by_name(form, name)
  for _, env in ipairs(form.environments or {}) do
    if env.name == name then
      return env
    end
  end
end

-- Environment named by the "<prefix>environment_name" field next to a tags field, if known
local function sibling_environment(form, parsed, section, prefix)
  local key = prefix .. "environment_name"
  local value = parsed[section][key]
  if value == nil then
    value = parsed.params[key] or parsed.variables[key]
  end
  return value and environment_by_name(form, value)
end

-- Right-hand hint of a parameter: its type, allowed values and whether it is required
local function param_hint(p)
  local parts = { p.type }
  if p.values then
    local shown = {}
    for _, v in ipairs(p.values) do
      table.insert(shown, display_value(v))
    end
    table.insert(parts, table.concat(shown, " | "))
  end
  local chunks = { { "  " .. table.concat(parts, " · "), "WorkhorseRunHint" } }
  if p.default == nil then
    table.insert(chunks, { "  required", "WorkhorseRunRequired" })
  end
  return chunks
end

-- Highlights and hints, recomputed on every change so they follow the lines
local function decorate(bufnr)
  local form = forms.get(bufnr)
  if not form then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = form.environments and M.parse_lines(lines)
  local section
  -- Whose tags a tags field offers: its environment's, or all of them
  local function tags_hint(name)
    local kind, prefix = env_field(name)
    if not parsed or kind ~= "tags" then
      return nil
    end
    local env = sibling_environment(form, parsed, section == VARIABLES and "variables" or "params", prefix)
    return { "  · tags of " .. (env and env.name or "any environment"), "WorkhorseRunHint" }
  end
  for lnum, line in ipairs(lines) do
    local row = lnum - 1
    if lnum == 1 and line:match("^# ") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    elseif line == PARAMETERS or line == VARIABLES then
      section = line
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseRunSection" })
    elseif line:match("^#") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseRunHint" })
    else
      local key = line:match("^([^:#][^:]*):")
      if key then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #key + 1, hl_group = "WorkhorseRunKey" })
        local name = vim.trim(key)
        local p = section == PARAMETERS and param_by_name(form, name)
        local v = section == VARIABLES and variable_by_name(form, name)
        local hint = tags_hint(name)
        if p then
          local mark = { virt_text = param_hint(p) }
          if hint then
            table.insert(mark.virt_text, 2, hint)
          end
          if p.display_name and p.display_name ~= p.name then
            mark.virt_lines = { { { p.display_name, "WorkhorseRunHint" } } }
            mark.virt_lines_above = true
          end
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, mark)
        elseif v and v.secret then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { { "  secret", "WorkhorseRunHint" } } })
        elseif v and hint then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { hint } })
        elseif not section and name:lower() == "branch" and form.definition.repository.name then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
            virt_text = { { "  " .. form.definition.repository.name, "WorkhorseRunHint" } },
          })
        end
      end
    end
  end
end

-- Completion ------------------------------------------------------------------

-- Tags offered for a tags field: those of its environment (all of them when it names none),
-- minus the ones already listed before the last item, with the field's default (e.g. "-",
-- no filter) first
local function tag_choices(form, parsed, section, name, prefix, default)
  local env = sibling_environment(form, parsed, section, prefix)
  local listed = {}
  local items = vim.split(parsed[section][name], ",", { trimempty = false })
  for i = 1, #items - 1 do
    listed[vim.trim(items[i])] = true
  end
  local result = {}
  if default and default ~= "" then
    table.insert(result, default)
    listed[default] = true
  end
  for _, tag in ipairs(env and env.tags or form.all_tags) do
    if not listed[tag] then
      table.insert(result, tag)
    end
  end
  return result
end

-- Choices of the field on line `lnum`: branches, a parameter's allowed values, environments
-- or their tags; nil for a free-text field (or one whose choices are still loading). The
-- second result is true for a comma-separated list (tags), completed one item at a time
local function field_choices(bufnr, lnum)
  local form = forms.get(bufnr)
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if parsed.lnums.branch == lnum then
    return form.branches
  end
  for _, section in ipairs({ "params", "variables" }) do
    for name in pairs(parsed[section]) do
      if parsed.lnums[section .. ":" .. name] == lnum then
        local p = section == "params" and param_by_name(form, name)
        if p and p.values then
          return vim.tbl_map(display_value, p.values)
        elseif p and p.type == "boolean" then
          return { "true", "false" }
        end
        local kind, prefix = env_field(name)
        if not kind or not form.environments then
          return nil
        elseif kind == "name" then
          return vim.tbl_map(function(env)
            return env.name
          end, form.environments)
        end
        local v = not p and variable_by_name(form, name)
        local default = p and display_value(p.default) or (v and v.value)
        return tag_choices(form, parsed, section, name, prefix, default), true
      end
    end
  end
  return nil
end

-- Submit ----------------------------------------------------------------------

-- Values to send (only those changed from the defaults), or a list of errors
local function collect(form, parsed)
  local errors = {}
  for _, line in ipairs(parsed.unknown) do
    table.insert(errors, "Not a 'name: value' line: " .. line)
  end
  local branch = parsed.branch or ""
  if branch == "" then
    table.insert(errors, "Branch is empty")
  end

  local params = {}
  for name, value in pairs(parsed.params) do
    local p = param_by_name(form, name)
    if not p then
      table.insert(errors, "Unknown parameter: " .. name)
    elseif value == "" and p.default == nil then
      table.insert(errors, "Parameter " .. name .. " is required")
    elseif value ~= display_value(p.default) or p.default == nil then
      if p.type == "boolean" then
        if value:lower() ~= "true" and value:lower() ~= "false" then
          table.insert(errors, "Parameter " .. name .. " must be true or false")
        end
        value = value:lower()
      elseif p.type == "number" and not tonumber(value) then
        table.insert(errors, "Parameter " .. name .. " must be a number")
      end
      if p.values and not vim.tbl_contains(vim.tbl_map(display_value, p.values), value) then
        table.insert(errors, "Parameter " .. name .. " must be one of: " .. table.concat(vim.tbl_map(display_value, p.values), ", "))
      end
      params[name] = p.type == "object" and value or (value:gsub("\\n", "\n"))
    end
  end
  -- Removing a required parameter's line leaves it without a value
  for _, p in ipairs(form.params) do
    if p.default == nil and parsed.params[p.name] == nil then
      table.insert(errors, "Parameter " .. p.name .. " is required")
    end
  end

  local variables = {}
  for name, value in pairs(parsed.variables) do
    local v = variable_by_name(form, name)
    if not v then
      table.insert(errors, "Variable " .. name .. " cannot be set at queue time")
    elseif value ~= v.value then
      variables[name] = value
    end
  end

  if #errors > 0 then
    return nil, errors
  end
  if not branch:match("^refs/") then
    branch = "refs/heads/" .. branch
  end
  return { branch = branch, parameters = params, variables = variables }
end

--- Queue the run described by the current form, after a confirmation
function M.submit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms.get(bufnr)
  if not form then
    return
  end
  if form.queuing then
    vim.notify("Workhorse: Already queuing this run", vim.log.levels.INFO)
    return
  end
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local opts, errors = collect(form, parsed)
  if not opts then
    vim.notify("Workhorse: Cannot queue the run:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
    return
  end

  local changed = vim.tbl_count(opts.parameters) + vim.tbl_count(opts.variables)
  local prompt = ("Run %s on %s%s?"):format(
    form.definition.name,
    short_branch(opts.branch),
    changed > 0 and (" with " .. changed .. " changed value" .. (changed == 1 and "" or "s")) or ""
  )
  if vim.fn.confirm(prompt, "&Run\n&Cancel", 1) ~= 1 then
    return
  end

  form.queuing = true
  vim.notify("Workhorse: Queuing run...", vim.log.levels.INFO)
  builds_api.queue_build(form.definition.id, opts, function(run, err)
    if forms.get(bufnr) then
      forms.get(bufnr).queuing = false
    end
    if err or not run then
      vim.notify("Workhorse: Failed to queue run: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    vim.notify("Workhorse: Queued run #" .. (run.build_number or run.id), vim.log.levels.INFO)
    forms.close(bufnr)
    run.definition_name = run.definition_name or form.definition.name
    require("workhorse.builds").open_run(run, nil, { watch = true })
  end)
end

-- Loading ---------------------------------------------------------------------

-- Runtime parameters of a YAML pipeline at `branch` (Azure Repos only);
-- callback(params, err) with params = {} for classic pipelines
local function load_params(definition, branch, callback)
  if not definition.yaml_file then
    callback({})
    return
  end
  if definition.repository.type ~= "TfsGit" then
    callback(nil, "the YAML file is not in Azure Repos (" .. tostring(definition.repository.type) .. ")")
    return
  end
  builds_api.get_file(definition.repository.id, definition.yaml_file, branch, function(text, err)
    if not text then
      callback(nil, definition.yaml_file .. " on " .. short_branch(branch) .. ": " .. (err or "not found"))
      return
    end
    local ok, params = pcall(yaml.parameters, text)
    if not ok then
      callback(nil, definition.yaml_file .. ": " .. tostring(params))
      return
    end
    callback(params)
  end)
end

-- Fetch the deployment environments and their VM tags (once per form) when it has an
-- environment name or tags field
local function load_environments(bufnr)
  local form = forms.get(bufnr)
  if not form or form.environments or form.loading_environments then
    return
  end
  local needed = false
  for _, field in ipairs(vim.list_extend(vim.list_slice(form.params), form.definition.variables)) do
    needed = needed or env_field(field.name) ~= nil
  end
  if not needed then
    return
  end
  form.loading_environments = true
  builds_api.list_environments(function(envs)
    form.loading_environments = false
    if not envs or forms.get(bufnr) ~= form then
      return
    end
    local all = {}
    for _, env in ipairs(envs) do
      for _, tag in ipairs(env.tags) do
        all[tag] = true
      end
    end
    form.all_tags = vim.tbl_keys(all)
    table.sort(form.all_tags, function(a, b)
      return a:lower() < b:lower()
    end)
    form.environments = envs
    decorate(bufnr)
  end)
end

-- Re-read the parameters for the branch typed in the form, keeping the values entered
-- for parameters and variables that still exist
function M.reload(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms.get(bufnr)
  if not form then
    return
  end
  local values = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local branch = (values.branch and values.branch ~= "") and values.branch
    or form.definition.repository.default_branch or "master"
  -- Keep only the values the user changed, so new defaults of the branch show up
  for name, value in pairs(values.params) do
    local p = param_by_name(form, name)
    if p and value == display_value(p.default) then
      values.params[name] = nil
    end
  end
  load_params(form.definition, branch, function(params, err)
    if not forms.get(bufnr) or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    form.params, form.params_error = params or {}, err
    local cursor = vim.fn.win_findbuf(bufnr)[1] and vim.api.nvim_win_get_cursor(vim.fn.win_findbuf(bufnr)[1])
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, build_lines(form, values))
    decorate(bufnr)
    load_environments(bufnr)
    if cursor then
      local win = vim.fn.win_findbuf(bufnr)[1]
      vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], vim.api.nvim_buf_line_count(bufnr)), cursor[2] })
    end
    vim.notify("Workhorse: Parameters reloaded from " .. short_branch(branch), vim.log.levels.INFO)
  end)
end

local spec = {
  title = " Workhorse: run new build ",
  submit_desc = "queue the run",
  choices = field_choices,
  decorate = decorate,
  submit = function(bufnr)
    M.submit(bufnr)
  end,
  keymaps = function(bufnr, with_desc)
    vim.keymap.set("n", "<leader>R", function()
      M.reload(bufnr)
    end, with_desc("reload parameters for the branch"))
  end,
}

--- Open the form to queue a run of a pipeline (build definition)
function M.open(definition_id, definition_name)
  definition_id = tonumber(definition_id) or definition_id
  vim.notify("Workhorse: Loading pipeline " .. (definition_name or definition_id) .. "...", vim.log.levels.INFO)
  builds_api.get_definition(definition_id, function(definition, err)
    if err or not definition then
      vim.notify("Workhorse: Failed to load pipeline: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    definition.name = definition.name or definition_name or ("Pipeline " .. definition_id)
    load_params(definition, definition.repository.default_branch or "master", function(params, params_err)
      local form = {
        definition = definition,
        params = params or {},
        params_error = params_err,
        prev = vim.api.nvim_get_current_buf(),
      }
      local bufnr = forms.create(spec, form, "Workhorse|run|" .. definition.id, build_lines(form))
      -- Start on the branch value
      forms.show(bufnr, { 2, #vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] })
      load_environments(bufnr)

      if definition.repository.type == "TfsGit" and definition.repository.id then
        builds_api.list_branches(definition.repository.id, function(branches)
          if forms.get(bufnr) then
            forms.get(bufnr).branches = branches
          end
        end)
      end
    end)
  end)
end

return M
