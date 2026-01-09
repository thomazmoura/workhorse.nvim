local M = {}

local render = require("workhorse.buffer.render")
local parser = require("workhorse.buffer.parser")
local changes_mod = require("workhorse.buffer.changes")
local config = require("workhorse.config")
local boards = require("workhorse.api.boards")

-- Track workhorse buffers
local buffers = {}

-- Get available states for the work items in the buffer
local function get_available_states(work_items)
  local cfg = config.get()

  -- Determine work item type (use first item's type or default)
  local work_item_type = cfg.default_work_item_type
  if work_items and #work_items > 0 and work_items[1].type then
    work_item_type = work_items[1].type
  end

  -- Get states for this type, fallback to default User Story states
  local states = cfg.available_states[work_item_type]
  if not states then
    states = cfg.available_states["User Story"] or { "New", "Active", "Resolved", "Closed", "Removed" }
  end

  return states
end

-- Get grouping info (states or board columns) based on configuration
-- Calls callback with { mode = "state"|"board_column", values = [...], columns = [...] }
local function get_grouping_info(work_items, callback)
  local cfg = config.get()

  if cfg.grouping_mode == "board_column" then
    -- Fetch board columns from API
    local board_name = cfg.default_board or "Stories"

    boards.get_columns(board_name, function(data, err)
      if err then
        vim.notify("Workhorse: Failed to fetch board columns: " .. (err or "unknown") .. ". Falling back to state grouping.", vim.log.levels.WARN)
        -- Fallback to state grouping
        callback({ mode = "state", values = get_available_states(work_items) })
        return
      end
      callback({ mode = "board_column", values = data.order, columns = data.columns })
    end)
  else
    -- Use state grouping (default behavior)
    callback({ mode = "state", values = get_available_states(work_items) })
  end
end

-- Create a new workhorse buffer for displaying work items
function M.create(opts)
  local query_id = opts.query_id
  local query_name = opts.query_name or "Work Items"
  local work_items = opts.work_items or {}

  -- Create new buffer
  local bufnr = vim.api.nvim_create_buf(true, false)

  -- Set buffer name
  local buf_name = "workhorse://" .. query_name:gsub("[^%w]", "_")
  -- Ensure unique buffer name
  local suffix = 1
  local final_name = buf_name
  while vim.fn.bufexists(final_name) == 1 do
    final_name = buf_name .. "_" .. suffix
    suffix = suffix + 1
  end
  vim.api.nvim_buf_set_name(bufnr, final_name)

  -- Set buffer options
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].filetype = "workhorse"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"

  -- Also store in buffer variable for easy access
  vim.b[bufnr].workhorse = {
    query_id = query_id,
    query_name = query_name,
  }

  -- Get grouping info (async for board_column mode)
  get_grouping_info(work_items, function(grouping_info)
    -- Store buffer state
    buffers[bufnr] = {
      query_id = query_id,
      query_name = query_name,
      original_items = vim.deepcopy(work_items),
      work_items = work_items,
      grouping_mode = grouping_info.mode,
      available_states = grouping_info.mode == "state" and grouping_info.values or nil,
      available_columns = grouping_info.mode == "board_column" and grouping_info.values or nil,
      column_definitions = grouping_info.columns,
    }

    -- Render based on mode
    local lines, line_map
    if grouping_info.mode == "board_column" then
      lines, line_map = render.render_grouped_by_column(work_items, grouping_info.values)
    else
      lines, line_map = render.render_grouped_lines(work_items, grouping_info.values)
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Apply line highlights
    render.apply_line_highlights(bufnr, line_map)

    -- Store line map for reference
    buffers[bufnr].line_map = line_map

    -- Set buffer as unmodified
    vim.bo[bufnr].modified = false

    -- Set up autocommands for this buffer
    M.setup_autocmds(bufnr)

    -- Set up keymaps for this buffer
    M.setup_keymaps(bufnr)
  end)

  return bufnr
end

-- Set up autocommands for a workhorse buffer
function M.setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_buffer_" .. bufnr, { clear = true })

  -- Handle buffer unload
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.on_unload(bufnr)
    end,
  })

  -- Update pending move markers when text changes
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.update_pending_markers(bufnr)
    end,
  })
end

