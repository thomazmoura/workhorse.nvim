-- Variable groups (the "Library" of Azure Pipelines) of the configured project: listing, reading,
-- creating, updating and deleting them, the pipelines allowed to use one (pipeline permissions)
-- and its security (role assignments: Reader, User or Administrator per user or group).
-- Reads are project-level; writes are organization-level and name the project through the
-- group's project references.
local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")
local builds_api = require("workhorse.api.builds")

local strip_nulls = builds_api.strip_nulls
local url_encode = builds_api.url_encode

local VERSION = "api-version=7.1-preview.2"
local PREVIEW = "api-version=7.1-preview.1"

-- Roles of a variable group, from the least to the most
M.ROLES = { "Reader", "User", "Administrator" }

local function project()
  return url_encode(config.get().project)
end

local function on_error(callback, hint)
  return function(err)
    if hint and tostring(err):match("^API Error: 40[13]") then
      err = err .. " (" .. hint .. ")"
    end
    callback(nil, err)
  end
end

local MANAGE_HINT = "the PAT needs the Variable Groups scope \"Read, create, & manage\""

local function map_variables(variables)
  local result = {}
  for name, v in pairs(type(variables) == "table" and variables or {}) do
    if type(v) == "table" then
      strip_nulls(v)
      result[name] = {
        -- nil for a secret: the server never returns its value
        value = type(v.value) == "string" and v.value or nil,
        secret = v.isSecret == true,
        readonly = v.isReadOnly == true,
      }
    end
  end
  return result
end

local function map_group(g)
  strip_nulls(g)
  local modified_by = type(g.modifiedBy) == "table" and g.modifiedBy.displayName or nil
  return {
    id = g.id,
    name = g.name,
    description = type(g.description) == "string" and g.description or "",
    -- "Vsts", or "AzureKeyVault" for a group linked to a key vault (its secrets live there)
    type = type(g.type) == "string" and g.type or "Vsts",
    provider_data = type(g.providerData) == "table" and g.providerData or nil,
    variables = map_variables(g.variables),
    project_refs = type(g.variableGroupProjectReferences) == "table" and g.variableGroupProjectReferences or nil,
    modified_by = type(modified_by) == "string" and modified_by or nil,
    modified_on = type(g.modifiedOn) == "string" and g.modifiedOn or nil,
  }
end

M.map_group = map_group

local project_ids = {}

--- Id of the configured project (fetched once): callback(id) or callback(nil, err)
function M.project_id(callback)
  local name = config.get().project
  if project_ids[name] then
    return vim.schedule(function()
      callback(project_ids[name])
    end)
  end
  client.get("/_apis/projects/" .. project() .. "?api-version=7.1", {
    silent = true,
    on_success = function(data)
      if type(data) ~= "table" or type(data.id) ~= "string" then
        return callback(nil, "project " .. name .. " not found")
      end
      project_ids[name] = data.id
      callback(data.id)
    end,
    on_error = on_error(callback),
  })
end

--- Variable groups of the project, sorted by name: callback({ group }) or callback(nil, err),
--- group = { id, name, description, type, provider_data, variables = { [name] = { value,
--- secret, readonly } }, project_refs, modified_by, modified_on }
function M.list(callback)
  client.get("/" .. project() .. "/_apis/distributedtask/variablegroups?queryOrder=idAscending&" .. VERSION, {
    silent = true,
    on_success = function(data)
      local groups = {}
      local islist = vim.islist or vim.tbl_islist
      local values = type(data) == "table" and (data.value or (islist(data) and data)) or {}
      for _, g in ipairs(values) do
        if type(g) == "table" then
          table.insert(groups, map_group(g))
        end
      end
      table.sort(groups, function(a, b)
        return a.name:lower() < b.name:lower()
      end)
      callback(groups)
    end,
    on_error = on_error(callback, "the PAT needs the Variable Groups scope \"Read\""),
  })
end

--- One variable group, by id: callback(group) or callback(nil, err)
function M.get(id, callback)
  client.get("/" .. project() .. "/_apis/distributedtask/variablegroups/" .. id .. "?" .. VERSION, {
    silent = true,
    on_success = function(data)
      if type(data) ~= "table" or not data.id then
        return callback(nil, "library #" .. id .. " not found")
      end
      callback(map_group(data))
    end,
    on_error = on_error(callback, "the PAT needs the Variable Groups scope \"Read\""),
  })
end

-- Body of a create or update of `group`: every variable (a secret without a value keeps the one
-- stored), and its project references with the configured project's named after the group
local function group_body(group, project_id)
  local variables = {}
  for name, v in pairs(group.variables) do
    variables[name] = { value = v.value, isSecret = v.secret, isReadOnly = v.readonly }
  end
  local refs, found = {}, false
  for _, ref in ipairs(group.project_refs or {}) do
    ref = vim.deepcopy(ref)
    local reference = type(ref.projectReference) == "table" and ref.projectReference or {}
    if reference.id == project_id or reference.name == config.get().project then
      ref.name, ref.description, found = group.name, group.description, true
    end
    table.insert(refs, ref)
  end
  if not found then
    table.insert(refs, {
      name = group.name,
      description = group.description,
      projectReference = { id = project_id, name = config.get().project },
    })
  end
  return {
    name = group.name,
    description = group.description,
    type = group.type or "Vsts",
    providerData = group.provider_data,
    variables = variables,
    variableGroupProjectReferences = refs,
  }
end

