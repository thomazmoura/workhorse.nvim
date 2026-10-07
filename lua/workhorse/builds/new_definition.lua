-- "New pipeline" form: creates a YAML pipeline (build definition) from a file of an Azure
-- Repos Git repository, one "name: value" line per field. Built on the form engine of the
-- "Run new build" form (builds/form.lua): <Tab>/<S-Tab> move between the values, typing in a
-- field shows its choices (folders, repositories, branches, YAML files, agent queues), and
-- <CR>, <leader><leader> (or :w) creates the pipeline after a confirmation.
local M = {}

local builds_api = require("workhorse.api.builds")
local forms = require("workhorse.builds.form")

local ns = vim.api.nvim_create_namespace("workhorse_new_definition")

-- Fields, in order: key shown in the form and initial value
local FIELDS = {
  { id = "name", key = "Name", value = "" },
  { id = "folder", key = "Folder", value = "\\" },
  { id = "repository", key = "Repository", value = "" },
  { id = "branch", key = "Branch", value = "" },
  { id = "yaml", key = "YAML file", value = "" },
  { id = "queue", key = "Queue", value = "Default" },
}

local FIELD_BY_KEY = {}
for _, field in ipairs(FIELDS) do
  FIELD_BY_KEY[field.key:lower()] = field.id
end

-- Form state (see forms.get): { prev, repos, folders, queues, branches = { [repo id] = list or
-- "loading" }, yaml = { [repo id:branch] = list, "loading" or false (failed) }, local_yaml,
-- repo_id, repo_default, creating, on_done, created, cancelled }

local function short_branch(ref)
  return (ref or ""):gsub("^refs/heads/", "")
end

-- Form lines, with the values of `initial` ({ [field id] = value }) over the defaults
local function build_lines(initial)
  local lines = { "# New pipeline" }
  for _, field in ipairs(FIELDS) do
    table.insert(lines, field.key .. ": " .. ((initial or {})[field.id] or field.value))
  end
  table.insert(lines, "")
  return lines
end

--- Parse the form lines into { [field id] = value, lnums = { [field id] = lnum },
--- unknown = { "line" } }
function M.parse_lines(lines)
  local result = { lnums = {}, unknown = {} }
  for lnum, line in ipairs(lines) do
    if not line:match("^%s*$") and not line:match("^#") then
      local key, value = line:match("^([^:]+):%s?(.*)$")
      local id = key and FIELD_BY_KEY[vim.trim(key):lower()]
      if id then
        result[id] = vim.trim(value)
        result.lnums[id] = lnum
      else
        table.insert(result.unknown, line)
      end
    end
  end
  return result
end

local function find_by_name(list, name)
  name = (name or ""):lower()
  for _, item in ipairs(list or {}) do
    if item.name:lower() == name then
      return item
    end
  end
end

local function names(list)
  return vim.tbl_map(function(item)
    return item.name
  end, list or {})
end

-- Loading ---------------------------------------------------------------------

-- Fetch the branches of a repository (once per form)
local function load_branches(bufnr, repo)
  local form = forms.get(bufnr)
  if form.branches[repo.id] then
    return
  end
  form.branches[repo.id] = "loading"
  builds_api.list_branches(repo.id, function(branches)
    if forms.get(bufnr) ~= form then
      return
    end
    form.branches[repo.id] = branches or {}
    forms.refresh_completion(bufnr)
  end)
end

-- Fetch the YAML files of a repository at a branch (once per form and branch)
local function load_yaml(bufnr, repo, branch)
  local form = forms.get(bufnr)
  local key = repo.id .. ":" .. branch
  if form.yaml[key] ~= nil then
    return
  end
  form.yaml[key] = "loading"
  builds_api.list_yaml_files(repo.id, branch, function(files)
    if forms.get(bufnr) ~= form then
      return
    end
    form.yaml[key] = files or false
    form.spec.decorate(bufnr)
    forms.refresh_completion(bufnr)
  end)
end

