-- Fields of a YAML pipeline (build definition) as "Key: value" lines, shared by the "New pipeline"
-- form (builds/new_definition.lua) and the Settings tab of a pipeline (pipeline_screen/settings.lua):
--
--   Name: MyApp-CI
--   Folder: \Infra
--   Repository: Infra
--   Branch: main
--   YAML file: pipelines/ci.yml
--   Queue: Default
--
-- What the fields offer (folders, repositories, branches, YAML files, agent queues) is loaded into
-- a plain state table:
--   { repos, folders, queues, branches = { [repo id] = list or "loading" },
--     yaml = { [repo id:branch] = list, "loading" or false (failed) }, local_yaml,
--     alive = fn() -> false once the buffer is gone, changed = fn() after a late load }
local M = {}

local builds_api = require("workhorse.api.builds")

-- Fields, in order: key shown in the lines and initial value (of the form)
M.FIELDS = {
  { id = "name", key = "Name", value = "" },
  { id = "folder", key = "Folder", value = "\\" },
  { id = "repository", key = "Repository", value = "" },
  { id = "branch", key = "Branch", value = "" },
  { id = "yaml", key = "YAML file", value = "" },
  { id = "queue", key = "Queue", value = "Default" },
}

M.FIELD_BY_KEY = {}
M.KEY_OF = {}
for _, field in ipairs(M.FIELDS) do
  M.FIELD_BY_KEY[field.key:lower()] = field.id
  M.KEY_OF[field.id] = field.key
end

function M.short_branch(ref)
  return ((ref or ""):gsub("^refs/heads/", ""))
end

--- New state (see the top of this file)
function M.new_state(alive, changed)
  return { branches = {}, yaml = {}, alive = alive, changed = changed }
end

--- Parse "Key: value" lines (from line `first` on, default 2: the form's title comes first; blank
--- and # lines skipped) into { [field id] = value, lnums = { [field id] = lnum }, unknown = { "line" },
--- unknown_lnums = { lnum }, duplicates = { lnum } or nil }
function M.parse_lines(lines, first)
  first = first or 2
  local result = { lnums = {}, unknown = {}, unknown_lnums = {} }
  for lnum, line in ipairs(lines) do
    if lnum >= first and not line:match("^%s*$") and not line:match("^#") then
      local key, value = line:match("^([^:]+):%s?(.*)$")
      local id = key and M.FIELD_BY_KEY[vim.trim(key):lower()]
      if id then
        -- The last one wins; the screens that need one line per field check `duplicates`
        if result.lnums[id] then
          result.duplicates = result.duplicates or {}
          table.insert(result.duplicates, lnum)
        end
        result[id] = vim.trim(value)
        result.lnums[id] = lnum
      else
        table.insert(result.unknown, line)
        table.insert(result.unknown_lnums, lnum)
      end
    end
  end
  return result
end

--- Field of buffer line `lnum`, from parsed lines
function M.field_at(parsed, lnum)
  for id, l in pairs(parsed.lnums) do
    if l == lnum then
      return id
    end
  end
end

function M.find_by_name(list, name)
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

