local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")

-- List all saved queries (hierarchical)
function M.list(callback)
  local cfg = config.get()
  local path = "/" .. cfg.project .. "/_apis/wit/queries?$depth=2&api-version=7.1"

  client.get(path, {
    on_success = function(data)
      if callback then
        callback(data.value or {})
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Get query metadata (name, path, etc.) by ID
function M.get_info(query_id, callback)
  local cfg = config.get()
  local path = "/" .. cfg.project .. "/_apis/wit/queries/" .. query_id .. "?api-version=7.1"

  client.get(path, {
    on_success = function(data)
      if callback then
        callback({
          id = data.id,
          name = data.name,
          path = data.path,
          query_type = data.queryType,
        })
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Execute a saved query by ID, returns work item IDs
function M.execute(query_id, callback)
  local cfg = config.get()
  local path = "/" .. cfg.project .. "/_apis/wit/wiql/" .. query_id .. "?api-version=7.1"

  client.get(path, {
    on_success = function(data)
      if callback then
        local result = {
          query_type = data.queryType,
          relations = data.workItemRelations or nil,
        }

        -- Extract IDs from flat queries
        local ids = {}
        if data.workItems then
          for _, item in ipairs(data.workItems) do
            table.insert(ids, item.id)
          end
        end

        -- Extract IDs from tree queries
        if data.workItemRelations then
          local seen = {}
          for _, rel in ipairs(data.workItemRelations) do
            local source = type(rel.source) == "table" and rel.source or nil
            local target = type(rel.target) == "table" and rel.target or nil
            if source and source.id and not seen[source.id] then
              seen[source.id] = true
              table.insert(ids, source.id)
            end
            if target and target.id and not seen[target.id] then
              seen[target.id] = true
              table.insert(ids, target.id)
            end
          end
        end

        result.ids = ids
        callback(result)
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Execute raw WIQL query
function M.execute_wiql(wiql_text, callback)
  local cfg = config.get()
  local path = "/" .. cfg.project .. "/_apis/wit/wiql?api-version=7.1"

  client.post(path, { query = wiql_text }, {
    on_success = function(data)
      if callback then
        local result = {
          query_type = data.queryType,
          relations = data.workItemRelations or nil,
        }

        local ids = {}
        if data.workItems then
          for _, item in ipairs(data.workItems) do
            table.insert(ids, item.id)
          end
        end

        if data.workItemRelations then
          local seen = {}
          for _, rel in ipairs(data.workItemRelations) do
            local source = type(rel.source) == "table" and rel.source or nil
            local target = type(rel.target) == "table" and rel.target or nil
            if source and source.id and not seen[source.id] then
              seen[source.id] = true
              table.insert(ids, source.id)
            end
            if target and target.id and not seen[target.id] then
              seen[target.id] = true
              table.insert(ids, target.id)
            end
          end
        end

        result.ids = ids
        callback(result)
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Flatten hierarchical query structure for pickers
function M.flatten(queries, parent_path)
  parent_path = parent_path or ""
  local result = {}

  for _, query in ipairs(queries) do
    local path = parent_path
    if path ~= "" then
      path = path .. "/"
    end
    path = path .. query.name

    if query.isFolder then
      -- Recurse into folder
      if query.children then
        local children = M.flatten(query.children, path)
        for _, child in ipairs(children) do
          table.insert(result, child)
        end
      end
    else
      -- It's a query, add to results
      table.insert(result, {
        id = query.id,
        name = query.name,
        path = path,
        queryType = query.queryType,
      })
    end
  end

  return result
end

return M
