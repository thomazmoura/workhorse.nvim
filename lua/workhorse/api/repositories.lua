-- Git repositories of the configured project: listing, creating (with an initial commit),
-- renaming and deleting them, plus their branches and the .gitignore templates
local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")
local builds_api = require("workhorse.api.builds")

local strip_nulls = builds_api.strip_nulls
local url_encode = builds_api.url_encode

local EMPTY_OBJECT_ID = string.rep("0", 40)

-- .gitignore templates: Azure DevOps Server does not serve its own to a PAT, so GitHub's (the
-- ones the web UI offers come from the same collection)
local GITIGNORE_URL = "https://api.github.com/gitignore/templates"

local function project_path(rest)
  return "/" .. url_encode(config.get().project) .. "/_apis/git/repositories" .. rest
end

local function map_repo(r)
  strip_nulls(r)
  return {
    id = r.id,
    name = r.name,
    project = type(r.project) == "table" and { id = r.project.id, name = r.project.name } or nil,
    default_branch = r.defaultBranch,
    size = r.size,
    web_url = r.webUrl,
    remote_url = r.remoteUrl,
    ssh_url = r.sshUrl,
    disabled = r.isDisabled == true,
  }
end

local function on_error(callback)
  return function(err)
    callback(nil, err)
  end
end

-- Creating, renaming and deleting repositories: a 401 is a PAT without the scope for it
local function manage_error(callback)
  return function(err)
    if tostring(err):match("^API Error: 401") then
      err = err .. " (the PAT needs the Code scope \"Read, write, & manage\")"
    end
    callback(nil, err)
  end
end

--- Repositories of the project, disabled ones included (flagged): callback({ repo }) sorted by
--- name, repo = { id, name, project = { id, name }, default_branch, size, web_url, disabled }
function M.list(callback)
  client.get(project_path("?api-version=7.1"), {
    silent = true,
    on_success = function(data)
      local repos = {}
      for _, r in ipairs(data and data.value or {}) do
        table.insert(repos, map_repo(r))
      end
      table.sort(repos, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      callback(repos)
    end,
    on_error = on_error(callback),
  })
end

--- Create an empty repository: callback(repo) or callback(nil, err)
function M.create(name, callback)
  client.post(project_path("?api-version=7.1"), { name = name }, {
    silent = true,
    on_success = function(data)
      callback(map_repo(data or {}))
    end,
    on_error = manage_error(callback),
  })
end

--- Rename a repository: callback(repo) or callback(nil, err)
function M.rename(id, name, callback)
  client.request({
    path = project_path("/" .. id .. "?api-version=7.1"),
    method = "PATCH",
    body = { name = name },
    silent = true,
    on_success = function(data)
      callback(map_repo(data or {}))
    end,
    on_error = manage_error(callback),
  })
end

--- Delete a repository (into the recycle bin on servers that have one): callback(true) or
--- callback(nil, err)
function M.delete(id, callback)
  client.request({
    path = project_path("/" .. id .. "?api-version=7.1"),
    method = "DELETE",
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = manage_error(callback),
  })
end

--- Push the first commit of an empty repository, creating `branch` ("main") with `files`
--- ({ { path = "/README.md", content = "..." } }): callback(true) or callback(nil, err)
function M.initial_commit(repo_id, branch, files, message, callback)
  local changes = {}
  for _, file in ipairs(files) do
    table.insert(changes, {
      changeType = "add",
      item = { path = file.path },
      newContent = { content = file.content, contentType = "rawtext" },
    })
  end
  client.post(project_path("/" .. repo_id .. "/pushes?api-version=7.1"), {
    refUpdates = { { name = "refs/heads/" .. branch, oldObjectId = EMPTY_OBJECT_ID } },
    commits = { { comment = message, changes = changes } },
  }, {
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback),
  })
end

--- Branch names (without refs/heads/) of a repository, sorted: callback(branches) or
--- callback(nil, err)
function M.branches(repo_id, callback)
  client.get(project_path("/" .. repo_id .. "/refs?filter=heads/&api-version=7.1"), {
    silent = true,
    on_success = function(data)
      local branches = {}
      for _, ref in ipairs(data and data.value or {}) do
        table.insert(branches, (ref.name:gsub("^refs/heads/", "")))
      end
      table.sort(branches, function(a, b)
        return a:lower() < b:lower()
      end)
      callback(branches)
    end,
    on_error = on_error(callback),
  })
end

-- GET a URL outside Azure DevOps (no credentials): callback(decoded) or callback(nil, err)
local function get_public(url, callback)
  require("plenary.curl").get(url, {
    headers = { accept = "application/vnd.github+json", user_agent = "workhorse.nvim" },
    callback = vim.schedule_wrap(function(response)
      if response.status ~= 200 then
        return callback(nil, "HTTP " .. response.status)
      end
      local ok, data = pcall(vim.json.decode, response.body)
      callback(ok and data or nil, not ok and "invalid JSON" or nil)
    end),
    on_error = vim.schedule_wrap(function(err)
      callback(nil, err and err.message or "network error")
    end),
  })
end

local templates = nil

--- Names of the .gitignore templates ("VisualStudio", "Node", ...), fetched once: callback(names)
--- or callback(nil, err)
function M.gitignore_templates(callback)
  if templates then
    return callback(templates)
  end
  get_public(GITIGNORE_URL, function(data, err)
    if type(data) ~= "table" then
      return callback(nil, err or "no templates")
    end
    templates = data
    callback(templates)
  end)
end

--- Content of a .gitignore template: callback(text) or callback(nil, err)
function M.gitignore_template(name, callback)
  get_public(GITIGNORE_URL .. "/" .. url_encode(name), function(data, err)
    if type(data) ~= "table" or type(data.source) ~= "string" then
      return callback(nil, err or "no template " .. name)
    end
    callback(data.source)
  end)
end

return M
