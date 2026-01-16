local M = {}

-- Change types
M.ChangeType = {
  CREATED = "created",
  UPDATED = "updated",
  DELETED = "deleted",
  STATE_CHANGED = "state_changed",
  COLUMN_CHANGED = "column_changed",
  STACK_RANK_CHANGED = "stack_rank_changed",
}

-- Normalize title for comparison (trim whitespace, normalize internal spaces)
local function normalize_title(title)
  if not title then
    return ""
  end
  -- Trim leading/trailing whitespace and normalize internal whitespace
  return vim.trim(title):gsub("%s+", " ")
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

local function to_number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

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

-- Check if two titles are equal (after normalization)
local function titles_equal(a, b)
  return normalize_title(a) == normalize_title(b)
end

-- Check if a section is in the list of available sections
local function is_section_available(section, available_sections)
  if not available_sections or not section or section == "" then
    return false
  end
  for _, s in ipairs(available_sections) do
    if s == section then
      return true
    end
  end
  return false
end

-- Detect changes between original work items and current buffer state
-- current_items should have current_section field from parse_buffer_with_sections
-- grouping_mode: "state" (default) or "board_column"
-- available_sections: list of sections that are rendered (used to avoid false deletions)
-- column_definitions: board column metadata (used for state-mapped column rules)
-- Returns array of change records:
-- { type, id, title, old_title, work_item, new_state, old_state, new_column, old_column }
function M.detect(original_items, current_items, grouping_mode, available_sections, column_definitions)
  local changes = {}
  grouping_mode = grouping_mode or "state"

  -- Build lookup of original items by ID
  local original_by_id = {}
  for _, item in ipairs(original_items) do
    original_by_id[item.id] = item
  end

  -- Build lookup of current items by ID
  local current_by_id = {}
  for _, item in ipairs(current_items) do
    if item.id then
      current_by_id[item.id] = item
    else
      -- New item (no ID) - only if title is not empty
      local title = normalize_title(item.title)
      if title ~= "" then
        local change = {
          type = M.ChangeType.CREATED,
          title = title,
          line_number = item.line_number,
        }
        -- In board_column mode, section is a column, not a state
        if grouping_mode == "board_column" then
          change.new_column = item.current_section
        else
          change.new_state = item.current_section
        end
        table.insert(changes, change)
      end
    end
  end

  -- Check for updates, deletions, and state/column changes
  for _, orig in ipairs(original_items) do
    local current = current_by_id[orig.id]
    if not current then
      -- Check if the item was actually rendered (has a valid section)
      local orig_section = grouping_mode == "board_column" and orig.board_column or orig.state
      local was_rendered = is_section_available(orig_section, available_sections)

      -- Only mark as deleted if it was rendered (otherwise it was just not displayed)
      if was_rendered then
        table.insert(changes, {
          type = M.ChangeType.DELETED,
          id = orig.id,
          title = orig.title,
          work_item = orig,
        })
      end
    else
      -- Check for title change
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

      -- Check for section change (moved to different section)
      if grouping_mode == "board_column" then
        -- Compare against original board_column
        local new_col = current.current_section
        local old_col = orig.board_column
        local both_unknown = is_unknown_column(new_col) and is_unknown_column(old_col)
        if new_col and not both_unknown and new_col ~= old_col then
          table.insert(changes, {
            type = M.ChangeType.COLUMN_CHANGED,
            id = orig.id,
            title = orig.title,
            old_column = old_col,
            new_column = new_col,
            line_number = current.line_number,
            work_item = orig,
            -- Include area_path and type for WEF field resolution
            area_path = orig.area_path,
            work_item_type = orig.type,
          })
        end
      else
        -- Compare against original state
        if current.current_section and current.current_section ~= orig.state then
          table.insert(changes, {
            type = M.ChangeType.STATE_CHANGED,
            id = orig.id,
            title = orig.title,
            old_state = orig.state,
            new_state = current.current_section,
            line_number = current.line_number,
            work_item = orig,
          })
        end
      end
    end
  end

  if grouping_mode == "board_column" then
    local sections = {}
    for _, item in ipairs(current_items) do
      if item.id
        and is_section_available(item.current_section, available_sections)
        and not is_unknown_column(item.current_section)
        and not is_closed_column(item.current_section, column_definitions) then
        sections[item.current_section] = sections[item.current_section] or {}
        table.insert(sections[item.current_section], item)
      end
    end

    for _, items in pairs(sections) do
      table.sort(items, function(a, b)
        return a.line_number < b.line_number
      end)

      local current_order = {}
      for _, item in ipairs(items) do
        table.insert(current_order, item.id)
      end

      local original_order = {}
      local original_items_in_section = {}
      for _, orig in ipairs(original_items) do
        if orig.board_column == items[1].current_section
          and not is_unknown_column(orig.board_column)
          and is_section_available(orig.board_column, available_sections) then
          table.insert(original_items_in_section, orig)
        end
      end
      table.sort(original_items_in_section, function(a, b)
        local rank_a = a.stack_rank or math.huge
        local rank_b = b.stack_rank or math.huge
        if rank_a == rank_b then
          return (a.id or 0) < (b.id or 0)
        end
        return rank_a < rank_b
      end)
      for _, orig in ipairs(original_items_in_section) do
        table.insert(original_order, orig.id)
      end

      local order_changed = #current_order ~= #original_order
      if not order_changed then
        for idx, id in ipairs(current_order) do
          if original_order[idx] ~= id then
            order_changed = true
            break
          end
        end
      end

      if order_changed and #items > 1 then
        local moved_set = {}
        local lcs = lcs_set(original_order, current_order)
        for _, id in ipairs(current_order) do
          if not lcs[id] then
            moved_set[id] = true
          end
        end

        local fixed_ranks = {}
        local fixed_positions = {}
        for idx, item in ipairs(items) do
          if not moved_set[item.id] then
            local orig = original_by_id[item.id]
            local rank = orig and to_number(orig.stack_rank)
            if rank then
              fixed_ranks[item.id] = rank
              fixed_positions[idx] = rank
            end
          end
        end

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

        for idx, item in ipairs(items) do
          if moved_set[item.id] then
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
    end
  end

  return changes
