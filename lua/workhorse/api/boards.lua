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

return M
