local M = {}

local render = require("workhorse.buffer.render")
local parser = require("workhorse.buffer.parser")
local changes_mod = require("workhorse.buffer.changes")
local config = require("workhorse.config")

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

  -- Get available states for grouping
  local available_states = get_available_states(work_items)

  -- Store buffer state
  buffers[bufnr] = {
    query_id = query_id,
    query_name = query_name,
    original_items = vim.deepcopy(work_items),
    work_items = work_items,
    available_states = available_states,
  }

  -- Also store in buffer variable for easy access
  vim.b[bufnr].workhorse = {
    query_id = query_id,
    query_name = query_name,
  }

  -- Render work items grouped by state
  local lines, line_map = render.render_grouped_lines(work_items, available_states)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Apply line highlights (state headers and type prefixes)
  render.apply_line_highlights(bufnr, line_map)

  -- Store line map for reference
  buffers[bufnr].line_map = line_map

  -- Set buffer as unmodified
  vim.bo[bufnr].modified = false

  -- Set up autocommands for this buffer
  M.setup_autocmds(bufnr)

  -- Set up keymaps for this buffer
  M.setup_keymaps(bufnr)

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

  -- Enter to change state
  vim.keymap.set("n", "<CR>", function()
    require("workhorse").change_state()
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
  if not state then
    vim.notify("Workhorse: Buffer state not found", vim.log.levels.ERROR)
    return
  end

  -- Parse current buffer contents with section tracking
  local current_items = parser.parse_buffer_with_sections(bufnr)

  -- Detect changes (including state changes)
  local changes = changes_mod.detect(state.original_items, current_items)

  if #changes == 0 then
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    vim.bo[bufnr].modified = false
    return
  end

  -- Apply changes (with or without confirmation)
  local cfg = config.get()
  if cfg.confirm_changes then
    require("workhorse.ui.confirm").show(changes, function()
      M.apply_changes(bufnr, changes)
    end)
  else
    M.apply_changes(bufnr, changes)
  end
end

-- Apply changes to Azure DevOps
function M.apply_changes(bufnr, changes)
  local state = buffers[bufnr]
  local workitems = require("workhorse.api.workitems")
  local cfg = config.get()

  local total = #changes
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

  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      -- Create new work item (optionally with initial state)
      local create_opts = {
        title = change.title,
        type = cfg.default_work_item_type,
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
    end
  end
end

-- Refresh buffer with latest data from server
function M.refresh_buffer(bufnr, work_items)
  local state = buffers[bufnr]
  if not state then
    return
  end

  -- Update available states (in case work item types changed)
  local available_states = get_available_states(work_items)

  -- Update state
  state.original_items = vim.deepcopy(work_items)
  state.work_items = work_items
  state.available_states = available_states

  -- Re-render with grouping
  local lines, line_map = render.render_grouped_lines(work_items, available_states)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  state.line_map = line_map

  -- Clear any pending markers and apply line highlights
  render.clear_virtual_text(bufnr)
  render.apply_line_highlights(bufnr, line_map)

  -- Mark as unmodified
  vim.bo[bufnr].modified = false
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
