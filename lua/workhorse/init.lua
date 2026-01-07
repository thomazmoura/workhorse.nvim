local M = {}

local config = require("workhorse.config")

-- Check if plugin is configured, show warning if not
local function check_config()
  if not config.is_valid() then
    vim.notify(
      "Workhorse: Plugin not configured. Please call require('workhorse').setup() with server_url, pat, and project.",
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

-- Setup the plugin
function M.setup(opts)
  config.setup(opts)
end

-- Open work items from a saved query
function M.open_query(query_id)
  if not check_config() then
    return
  end
  local queries = require("workhorse.api.queries")
  local workitems = require("workhorse.api.workitems")
  local buffer = require("workhorse.buffer")

  vim.notify("Workhorse: Loading query...", vim.log.levels.INFO)

  -- Execute query to get work item IDs
  queries.execute(query_id, function(ids, err)
    if err then
      vim.notify("Workhorse: Failed to execute query: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    if not ids or #ids == 0 then
      vim.notify("Workhorse: Query returned no work items", vim.log.levels.WARN)
      return
    end

    -- Fetch work item details
    workitems.get_by_ids(ids, function(items, fetch_err)
      if fetch_err then
        vim.notify("Workhorse: Failed to fetch work items: " .. (fetch_err or "unknown error"), vim.log.levels.ERROR)
        return
      end

      -- Create buffer with work items
      local bufnr = buffer.create({
        query_id = query_id,
        query_name = "Query",
        work_items = items,
      })

      -- Save for resume
      require("workhorse.session").save_last_query(query_id, "Query")

      -- Switch to the buffer
      vim.api.nvim_set_current_buf(bufnr)
      vim.notify("Workhorse: Loaded " .. #items .. " work items", vim.log.levels.INFO)
    end)
  end)
end

-- Open Telescope picker for saved queries
function M.pick_query()
  if not check_config() then
    return
  end

  local ok, telescope_ext = pcall(require, "workhorse.telescope.queries")
  if not ok then
    vim.notify(
      "Workhorse: Telescope extension not available. Use :Workhorse query <id> instead.",
      vim.log.levels.WARN
    )
    return
  end
  telescope_ext.pick()
end

-- Refresh current buffer from server
function M.refresh()
  local buffer = require("workhorse.buffer")
  local queries = require("workhorse.api.queries")
  local workitems = require("workhorse.api.workitems")

  local bufnr, state = buffer.get_current()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end

  vim.notify("Workhorse: Refreshing...", vim.log.levels.INFO)

  -- Re-execute query
  queries.execute(state.query_id, function(ids, err)
    if err then
      vim.notify("Workhorse: Failed to refresh: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    if not ids or #ids == 0 then
      buffer.refresh_buffer(bufnr, {})
      vim.notify("Workhorse: Query returned no work items", vim.log.levels.WARN)
      return
    end

    -- Fetch updated work items
    workitems.get_by_ids(ids, function(items, fetch_err)
      if fetch_err then
        vim.notify("Workhorse: Failed to fetch work items: " .. (fetch_err or "unknown error"), vim.log.levels.ERROR)
        return
      end

      buffer.refresh_buffer(bufnr, items)
      vim.notify("Workhorse: Refreshed " .. #items .. " work items", vim.log.levels.INFO)
    end)
  end)
end

-- Change state of work item under cursor
function M.change_state()
  local buffer = require("workhorse.buffer")
  local state_menu = require("workhorse.ui.state_menu")
  local workitems = require("workhorse.api.workitems")
  local render = require("workhorse.buffer.render")

  local bufnr, _ = buffer.get_current()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end

  local item, line_num = buffer.get_item_at_cursor(bufnr)
  if not item then
    vim.notify("Workhorse: No work item on this line", vim.log.levels.WARN)
    return
  end

  -- Show actions menu (which includes state change)
  state_menu.show_actions(item, {
    on_state = function(new_state)
      if new_state == item.state then
        vim.notify("Workhorse: State unchanged", vim.log.levels.INFO)
        return
      end

      vim.notify("Workhorse: Changing state to " .. new_state .. "...", vim.log.levels.INFO)

      workitems.update_state(item.id, new_state, function(updated_item, err)
        if err then
          vim.notify("Workhorse: Failed to update state: " .. (err or "unknown error"), vim.log.levels.ERROR)
          return
        end

        -- Update local state
        item.state = new_state

        -- Update virtual text
        render.update_line_virtual_text(bufnr, line_num, new_state)

        vim.notify("Workhorse: State changed to " .. new_state, vim.log.levels.INFO)
      end)
    end,
    on_open = function()
      buffer.open_in_browser(bufnr)
    end,
    on_refresh = function()
      M.refresh()
    end,
  })
end

-- Apply changes in current buffer to Azure DevOps
function M.apply()
  local buffer = require("workhorse.buffer")
  local bufnr = buffer.get_current()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end
  buffer.on_write(bufnr)
end

-- Open description for work item under cursor
function M.open_description()
  local buffer = require("workhorse.buffer")
  local description = require("workhorse.buffer.description")

  local bufnr, _ = buffer.get_current()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end

  local item = buffer.get_item_at_cursor(bufnr)
  if not item then
    vim.notify("Workhorse: No work item on this line", vim.log.levels.WARN)
    return
  end

  description.open(item)
end

-- Resume the last opened query
function M.resume()
  local session = require("workhorse.session")
  local last_query = session.get_last_query()
  if not last_query then
    vim.notify("Workhorse: No previous query to resume", vim.log.levels.WARN)
    return
  end
  M.open_query(last_query.id)
end

return M
