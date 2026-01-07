local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")

-- Recursively flatten area tree into list of paths
local function flatten_areas(node, parent_path, result)
  local path = parent_path and (parent_path .. "\\" .. node.name) or node.name
  table.insert(result, path)
  if node.children then
    for _, child in ipairs(node.children) do
      flatten_areas(child, path, result)
    end
  end
end

-- Get all area paths for the project
function M.get_all(callback)
  local cfg = config.get()
  local path = "/" .. cfg.project .. "/_apis/wit/classificationnodes/areas?$depth=10&api-version=7.1"

  client.get(path, {
    on_success = function(data)
      local areas = {}
      flatten_areas(data, nil, areas)
      callback(areas)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

return M
