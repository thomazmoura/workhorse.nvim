-- Identity cache: every user and group of the collection (teams included), for the repository
-- Security tab (adding a user or group) and the required reviewers of the Policies tab. Listing
-- them takes a few hundred lookups (see api/identities.lua), so, like paperboy.nvim's company
-- directory, it is kept in memory and on disk encrypted when there is a cache key (see
-- keyring.lua), and only queried again on demand (M.update, <leader>wR on the repository screens
-- or :Workhorse identities refresh).
local M = {}

local config = require("workhorse.config")
local keyring = require("workhorse.keyring")

local CACHE_NAME = "identities"

-- { server_url, fetched_at, identities = { { id, descriptor, name, kind, email, account } } }
local data = nil
-- Identities resolved elsewhere this session (M.remember), not in the cache
local extra = {}
-- Lookup tables of `data` and `extra`: { by_descriptor, by_id, by_name (lowercase) }
local index = { by_descriptor = {}, by_id = {}, by_name = {} }
-- Callbacks of the load or update in flight
local waiting = nil

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

local function matches_config(cached)
  return type(cached) == "table" and cached.server_url == config.get().server_url
    and type(cached.identities) == "table"
end

-- Names unique: a name shared by several identities gets their account (or e-mail) appended
local function disambiguate(identities)
  local count = {}
  for _, i in ipairs(identities) do
    count[i.name:lower()] = (count[i.name:lower()] or 0) + 1
  end
  for _, i in ipairs(identities) do
    if count[i.name:lower()] > 1 and (i.account or i.email) then
      i.name = ("%s (%s)"):format(i.name, i.account or i.email)
    end
  end
end

-- Groups first, then users, each by name
local function sort(identities)
  table.sort(identities, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "group"
    end
    return a.name:lower() < b.name:lower()
  end)
end

local function add_to_index(i)
  index.by_descriptor[i.descriptor] = i
  if i.id then
    index.by_id[i.id] = i
  end
  index.by_name[i.name:lower()] = index.by_name[i.name:lower()] or i
end

local function build_index()
  index = { by_descriptor = {}, by_id = {}, by_name = {} }
  for _, i in ipairs(data and data.identities or {}) do
    add_to_index(i)
  end
  for _, i in ipairs(extra) do
    if not index.by_descriptor[i.descriptor] then
      add_to_index(i)
    end
  end
end

local function finish(result, err)
  local callbacks = waiting or {}
  waiting = nil
  for _, cb in ipairs(callbacks) do
    cb(result, err)
  end
end

local function fetch(retry_key)
  require("workhorse.api.identities").list_all(function(identities, err)
    if not identities then
      return finish(nil, "failed to list the users and groups: " .. tostring(err or "unknown error"))
    end
    local seen, unique = {}, {}
    for _, i in ipairs(identities) do
      if not seen[i.descriptor] then
        seen[i.descriptor] = true
        i.member_of = nil
        table.insert(unique, i)
      end
    end
    disambiguate(unique)
    sort(unique)
    data = { server_url = config.get().server_url, fetched_at = os.time(), identities = unique }
    build_index()
    keyring.save(CACHE_NAME, data, function(saved, save_err)
      if save_err then
        notify("Could not save the identity cache: " .. save_err, vim.log.levels.WARN)
      end
      notify(("Identity cache updated: %d users and groups (%s)"):format(#unique,
        saved and "encrypted on disk" or "in memory"))
      finish(data)
    end, retry_key)
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
  notify("Updating the identity cache (users and groups)...")
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
      build_index()
      return finish(data)
    end
    notify("Loading the users and groups...")
    fetch(false)
  end)
end

--- The cache when already loaded (nil otherwise): for completion, which can't wait
function M.loaded()
  return data and matches_config(data) and data or nil
end

--- Identity of a descriptor, nil when unknown
function M.by_descriptor(descriptor)
  return index.by_descriptor[descriptor]
end

--- Identity of an id, nil when unknown
function M.by_id(id)
  return index.by_id[id]
end

--- Identity of a name (case-insensitive), nil when unknown
function M.by_name(name)
  return index.by_name[vim.trim(name or ""):lower()]
end

--- Names of the cached identities (groups first), of one kind ("group"|"user") when given
function M.names(kind)
  local result = {}
  for _, i in ipairs(data and data.identities or {}) do
    if not kind or i.kind == kind then
      table.insert(result, i.name)
    end
  end
  return result
end

--- Add identities resolved elsewhere (e.g. from an ACL) to the session's lookups, without
--- saving them; returns them as kept (an identity already known is returned as cached)
function M.remember(identities)
  local result = {}
  for _, i in ipairs(identities) do
    local known = index.by_descriptor[i.descriptor]
    if not known then
      i.member_of = nil
      if index.by_name[i.name:lower()] and (i.account or i.email) then
        i.name = ("%s (%s)"):format(i.name, i.account or i.email)
      end
      table.insert(extra, i)
      add_to_index(i)
      known = i
    end
    table.insert(result, known)
  end
  return result
end

return M
