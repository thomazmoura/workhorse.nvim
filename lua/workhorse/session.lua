local M = {}

local session_file = vim.fn.stdpath("data") .. "/workhorse_session.json"

function M.save_last_query(query_id, query_name)
  local data = vim.json.encode({ last_query = { id = query_id, name = query_name } })
  local file = io.open(session_file, "w")
  if file then
    file:write(data)
    file:close()
  end
end

function M.get_last_query()
  local file = io.open(session_file, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and data and data.last_query then
    return data.last_query
  end
  return nil
end

return M
