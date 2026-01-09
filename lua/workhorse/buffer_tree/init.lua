local M = {}

local render = require("workhorse.buffer_tree.render")
local parser = require("workhorse.buffer_tree.parser")
local changes_mod = require("workhorse.buffer_tree.changes")
local config = require("workhorse.config")
local boards = require("workhorse.api.boards")

local buffers = {}

local function build_tree(relations, work_items)
  local items_by_id = {}
  for _, item in ipairs(work_items or {}) do
    items_by_id[item.id] = item
  end

  local children = {}
  local roots = {}
  local seen_root = {}
  local parent_by_id = {}

  for _, rel in ipairs(relations or {}) do
    local source = type(rel.source) == "table" and rel.source or nil
    local target = type(rel.target) == "table" and rel.target or nil
    if source and target then
      local parent = source.id
      local child = target.id
      parent_by_id[child] = parent_by_id[child] or parent
      children[parent] = children[parent] or {}
      table.insert(children[parent], child)
    elseif target and not source then
      local root = target.id
      if not seen_root[root] then
        table.insert(roots, root)
        seen_root[root] = true
      end
    end
  end

  for id, _ in pairs(items_by_id) do
    if not parent_by_id[id] and not seen_root[id] then
      table.insert(roots, id)
      seen_root[id] = true
    end
  end

  local nodes = {}
  local levels = {}
  local visited = {}

  local function walk(id, level)
    if visited[id] then
      return
    end
    visited[id] = true
    local item = items_by_id[id]
    if item then
      levels[id] = level
      table.insert(nodes, { item = item, level = level })
    end
    for _, child_id in ipairs(children[id] or {}) do
      walk(child_id, level + 1)
    end
  end

  for _, root_id in ipairs(roots) do
    walk(root_id, 0)
  end

  return nodes, parent_by_id, levels
end

local function infer_level_types(nodes)
  local level_types = {}
  for _, node in ipairs(nodes or {}) do
    if level_types[node.level] == nil then
      level_types[node.level] = node.item.type
    end
  end
  return level_types
end

