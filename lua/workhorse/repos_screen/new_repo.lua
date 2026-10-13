-- "New repository" form, opened for each new line when saving the repositories list: one
-- "name: value" line per field, on the form engine of the build forms (builds/form.lua). The
-- repository is created in the configured project; with a default branch and something to
-- commit (the chosen .gitignore and/or a README.md, off by default), a first commit creates the
-- branch, so its policies can be set right away; with nothing to commit it starts without
-- branches. <CR>, <leader><leader> (or :w) creates it after a confirmation.
local M = {}

local forms = require("workhorse.builds.form")
local repos_api = require("workhorse.api.repositories")
local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_new_repo")

local NO_GITIGNORE = "none"
local YES_NO = { "no", "yes" }

local FIELDS = {
  { id = "name", key = "Name", value = "" },
  { id = "branch", key = "Default branch", value = "main" },
  { id = "gitignore", key = ".gitignore", value = NO_GITIGNORE },
  { id = "readme", key = "README.md", value = "no" },
}

local FIELD_BY_KEY = {}
for _, field in ipairs(FIELDS) do
  FIELD_BY_KEY[field.key:lower()] = field.id
end

-- Form state (see forms.get): { prev, templates (nil while loading, false when they failed),
-- creating, on_done, created, cancelled }

--- Parse the form lines into { [field id] = value, lnums = { [field id] = lnum }, unknown }
local function parse_lines(lines)
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

local function field_at(bufnr, lnum)
  local parsed = parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  for id, l in pairs(parsed.lnums) do
    if l == lnum then
      return id, parsed
    end
  end
end

local function find_template(form, name)
  name = (name or ""):lower()
  for _, template in ipairs(form.templates or {}) do
    if template:lower() == name then
      return template
    end
  end
end

local function field_choices(bufnr, lnum)
  local form = forms.get(bufnr)
  local field = field_at(bufnr, lnum)
  if field == "gitignore" then
    return vim.list_extend({ NO_GITIGNORE }, form.templates or {})
  elseif field == "branch" then
    return { "main", "master", "develop" }
  elseif field == "readme" then
    return YES_NO
  end
  return nil
end

local function hint(text, hl)
  return { "  " .. text, hl or "WorkhorseRunHint" }
end

local function decorate(bufnr)
  local form = forms.get(bufnr)
  if not form then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parsed = parse_lines(lines)
  local gitignore = parsed.gitignore or ""
  local readme = (parsed.readme or ""):lower()
  local commits = readme == "yes" or (gitignore ~= "" and gitignore:lower() ~= NO_GITIGNORE)
  local hints = {
    name = (parsed.name or "") == "" and hint("required", "WorkhorseRunRequired") or nil,
    branch = (parsed.branch or "") == "" and hint("empty: the repository starts without branches")
      or commits and hint("created by a first commit")
      or hint("nothing to commit: the repository starts without branches", "WorkhorseRunRequired"),
    readme = not vim.tbl_contains(YES_NO, readme) and hint("yes or no", "WorkhorseRunRequired") or nil,
  }
  if form.templates == nil then
    hints.gitignore = hint("loading templates...")
  elseif form.templates == false then
    hints.gitignore = hint("templates unavailable: " .. NO_GITIGNORE .. " only", "WorkhorseRunRequired")
  elseif gitignore ~= "" and gitignore:lower() ~= NO_GITIGNORE and not find_template(form, gitignore) then
    hints.gitignore = hint("unknown template", "WorkhorseRunRequired")
  end
  for lnum, line in ipairs(lines) do
    local row = lnum - 1
    if lnum == 1 and line:match("^# ") then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #line, hl_group = "WorkhorseBuildHeader" })
    else
      local key = line:match("^([^:#][^:]*):")
      if key then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = #key + 1, hl_group = "WorkhorseRunKey" })
        local id = FIELD_BY_KEY[vim.trim(key):lower()]
        if id and hints[id] and parsed.lnums[id] == lnum then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { hints[id] } })
        end
      end
    end
  end
end

-- What to create, or a list of errors
local function collect(form, parsed)
  local errors = {}
  for _, line in ipairs(parsed.unknown) do
    table.insert(errors, "Not a 'name: value' line: " .. line)
  end
  local name = parsed.name or ""
  if name == "" then
    table.insert(errors, "Name is empty")
  end
  local branch = (parsed.branch or ""):gsub("^refs/heads/", "")
  local gitignore = parsed.gitignore or ""
  local template
  if gitignore ~= "" and gitignore:lower() ~= NO_GITIGNORE then
    if not form.templates then
      table.insert(errors, form.templates == nil and "The .gitignore templates are still loading"
        or "The .gitignore templates are unavailable")
    else
      template = find_template(form, gitignore)
      if not template then
        table.insert(errors, "Unknown .gitignore template: " .. gitignore)
      end
    end
  end
  local readme = (parsed.readme or "no"):lower()
  if not vim.tbl_contains(YES_NO, readme) then
    table.insert(errors, "README.md must be yes or no: " .. parsed.readme)
  end
  if #errors > 0 then
    return nil, errors
  end
  -- Nothing to commit: no first commit to create the branch with
  if not template and readme ~= "yes" then
    branch = ""
  end
  return { name = name, branch = branch, template = template, readme = readme == "yes" }
