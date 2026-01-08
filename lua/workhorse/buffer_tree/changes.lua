local M = {}

M.ChangeType = {
  CREATED = "created",
  UPDATED = "updated",
  DELETED = "deleted",
  COLUMN_CHANGED = "column_changed",
  PARENT_CHANGED = "parent_changed",
  STACK_RANK_CHANGED = "stack_rank_changed",
}

local function normalize_title(title)
  if not title then
    return ""
  end
  return vim.trim(title):gsub("%s+", " ")
end

local function titles_equal(a, b)
  return normalize_title(a) == normalize_title(b)
end

local function to_number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

local function is_unknown_column(column)
  return column == nil or column == "" or column == "Unknown"
end

local function is_closed_column(column, column_definitions)
  if not column or not column_definitions then
    return false
  end
  for _, col in ipairs(column_definitions) do
    if col.name == column then
      for _, state in pairs(col.stateMappings or {}) do
        if state == "Closed" then
          return true
        end
      end
      break
    end
  end
  return false
end

-- Longest Common Subsequence - returns set of items in LCS
local function lcs_set(a, b)
  local n = #a
  local m = #b
  local dp = {}
  for i = 0, n do
    dp[i] = {}
    for j = 0, m do
      dp[i][j] = 0
    end
  end

  for i = 1, n do
    for j = 1, m do
      if a[i] == b[j] then
        dp[i][j] = dp[i - 1][j - 1] + 1
      else
        dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
      end
    end
  end

  local i = n
  local j = m
  local set = {}
  while i > 0 and j > 0 do
    if a[i] == b[j] then
      set[a[i]] = true
      i = i - 1
      j = j - 1
    elseif dp[i - 1][j] >= dp[i][j - 1] then
      i = i - 1
    else
      j = j - 1
    end
  end

  return set
end

-- Calculate new stack ranks for moved items using interpolation
local function calculate_new_ranks(items, moved_set, original_by_id, fixed_positions)
  local step = 1000
  local assigned = {}
  local i = 1

  while i <= #items do
    local item = items[i]
    if moved_set[item.id] then
      local start = i
      while i <= #items and moved_set[items[i].id] do
        i = i + 1
      end
      local finish = i - 1

      local prev_rank = nil
      for p = start - 1, 1, -1 do
        if fixed_positions[p] then
          prev_rank = fixed_positions[p]
          break
        end
      end
      local next_rank = nil
      for n = finish + 1, #items do
        if fixed_positions[n] then
          next_rank = fixed_positions[n]
          break
        end
      end

      local count = finish - start + 1
      if prev_rank and next_rank then
        local span = next_rank - prev_rank
        local inc = span / (count + 1)
        for offset = 1, count do
          local idx = start + offset - 1
          assigned[idx] = prev_rank + inc * offset
        end
      elseif prev_rank then
        for offset = 1, count do
          local idx = start + offset - 1
          assigned[idx] = prev_rank + step * offset
        end
      elseif next_rank then
        for offset = 1, count do
          local idx = finish - offset + 1
          assigned[idx] = next_rank - step * offset
        end
      else
        for offset = 1, count do
          local idx = start + offset - 1
          assigned[idx] = step * offset
        end
      end
    else
      local orig = original_by_id[item.id]
      assigned[i] = orig and to_number(orig.stack_rank) or nil
      i = i + 1
    end
  end

  return assigned
end

-- Detect stack rank changes for a group of items (used for both roots and siblings)
local function detect_rank_changes_for_group(current_items, original_items_sorted, original_by_id, changes)
  if #current_items <= 1 then
    return
  end

  -- Sort current by line_number
  table.sort(current_items, function(a, b)
    return a.line_number < b.line_number
  end)

  local current_order = {}
  for _, item in ipairs(current_items) do
    if item.id then
      table.insert(current_order, item.id)
    end
  end

  local original_order = {}
  for _, orig in ipairs(original_items_sorted) do
    table.insert(original_order, orig.id)
  end

  -- Check if order changed
  local order_changed = #current_order ~= #original_order
  if not order_changed then
    for idx, id in ipairs(current_order) do
      if original_order[idx] ~= id then
        order_changed = true
        break
      end
    end
  end

  if not order_changed then
    return
  end

  -- Find moved items using LCS
  local moved_set = {}
  local lcs = lcs_set(original_order, current_order)
  for _, id in ipairs(current_order) do
    if not lcs[id] then
      moved_set[id] = true
    end
  end

  -- Build fixed positions and ranks
  local fixed_positions = {}
  for idx, item in ipairs(current_items) do
    if item.id and not moved_set[item.id] then
      local orig = original_by_id[item.id]
      local rank = orig and to_number(orig.stack_rank)
      if rank then
        fixed_positions[idx] = rank
      end
    end
  end

  -- Calculate new ranks
  local assigned = calculate_new_ranks(current_items, moved_set, original_by_id, fixed_positions)

  -- Create changes for moved items
  for idx, item in ipairs(current_items) do
    if item.id and moved_set[item.id] then
      local orig = original_by_id[item.id]
      local new_rank = assigned[idx]
      if orig and new_rank and to_number(orig.stack_rank) ~= new_rank then
        table.insert(changes, {
          type = M.ChangeType.STACK_RANK_CHANGED,
          id = item.id,
          title = orig.title,
          old_rank = orig.stack_rank,
          new_rank = new_rank,
          line_number = item.line_number,
          work_item = orig,
        })
      end
    end
  end