-- Send `group` (with its project id) by `method` to `path`: callback(group) or callback(nil, err)
local function write(method, path, group, callback)
  M.project_id(function(project_id, err)
    if not project_id then
      return callback(nil, err)
    end
    client.request({
      path = path,
      method = method,
      body = group_body(group, project_id),
      silent = true,
      on_success = function(data)
        callback(map_group(data or {}))
      end,
      on_error = on_error(callback, MANAGE_HINT),
    })
  end)
end

--- Create the variable group `group` ({ name, description, variables }) in the project:
--- callback(group) or callback(nil, err)
function M.create(group, callback)
  write("POST", "/_apis/distributedtask/variablegroups?" .. VERSION, group, callback)
end

--- Replace the variable group `group.id` with `group` (its name, description and variables):
--- callback(group) or callback(nil, err)
function M.update(group, callback)
  write("PUT", "/_apis/distributedtask/variablegroups/" .. group.id .. "?" .. VERSION, group, callback)
end

--- Delete a variable group from the project: callback(true) or callback(nil, err)
function M.delete(id, callback)
  M.project_id(function(project_id, err)
    if not project_id then
      return callback(nil, err)
    end
    client.request({
      path = "/_apis/distributedtask/variablegroups/" .. id .. "?projectIds=" .. project_id .. "&" .. VERSION,
      method = "DELETE",
      silent = true,
      on_success = function()
        callback(true)
      end,
      on_error = on_error(callback, MANAGE_HINT),
    })
  end)
end

-- Pipeline permissions -------------------------------------------------------

local function permissions_path(id)
  return "/" .. project() .. "/_apis/pipelines/pipelinePermissions/variablegroup/" .. id .. "?" .. PREVIEW
end

--- Pipelines allowed to use the variable group `id`: callback({ all = bool (open access),
--- pipelines = { [definition id] = { authorized_by, authorized_on } } }) or callback(nil, err)
function M.pipeline_permissions(id, callback)
  client.get(permissions_path(id), {
    silent = true,
    on_success = function(data)
      data = type(data) == "table" and data or {}
      local result = { all = type(data.allPipelines) == "table" and data.allPipelines.authorized == true,
        pipelines = {} }
      for _, p in ipairs(type(data.pipelines) == "table" and data.pipelines or {}) do
        if type(p) == "table" and p.authorized == true and p.id then
          strip_nulls(p)
          result.pipelines[p.id] = {
            authorized_by = type(p.authorizedBy) == "table" and p.authorizedBy.displayName or nil,
            authorized_on = type(p.authorizedOn) == "string" and p.authorizedOn or nil,
          }
        end
      end
      callback(result)
    end,
    on_error = on_error(callback, "the PAT needs the Build scope \"Read\""),
  })
end

--- Authorize or revoke pipelines on the variable group `id`: `changes` = { all = bool|nil (open
--- access), pipelines = { { id, authorized } } }: callback(true) or callback(nil, err)
function M.set_pipeline_permissions(id, changes, callback)
  local body = { resource = { type = "variablegroup", id = tostring(id) } }
  if #changes.pipelines > 0 then
    body.pipelines = changes.pipelines
  end
  if changes.all ~= nil then
    body.allPipelines = { authorized = changes.all }
  end
  client.request({
    path = permissions_path(id),
    method = "PATCH",
    body = body,
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback, "the PAT needs the Pipeline Resources scope \"Use and manage\""),
  })
end

-- Security (role assignments) -------------------------------------------------

local function roles_path(project_id, id)
  return "/_apis/securityroles/scopes/distributedtask.variablegroup/roleassignments/resources/" .. project_id
    .. "%24" .. id .. "?" .. PREVIEW
end

--- Roles on the variable group `id` (of the project `project_id`): callback({ { id (of the
--- identity), name, role, inherited } }) or callback(nil, err)
function M.role_assignments(project_id, id, callback)
  client.get(roles_path(project_id, id), {
    silent = true,
    on_success = function(data)
      local result = {}
      for _, a in ipairs(type(data) == "table" and type(data.value) == "table" and data.value or {}) do
        local identity = type(a.identity) == "table" and a.identity or {}
        local role = type(a.role) == "table" and a.role or {}
        if type(identity.id) == "string" and type(role.name) == "string" then
          table.insert(result, {
            id = identity.id,
            name = type(identity.displayName) == "string" and identity.displayName or identity.id,
            role = type(role.displayName) == "string" and role.displayName or role.name,
            inherited = a.access == "inherited",
          })
        end
      end
      callback(result)
    end,
    on_error = on_error(callback),
  })
end

--- Assign roles on the variable group `id`: `assignments` = { { id (of the identity), role } }:
--- callback(true) or callback(nil, err)
function M.set_roles(project_id, id, assignments, callback)
  client.request({
    path = roles_path(project_id, id),
    method = "PUT",
    body = vim.tbl_map(function(a)
      return { userId = a.id, roleName = a.role }
    end, assignments),
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback),
  })
end

--- Remove the roles assigned on the variable group `id` to the identities `ids`: callback(true)
--- or callback(nil, err)
function M.remove_roles(project_id, id, ids, callback)
  client.request({
    path = roles_path(project_id, id),
    method = "PATCH",
    body = ids,
    silent = true,
    on_success = function()
      callback(true)
    end,
    on_error = on_error(callback),
  })
end

--- Web page of the variable group `id` (the Library when nil)
function M.web_url(id)
  local server = (config.get().server_url or ""):gsub("/$", "")
  local url = ("%s/%s/_library?itemType=VariableGroups"):format(server, project())
  if id then
    url = url .. "&view=VariableGroupView&variableGroupId=" .. id
  end
  return url
end

return M
