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

local function get_board_names()
  local cfg = config.get()
  local names = {}
  local seen = {}

  local function add(name)
    if name and name ~= "" and not seen[name] then
      table.insert(names, name)
      seen[name] = true
    end
  end

  add(cfg.default_board or "Stories")
  for _, name in ipairs(cfg.column_boards or {}) do
    add(name)
  end

  return names
end

local function merge_board_errors(errors)
  if not errors or not next(errors) then
    return nil
  end

  local parts = {}
  for name, err in pairs(errors) do
    table.insert(parts, name .. ": " .. tostring(err))
  end

  return table.concat(parts, "; ")
end

-- Apply user's column order preference to API order
-- User-specified columns appear first, remaining API columns follow
local function apply_column_order_preference(api_order, user_order)
  if not user_order or #user_order == 0 then
    return api_order
  end

  -- Create set of API columns for fast lookup
  local api_set = {}
  for _, col in ipairs(api_order) do
    api_set[col] = true
  end

  -- Start with user-specified columns (only those that exist in API)
  local result = {}
  local used = {}
  for _, col in ipairs(user_order) do
    if api_set[col] then
      table.insert(result, col)
      used[col] = true
    end
  end

  -- Append remaining API columns in their original order
  for _, col in ipairs(api_order) do
    if not used[col] then
      table.insert(result, col)
    end
  end

  return result
end

