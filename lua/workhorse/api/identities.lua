-- Identities (users and groups) of the organization. Listing them all goes through the members
-- of "Project Collection Valid Users" (every user and group of the collection, teams included),
-- resolved in batches: the Graph API needs a scope PATs often lack. On Azure DevOps Services the
-- identities live on the organization's vssps host.
local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")
local builds_api = require("workhorse.api.builds")

local url_encode = builds_api.url_encode

-- Identities resolved per request (longer URLs are refused by some servers)
local BATCH = 50

--- Value of the header `name` of a plenary.curl response, nil when absent
function M.header(response, name)
  name = name:lower()
  for _, line in ipairs(type(response) == "table" and response.headers or {}) do
    local key, value = line:match("^([^:]+):%s*(.-)%s*$")
    if key and key:lower() == name and value ~= "" then
      return value
    end
  end
end

-- Host of the identities: the server itself, or vssps.dev.azure.com/{org} on the cloud
local function base_url()
  local org = (config.get().server_url or ""):match("^https://dev%.azure%.com/([^/]+)")
  return org and ("https://vssps.dev.azure.com/" .. org) or nil
end

local function get(path, callback)
  client.get(path, {
    base_url = base_url(),
    silent = true,
    on_success = function(data)
      callback(data)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

local function property(identity, name)
  local p = type(identity.properties) == "table" and identity.properties[name]
  return type(p) == "table" and p["$value"] or nil
end

--- An identity of the API as { id, descriptor, name, kind = "group"|"user", email, account,
--- member_of = { descriptor } (only when queried with membership) }; resolved by id or
--- descriptor, `requested` is the id or descriptor asked for
function M.map(i)
  builds_api.strip_nulls(i)
  local account = property(i, "Account")
  local domain = property(i, "Domain")
  local email = property(i, "Mail")
  local group = i.isContainer == true
  return {
    id = i.id,
    descriptor = i.descriptor,
    name = i.customDisplayName or i.providerDisplayName or account or i.descriptor,
    kind = group and "group" or "user",
    email = email ~= "" and email or nil,
    -- Groups have an internal URI there
    account = not group and account and (domain and (domain .. "\\" .. account) or account) or nil,
    member_of = type(i.memberOf) == "table" and i.memberOf or nil,
  }
end

-- Identities of `values` (ids or descriptors, by `param`), batch after batch:
-- callback({ identity }) or callback(nil, err)
local function resolve(param, values, callback, membership)
  local result, index = {}, 1
  local function next_batch()
    if index > #values then
      return callback(result)
    end
    local batch = vim.list_slice(values, index, index + BATCH - 1)
    index = index + BATCH
    get("/_apis/identities?" .. param .. "=" .. url_encode(table.concat(batch, ","))
      .. "&queryMembership=" .. (membership or "None") .. "&api-version=7.1", function(data, err)
      if not data then
        return callback(nil, err)
      end
      -- In the order requested (null for an unknown one): an identity may come back under
      -- another descriptor than the one asked for (well-known groups have aliases in ACLs)
      local values = data.value or {}
      for k, i in ipairs(values) do
        if type(i) == "table" and i.descriptor then
          local identity = M.map(i)
          identity.requested = #values == #batch and batch[k] or nil
          table.insert(result, identity)
        end
      end
      next_batch()
    end)
  end
  next_batch()
end

--- Identities of these descriptors: callback({ identity }) or callback(nil, err)
function M.by_descriptors(descriptors, callback)
  resolve("descriptors", descriptors, callback)
end

--- Identities of these ids: callback({ identity }) or callback(nil, err)
function M.by_ids(ids, callback)
  resolve("identityIds", ids, callback)
end

--- Groups the identities of `descriptors` belong to, directly or not: callback({ [descriptor] =
--- { group descriptor } }) or callback(nil, err)
function M.memberships(descriptors, callback)
  resolve("descriptors", descriptors, function(identities, err)
    if not identities then
      return callback(nil, err)
    end
    local result = {}
    for _, identity in ipairs(identities) do
      result[identity.requested or identity.descriptor] = identity.member_of or {}
    end
    callback(result)
  end, "Expanded")
end

--- Every user and group of the collection: callback({ identity }) or callback(nil, err)
function M.list_all(callback)
  get("/_apis/identities?searchFilter=General&filterValue=" .. url_encode("Project Collection Valid Users")
    .. "&queryMembership=None&api-version=7.1", function(data, err)
    if not data then
      return callback(nil, err)
    end
    local everyone
    for _, i in ipairs(data.value or {}) do
      if type(i) == "table" and type(i.providerDisplayName) == "string"
        and i.providerDisplayName:match("\\Project Collection Valid Users$") then
        everyone = i
      end
    end
    if not everyone then
      return callback(nil, "group Project Collection Valid Users not found")
    end
    get("/_apis/identities?descriptors=" .. url_encode(everyone.descriptor) .. "&queryMembership=Expanded"
      .. "&api-version=7.1", function(expanded, expand_err)
      local group = expanded and expanded.value and expanded.value[1]
      if type(group) ~= "table" then
        return callback(nil, expand_err or "could not list the members of Project Collection Valid Users")
      end
      M.by_ids(type(group.memberIds) == "table" and group.memberIds or {}, function(identities, resolve_err)
        if not identities then
          return callback(nil, resolve_err)
        end
        table.insert(identities, M.map(everyone))
        callback(identities)
      end)
    end)
  end)
end

return M
