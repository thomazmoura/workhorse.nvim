-- Branch policies of the project's repositories (policy configurations): listing those of one
-- repository, by branch, and creating, updating and deleting them
local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")
local builds_api = require("workhorse.api.builds")

local url_encode = builds_api.url_encode

-- Policy types edited by the Policies tab (and the status checks, shown read-only)
M.TYPES = {
  min_reviewers = "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd",
  work_items = "40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e",
  comments = "c6a1889d-b943-4856-b76f-9e46bb6b0df2",
  merge_strategy = "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab",
  build = "0609b952-1397-4640-95ec-e00a01b2c241",
  reviewers = "fd2167ab-b0be-447a-8ec8-39368250530e",
  status = "cbdc66da-9728-4af8-aada-9a5a32e4a226",
}

local KIND_BY_TYPE = {}
for kind, id in pairs(M.TYPES) do
  KIND_BY_TYPE[id] = kind
end

local function path(rest)
  return "/" .. url_encode(config.get().project) .. "/_apis/policy/configurations" .. rest
end

local function on_error(callback)
  return function(err)
    callback(nil, err)
  end
end

--- Scope of a policy on one branch of a repository
function M.scope(repo_id, branch)
  return { { repositoryId = repo_id, refName = "refs/heads/" .. branch, matchKind = "Exact" } }
end

--- Policies on the branches of a repository (exact branch scope, of the types above):
--- callback({ [branch] = { { id, kind, enabled, blocking, settings } } }) or callback(nil, err)
function M.list(repo_id, callback)
  local by_branch = {}
  local function page(token)
    client.get(path("?api-version=7.1" .. (token and ("&continuationToken=" .. url_encode(token)) or "")), {
      silent = true,
      on_success = function(data, response)
        for _, c in ipairs(data and data.value or {}) do
          local kind = type(c.type) == "table" and KIND_BY_TYPE[c.type.id]
          local scopes = type(c.settings) == "table" and c.settings.scope or {}
          for _, scope in ipairs(type(scopes) == "table" and scopes or {}) do
            local branch = type(scope.refName) == "string" and scope.refName:match("^refs/heads/(.+)$")
            if kind and branch and scope.repositoryId == repo_id and scope.matchKind ~= "Prefix" then
              by_branch[branch] = by_branch[branch] or {}
              table.insert(by_branch[branch], {
                id = c.id,
                kind = kind,
                enabled = c.isEnabled == true,
                blocking = c.isBlocking == true,
                settings = c.settings,
              })
            end
          end
        end
        local next_token = require("workhorse.api.identities").header(response, "x-ms-continuationtoken")
        if next_token then
          return page(next_token)
        end
        callback(by_branch)
      end,
      on_error = on_error(callback),
    })
  end
  page(nil)
end

local function body(policy)
  return {
    isEnabled = policy.enabled,
    isBlocking = policy.blocking,
    type = { id = M.TYPES[policy.kind] },
    settings = policy.settings,
  }
end

--- Create a policy ({ kind, enabled, blocking, settings }): callback(true) or callback(nil, err)
function M.create(policy, callback)
  client.post(path("?api-version=7.1"), body(policy), {
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback),
  })
end

--- Replace the policy `policy.id`: callback(true) or callback(nil, err)
function M.update(policy, callback)
  client.request({
    path = path("/" .. policy.id .. "?api-version=7.1"),
    method = "PUT",
    body = body(policy),
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback),
  })
end

--- Delete the policy `id`: callback(true) or callback(nil, err)
function M.delete(id, callback)
  client.request({
    path = path("/" .. id .. "?api-version=7.1"),
    method = "DELETE",
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback),
  })
end

return M
