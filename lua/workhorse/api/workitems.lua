local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")

-- Fields to fetch for work items
local FIELDS = {
  "System.Id",
  "System.Title",
  "System.State",
  "System.WorkItemType",
  "System.AreaPath",
  "System.IterationPath",
  "System.Description",
  "System.Rev",
}

-- Parse API response into internal work item format
local function parse_work_item(item)
  local fields = item.fields or {}
  return {
    id = item.id,
    rev = item.rev,
    title = fields["System.Title"] or "",
    state = fields["System.State"] or "",
    type = fields["System.WorkItemType"] or "",
    area_path = fields["System.AreaPath"] or "",
    iteration_path = fields["System.IterationPath"] or "",
    description = fields["System.Description"] or "",
    url = item.url,
  }
end

-- Get work items by IDs
function M.get_by_ids(ids, callback)
  if not ids or #ids == 0 then
    if callback then
      callback({})
    end
    return
  end

  local ids_str = table.concat(ids, ",")
  local fields_str = table.concat(FIELDS, ",")
  local path = "/_apis/wit/workitems?ids=" .. ids_str .. "&fields=" .. fields_str .. "&api-version=7.1"

  client.get(path, {
    on_success = function(data)
      if callback then
        local items = {}
        for _, item in ipairs(data.value or {}) do
          table.insert(items, parse_work_item(item))
        end
        callback(items)
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Get a single work item by ID
function M.get(id, callback)
  M.get_by_ids({ id }, function(items, err)
    if err then
      if callback then
        callback(nil, err)
      end
      return
    end
    if callback then
      callback(items[1])
    end
  end)
end

-- Build JSON Patch operations for field changes
local function build_patch(field_changes)
  local patch = {}
  for field, value in pairs(field_changes) do
    table.insert(patch, {
      op = "add",
      path = "/fields/" .. field,
      value = value,
    })
  end
  return patch
end

-- Create a new work item
function M.create(opts, callback)
  local cfg = config.get()
  local work_item_type = opts.type or cfg.default_work_item_type

  -- URL encode the work item type
  local encoded_type = work_item_type:gsub(" ", "%%20")
  local path = "/" .. cfg.project .. "/_apis/wit/workitems/$" .. encoded_type .. "?api-version=7.1"

  local field_changes = {
    ["System.Title"] = opts.title,
  }

  if opts.area_path or cfg.default_area_path then
    field_changes["System.AreaPath"] = opts.area_path or cfg.default_area_path
  end

  if opts.iteration_path or cfg.default_iteration_path then
    field_changes["System.IterationPath"] = opts.iteration_path or cfg.default_iteration_path
  end

  if opts.state then
    field_changes["System.State"] = opts.state
  end

  local patch = build_patch(field_changes)

  client.patch(path, patch, {
    on_success = function(data)
      if callback then
        callback(parse_work_item(data))
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Update a work item
function M.update(id, field_changes, callback)
  local path = "/_apis/wit/workitems/" .. id .. "?api-version=7.1"
  local patch = build_patch(field_changes)

  client.patch(path, patch, {
    on_success = function(data)
      if callback then
        callback(parse_work_item(data))
      end
    end,
    on_error = function(err)
      if callback then
        callback(nil, err)
      end
    end,
  })
end

-- Update title
function M.update_title(id, new_title, callback)
  M.update(id, { ["System.Title"] = new_title }, callback)
end

-- Update state
function M.update_state(id, new_state, callback)
  M.update(id, { ["System.State"] = new_state }, callback)
end

-- Update description
function M.update_description(id, new_description, callback)
  M.update(id, { ["System.Description"] = new_description }, callback)
end

-- Soft delete (change state to Removed)
function M.soft_delete(id, callback)
  local cfg = config.get()
  M.update_state(id, cfg.deleted_state, callback)
end

return M