-- YAML files of the git repository of the current directory (paths from its root), the
-- choices until those of the repository and branch typed in the form are loaded
local function local_yaml(form)
  if not form.local_yaml then
    local files = vim.fn.systemlist({ "git", "ls-files", "--full-name", "--", ":(top,icase)*.yml", ":(top,icase)*.yaml" })
    form.local_yaml = vim.v.shell_error == 0 and files or {}
  end
  return form.local_yaml
end

-- Remote YAML files for the typed repository and branch: the list, "loading", or nil
-- (unknown repository, empty branch, failed request)
local function remote_yaml(form, parsed)
  local repo = find_by_name(form.repos, parsed.repository)
  local branch = parsed.branch or ""
  if not repo or branch == "" then
    return nil
  end
  return form.yaml[repo.id .. ":" .. branch] or nil, repo, branch
end

-- Completion ------------------------------------------------------------------

-- Choices of the field on line `lnum` ({} while they load), nil for the name
local function field_choices(bufnr, lnum)
  local form = forms.get(bufnr)
  local parsed = M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local field
  for id, l in pairs(parsed.lnums) do
    if l == lnum then
      field = id
    end
  end
  if field == "folder" then
    return form.folders or {}
  elseif field == "repository" then
    return names(form.repos)
  elseif field == "queue" then
    return names(form.queues)
  elseif field == "branch" then
    local repo = find_by_name(form.repos, parsed.repository)
    if not repo then
      return {}
    end
    load_branches(bufnr, repo)
    local branches = form.branches[repo.id]
    return type(branches) == "table" and branches or {}
  elseif field == "yaml" then
    local files, repo, branch = remote_yaml(form, parsed)
    if repo and files == nil and form.yaml[repo.id .. ":" .. branch] == nil then
      load_yaml(bufnr, repo, branch)
    end
    return type(files) == "table" and files or local_yaml(form)
  end
  return nil
end

-- Decoration ------------------------------------------------------------------

local function hint(text, hl)
  return { "  " .. text, hl or "WorkhorseRunHint" }
end

-- Right-hand hints of each field, from the typed values and what has been loaded
local function field_hints(form, parsed)
  local repo = find_by_name(form.repos, parsed.repository)
  local hints = {}

  hints.name = (parsed.name or "") == "" and { hint("defaults to " .. (repo and repo.name or "the repository name")) }
  hints.folder = { hint("\\ is the root") }

  if not form.repos then
    hints.repository = { hint("loading repositories...") }
  elseif (parsed.repository or "") == "" then
    hints.repository = { hint("required", "WorkhorseRunRequired") }
  elseif not repo then
    hints.repository = { hint("unknown repository", "WorkhorseRunRequired") }
  end

  if (parsed.branch or "") == "" then
    hints.branch = { hint("required", "WorkhorseRunRequired") }
  elseif repo and repo.default_branch and parsed.branch == short_branch(repo.default_branch) then
    hints.branch = { hint("default branch of " .. repo.name) }
  end

  local files, _, branch = remote_yaml(form, parsed)
  local source
  if files == "loading" then
    source = hint("loading files of " .. repo.name .. "@" .. branch .. "...")
  elseif type(files) == "table" then
    source = hint("files of " .. repo.name .. "@" .. branch)
  elseif #(form.local_yaml or {}) > 0 then
    source = hint("local files")
  end
  local yaml_hints = {}
  if (parsed.yaml or "") == "" then
    table.insert(yaml_hints, hint("required", "WorkhorseRunRequired"))
  elseif type(files) == "table" and not vim.tbl_contains(files, (parsed.yaml:gsub("^/", ""))) then
    table.insert(yaml_hints, hint("not found on " .. branch, "WorkhorseRunRequired"))
  end
  table.insert(yaml_hints, source)
  hints.yaml = yaml_hints

  if form.queues and (parsed.queue or "") ~= "" and not find_by_name(form.queues, parsed.queue) then
    hints.queue = { hint("unknown agent queue", "WorkhorseRunRequired") }
  else
    hints.queue = { hint("agent queue for jobs without a pool, empty for none") }
  end
  return hints
end

