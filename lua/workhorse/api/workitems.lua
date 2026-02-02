local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")

-- Debug logging helper
local function debug_log(msg)
  if config.get().debug then
    vim.notify("DEBUG: " .. msg, vim.log.levels.INFO)
  end
end

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
  "Microsoft.VSTS.Common.ClosedDate",
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
    closed_date = fields["Microsoft.VSTS.Common.ClosedDate"],
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

  debug_log("M.update: id=" .. id .. ", patch=" .. vim.inspect(patch))

  client.patch(path, patch, {
    on_success = function(data)
      debug_log("M.update SUCCESS for id=" .. id)
      if callback then
        callback(parse_work_item(data))
      end
    end,
    on_error = function(err)
      debug_log("M.update ERROR for id=" .. id .. ": " .. tostring(err))
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

-- Update board column (with optional state mapping for column transitions)
-- state_for_column: optional state to set when moving to this column (from board's stateMappings)
function M.update_board_column(id, new_column, callback, state_for_column)
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

    local updates = { [field] = new_column }
    -- Also update state if provided (required for column transitions)
    if state_for_column then
      updates["System.State"] = state_for_column
    end

    M.update(id, updates, callback)
  end)
end

-- Update stack rank
function M.update_stack_rank(id, new_rank, callback)
  M.update(id, { ["Microsoft.VSTS.Common.StackRank"] = new_rank }, callback)
end

-- Update multiple fields at once (merges all changes into a single API request)
-- fields: { title = "...", board_column = "...", stack_rank = N, description = "...", tags = "..." }
-- kanban_field_name: optional - the correct WEF field name from the board API (e.g., "WEF_xxx_Kanban.Column")
--                    If provided, uses this field directly instead of scanning work item fields
function M.update_fields(id, fields, callback, kanban_field_name)
  if not fields or not next(fields) then
    if callback then
      callback(nil, "No fields to update")
    end
    return
  end

  -- Helper to add common fields to field_changes
  local function add_common_fields(field_changes)
    if fields.title and fields.title ~= "" then
      field_changes["System.Title"] = fields.title
    end
    if fields.stack_rank then
      field_changes["Microsoft.VSTS.Common.StackRank"] = fields.stack_rank
    end
    if fields.description ~= nil then
      field_changes["System.Description"] = fields.description
    end
    if fields.tags ~= nil then
      field_changes["System.Tags"] = fields.tags
    end
    if fields.state and fields.state ~= "" then
      field_changes["System.State"] = fields.state
    end
  end

  -- If board_column is specified, we need the correct Kanban field name
  if fields.board_column and fields.board_column ~= "" then
    if kanban_field_name then
      -- Use the provided field name directly (from board API)
      local field_changes = {}
      add_common_fields(field_changes)
      field_changes[kanban_field_name] = fields.board_column

      debug_log("update_fields: using provided kanban_field=" .. kanban_field_name .. ", board_column=" .. tostring(fields.board_column))

      M.update(id, field_changes, callback)
    else
      -- Fallback: scan work item fields to find a Kanban column field
      debug_log("update_fields: no kanban_field_name provided, scanning work item fields for #" .. id)
      get_all_fields(id, function(all_fields, err)
        if err then
          if callback then
            callback(nil, err)
          end
          return
        end

        local current_column = all_fields and all_fields["System.BoardColumn"]
        local kanban_field = find_kanban_column_field(all_fields, current_column)
        if not kanban_field then
          local work_item_type = all_fields and all_fields["System.WorkItemType"] or "Unknown"
          local area_path = all_fields and all_fields["System.AreaPath"] or "Unknown"
          local msg = string.format(
            "Could not find a Kanban column field for work item #%d (%s in area '%s'). "
              .. "This may happen if the work item's area is not associated with the configured team's board. "
              .. "Check that the work item's area path matches the team configuration.",
            id, work_item_type, area_path
          )
          vim.notify("Workhorse: " .. msg, vim.log.levels.ERROR)
          if callback then
            callback(nil, msg)
          end
          return
        end

        -- Build the field changes map
        local field_changes = {}
        add_common_fields(field_changes)
        field_changes[kanban_field] = fields.board_column

        debug_log("update_fields: scanned kanban_field=" .. kanban_field .. ", board_column=" .. tostring(fields.board_column))

        M.update(id, field_changes, callback)
      end)
    end
  else
    -- No board_column, can update directly without field lookup
    local field_changes = {}
    add_common_fields(field_changes)

    if not next(field_changes) then
      if callback then
        callback(nil, "No valid fields to update")
      end
      return
    end

    M.update(id, field_changes, callback)
  end
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
