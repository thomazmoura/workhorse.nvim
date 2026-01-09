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
  "System.BoardColumn",
  "System.BoardColumnDone",
  "System.Tags",
  "Microsoft.VSTS.Common.StackRank",
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
    tags = fields["System.Tags"] or "",
    url = item.url,
    board_column = fields["System.BoardColumn"] or "",
    board_column_done = fields["System.BoardColumnDone"] or false,
    stack_rank = fields["Microsoft.VSTS.Common.StackRank"],
  }
end

local function find_kanban_column_field(fields, preferred_value)
  local candidates = {}
  for name, value in pairs(fields or {}) do
    if type(name) == "string" and name:match("Kanban%.Column$") then
      table.insert(candidates, { name = name, value = value })
    end
  end

  if preferred_value then
    for _, candidate in ipairs(candidates) do
      if candidate.value == preferred_value then
        return candidate.name
      end
    end
  end

  if #candidates > 0 then
    return candidates[1].name
  end

  return nil
end

local function get_all_fields(id, callback)
  local path = "/_apis/wit/workitems/" .. id .. "?$expand=all&api-version=7.1"

  client.get(path, {
    on_success = function(data)
      callback(data and data.fields or {})
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
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

-- Update tags (accepts array of tag strings)
function M.update_tags(id, tags_array, callback)
  local tags_str = table.concat(tags_array, "; ")
  M.update(id, { ["System.Tags"] = tags_str }, callback)
end

-- Soft delete (change state to Removed)
function M.soft_delete(id, callback)
  local cfg = config.get()
  M.update_state(id, cfg.deleted_state, callback)
end

-- Update board column
function M.update_board_column(id, new_column, callback)
  get_all_fields(id, function(fields, err)
    if err then
      if callback then
        callback(nil, err)
      end
      return
    end

    local current_column = fields and fields["System.BoardColumn"]
    local field = find_kanban_column_field(fields, current_column)
    if not field then
      local msg = "No writable Kanban column field found for work item"
      vim.notify("Workhorse: " .. msg, vim.log.levels.ERROR)
      if callback then
        callback(nil, msg)
      end
      return
    end

    M.update(id, { [field] = new_column }, callback)
  end)
end

-- Update stack rank
function M.update_stack_rank(id, new_rank, callback)
  M.update(id, { ["Microsoft.VSTS.Common.StackRank"] = new_rank }, callback)
end

local function get_with_relations(id, callback)
  local path = "/_apis/wit/workitems/" .. id .. "?$expand=relations&api-version=7.1"

  client.get(path, {
    on_success = function(data)
      callback(data)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

local function build_work_item_url(id)
  local cfg = config.get()
  return cfg.server_url:gsub("/$", "") .. "/" .. cfg.project .. "/_apis/wit/workItems/" .. id
end

function M.update_parent(id, parent_id, callback)
  get_with_relations(id, function(data, err)
    if err then
      if callback then
        callback(nil, err)
      end
      return
    end

    local relations = data and data.relations or {}
    local parent_index = nil
    for idx, rel in ipairs(relations) do
      if rel.rel == "System.LinkTypes.Hierarchy-Reverse" then
        parent_index = idx - 1
        break
      end
    end

    local patch = {}
    if parent_index ~= nil then
      table.insert(patch, {
        op = "remove",
        path = "/relations/" .. parent_index,
      })
    end

    if parent_id then
      table.insert(patch, {
        op = "add",
        path = "/relations/-",
        value = {
          rel = "System.LinkTypes.Hierarchy-Reverse",
          url = build_work_item_url(parent_id),
        },
      })
    end

    if #patch == 0 then
      if callback then
        callback(parse_work_item(data))
      end
      return
    end

    local path = "/_apis/wit/workitems/" .. id .. "?api-version=7.1"
    client.patch(path, patch, {
      on_success = function(updated)
        if callback then
          callback(parse_work_item(updated))
        end
      end,
      on_error = function(err_msg)
        if callback then
          callback(nil, err_msg)
        end
      end,
    })
  end)
end

return M