-- Get grouping info (states or board columns) based on configuration
-- Calls callback with { mode = "state"|"board_column", values = [...], columns = [...] }
local function get_grouping_info(work_items, callback)
  local cfg = config.get()

  if cfg.grouping_mode == "board_column" then
    -- Fetch board configuration from API (includes column field name)
    local board_names = get_board_names()

    boards.get_boards(board_names, function(data_list, errors)
      if not data_list or #data_list == 0 then
        local error_summary = merge_board_errors(errors)
        vim.notify(
          "Workhorse: Failed to fetch board columns"
            .. (error_summary and (": " .. error_summary) or "")
            .. ". Falling back to state grouping.",
          vim.log.levels.WARN
        )
        -- Fallback to state grouping
        callback({ mode = "state", values = get_available_states(work_items) })
        return
      end

      -- Get area path for WEF mapping (use configured team area or first work item's area)
      local area_path = cfg.default_area_path
      if not area_path and work_items and #work_items > 0 then
        area_path = work_items[1].area_path
      end

      local merged = boards.merge_boards(data_list, area_path)
      -- Apply user's column order preference
      local final_order = apply_column_order_preference(merged.order, cfg.column_order)
      callback({
        mode = "board_column",
        values = final_order,
        columns = merged.columns,
        column_field = merged.column_field, -- WEF field name when consistent across boards
        column_fields_by_type = merged.column_fields_by_type, -- WEF mapping by area+type
      })
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
      column_field = grouping_info.column_field, -- WEF field name for the board (legacy)
      column_fields_by_type = grouping_info.column_fields_by_type, -- WEF mapping by area+type
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
    render.apply_type_decorations(bufnr, line_map)

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

-- Update virtual text markers for pending column changes
function M.update_pending_markers(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end

  -- Clear existing markers
  render.clear_virtual_text(bufnr)

  -- Parse current buffer with sections
  local current_items = parser.parse_buffer_with_sections(bufnr)

  -- Get pending moves (returns both new and original columns)
  local pending_moves, original_columns = changes_mod.get_pending_moves(state.original_items, current_items)

  -- Add markers
  if next(pending_moves) then
    render.add_pending_move_markers(bufnr, pending_moves, original_columns)
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

-- Group changes by work item ID and merge field updates (including description and tags)
local function group_and_merge_changes(changes, column_definitions, desc_changes, tag_changes, side_panels)
  local creates = {}
  local deletes = {}
  local updates_by_id = {} -- { [id] = { fields = {}, work_item = item, area_path = ..., work_item_type = ... } }

  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      table.insert(creates, change)
    elseif change.type == changes_mod.ChangeType.DELETED then
      table.insert(deletes, change)
    else
      -- Group field updates by work item ID
      local id = change.id
      if id then
        if not updates_by_id[id] then
          updates_by_id[id] = { fields = {} }
        end

        if change.type == changes_mod.ChangeType.UPDATED then
          updates_by_id[id].fields.title = change.title
        elseif change.type == changes_mod.ChangeType.COLUMN_CHANGED then
          updates_by_id[id].fields.board_column = change.new_column
          -- Store area_path and work_item_type for WEF field resolution
          updates_by_id[id].area_path = change.area_path
          updates_by_id[id].work_item_type = change.work_item_type
          -- Note: Do NOT set state_for_column here - Azure DevOps handles state
          -- transitions automatically when the board column is updated.
          -- Explicitly setting State causes TF401320 errors due to workflow rules.
        elseif change.type == changes_mod.ChangeType.STACK_RANK_CHANGED then
          updates_by_id[id].fields.stack_rank = change.new_rank
        end
      end
    end
  end

  -- Merge description changes into updates_by_id
  for _, desc_change in ipairs(desc_changes or {}) do
    local id = desc_change.id
    if not updates_by_id[id] then
      updates_by_id[id] = { fields = {} }
    end
    updates_by_id[id].fields.description = desc_change.description
    updates_by_id[id].desc_change = desc_change
  end

  -- Merge tag changes into updates_by_id
  for _, tag_change in ipairs(tag_changes or {}) do
    local id = tag_change.id
    if not updates_by_id[id] then
      updates_by_id[id] = { fields = {} }
    end
    -- Convert tags array to semicolon-separated string
    updates_by_id[id].fields.tags = table.concat(tag_change.tags, "; ")
    updates_by_id[id].tag_change = tag_change
  end

  return creates, deletes, updates_by_id
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

  -- Group and merge ALL changes by work item ID (including description and tags)
  local creates, deletes, updates_by_id = group_and_merge_changes(
    changes, state.column_definitions, desc_changes, tag_changes, side_panels
  )

  -- Count total operations
  local update_count = 0
  for _ in pairs(updates_by_id) do
    update_count = update_count + 1
  end
  local total = #creates + #deletes + update_count
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

  -- Apply creates
  for _, change in ipairs(creates) do
    local create_opts = {
      title = change.title,
      type = cfg.default_work_item_type,
      area_path = area_path,
    }
    if change.new_state then
      create_opts.state = change.new_state
    elseif change.new_column then
      -- In board_column mode, use default state (items start as New)
      create_opts.state = cfg.default_new_state or "New"
    end
    workitems.create(create_opts, function(item, err)
      if err then
        table.insert(errors, "Create failed: " .. (err or "unknown error"))
        on_complete()
      elseif change.new_column and item then
        -- In board_column mode, update the column after creation
        -- Note: Don't pass state - let Azure DevOps handle state transitions automatically
        workitems.update_board_column(item.id, change.new_column, function(_, col_err)
          if col_err then
            table.insert(errors, "Column update for new item failed: " .. (col_err or "unknown error"))
          end
          on_complete()
        end)
      else
        on_complete()
      end
    end)
  end

  -- Apply deletes
  for _, change in ipairs(deletes) do
    workitems.soft_delete(change.id, function(item, err)
      if err then
        table.insert(errors, "Delete #" .. change.id .. " failed: " .. (err or "unknown error"))
      end
      on_complete()
    end)
  end

  -- Apply merged field updates (single request per work item, includes description and tags)
  for id, update_info in pairs(updates_by_id) do
    -- Resolve the correct WEF field for this work item based on area and type
    local kanban_field = nil
    if update_info.fields.board_column then
      -- First try to resolve using the area+type map
      kanban_field = boards.resolve_column_field(
        state.column_fields_by_type,
        update_info.area_path,
        update_info.work_item_type
      )
      -- Fallback to the legacy single column_field if resolution fails
      if not kanban_field then
        kanban_field = state.column_field
      end
      -- If still no field, notify user but continue (workitems.update_fields will try to discover it)
      if not kanban_field and update_info.work_item_type then
        vim.notify(
          string.format(
            "Workhorse: Could not determine board column field for #%d (%s in %s). Will attempt auto-discovery.",
            id, update_info.work_item_type or "Unknown type", update_info.area_path or "Unknown area"
          ),
          vim.log.levels.WARN
        )
      end
    end

    workitems.update_fields(id, update_info.fields, function(item, err)
      if err then
        table.insert(errors, "Update #" .. id .. " failed: " .. (err or "unknown error"))
      else
        -- Mark side panel changes as saved if they were included
        if update_info.desc_change then
          side_panels.mark_description_saved(id)
        end
        if update_info.tag_change then
          side_panels.mark_tags_saved(id)
        end
      end
      on_complete()
    end, kanban_field)
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
    buf_state.column_field = grouping_info.column_field
    buf_state.column_fields_by_type = grouping_info.column_fields_by_type

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
    render.apply_type_decorations(bufnr, line_map)

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
