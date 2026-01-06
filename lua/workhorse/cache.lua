local M = {}

local config = require("workhorse.config")

-- In-memory cache
-- Structure: { [key] = { data = ..., timestamp = ... } }
local cache = {}

-- Get cached data if still valid
function M.get(key)
  local entry = cache[key]
  if not entry then
    return nil
  end

  local cfg = config.get()
  if not cfg.cache.enabled then
    return nil
  end

  local now = os.time()
  if now - entry.timestamp > cfg.cache.ttl then
    -- Expired
    cache[key] = nil
    return nil
  end

  return entry.data
end

-- Store data in cache
function M.set(key, data)
  local cfg = config.get()
  if not cfg.cache.enabled then
    return
  end

  cache[key] = {
    data = vim.deepcopy(data),
    timestamp = os.time(),
  }
end

-- Invalidate specific cache entry
function M.invalidate(key)
  cache[key] = nil
end

-- Clear all cache
function M.clear()
  cache = {}
end

-- Get cache stats (for debugging)
function M.stats()
  local count = 0
  local keys = {}
  for key, _ in pairs(cache) do
    count = count + 1
    table.insert(keys, key)
  end
  return {
    count = count,
    keys = keys,
  }
end

-- Cache key builders
function M.query_key(query_id)
  return "query:" .. query_id
end

function M.workitem_key(id)
  return "workitem:" .. id
end

function M.queries_list_key()
  return "queries:list"
end

return M
