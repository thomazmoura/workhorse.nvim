-- Permissions of Git repositories: the actions of the "Git Repositories" security namespace and
-- the access control lists (ACLs) of a repository's token, one access control entry (ACE) per
-- identity with its explicit allow/deny bits and, with the extended info, the inherited and
-- effective ones.
local M = {}

local client = require("workhorse.api.client")
local url_encode = require("workhorse.api.builds").url_encode

M.NAMESPACE = "2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87"

-- Actions the repository's Security page does not show: Administer (deprecated), Create
-- repository (project level only) and Advanced Security (not on Azure DevOps Server)
local HIDDEN_BITS = { [1] = true, [256] = true }

local function on_error(callback)
  return function(err)
    callback(nil, err)
  end
end

-- Changing permissions: a 401 is a PAT without the scope for it
local function manage_error(callback)
  return function(err)
    if tostring(err):match("^API Error: 401") then
      err = err .. " (the PAT needs the Security scope \"Manage\")"
    end
    callback(nil, err)
  end
end

--- Token of a repository's permissions; of every repository of the project without repo_id
function M.token(project_id, repo_id)
  return "repoV2/" .. project_id .. (repo_id and ("/" .. repo_id) or "")
end

local actions = nil

--- Actions of a repository, sorted by name: callback({ { bit, name } }) or callback(nil, err).
--- Fetched once
function M.actions(callback)
  if actions then
    return callback(actions)
  end
  client.get("/_apis/securitynamespaces/" .. M.NAMESPACE .. "?api-version=7.1", {
    silent = true,
    on_success = function(data)
      local namespace = data and data.value and data.value[1]
      if type(namespace) ~= "table" then
        return callback(nil, "no Git Repositories security namespace")
      end
      local result = {}
      for _, action in ipairs(namespace.actions or {}) do
        local name = action.displayName or action.name
        if not HIDDEN_BITS[action.bit] and not name:match("^Advanced Security") then
          table.insert(result, { bit = action.bit, name = name })
        end
      end
      table.sort(result, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      actions = result
      callback(actions)
    end,
    on_error = on_error(callback),
  })
end

--- ACL of `token` with the extended info: callback({ inherit = bool, aces = { [descriptor] = {
--- allow, deny, inherited_allow, inherited_deny, effective_allow, effective_deny } } }) or
--- callback(nil, err). `descriptors` (optional) limits it to those identities
function M.acl(token, descriptors, callback)
  local path = "/_apis/accesscontrollists/" .. M.NAMESPACE .. "?token=" .. url_encode(token)
    .. "&includeExtendedInfo=true&api-version=7.1"
  if descriptors and #descriptors > 0 then
    path = path .. "&descriptors=" .. url_encode(table.concat(descriptors, ","))
  end
  client.get(path, {
    silent = true,
    on_success = function(data)
      local acl = data and data.value and data.value[1]
      local result = { inherit = true, aces = {} }
      if type(acl) == "table" then
        result.inherit = acl.inheritPermissions ~= false
        for descriptor, ace in pairs(acl.acesDictionary or {}) do
          local info = type(ace.extendedInfo) == "table" and ace.extendedInfo or {}
          result.aces[descriptor] = {
            allow = ace.allow or 0,
            deny = ace.deny or 0,
            inherited_allow = info.inheritedAllow or 0,
            inherited_deny = info.inheritedDeny or 0,
            effective_allow = info.effectiveAllow or 0,
            effective_deny = info.effectiveDeny or 0,
          }
        end
      end
      callback(result)
    end,
    on_error = on_error(callback),
  })
end

--- Replace the explicit permissions of an identity on `token` (merge off: the bits not given are
--- cleared): callback(true) or callback(nil, err)
function M.set_ace(token, descriptor, allow, deny, callback)
  client.post("/_apis/accesscontrolentries/" .. M.NAMESPACE .. "?api-version=7.1", {
    token = token,
    merge = false,
    accessControlEntries = { { descriptor = descriptor, allow = allow, deny = deny } },
  }, {
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = manage_error(callback),
  })
end

--- Remove the explicit permissions of identities on `token`: callback(true) or callback(nil, err)
function M.remove_aces(token, descriptors, callback)
  client.request({
    path = "/_apis/accesscontrolentries/" .. M.NAMESPACE .. "?token=" .. url_encode(token)
      .. "&descriptors=" .. url_encode(table.concat(descriptors, ",")) .. "&api-version=7.1",
    method = "DELETE",
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = manage_error(callback),
  })
end

--- Turn the inheritance of `token`'s permissions on or off: callback(true) or callback(nil, err).
--- Setting an ACL replaces it whole, so its current entries are read and sent back with it
function M.set_inheritance(token, inherit, callback)
  M.acl(token, nil, function(acl, err)
    if not acl then
      return callback(nil, err)
    end
    local aces = vim.empty_dict()
    for descriptor, ace in pairs(acl.aces) do
      if ace.allow ~= 0 or ace.deny ~= 0 then
        aces[descriptor] = { descriptor = descriptor, allow = ace.allow, deny = ace.deny }
      end
    end
    client.post("/_apis/accesscontrollists/" .. M.NAMESPACE .. "?api-version=7.1", {
      value = { { token = token, inheritPermissions = inherit, acesDictionary = aces } },
    }, {
      silent = true,
      on_success = function()
        callback(true)
      end,
      on_error = manage_error(callback),
    })
  end)
end

return M