-- Update virtual text markers for pending state changes
function M.update_pending_markers(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end

  -- Clear existing markers
  render.clear_virtual_text(bufnr)

  -- Parse current buffer with sections
  local current_items = parser.parse_buffer_with_sections(bufnr)

  -- Get pending moves
  local pending_moves = changes_mod.get_pending_moves(state.original_items, current_items)

  -- Add markers
  if next(pending_moves) then
    render.add_pending_move_markers(bufnr, pending_moves)
  end
end

-- Set up keymaps for a workhorse buffer
function M.setup_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true }

  -- Leader-Leader to apply changes (overrides global :wa mapping)
  vim.keymap.set("n", "<leader><leader>", function()
    require("workhorse").apply()
  end, opts)

  -- Enter to open description
  vim.keymap.set("n", "<CR>", function()
    require("workhorse").open_description()
  end, opts)

  -- Ctrl-r to refresh
  vim.keymap.set("n", "<leader>R", function()
    require("workhorse").refresh()
  end, opts)

  -- gx to open in browser
  vim.keymap.set("n", "gw", function()
    M.open_in_browser(bufnr)
  end, opts)
end

-- Get buffer state
function M.get_state(bufnr)
  return buffers[bufnr]
end

-- Check if buffer is a workhorse buffer
function M.is_workhorse_buffer(bufnr)
  return buffers[bufnr] ~= nil
end

-- Get current workhorse buffer state (if in one)
function M.get_current()
  local bufnr = vim.api.nvim_get_current_buf()
  if M.is_workhorse_buffer(bufnr) then
    return bufnr, buffers[bufnr]
  end
  return nil, nil
end

-- Handle buffer write / apply
function M.on_write(bufnr)
  local state = buffers[bufnr]
  local side_panels = require("workhorse.buffer.side_panels")

  if not state then
    vim.notify("Workhorse: Buffer state not found", vim.log.levels.ERROR)
    return
  end

  -- Parse current buffer contents with section tracking
  local current_items = parser.parse_buffer_with_sections(bufnr)

  -- Detect changes (including state/column changes)
  local available_sections = state.grouping_mode == "board_column"
    and state.available_columns
    or state.available_states
  local changes = changes_mod.detect(
    state.original_items,
    current_items,
    state.grouping_mode,
    available_sections,
    state.column_definitions
  )

  -- Check for description and tag changes too
  local has_panel_changes = side_panels.has_pending_changes()

  if #changes == 0 and not has_panel_changes then
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    vim.bo[bufnr].modified = false
    return
  end

  -- Check if there are new items that need an area path
  local has_new = false
  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      has_new = true
      break
    end
  end

  local cfg = config.get()

  -- Helper to proceed with confirmation and apply
  local function proceed_with_changes(area_path)
    if cfg.confirm_changes then
      require("workhorse.ui.confirm").show(changes, function()
        M.apply_changes(bufnr, changes, area_path)
      end)
    else
      M.apply_changes(bufnr, changes, area_path)
    end
  end

  if has_new then
    -- Use default_area_path if configured, otherwise show picker
    if cfg.default_area_path then
      proceed_with_changes(cfg.default_area_path)
    else
      require("workhorse.ui.area_picker").show(function(selected_area)
        proceed_with_changes(selected_area)
      end, function()
        -- Cancelled - don't apply changes
        vim.notify("Workhorse: Area selection cancelled", vim.log.levels.INFO)
      end)
    end
  else
    -- No new items, proceed normally
    proceed_with_changes(nil)
  end
end