local function show_column_menu(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end

  local item = M.get_item_at_cursor(bufnr)
  if not item then
    vim.notify("Workhorse: No work item on this line", vim.log.levels.WARN)
    return
  end

  local cfg = config.get()
  local board_name = cfg.default_board or "Stories"
  local original_column = nil
  for _, orig in ipairs(state.original_items or {}) do
    if orig.id == item.id then
      original_column = orig.board_column
      break
    end
  end

  boards.get_columns(board_name, function(data, err)
    if err then
      vim.notify("Workhorse: Failed to fetch board columns: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    local columns = {}
    for _, col in ipairs(data.order or {}) do
      table.insert(columns, col)
    end

    vim.ui.select(columns, {
      prompt = "Select board column for #" .. item.id,
    }, function(choice)
      if not choice then
        return
      end

      if original_column and original_column == choice then
        state.column_overrides[item.id] = nil
      else
        state.column_overrides[item.id] = choice
      end

      item.board_column = choice
      render.apply_column_virtual_text(bufnr, state.line_map, state.column_overrides, cfg.column_colors, state.original_items)
      render.apply_indent_highlights(bufnr, state.line_map, cfg.tree_indent_hl)
      render.apply_column_line_highlights(bufnr, state.line_map, state.column_overrides, cfg.column_colors)
      render.apply_tag_title_highlights(bufnr, state.line_map)
      render.apply_type_decorations(bufnr, state.line_map)

      vim.notify("Workhorse: Column updated to " .. choice, vim.log.levels.INFO)
    end)
  end)
end

function M.create(opts)
  local query_id = opts.query_id
  local query_name = opts.query_name or "Work Items"
  local work_items = opts.work_items or {}
  local relations = opts.relations or {}

  local bufnr = vim.api.nvim_create_buf(true, false)

  local buf_name = "workhorse://tree/" .. query_name:gsub("[^%w]", "_")
  local suffix = 1
  local final_name = buf_name
  while vim.fn.bufexists(final_name) == 1 do
    final_name = buf_name .. "_" .. suffix
    suffix = suffix + 1
  end
  vim.api.nvim_buf_set_name(bufnr, final_name)

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].filetype = "workhorse"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"

  vim.b[bufnr].workhorse = {
    query_id = query_id,
    query_name = query_name,
  }

  local nodes, parent_by_id, levels = build_tree(relations, work_items)
  local level_types = infer_level_types(nodes)

  buffers[bufnr] = {
    query_id = query_id,
    query_name = query_name,
    original_items = vim.deepcopy(work_items),
    work_items = work_items,
    parent_by_id = parent_by_id,
    levels = levels,
    level_types = level_types,
    column_overrides = {},
    nodes = nodes,
    column_order = nil,
    column_definitions = nil,
  }

  -- Fetch board columns and render with grouping
  local cfg = config.get()
  local board_name = cfg.default_board or "Stories"

  boards.get_columns(board_name, function(data, err)
    if err then
      -- Fallback to regular rendering without column grouping
      local lines, line_map = render.render(nodes)
      buffers[bufnr].line_map = line_map
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      render.apply_column_virtual_text(bufnr, line_map, buffers[bufnr].column_overrides, cfg.column_colors, buffers[bufnr].original_items)
      render.apply_indent_highlights(bufnr, line_map, cfg.tree_indent_hl)
      render.apply_column_line_highlights(bufnr, line_map, buffers[bufnr].column_overrides, cfg.column_colors)
      render.apply_tag_title_highlights(bufnr, line_map)
      render.apply_type_decorations(bufnr, line_map)
    else
      buffers[bufnr].column_order = data.order or {}
      buffers[bufnr].column_definitions = data.columns or {}

      local lines, line_map = render.render_grouped_by_column(nodes, data.order, parent_by_id)
      buffers[bufnr].line_map = line_map

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      render.apply_column_virtual_text(bufnr, line_map, buffers[bufnr].column_overrides, cfg.column_colors, buffers[bufnr].original_items)
      render.apply_indent_highlights(bufnr, line_map, cfg.tree_indent_hl)
      render.apply_column_line_highlights(bufnr, line_map, buffers[bufnr].column_overrides, cfg.column_colors)
      render.apply_header_highlights(bufnr, line_map, cfg.column_colors)
      render.apply_tag_title_highlights(bufnr, line_map)
      render.apply_type_decorations(bufnr, line_map)
    end
    vim.bo[bufnr].modified = false
  end)

  M.setup_autocmds(bufnr)
  M.setup_keymaps(bufnr)

  return bufnr
end

function M.setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_tree_buffer_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.on_unload(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.update_virtual_text(bufnr)
    end,
  })
end

function M.setup_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true }

  vim.keymap.set("n", "<leader><leader>", function()
    require("workhorse").apply()
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    require("workhorse").open_description()
  end, opts)

  vim.keymap.set("n", "<leader>ws", function()
    show_column_menu(bufnr)
  end, opts)

  vim.keymap.set("n", "<leader>R", function()
    require("workhorse").refresh()
  end, opts)

  vim.keymap.set("n", "gw", function()
    M.open_in_browser(bufnr)
  end, opts)
end

function M.get_state(bufnr)
  return buffers[bufnr]
end

function M.is_tree_buffer(bufnr)
  return buffers[bufnr] ~= nil
end

function M.get_current()
  local bufnr = vim.api.nvim_get_current_buf()
  if M.is_tree_buffer(bufnr) then
    return bufnr, buffers[bufnr]
  end
  return nil, nil
end

