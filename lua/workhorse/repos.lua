-- Repository cache: every Git repository the PAT can see (with its clone URLs) and the pipelines
-- of the configured project (with the repository each one builds). It backs the repository and
-- pipeline pickers, and finds the repository of Neovim's working directory from its git remotes.
-- Kept in memory, and also on disk encrypted when there is a "workhorse" keyring (see
-- keyring.lua), so a new session reads it without querying Azure DevOps. M.update replaces it.
local M = {}

local async = require("workhorse.async")
local config = require("workhorse.config")
local keyring = require("workhorse.keyring")

local CACHE_NAME = "repos"

-- { server_url, project, fetched_at, repos = { repo }, definitions = { { id, name, path,
-- repository_id } } }
local data = nil
-- Callbacks of the load or update in flight
local waiting = nil

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

-- The cache belongs to one organization and project
local function matches_config(cached)
  local cfg = config.get()
  return type(cached) == "table" and cached.server_url == cfg.server_url and cached.project == cfg.project
    and type(cached.repos) == "table" and type(cached.definitions) == "table"
end

local function finish(result, err)
  local callbacks = waiting or {}
  waiting = nil
  for _, cb in ipairs(callbacks) do
    cb(result, err)
  end
end

local function fetch(retry_key)
  local prs_api = require("workhorse.api.pullrequests")
  local builds_api = require("workhorse.api.builds")
  local repos, definitions, failed
  local function joined()
    if failed then
      return finish(nil, failed)
    end
    if not repos or not definitions then
      return
    end
    local cfg = config.get()
    data = {
      server_url = cfg.server_url,
      project = cfg.project,
      fetched_at = os.time(),
      repos = repos,
      definitions = definitions,
    }
    keyring.save(CACHE_NAME, data, function(saved, err)
      if err then
        notify("Could not save the repository cache: " .. err, vim.log.levels.WARN)
      end
      notify(("Repository cache updated: %d repositories, %d pipelines (%s)"):format(#repos, #definitions,
        saved and "encrypted on disk" or "in memory"))
      finish(data)
    end, retry_key)
  end
  prs_api.list_repositories(function(result, err)
    if not result then
      failed = failed or ("failed to list the repositories: " .. tostring(err or "unknown error"))
    end
    repos = result
    joined()
  end)
  builds_api.list_definitions_full(function(result, err)
    if not result then
      failed = failed or ("failed to list the pipelines: " .. tostring(err or "unknown error"))
    end
    definitions = result
    joined()
  end)
end

--- Query Azure DevOps and replace the cache (in memory, and on disk when there is a key)
---@param callback function|nil Callback(data, error)
function M.update(callback)
  if waiting then
    table.insert(waiting, callback or function() end)
    return
  end
  waiting = { callback or function() end }
  notify("Updating the repository cache...")
  -- An explicit update looks the keyring up again when this session's lookup failed
  fetch(true)
end

--- The cache: from memory, else from disk, else queried from Azure DevOps
---@param callback function Callback(data, error)
function M.get(callback)
  if data and matches_config(data) then
    vim.schedule(function()
      callback(data)
    end)
    return
  end
  if waiting then
    table.insert(waiting, callback)
    return
  end
  waiting = { callback }
  keyring.load(CACHE_NAME, function(cached, err)
    if err then
      notify(err .. ": querying Azure DevOps again", vim.log.levels.WARN)
    end
    if cached and matches_config(cached) then
      data = cached
      return finish(data)
    end
    notify("Loading the repositories...")
    fetch(false)
  end)
end

--- Pipelines (definitions) building `repo`
function M.pipelines_of(cache, repo)
  local result = {}
  for _, d in ipairs(cache.definitions) do
    if d.repository_id == repo.id then
      table.insert(result, d)
    end
  end
  return result
end

-- URLs ------------------------------------------------------------------------

local function decode(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Keys ("project/repository", lowercase) a clone or web URL of an Azure Repos repository can
--- stand for. HTTPS (cloud, visualstudio.com and on-premises) has ".../{project}/_git/{repo}"
--- (or ".../_git/{repo}" when the repository is named after its project); SSH has
--- "v3/{organization}/{project}/{repo}" (on-premises: ".../{project}/_git/{repo}" too)
---@param url string
---@return string[]
function M.url_keys(url)
  local path = decode(vim.trim(url)):lower()
  path = path:gsub("[?#].*$", ""):gsub("/+$", ""):gsub("%.git$", "")
  local before, repo = path:match("([^/:]*)/_git/([^/]+)$")
  if repo then
    return { before .. "/" .. repo, repo .. "/" .. repo }
  end
  local project, ssh_repo = path:match("v3/[^/]+/([^/]+)/([^/]+)$")
  if ssh_repo then
    return { project .. "/" .. ssh_repo }
  end
  return {}
end

local function repo_key(repo)
  return (repo.project.name .. "/" .. repo.name):lower()
end

--- Fetch URLs of the git remotes of `dir`, "origin" first, then in `git remote` order
---@param callback function Callback(urls): empty when not a git repository
local function remote_urls(dir, callback)
  async.exec("git", { "-C", dir, "remote", "-v" }, function(stdout, _, code)
    local origin, others = {}, {}
    if code == 0 then
      for line in (stdout or ""):gmatch("[^\n]+") do
        local name, url = line:match("^(%S+)%s+(%S+)%s+%(fetch%)")
        if url then
          table.insert(name == "origin" and origin or others, url)
        end
      end
    end
    callback(vim.list_extend(origin, others))
  end)
end

--- The cached repository of Neovim's working directory: the first git remote that matches one
---@param callback function Callback(repo, cache, reason): repo nil with a reason when none matches
function M.current(callback)
  local cwd = vim.fn.getcwd()
  remote_urls(cwd, function(urls)
    if #urls == 0 then
      callback(nil, nil, cwd .. " is not a git repository with remotes")
      return
    end
    M.get(function(cache, err)
      if not cache then
        callback(nil, nil, err)
        return
      end
      local by_key = {}
      for _, repo in ipairs(cache.repos) do
        by_key[repo_key(repo)] = by_key[repo_key(repo)] or repo
      end
      for _, url in ipairs(urls) do
        for _, key in ipairs(M.url_keys(url)) do
          if by_key[key] then
            callback(by_key[key], cache)
            return
          end
        end
      end
      callback(nil, cache, "no known Azure DevOps repository matches the git remotes of " .. cwd
        .. " (update the cache with <leader>wR if it is new)")
    end)
  end)
end

return M