local function decorate(bufnr)
  local form = forms.get(bufnr)
  if not form then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = M.parse_lines(lines)
  local hints = field_hints(form, parsed)
  for lnum, line in ipairs(lines) do
    local row = lnum - 1
    if lnum == 1 and line:match("^# ") then
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
  local repo = find_by_name(form.repos, parsed.repository)
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
  load_branches(bufnr, repo)
  if parsed.branch ~= "" then
    load_yaml(bufnr, repo, parsed.branch)
  end
end

-- Submit ----------------------------------------------------------------------

-- What to send to create the pipeline, or a list of errors
local function collect(form, parsed)
  local errors = {}
  for _, line in ipairs(parsed.unknown) do
    table.insert(errors, "Not a 'name: value' line: " .. line)
  end

  local repo
  if not form.repos then
    table.insert(errors, "The repositories are still loading")
  elseif (parsed.repository or "") == "" then
    table.insert(errors, "Repository is empty")
  else
    repo = find_by_name(form.repos, parsed.repository)
    if not repo then
      table.insert(errors, "Unknown repository: " .. parsed.repository)
    end
  end

  local branch = parsed.branch or ""
  if branch == "" then
    table.insert(errors, "Branch is empty")
  end
  local yaml_file = (parsed.yaml or ""):gsub("^/", "")
  if yaml_file == "" then
    table.insert(errors, "YAML file is empty")
  end

  local queue
  if (parsed.queue or "") ~= "" then
    if not form.queues then
      table.insert(errors, "The agent queues are still loading")
    else
      queue = find_by_name(form.queues, parsed.queue)
      if not queue then
        table.insert(errors, "Unknown agent queue: " .. parsed.queue)
      end
    end
  end

  if #errors > 0 then
    return nil, errors
  end
  -- Folders are backslash-separated paths from the root ("\", "\Infra\Web")
  local folder = "\\" .. (parsed.folder or ""):gsub("/", "\\"):gsub("^\\+", ""):gsub("\\+$", "")
  if not branch:match("^refs/") then
    branch = "refs/heads/" .. branch
  end
  return {
    name = (parsed.name or "") ~= "" and parsed.name or repo.name,
    folder = folder,
    repository = { id = repo.id, name = repo.name },
    branch = branch,
    yaml_file = yaml_file,
    queue_id = queue and queue.id,
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
  local choice = vim.fn.confirm(prompt, "&Create\n&Cancel", 1)
  if choice ~= 1 then
    -- Opened by a save of the pipelines list: <C-c>/<Esc> on the prompt stops that save
    if choice == 0 and form.on_done then
      M.cancel(bufnr)
    end
    return
  end

  form.creating = true
  vim.notify("Workhorse: Creating pipeline...", vim.log.levels.INFO)
  builds_api.create_definition(opts, function(definition, err)
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
  local form = { prev = vim.api.nvim_get_current_buf(), branches = {}, yaml = {}, on_done = opts.on_done }
  local_yaml(form)
  local lines = build_lines({ name = opts.name, folder = opts.folder })
  local bufnr = forms.create(spec, form, "Workhorse|new-pipeline", lines)
  -- Start on the name value, or the repository when the name is given
  local row = (opts.name and opts.name ~= "") and 4 or 2
  forms.show(bufnr, { row, #lines[row] })

  -- What the fields offer, fetched in parallel
  local function loaded(apply)
    return function(result)
      if forms.get(bufnr) ~= form then
        return
      end
      apply(result or {})
      on_change(bufnr)
      decorate(bufnr)
      forms.refresh_completion(bufnr)
    end
  end
  builds_api.list_repositories(loaded(function(repos)
    form.repos = repos
  end))
  builds_api.list_queues(loaded(function(queues)
    form.queues = queues
  end))
  builds_api.list_definitions(loaded(function(definitions)
    local seen, folders = { ["\\"] = true }, { "\\" }
    for _, d in ipairs(definitions) do
      if not seen[d.path] then
        seen[d.path] = true
        table.insert(folders, d.path)
      end
    end
    table.sort(folders, function(a, b)
      return a:lower() < b:lower()
    end)
    form.folders = folders
  end))
end

return M