end

-- Push the first commit of the new repository (its .gitignore and/or README.md), creating its
-- default branch
local function first_commit(repo, opts, callback)
  local function push(files)
    local names = vim.tbl_map(function(file)
      return file.path:sub(2)
    end, files)
    repos_api.initial_commit(repo.id, opts.branch, files, "Add " .. table.concat(names, " and "), callback)
  end
  local files = opts.readme and { { path = "/README.md", content = "# " .. opts.name .. "\n" } } or {}
  if not opts.template then
    return push(files)
  end
  repos_api.gitignore_template(opts.template, function(text, err)
    if not text then
      return callback(nil, "could not get the .gitignore template " .. opts.template .. ": " .. tostring(err))
    end
    table.insert(files, 1, { path = "/.gitignore", content = text })
    push(files)
  end)
end

--- Create the repository described by the current form, after a confirmation
function M.submit(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local form = forms.get(bufnr)
  if not form then
    return
  end
  if form.creating then
    vim.notify("Workhorse: Already creating this repository", vim.log.levels.INFO)
    return
  end
  local opts, errors = collect(form, parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))
  if not opts then
    vim.notify("Workhorse: Cannot create the repository:\n  " .. table.concat(errors, "\n  "), vim.log.levels.ERROR)
    return
  end

  local contents = {}
  if opts.template then
    table.insert(contents, opts.template .. " .gitignore")
  end
  if opts.readme then
    table.insert(contents, "README.md")
  end
  local details = opts.branch == "" and "without branches"
    or ("with branch %s (%s)"):format(opts.branch, table.concat(contents, ", "))
  local choice = vim.fn.confirm(("Create repository %s in %s %s?"):format(opts.name, config.get().project, details),
    "&Create\n&Cancel", 1)
  if choice ~= 1 then
    -- <C-c>/<Esc> on the prompt stops the save of the repositories list
    if choice == 0 then
      M.cancel(bufnr)
    end
    return
  end

  form.creating = true
  vim.notify("Workhorse: Creating repository " .. opts.name .. "...", vim.log.levels.INFO)
  repos_api.create(opts.name, function(repo, err)
    if not repo then
      if forms.get(bufnr) then
        forms.get(bufnr).creating = false
      end
      vim.notify("Workhorse: Failed to create the repository: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    local function done()
      vim.notify("Workhorse: Created repository " .. repo.name, vim.log.levels.INFO)
      form.created = repo
      forms.close(bufnr)
    end
    if opts.branch == "" then
      return done()
    end
    first_commit(repo, opts, function(ok, commit_err)
      if ok then
        repo.default_branch = "refs/heads/" .. opts.branch
      else
        vim.notify("Workhorse: Created repository " .. repo.name .. ", but its first commit failed: "
          .. tostring(commit_err), vim.log.levels.WARN)
      end
      done()
    end)
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

local spec = {
  title = " Workhorse: new repository ",
  submit_desc = "create the repository",
  choices = field_choices,
  decorate = decorate,
  submit = function(bufnr)
    M.submit(bufnr)
  end,
  keymaps = function(bufnr, with_desc)
    vim.keymap.set({ "n", "i" }, "<C-c>", function()
      M.cancel(bufnr)
    end, with_desc("cancel"))
  end,
  on_close = function(form)
    if form.created then
      form.on_done("created", form.created)
    else
      form.on_done(form.cancelled and "cancelled" or "skipped")
    end
  end,
}

--- Open the form to create a repository named `name`. on_done(result, repo) is called once the
--- form closes: result "created" (with the repository), "skipped" (closed without creating) or
--- "cancelled" (<C-c>)
function M.open(name, on_done)
  local form = { prev = vim.api.nvim_get_current_buf(), on_done = on_done }
  local lines = { "# New repository" }
  for _, field in ipairs(FIELDS) do
    table.insert(lines, field.key .. ": " .. (field.id == "name" and (name or "") or field.value))
  end
  table.insert(lines, "")
  local bufnr = forms.create(spec, form, "Workhorse|new-repository", lines)
  -- Start on the .gitignore, the name being given
  forms.show(bufnr, { 4, #lines[4] })
  repos_api.gitignore_templates(function(templates)
    if forms.get(bufnr) ~= form then
      return
    end
    form.templates = templates or false
    decorate(bufnr)
    forms.refresh_completion(bufnr)
  end)
end

return M