--- Folders are backslash-separated paths from the root ("\", "\Infra\Web"); "/" works too
function M.normalize_folder(folder)
  return "\\" .. (folder or ""):gsub("/", "\\"):gsub("^\\+", ""):gsub("\\+$", "")
end

-- Loading ---------------------------------------------------------------------

--- Fetch the branches of a repository (once per state)
function M.load_branches(state, repo)
  if state.branches[repo.id] then
    return
  end
  state.branches[repo.id] = "loading"
  builds_api.list_branches(repo.id, function(branches)
    if not state.alive() then
      return
    end
    state.branches[repo.id] = branches or {}
    state.changed()
  end)
end

--- Fetch the YAML files of a repository at a branch (once per state and branch)
function M.load_yaml(state, repo, branch)
  local key = repo.id .. ":" .. branch
  if state.yaml[key] ~= nil then
    return
  end
  state.yaml[key] = "loading"
  builds_api.list_yaml_files(repo.id, branch, function(files)
    if not state.alive() then
      return
    end
    state.yaml[key] = files or false
    state.changed()
  end)
end

--- YAML files of the git repository of the current directory (paths from its root), the
--- choices until those of the repository and branch typed are loaded
function M.local_yaml(state)
  if not state.local_yaml then
    local files = vim.fn.systemlist({ "git", "ls-files", "--full-name", "--", ":(top,icase)*.yml", ":(top,icase)*.yaml" })
    state.local_yaml = vim.v.shell_error == 0 and files or {}
  end
  return state.local_yaml
end

--- Remote YAML files for the typed repository and branch: the list, "loading", or nil
--- (unknown repository, empty branch, failed request); then the repository and branch
function M.remote_yaml(state, parsed)
  local repo = M.find_by_name(state.repos, parsed.repository)
  local branch = parsed.branch or ""
  if not repo or branch == "" then
    return nil
  end
  return state.yaml[repo.id .. ":" .. branch] or nil, repo, branch
end

--- Load what the fields offer, in parallel: repositories, agent queues and folders (from the
--- existing pipelines). `loaded` runs after each one lands
function M.load_lists(state, loaded)
  local function done(apply)
    return function(result)
      if not state.alive() then
        return
      end
      apply(result or {})
      loaded()
    end
  end
  builds_api.list_repositories(done(function(repos)
    state.repos = repos
  end))
  builds_api.list_queues(done(function(queues)
    state.queues = queues
  end))
  builds_api.list_definitions(done(function(definitions)
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
    state.folders = folders
  end))
end

--- After the repository changed: its branches (and YAML files at the typed branch) start loading
function M.repo_changed(state, parsed)
  local repo = M.find_by_name(state.repos, parsed.repository)
  if not repo then
    return
  end
  M.load_branches(state, repo)
  if (parsed.branch or "") ~= "" then
    M.load_yaml(state, repo, parsed.branch)
  end
end

-- Completion ------------------------------------------------------------------

--- Choices of `field` ({} while they load), nil for free text (the name)
function M.choices(state, parsed, field)
  if field == "folder" then
    return state.folders or {}
  elseif field == "repository" then
    return names(state.repos)
  elseif field == "queue" then
    return names(state.queues)
  elseif field == "branch" then
    local repo = M.find_by_name(state.repos, parsed.repository)
    if not repo then
      return {}
    end
    M.load_branches(state, repo)
    local branches = state.branches[repo.id]
    return type(branches) == "table" and branches or {}
  elseif field == "yaml" then
    local files, repo, branch = M.remote_yaml(state, parsed)
    if repo and files == nil and state.yaml[repo.id .. ":" .. branch] == nil then
      M.load_yaml(state, repo, branch)
    end
    return type(files) == "table" and files or M.local_yaml(state)
  end
  return nil
end

-- Hints -----------------------------------------------------------------------

function M.hint(text, hl)
  return { "  " .. text, hl or "WorkhorseRunHint" }
end
local hint = M.hint

--- Right-hand hints of each field ({ [field id] = { chunk } }), from the typed values and what
--- has been loaded. opts.edit: an existing pipeline (its name cannot be emptied)
function M.hints(state, parsed, opts)
  local repo = M.find_by_name(state.repos, parsed.repository)
  local hints = {}

  if (parsed.name or "") == "" then
    hints.name = { opts and opts.edit and hint("required", "WorkhorseRunRequired")
      or hint("defaults to " .. (repo and repo.name or "the repository name")) }
  end
  hints.folder = { hint("\\ is the root") }

  if not state.repos then
    hints.repository = { hint("loading repositories...") }
  elseif (parsed.repository or "") == "" then
    hints.repository = { hint("required", "WorkhorseRunRequired") }
  elseif not repo then
    hints.repository = { hint("unknown repository", "WorkhorseRunRequired") }
  end

  if (parsed.branch or "") == "" then
    hints.branch = { hint("required", "WorkhorseRunRequired") }
  elseif repo and repo.default_branch and parsed.branch == M.short_branch(repo.default_branch) then
    hints.branch = { hint("default branch of " .. repo.name) }
  end

  local files, _, branch = M.remote_yaml(state, parsed)
  local source
  if files == "loading" then
    source = hint("loading files of " .. repo.name .. "@" .. branch .. "...")
  elseif type(files) == "table" then
    source = hint("files of " .. repo.name .. "@" .. branch)
  elseif #(state.local_yaml or {}) > 0 then
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

  if state.queues and (parsed.queue or "") ~= "" and not M.find_by_name(state.queues, parsed.queue) then
    hints.queue = { hint("unknown agent queue", "WorkhorseRunRequired") }
  else
    hints.queue = { hint("agent queue for jobs without a pool, empty for none") }
  end
  return hints
end

-- Values ----------------------------------------------------------------------

--- The value to send for field `id` of the parsed lines, or nil and an error:
---   name        the text ("" allowed: the caller decides)
---   folder      "\..." (see M.normalize_folder)
---   repository  { id, name, default_branch }
---   branch      "refs/heads/..."
---   yaml        the path, without a leading slash
---   queue       { id, name }, or false for none
function M.resolve(state, parsed, id)
  local value = parsed[id] or ""
  if id == "name" then
    return value
  elseif id == "folder" then
    return M.normalize_folder(value)
  elseif id == "repository" then
    if not state.repos then
      return nil, "The repositories are still loading"
    elseif value == "" then
      return nil, "Repository is empty"
    end
    local repo = M.find_by_name(state.repos, value)
    if not repo then
      return nil, "Unknown repository: " .. value
    end
    return repo
  elseif id == "branch" then
    if value == "" then
      return nil, "Branch is empty"
    end
    return value:match("^refs/") and value or ("refs/heads/" .. value)
  elseif id == "yaml" then
    value = value:gsub("^/", "")
    if value == "" then
      return nil, "YAML file is empty"
    end
    return value
  elseif id == "queue" then
    if value == "" then
      return false
    end
    if not state.queues then
      return nil, "The agent queues are still loading"
    end
    local queue = M.find_by_name(state.queues, value)
    if not queue then
      return nil, "Unknown agent queue: " .. value
    end
    return queue
  end
end

return M
