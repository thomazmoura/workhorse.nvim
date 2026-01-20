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

  -- Auto-start lualine integration if env var is set
  local lualine_query = vim.env.WORKHORSE_LUALINE_QUERY_ID
  if lualine_query and lualine_query ~= "" then
    require("workhorse.lualine").start()
  end
end

local function get_buffer_module(bufnr)
  local buffer_tree = require("workhorse.buffer_tree")
  local buffer_flat = require("workhorse.buffer")
  local target = bufnr or vim.api.nvim_get_current_buf()

  if buffer_tree.is_tree_buffer(target) then
    return buffer_tree, target
  end
  if buffer_flat.is_workhorse_buffer(target) then
    return buffer_flat, target
  end
  return nil, nil
end

local function is_tree_result(result)
  local query_type = result and result.query_type
  if query_type and type(query_type) == "string" then
    return query_type:lower() == "tree"
  end
  return result and result.relations and #result.relations > 0
end

-- Open work items from a saved query
function M.open_query(query_id, query_name)
  if not check_config() then
    return
  end
  local queries = require("workhorse.api.queries")
  local workitems = require("workhorse.api.workitems")
  local buffer = require("workhorse.buffer")
  local buffer_tree = require("workhorse.buffer_tree")

  -- Check for existing buffer with this query_id (flat or tree)
  local existing_bufnr = buffer.find_by_query_id(query_id) or buffer_tree.find_by_query_id(query_id)
  if existing_bufnr then
    vim.api.nvim_set_current_buf(existing_bufnr)
    M.refresh()
    return
  end

  -- Helper function that does the actual loading after we have the query name
  local function load_query(name)
    vim.notify("Workhorse: Loading query...", vim.log.levels.INFO)

    -- Execute query to get work item IDs
    queries.execute(query_id, function(result, err)
      if err then
        vim.notify("Workhorse: Failed to execute query: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end

      local ids = result and result.ids or {}
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

        local use_tree = is_tree_result(result)
        local bufnr
        if use_tree then
          bufnr = buffer_tree.create({
            query_id = query_id,
            query_name = name,
            work_items = items,
            relations = result.relations,
          })
        else
          bufnr = buffer.create({
            query_id = query_id,
            query_name = name,
            work_items = items,
          })
        end

        -- Save for resume
        require("workhorse.session").save_last_query(query_id, name)

        -- Switch to the buffer
        vim.api.nvim_set_current_buf(bufnr)
        vim.notify("Workhorse: Loaded " .. #items .. " work items", vim.log.levels.INFO)
      end)
    end)
  end

  -- If query_name not provided, fetch it first
  if not query_name then
    queries.get_info(query_id, function(info, err)
      if err then
        vim.notify("Workhorse: Failed to get query info: " .. (err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      load_query(info.name or "Query")
    end)
  else
    load_query(query_name)
  end
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
  local buffer_tree = require("workhorse.buffer_tree")
  local queries = require("workhorse.api.queries")
  local workitems = require("workhorse.api.workitems")

  local bufnr, state = buffer.get_current()
  if not bufnr then
    bufnr, state = buffer_tree.get_current()
  end
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end

  vim.notify("Workhorse: Refreshing...", vim.log.levels.INFO)

  -- Re-execute query
  queries.execute(state.query_id, function(result, err)
    if err then
      vim.notify("Workhorse: Failed to refresh: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    local ids = result and result.ids or {}
    if not ids or #ids == 0 then
      if buffer_tree.is_tree_buffer(bufnr) then
        buffer_tree.refresh_buffer(bufnr, {}, result and result.relations or nil)
      else
        buffer.refresh_buffer(bufnr, {})
      end
      vim.notify("Workhorse: Query returned no work items", vim.log.levels.WARN)
      return
    end

    -- Fetch updated work items
    workitems.get_by_ids(ids, function(items, fetch_err)
      if fetch_err then
        vim.notify("Workhorse: Failed to fetch work items: " .. (fetch_err or "unknown error"), vim.log.levels.ERROR)
        return
      end

      if buffer_tree.is_tree_buffer(bufnr) then
        buffer_tree.refresh_buffer(bufnr, items, result and result.relations or nil)
      else
        buffer.refresh_buffer(bufnr, items)
      end
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

  local buf_module, bufnr = get_buffer_module()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end

  local item, line_num = buf_module.get_item_at_cursor(bufnr)
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

        if not require("workhorse.buffer_tree").is_tree_buffer(bufnr) then
          render.update_line_virtual_text(bufnr, line_num, new_state)
        end

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
  local buf_module, bufnr = get_buffer_module()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end
  buf_module.on_write(bufnr)
end

-- Open description and tags side panels for work item under cursor
function M.open_description()
  local side_panels = require("workhorse.buffer.side_panels")

  local buf_module, bufnr = get_buffer_module()
  if not bufnr then
    vim.notify("Workhorse: Not in a workhorse buffer", vim.log.levels.WARN)
    return
  end

  local item = buf_module.get_item_at_cursor(bufnr)
  if not item then
    vim.notify("Workhorse: No work item on this line", vim.log.levels.WARN)
    return
  end

  side_panels.open(item)
end

-- Resume the last opened query
function M.resume()
  local session = require("workhorse.session")
  local last_query = session.get_last_query()
  if not last_query then
    vim.notify("Workhorse: No previous query to resume", vim.log.levels.WARN)
    return
  end
  M.open_query(last_query.id, last_query.name)
end

-- Export lualine integration module
M.lualine = require("workhorse.lualine")

return M