local function show_confirm(changes, on_confirm, on_cancel)
  local side_panels = require("workhorse.buffer.side_panels")
  local formatted = changes_mod.format_for_display(changes)
  local desc_changes = side_panels.get_pending_description_changes()
  for _, desc_change in ipairs(desc_changes) do
    table.insert(formatted, "  ~ #" .. desc_change.id .. ": description updated")
  end
  local tag_changes = side_panels.get_pending_tag_changes()
  for _, tag_change in ipairs(tag_changes) do
    table.insert(formatted, "  ~ #" .. tag_change.id .. ": tags updated")
  end

  if #formatted == 0 then
    if on_confirm then
      on_confirm()
    end
    return
  end

  vim.notify("Pending changes:\n" .. table.concat(formatted, "\n"), vim.log.levels.INFO)

  vim.ui.select({ "Yes - Apply changes", "No - Cancel" }, {
    prompt = "Apply changes?",
  }, function(choice)
    if choice and choice:match("^Yes") then
      if on_confirm then
        on_confirm()
      end
    else
      if on_cancel then
        on_cancel()
      end
    end
  end)
end

function M.on_write(bufnr)
  local state = buffers[bufnr]
  local side_panels = require("workhorse.buffer.side_panels")
  local cfg = config.get()

  if not state then
    vim.notify("Workhorse: Buffer state not found", vim.log.levels.ERROR)
    return
  end

  -- Use section-aware parsing if we have column grouping
  local current_items
  if state.column_order then
    current_items = parser.parse_buffer_with_sections(bufnr)
  else
    current_items = parser.parse_buffer(bufnr)
  end
  local changes, errors = changes_mod.detect(state, current_items, state.column_overrides, state.column_order, state.column_definitions)

  local has_panel_changes = side_panels.has_pending_changes()

  if #errors > 0 then
    vim.notify("Workhorse: Fix errors before applying:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end

  if #changes == 0 and not has_panel_changes then
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    vim.bo[bufnr].modified = false
    return
  end

  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      local level_type = state.level_types and state.level_types[change.level]
      if not level_type then
        -- Fall back to hierarchy config
        local hierarchy = cfg.work_item_type_hierarchy or {}
        level_type = hierarchy[change.level + 1] -- Lua is 1-indexed
      end
      change.item_type = level_type or cfg.default_work_item_type
      -- Check if parent is missing (neither existing ID nor new item line)
      if change.level > 0 and not change.parent_id and not change.parent_line_number then
        table.insert(errors, "Missing parent for new item: " .. change.title)
      end
    end
  end

  if #errors > 0 then
    vim.notify("Workhorse: Fix errors before applying:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end

  local function proceed_with_changes(area_path)
    if cfg.confirm_changes then
      show_confirm(changes, function()
        M.apply_changes(bufnr, changes, area_path)
      end)
    else
      M.apply_changes(bufnr, changes, area_path)
    end
  end

  local has_new = false
  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      has_new = true
      break
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
        vim.notify("Workhorse: Area selection cancelled", vim.log.levels.INFO)
      end)
    end
  else
    proceed_with_changes(nil)
  end
end

-- Get the required state for a column based on work item type and column definitions
local function get_state_for_column(column_name, work_item_type, column_definitions)
  if not column_definitions then
    return nil
  end
  for _, col in ipairs(column_definitions) do
    if col.name == column_name and col.stateMappings then
      return col.stateMappings[work_item_type]
    end
  end
  return nil
end

function M.apply_changes(bufnr, changes, area_path)
  local state = buffers[bufnr]
  local workitems = require("workhorse.api.workitems")
  local side_panels = require("workhorse.buffer.side_panels")
  local cfg = config.get()

  local desc_changes = side_panels.get_pending_description_changes()
  local tag_changes = side_panels.get_pending_tag_changes()

  -- Separate CREATED changes from others
  local created_changes = {}
  local other_changes = {}
  for _, change in ipairs(changes) do
    if change.type == changes_mod.ChangeType.CREATED then
      table.insert(created_changes, change)
    else
      table.insert(other_changes, change)
    end
  end

  -- Sort CREATED changes by level (lowest first) so parents are created before children
  table.sort(created_changes, function(a, b)
    return (a.level or 0) < (b.level or 0)
  end)

  local total = #changes + #desc_changes + #tag_changes
  local completed = 0
  local errors = {}

  -- Track created item IDs by their line number (for resolving parent chains)
  local created_ids_by_line = {}

  local function on_complete()
    completed = completed + 1
    if completed == total then
      if #errors > 0 then
        vim.notify(
          "Workhorse: " .. (total - #errors) .. "/" .. total .. " changes applied.\nErrors:\n" .. table.concat(errors, "\n"),
          vim.log.levels.WARN
        )
      else
        vim.notify("Workhorse: " .. total .. " changes applied", vim.log.levels.INFO)
      end

      require("workhorse").refresh()
    end
  end

  if total == 0 then
    vim.notify("Workhorse: No changes to apply", vim.log.levels.INFO)
    return
  end

  -- Process description changes in parallel
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

  -- Process tag changes in parallel
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

  -- Process CREATED changes sequentially by level
  local function process_created(index)
    if index > #created_changes then
      -- All created items processed, now process other changes in parallel
      for _, change in ipairs(other_changes) do
        if change.type == changes_mod.ChangeType.UPDATED then
          workitems.update_title(change.id, change.title, function(item, err)
            if err then
              table.insert(errors, "Update #" .. change.id .. " failed: " .. (err or "unknown error"))
            end
            on_complete()
          end)
        elseif change.type == changes_mod.ChangeType.DELETED then
          workitems.soft_delete(change.id, function(item, err)
            if err then
              table.insert(errors, "Delete #" .. change.id .. " failed: " .. (err or "unknown error"))
            end
            on_complete()
          end)
        elseif change.type == changes_mod.ChangeType.COLUMN_CHANGED then
          local work_item_type = change.work_item and change.work_item.type
          local state_for_col = get_state_for_column(change.new_column, work_item_type, state.column_definitions)
          workitems.update_board_column(change.id, change.new_column, function(item, err)
            if err then
              table.insert(errors, "Column change #" .. change.id .. " failed: " .. (err or "unknown error"))
            end
            on_complete()
          end, state_for_col)
        elseif change.type == changes_mod.ChangeType.PARENT_CHANGED then
          workitems.update_parent(change.id, change.new_parent, function(item, err)
            if err then
              table.insert(errors, "Parent change #" .. change.id .. " failed: " .. (err or "unknown error"))
            end
            on_complete()
          end)
        elseif change.type == changes_mod.ChangeType.STACK_RANK_CHANGED then
          workitems.update_stack_rank(change.id, change.new_rank, function(item, err)
            if err then
              table.insert(errors, "Stack rank #" .. change.id .. " failed: " .. (err or "unknown error"))
            end
            on_complete()
          end)
        end
      end
      return
    end

    local change = created_changes[index]
    local create_opts = {
      title = change.title,
      type = change.item_type or cfg.default_work_item_type,
      area_path = area_path,
    }

    workitems.create(create_opts, function(item, err)
      if err then
        table.insert(errors, "Create failed: " .. (err or "unknown error"))
        on_complete()
        process_created(index + 1)
        return
      end

      -- Track the created ID by line number for child resolution
      created_ids_by_line[change.line_number] = item.id

      -- Resolve parent ID: use existing parent_id, or look up from created items
      local parent_id = change.parent_id
      if not parent_id and change.parent_line_number then
        parent_id = created_ids_by_line[change.parent_line_number]
      end

      if parent_id then
        workitems.update_parent(item.id, parent_id, function(_, parent_err)
          if parent_err then
            table.insert(errors, "Parent update #" .. item.id .. " failed: " .. (parent_err or "unknown error"))
          end
          on_complete()
          process_created(index + 1)
        end)
      else
        on_complete()
        process_created(index + 1)
      end
    end)
  end

  -- Start processing created items (or jump directly to other changes if none)
  process_created(1)
end

function M.refresh_buffer(bufnr, work_items, relations)
  local buf_state = buffers[bufnr]
  if not buf_state then
    return
  end

  local nodes, parent_by_id, levels = build_tree(relations or {}, work_items or {})
  local level_types = infer_level_types(nodes)

  buf_state.original_items = vim.deepcopy(work_items)
  buf_state.work_items = work_items
  buf_state.parent_by_id = parent_by_id
  buf_state.levels = levels
  buf_state.level_types = level_types
  buf_state.column_overrides = {}
  buf_state.nodes = nodes

  local cfg = config.get()

  -- Use column-grouped rendering if we have column info
  if buf_state.column_order then
    local lines, line_map = render.render_grouped_by_column(nodes, buf_state.column_order, parent_by_id)
    buf_state.line_map = line_map
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    render.apply_column_virtual_text(bufnr, line_map, buf_state.column_overrides, cfg.column_colors, buf_state.original_items)
    render.apply_indent_highlights(bufnr, line_map, cfg.tree_indent_hl)
    render.apply_column_line_highlights(bufnr, line_map, buf_state.column_overrides, cfg.column_colors)
    render.apply_header_highlights(bufnr, line_map, cfg.column_colors)
    render.apply_tag_title_highlights(bufnr, line_map)
    render.apply_type_decorations(bufnr, line_map)
  else
    local lines, line_map = render.render(nodes)
    buf_state.line_map = line_map
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    render.apply_column_virtual_text(bufnr, line_map, buf_state.column_overrides, cfg.column_colors, buf_state.original_items)
    render.apply_indent_highlights(bufnr, line_map, cfg.tree_indent_hl)
    render.apply_column_line_highlights(bufnr, line_map, buf_state.column_overrides, cfg.column_colors)
    render.apply_tag_title_highlights(bufnr, line_map)
    render.apply_type_decorations(bufnr, line_map)
  end

  vim.bo[bufnr].modified = false
end

function M.update_virtual_text(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end

  local by_id = {}
  for _, item in ipairs(state.work_items or {}) do
    by_id[item.id] = item
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line_map = {}
  local current_section = nil

  for i, line in ipairs(lines) do
    local header = parser.parse_header(line)
    if header then
      current_section = header
      line_map[i] = { type = "header", section = header }
    else
      local parsed = parser.parse_line(line)
      if parsed and parsed.id then
        local item = by_id[parsed.id] or { id = parsed.id, board_column = "" }
        local prefix_len = render.get_prefix_len(parsed.level)
        line_map[i] = {
          type = "item",
          item = item,
          level = parsed.level,
          prefix_len = prefix_len,
          section = current_section,
        }
      end
    end
  end

  state.line_map = line_map

  local cfg = config.get()
  render.apply_column_virtual_text(bufnr, line_map, state.column_overrides, cfg.column_colors, state.original_items)
  render.apply_indent_highlights(bufnr, line_map, cfg.tree_indent_hl)
  render.apply_column_line_highlights(bufnr, line_map, state.column_overrides, cfg.column_colors)
  render.apply_tag_title_highlights(bufnr, line_map)
  render.apply_type_decorations(bufnr, line_map)
  if state.column_order then
    render.apply_header_highlights(bufnr, line_map, cfg.column_colors)
  end
end

function M.on_unload(bufnr)
  buffers[bufnr] = nil
end

function M.open_in_browser(bufnr)
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local item = parser.parse_line(vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1])
  local id = item and item.id or nil

  if not id then
    vim.notify("Workhorse: No work item on this line", vim.log.levels.WARN)
    return
  end

  local cfg = config.get()
  local url = cfg.server_url .. "/" .. cfg.project .. "/_workitems/edit/" .. id

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

function M.get_item_at_cursor(bufnr)
  local state = buffers[bufnr]
  if not state then
    return nil
  end

  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  local parsed = parser.parse_line(vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1])
  if not parsed or not parsed.id then
    return nil
  end

  for _, item in ipairs(state.work_items) do
    if item.id == parsed.id then
      return item, line_num
    end
  end

  return nil
end

return M
