local M = {}

local session_file = vim.fn.stdpath("data") .. "/workhorse_session.json"

local function read()
  local file = io.open(session_file, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

-- Update one key, keeping the rest of the session (last query and last build share the file)
local function save(key, value)
  local data = read()
  data[key] = value
  local file = io.open(session_file, "w")
  if file then
    file:write(vim.json.encode(data))
    file:close()
  end
end

function M.save_last_query(query_id, query_name)
  save("last_query", { id = query_id, name = query_name })
end

function M.get_last_query()
  return read().last_query
end

function M.save_last_build(definition_id, definition_name)
  save("last_build", { id = definition_id, name = definition_name })
end

function M.get_last_build()
  return read().last_build
end

return M
