local M = {}

-- Change types
M.ChangeType = {
  CREATED = "created",
  UPDATED = "updated",
  DELETED = "deleted",
  STATE_CHANGED = "state_changed",
  COLUMN_CHANGED = "column_changed",
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
-- Returns array of change records:
-- { type, id, title, old_title, work_item, new_state, old_state, new_column, old_column }
function M.detect(original_items, current_items, grouping_mode, available_sections)
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
        table.insert(changes, {
          type = M.ChangeType.CREATED,
          title = title,
          line_number = item.line_number,
          new_state = item.current_section,  -- Section where it was added
        })
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
      local state_info = change.new_state and (" [" .. change.new_state .. "]") or ""
      table.insert(lines, "  + [NEW] " .. change.title .. state_info)
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
    end
  end

  return lines
end

-- Get pending state changes as a map of line_num -> new_state
-- Used for showing virtual text markers
function M.get_pending_moves(original_items, current_items)
  local pending = {}

  -- Build lookup of original items by ID
  local original_by_id = {}
  for _, item in ipairs(original_items) do
    original_by_id[item.id] = item
  end

  for _, current in ipairs(current_items) do
    if current.id and current.current_state then
      local orig = original_by_id[current.id]
      if orig and orig.state ~= current.current_state then
        pending[current.line_number] = current.current_state
      end
    end
  end

  return pending
end

return M