end

local function compute_parent_map(items)
  local parents_by_id = {}
  local parents_by_line = {}
  local last_at_level = {} -- Now stores { id = ..., line_number = ... }
  local errors = {}

  for _, item in ipairs(items) do
    local level = item.level or 0
    if level == 0 then
      if item.id then
        parents_by_id[item.id] = nil
      end
      parents_by_line[item.line_number] = nil
    else
      local parent_ref = last_at_level[level - 1]
      if not parent_ref then
        table.insert(errors, "No parent found for line " .. item.line_number)
      else
        -- Use parent's ID if available
        local parent_id = parent_ref.id
        if item.id then
          parents_by_id[item.id] = parent_id
        end
        -- Store full ref for resolving parent chains of new items
        parents_by_line[item.line_number] = parent_ref
      end
    end
    -- Track both id and line_number for each level
    last_at_level[level] = { id = item.id, line_number = item.line_number }
  end

  return parents_by_id, parents_by_line, errors
end

-- Detect changes in tree buffer
-- state: buffer state with original_items, levels, parent_by_id
-- current_items: parsed items from buffer (with current_section if using column grouping)
-- column_overrides: manual column changes from menu
-- available_sections: list of rendered sections (for grouped mode)
-- column_definitions: board column metadata (for closed column detection)
function M.detect(state, current_items, column_overrides, available_sections, column_definitions)
  local changes = {}
  local errors = {}

  local original_by_id = {}
  for _, item in ipairs(state.original_items or {}) do
    original_by_id[item.id] = item
  end

  local current_by_id = {}
  for _, item in ipairs(current_items or {}) do
    if item.id then
      current_by_id[item.id] = item
    else
      local title = normalize_title(item.title)
      if title ~= "" then
        table.insert(changes, {
          type = M.ChangeType.CREATED,
          title = title,
          line_number = item.line_number,
          level = item.level or 0,
          parent_id = nil,
          work_item = nil,
          new_section = item.current_section,
        })
      end
    end
  end

  local parent_map, parent_map_by_line, parent_errors = compute_parent_map(current_items)
  for _, err in ipairs(parent_errors) do
    table.insert(errors, err)
  end

  for _, item in ipairs(current_items or {}) do
    if item.id and state.levels and state.levels[item.id] ~= nil then
      local original_level = state.levels[item.id]
      if original_level ~= item.level then
        table.insert(errors, "Indentation change not allowed for #" .. item.id)
      end
    end
  end

  for _, change in ipairs(changes) do
    if change.type == M.ChangeType.CREATED then
      if change.level and change.level > 0 then
        local parent_ref = parent_map_by_line[change.line_number]
        if parent_ref then
          change.parent_id = parent_ref.id -- May be nil if parent is also new
          change.parent_line_number = parent_ref.line_number -- For resolving chains
        end
      end
    end
  end

  for _, orig in ipairs(state.original_items or {}) do
    local current = current_by_id[orig.id]
    if not current then
      table.insert(changes, {
        type = M.ChangeType.DELETED,
        id = orig.id,
        title = orig.title,
        work_item = orig,
      })
    else
      if not titles_equal(current.title, orig.title) then
        table.insert(changes, {
          type = M.ChangeType.UPDATED,
          id = orig.id,
          title = normalize_title(current.title),
          old_title = orig.title,
          line_number = current.line_number,
          work_item = orig,
        })
      end

      local new_parent = parent_map[orig.id]
      local old_parent = state.parent_by_id and state.parent_by_id[orig.id] or nil
      if new_parent ~= old_parent then
        table.insert(changes, {
          type = M.ChangeType.PARENT_CHANGED,
          id = orig.id,
          title = orig.title,
          old_parent = old_parent,
          new_parent = new_parent,
          line_number = current.line_number,
          work_item = orig,
        })
      end

      -- Check column change for level-0 items (from section headers)
      local orig_level = state.levels and state.levels[orig.id]
      if orig_level == 0 and current.current_section then
        local new_col = current.current_section
        local old_col = orig.board_column
        local both_unknown = is_unknown_column(new_col) and is_unknown_column(old_col)
        if not both_unknown and new_col ~= old_col then
          table.insert(changes, {
            type = M.ChangeType.COLUMN_CHANGED,
            id = orig.id,
            title = orig.title,
            old_column = old_col,
            new_column = new_col,
            line_number = current.line_number,
            work_item = orig,
          })
        end
      end
    end
  end

  -- Manual column overrides (from menu)
  for id, new_column in pairs(column_overrides or {}) do
    local orig = original_by_id[id]
    if orig and current_by_id[id] and orig.board_column ~= new_column then
      -- Check if we already have a column change from section
      local already_changed = false
      for _, change in ipairs(changes) do
        if change.type == M.ChangeType.COLUMN_CHANGED and change.id == id then
          already_changed = true
          break
        end
      end
      if not already_changed then
        table.insert(changes, {
          type = M.ChangeType.COLUMN_CHANGED,
          id = id,
          title = orig.title,
          old_column = orig.board_column,
          new_column = new_column,
          work_item = orig,
        })
      end
    end
  end

  -- Detect stack rank changes for level-0 items within each column
  if available_sections then
    for _, section in ipairs(available_sections) do
      if not is_unknown_column(section) and not is_closed_column(section, column_definitions) then
        -- Get current level-0 items in this section
        local current_in_section = {}
        for _, item in ipairs(current_items) do
          if item.id and item.level == 0 and item.current_section == section then
            table.insert(current_in_section, item)
          end
        end

        -- Get original level-0 items in this section, sorted by stack_rank
        local original_in_section = {}
        for _, orig in ipairs(state.original_items or {}) do
          local orig_level = state.levels and state.levels[orig.id]
          if orig_level == 0 and orig.board_column == section then
            table.insert(original_in_section, orig)
          end
        end
        table.sort(original_in_section, function(a, b)
          local rank_a = a.stack_rank or math.huge
          local rank_b = b.stack_rank or math.huge
          if rank_a == rank_b then
            return (a.id or 0) < (b.id or 0)
          end
          return rank_a < rank_b
        end)

        detect_rank_changes_for_group(current_in_section, original_in_section, original_by_id, changes)
      end
    end
  end

  -- Detect stack rank changes for siblings (same parent)
  local children_by_parent = {}
  for _, item in ipairs(current_items) do
    if item.id and item.level > 0 then
      local parent_id = parent_map[item.id]
      if parent_id then
        children_by_parent[parent_id] = children_by_parent[parent_id] or {}
        table.insert(children_by_parent[parent_id], item)
      end
    end
  end

  for parent_id, current_children in pairs(children_by_parent) do
    -- Get original children sorted by stack_rank
    local original_children = {}
    for _, orig in ipairs(state.original_items or {}) do
      local orig_parent = state.parent_by_id and state.parent_by_id[orig.id]
      if orig_parent == parent_id then
        table.insert(original_children, orig)
      end
    end
    table.sort(original_children, function(a, b)
      local rank_a = a.stack_rank or math.huge
      local rank_b = b.stack_rank or math.huge
      if rank_a == rank_b then
        return (a.id or 0) < (b.id or 0)
      end
      return rank_a < rank_b
    end)

    detect_rank_changes_for_group(current_children, original_children, original_by_id, changes)
  end

  return changes, errors
end

function M.format_for_display(changes)
  local lines = {}
  for _, change in ipairs(changes) do
    if change.type == M.ChangeType.CREATED then
      local section_info = change.new_section and (" [" .. change.new_section .. "]") or ""
      table.insert(lines, "  + [NEW] " .. change.title .. section_info)
    elseif change.type == M.ChangeType.UPDATED then
      table.insert(lines, "  ~ #" .. change.id .. ": " .. change.old_title)
      table.insert(lines, "      -> " .. change.title)
    elseif change.type == M.ChangeType.DELETED then
      table.insert(lines, "  - #" .. change.id .. " -> Removed")
    elseif change.type == M.ChangeType.COLUMN_CHANGED then
      local old_col = change.old_column or "Unknown"
      local new_col = change.new_column or "Unknown"
      table.insert(lines, "  → #" .. change.id .. ": " .. old_col .. " -> " .. new_col)
    elseif change.type == M.ChangeType.PARENT_CHANGED then
      table.insert(lines, "  ↳ #" .. change.id .. ": parent changed")
    elseif change.type == M.ChangeType.STACK_RANK_CHANGED then
      table.insert(lines, "  ↕ #" .. change.id .. ": order updated")
    end
  end
  return lines
end

return M
