local M = {}

local client = require("workhorse.api.client")
local config = require("workhorse.config")

-- URL encode a string (handles spaces and special characters)
local function url_encode(str)
  if not str then
    return str
  end
  return str:gsub(" ", "%%20"):gsub("[^%w%-_.~%%]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

-- Get board columns for a team's board
-- Returns: { columns = [{name, id, columnType, isSplit, stateMappings}, ...], order = [name1, name2, ...] }
function M.get_columns(board_name, callback)
  local cfg = config.get()
  local team = url_encode(cfg.team or cfg.project) -- Fallback to project name as default team
  local encoded_board = url_encode(board_name)
  local path = "/" .. cfg.project .. "/" .. team .. "/_apis/work/boards/" .. encoded_board .. "/columns?api-version=7.1"

  client.get(path, {
    on_success = function(data)
      local columns = {}
      local order = {}
      for _, col in ipairs(data.value or {}) do
        table.insert(columns, {
          name = col.name,
          id = col.id,
          columnType = col.columnType,
          isSplit = col.isSplit,
          stateMappings = col.stateMappings,
        })
        table.insert(order, col.name)
      end
      callback({ columns = columns, order = order })
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

local function merge_columns(board_data_list)
  local order = {}
  local seen = {}
  local columns_by_name = {}

  for _, board in ipairs(board_data_list or {}) do
    for _, col_name in ipairs(board.order or {}) do
      if not seen[col_name] then
        table.insert(order, col_name)
        seen[col_name] = true
      end
    end

    for _, col in ipairs(board.columns or {}) do
      if col.name and not columns_by_name[col.name] then
        columns_by_name[col.name] = col
      end
    end
  end

  local columns = {}
  for _, name in ipairs(order) do
    local col = columns_by_name[name]
    if col then
      table.insert(columns, col)
    end
  end

  for name, col in pairs(columns_by_name) do
    if not seen[name] then
      table.insert(columns, col)
    end
  end

  return { order = order, columns = columns }
end

-- Get full board configuration including the correct column field name
-- Returns: { id, name, column_field, done_field, row_field, columns, order }
function M.get_board(board_name, callback)
  local cfg = config.get()
  local team = url_encode(cfg.team or cfg.project)
  local encoded_board = url_encode(board_name)
  local path = "/" .. cfg.project .. "/" .. team .. "/_apis/work/boards/" .. encoded_board .. "?api-version=7.1"

  client.get(path, {
    on_success = function(data)
      local columns = {}
      local order = {}
      for _, col in ipairs(data.columns or {}) do
        table.insert(columns, {
          name = col.name,
          id = col.id,
          columnType = col.columnType,
          isSplit = col.isSplit,
          stateMappings = col.stateMappings,
        })
        table.insert(order, col.name)
      end
      callback({
        id = data.id,
        name = data.name,
        column_field = data.fields and data.fields.columnField and data.fields.columnField.referenceName,
        done_field = data.fields and data.fields.doneField and data.fields.doneField.referenceName,
        row_field = data.fields and data.fields.rowField and data.fields.rowField.referenceName,
        columns = columns,
        order = order,
      })
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Get multiple boards in sequence
-- Returns array of board data and errors keyed by board name
function M.get_boards(board_names, callback)
  local results = {}
  local errors = {}

  local function next_board(idx)
    if idx > #board_names then
      callback(results, errors)
      return
    end

    local name = board_names[idx]
    M.get_board(name, function(data, err)
      if err or not data then
        errors[name] = err or "unknown error"
      else
        table.insert(results, data)
      end
      next_board(idx + 1)
    end)
  end

  next_board(1)
end

-- Build a lookup key for column_fields_by_type
-- Uses area_path and work_item_type to create a unique key
local function build_wef_key(area_path, work_item_type)
  return (area_path or "") .. "|" .. (work_item_type or "")
end

-- Expose the key builder for other modules
M.build_wef_key = build_wef_key

-- Extract work item types from a board's columns stateMappings
local function get_types_from_board(board_data)
  local types = {}
  local seen = {}
  for _, col in ipairs(board_data.columns or {}) do
    for wit, _ in pairs(col.stateMappings or {}) do
      if not seen[wit] then
        table.insert(types, wit)
        seen[wit] = true
      end
    end
  end
  return types
end

-- Merge board data into a single column definition list
-- Returns: { columns, order, column_field, column_fields_by_type }
-- column_fields_by_type: maps "area_path|work_item_type" -> WEF field name
function M.merge_boards(board_data_list, area_path)
  local merged = merge_columns(board_data_list)
  local column_field = nil
  local column_fields_by_type = {}

  -- Build column_fields_by_type mapping for each board's work item types
  for _, board in ipairs(board_data_list or {}) do
    if board.column_field then
      local types = get_types_from_board(board)
      for _, wit in ipairs(types) do
        local key = build_wef_key(area_path, wit)
        column_fields_by_type[key] = board.column_field
      end
    end
  end

  -- Keep column_field for backward compatibility when all boards use the same field
  if #board_data_list == 1 then
    column_field = board_data_list[1].column_field
  elseif #board_data_list > 1 then
    local candidate = board_data_list[1].column_field
    local same = candidate ~= nil
    for _, board in ipairs(board_data_list) do
      if board.column_field ~= candidate then
        same = false
        break
      end
    end
    if same then
      column_field = candidate
    end
  end

  return {
    columns = merged.columns,
    order = merged.order,
    column_field = column_field,
    column_fields_by_type = column_fields_by_type,
  }
end

-- List available boards for a team
function M.list_boards(callback)
  local cfg = config.get()
  local team = url_encode(cfg.team or cfg.project)
  local path = "/" .. cfg.project .. "/" .. team .. "/_apis/work/boards?api-version=7.1"

  client.get(path, {
    on_success = function(data)
      callback(data.value or {})
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  })
end

-- Resolve the correct column field (WEF) for a given work item
-- column_fields_by_type: the map from merge_boards()
-- area_path: the work item's System.AreaPath
-- work_item_type: the work item's System.WorkItemType
-- Returns: WEF field name or nil if not found
function M.resolve_column_field(column_fields_by_type, area_path, work_item_type)
  if not column_fields_by_type then
    return nil
  end

  -- Try exact match first (area + type)
  local key = build_wef_key(area_path, work_item_type)
  if column_fields_by_type[key] then
    return column_fields_by_type[key]
  end

  -- Try with empty area (type only) - useful for items from different areas
  -- that use the same board configuration
  local type_only_key = build_wef_key("", work_item_type)
  if column_fields_by_type[type_only_key] then
    return column_fields_by_type[type_only_key]
  end

  -- Try parent area paths (e.g., "Project\Team\SubArea" -> "Project\Team" -> "Project")
  if area_path and area_path ~= "" then
    local parts = vim.split(area_path, "\\")
    for i = #parts - 1, 1, -1 do
      local parent_area = table.concat(parts, "\\", 1, i)
      local parent_key = build_wef_key(parent_area, work_item_type)
      if column_fields_by_type[parent_key] then
        return column_fields_by_type[parent_key]
      end
    end
  end

  return nil
end

return M