-- Apply changes to Azure DevOps
function M.apply_changes(bufnr, changes, area_path)
  local state = buffers[bufnr]
  local workitems = require("workhorse.api.workitems")
  local side_panels = require("workhorse.buffer.side_panels")
  local cfg = config.get()

  -- Get pending description and tag changes
  local desc_changes = side_panels.get_pending_description_changes()
  local tag_changes = side_panels.get_pending_tag_changes()

  local total = #changes + #desc_changes + #tag_changes
  local completed = 0
  local errors = {}

  local function on_complete()
    completed = completed + 1
    if completed == total then
      -- All done
      if #errors > 0 then
        vim.notify(
          "Workhorse: " .. (total - #errors) .. "/" .. total .. " changes applied.\nErrors:\n" .. table.concat(errors, "\n"),
          vim.log.levels.WARN
        )
      else
        vim.notify("Workhorse: " .. total .. " changes applied", vim.log.levels.INFO)
      end

      -- Refresh the buffer
      require("workhorse").refresh()
    end
  end

  -- Handle case where there are no changes
  if total == 0 then
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    return
  end

  -- Apply description changes
  for _, desc_change in ipairs(desc_changes) do
    workitems.update_description(desc_change.id, desc_change.description, function(item, err)
      if err then
        table.insert(errors, "Description #" .. desc_change.id .. " failed: " .. (err or "unknown error"))
      else
        side_panels.mark_description_saved(desc_change.id)
      end
      on_complete()
    end)
  end

  -- Apply tag changes
  for _, tag_change in ipairs(tag_changes) do
    workitems.update_tags(tag_change.id, tag_change.tags, function(item, err)
      if err then
        table.insert(errors, "Tags #" .. tag_change.id .. " failed: " .. (err or "unknown error"))
      else
        side_panels.mark_tags_saved(tag_change.id)
      end
      on_complete()
    end)
  end

  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      -- Create new work item (optionally with initial state and area)
      local create_opts = {
        title = change.title,
        type = cfg.default_work_item_type,
        area_path = area_path,
      }
      if change.new_state then
        create_opts.state = change.new_state
      end
      workitems.create(create_opts, function(item, err)
        if err then
          table.insert(errors, "Create failed: " .. (err or "unknown error"))
        end
        on_complete()
      end)
    elseif change.type == changes_mod.ChangeType.UPDATED then
      -- Update title
      workitems.update_title(change.id, change.title, function(item, err)
        if err then
          table.insert(errors, "Update #" .. change.id .. " failed: " .. (err or "unknown error"))
        end
        on_complete()
      end)
    elseif change.type == changes_mod.ChangeType.DELETED then
      -- Soft delete (change state to Removed)
      workitems.soft_delete(change.id, function(item, err)
        if err then
          table.insert(errors, "Delete #" .. change.id .. " failed: " .. (err or "unknown error"))
        end
        on_complete()
      end)
    elseif change.type == changes_mod.ChangeType.STATE_CHANGED then
      -- Update state
      workitems.update_state(change.id, change.new_state, function(item, err)
        if err then
          table.insert(errors, "State change #" .. change.id .. " failed: " .. (err or "unknown error"))
        end
        on_complete()
      end)
    elseif change.type == changes_mod.ChangeType.COLUMN_CHANGED then
      -- Update board column
      workitems.update_board_column(change.id, change.new_column, function(item, err)
        if err then
          table.insert(errors, "Column change #" .. change.id .. " failed: " .. (err or "unknown error"))
        end
        on_complete()
      end)
    elseif change.type == changes_mod.ChangeType.STACK_RANK_CHANGED then
      -- Update stack rank
      workitems.update_stack_rank(change.id, change.new_rank, function(item, err)
        if err then
          table.insert(errors, "Order change #" .. change.id .. " failed: " .. (err or "unknown error"))
        end
        on_complete()
      end)
    end
  end
end

-- Refresh buffer with latest data from server
function M.refresh_buffer(bufnr, work_items)
  local buf_state = buffers[bufnr]
  if not buf_state then
    return
  end

  -- Get grouping info (async for board_column mode)
  get_grouping_info(work_items, function(grouping_info)
    -- Update state
    buf_state.original_items = vim.deepcopy(work_items)
    buf_state.work_items = work_items
    buf_state.grouping_mode = grouping_info.mode
    buf_state.available_states = grouping_info.mode == "state" and grouping_info.values or nil
    buf_state.available_columns = grouping_info.mode == "board_column" and grouping_info.values or nil
    buf_state.column_definitions = grouping_info.columns

    -- Re-render based on mode
    local lines, line_map
    if grouping_info.mode == "board_column" then
      lines, line_map = render.render_grouped_by_column(work_items, grouping_info.values)
    else
      lines, line_map = render.render_grouped_lines(work_items, grouping_info.values)
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    buf_state.line_map = line_map

    -- Clear any pending markers and apply line highlights
    render.clear_virtual_text(bufnr)
    render.apply_line_highlights(bufnr, line_map)

    -- Mark as unmodified
    vim.bo[bufnr].modified = false
  end)
end

-- Handle buffer unload
function M.on_unload(bufnr)
  buffers[bufnr] = nil
end

-- Open work item in browser
function M.open_in_browser(bufnr)
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local id = parser.get_id_at_line(bufnr, line_num)

  if not id then
    vim.notify("Workhorse: No work item on this line", vim.log.levels.WARN)
    return
  end

  local cfg = config.get()
  local url = cfg.server_url .. "/" .. cfg.project .. "/_workitems/edit/" .. id

  -- Open URL based on OS
  local cmd
  if vim.fn.has("mac") == 1 then
    cmd = { "open", url }
  elseif vim.fn.has("unix") == 1 then
    cmd = { "xdg-open", url }
  else
    cmd = { "start", url }
  end

  vim.fn.jobstart(cmd, { detach = true })
  vim.notify("Workhorse: Opening #" .. id .. " in browser", vim.log.levels.INFO)
end

-- Get work item at cursor position
function M.get_item_at_cursor(bufnr)
  local state = buffers[bufnr]
  if not state then
    return nil
  end

  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local id = parser.get_id_at_line(bufnr, line_num)

  if not id then
    return nil
  end

  -- Find the work item in our state
  for _, item in ipairs(state.work_items) do
    if item.id == id then
      return item, line_num
    end
  end

  return nil
end

return M
