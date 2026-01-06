local M = {}

-- Change types
M.ChangeType = {
  CREATED = "created",
  UPDATED = "updated",
  DELETED = "deleted",
}

-- Normalize title for comparison (trim whitespace, normalize internal spaces)
local function normalize_title(title)
  if not title then
    return ""
  end
  -- Trim leading/trailing whitespace and normalize internal whitespace
  return vim.trim(title):gsub("%s+", " ")
end

-- Check if two titles are equal (after normalization)
local function titles_equal(a, b)
  return normalize_title(a) == normalize_title(b)
end

-- Detect changes between original work items and current buffer state
-- Returns array of change records:
-- { type, id, title, old_title, work_item }
function M.detect(original_items, current_items)
  local changes = {}

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
        })
      end
    end
  end

  -- Check for updates and deletions
  for _, orig in ipairs(original_items) do
    local current = current_by_id[orig.id]
    if not current then
      -- Line was deleted (soft delete)
      table.insert(changes, {
        type = M.ChangeType.DELETED,
        id = orig.id,
        title = orig.title,
        work_item = orig,
      })
    elseif not titles_equal(current.title, orig.title) then
      -- Title was actually changed (after normalization)
      table.insert(changes, {
        type = M.ChangeType.UPDATED,
        id = orig.id,
        title = normalize_title(current.title),
        old_title = orig.title,
        line_number = current.line_number,
        work_item = orig,
      })
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
      table.insert(lines, "  + [NEW] " .. change.title)
    elseif change.type == M.ChangeType.UPDATED then
      table.insert(lines, "  ~ #" .. change.id .. ": " .. change.old_title)
      table.insert(lines, "      -> " .. change.title)
    elseif change.type == M.ChangeType.DELETED then
      table.insert(lines, "  - #" .. change.id .. " -> Removed")
    end
  end

  return lines
end

return M
