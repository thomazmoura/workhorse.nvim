local M = {}

local state = {
  item = nil,
  loading = false,
  error = nil,
  timer = nil,
}

function M.get()
  if not state.item then
    return ""
  end
  return string.format("#%d | %s", state.item.id, state.item.title)
end

function M.fetch()
  local query_id = vim.env.WORKHORSE_LUALINE_QUERY_ID
  if not query_id or query_id == "" then
    return
  end

  if state.loading then
    return
  end

  state.loading = true

  local queries = require("workhorse.api.queries")
  queries.execute(query_id, function(result, err)
    if err then
      state.error = err
      state.loading = false
      return
    end

    if not result or not result.ids or #result.ids == 0 then
      state.item = nil
      state.loading = false
      return
    end

    local workitems = require("workhorse.api.workitems")
    workitems.get_by_ids(result.ids, function(items, item_err)
      state.loading = false
      if item_err or not items or #items == 0 then
        state.error = item_err
        return
      end

      table.sort(items, function(a, b)
        local rank_a = a.stack_rank or math.huge
        local rank_b = b.stack_rank or math.huge
        if rank_a == rank_b then
          return (a.id or 0) < (b.id or 0)
        end
        return rank_a < rank_b
      end)

      state.item = {
        id = items[1].id,
        title = items[1].title,
      }
      state.error = nil
    end)
  end)
end

function M.start()
  local query_id = vim.env.WORKHORSE_LUALINE_QUERY_ID
  if not query_id or query_id == "" then
    return
  end

  if state.timer then
    return
  end

  local config = require("workhorse.config")
  local cfg = config.get()
  local interval = cfg.lualine and cfg.lualine.refresh_interval or 60000

  state.timer = vim.loop.new_timer()
  state.timer:start(0, interval, vim.schedule_wrap(function()
    M.fetch()
  end))
end

function M.stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

function M.is_running()
  return state.timer ~= nil
end

function M.get_error()
  return state.error
end

return M