end

-- Check if there are any changes
function M.has_changes(original_items, current_items)
  local changes = M.detect(original_items, current_items)
  return #changes > 0
end

-- Group changes by type
function M.group_by_type(changes)
  local grouped = {
    created = {},
    updated = {},
    deleted = {},
    state_changed = {},
    column_changed = {},
    stack_rank_changed = {},
  }

  for _, change in ipairs(changes) do
    table.insert(grouped[change.type], change)
  end

  return grouped
end

-- Format changes for display
function M.format_for_display(changes)
  local lines = {}

  for _, change in ipairs(changes) do
    if change.type == M.ChangeType.CREATED then
      local section_info = ""
      if change.new_state then
        section_info = " [" .. change.new_state .. "]"
      elseif change.new_column then
        section_info = " [" .. change.new_column .. "]"
      end
      table.insert(lines, "  + [NEW] " .. change.title .. section_info)
    elseif change.type == M.ChangeType.UPDATED then
      table.insert(lines, "  ~ #" .. change.id .. ": " .. change.old_title)
      table.insert(lines, "      -> " .. change.title)
    elseif change.type == M.ChangeType.DELETED then
      table.insert(lines, "  - #" .. change.id .. " -> Removed")
    elseif change.type == M.ChangeType.STATE_CHANGED then
      table.insert(lines, "  → #" .. change.id .. ": " .. change.old_state .. " -> " .. change.new_state)
    elseif change.type == M.ChangeType.COLUMN_CHANGED then
      local old_col = change.old_column or "Unknown"
      local new_col = change.new_column or "Unknown"
      table.insert(lines, "  → #" .. change.id .. ": " .. old_col .. " -> " .. new_col)
    elseif change.type == M.ChangeType.STACK_RANK_CHANGED then
      table.insert(lines, "  ↕ #" .. change.id .. ": order updated")
    end
  end

  return lines
end

-- Get pending column changes as maps of line_num -> column
-- Returns: pending_moves (line_num -> new_column), original_columns (line_num -> original_column)
-- Used for showing virtual text markers
function M.get_pending_moves(original_items, current_items)
  local pending = {}
  local original_columns = {}

  -- Build lookup of original items by ID
  local original_by_id = {}
  for _, item in ipairs(original_items) do
    original_by_id[item.id] = item
  end

  for _, current in ipairs(current_items) do
    if current.id and current.current_section then
      local orig = original_by_id[current.id]
      if orig and orig.board_column ~= current.current_section then
        pending[current.line_number] = current.current_section
        original_columns[current.line_number] = orig.board_column
      end
    end
  end

  return pending, original_columns
end

return M
