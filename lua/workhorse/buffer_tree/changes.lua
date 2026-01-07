local M = {}

M.ChangeType = {
  CREATED = "created",
  UPDATED = "updated",
  DELETED = "deleted",
  COLUMN_CHANGED = "column_changed",
  PARENT_CHANGED = "parent_changed",
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

local function compute_parent_map(items)
  local parents_by_id = {}
  local parents_by_line = {}
  local last_at_level = {}
  local errors = {}

  for _, item in ipairs(items) do
    local level = item.level or 0
    if level == 0 then
      if item.id then
        parents_by_id[item.id] = nil
      end
      parents_by_line[item.line_number] = nil
    else
      local parent = last_at_level[level - 1]
      if not parent then
        table.insert(errors, "No parent found for line " .. item.line_number)
      else
        if item.id then
          parents_by_id[item.id] = parent
        end
        parents_by_line[item.line_number] = parent
      end
    end
    last_at_level[level] = item.id
  end

  return parents_by_id, parents_by_line, errors
end

function M.detect(state, current_items, column_overrides)
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
      local parent_id = nil
      if change.level and change.level > 0 then
        parent_id = parent_map_by_line[change.line_number]
      end
      change.parent_id = parent_id
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
    end
  end

  for id, new_column in pairs(column_overrides or {}) do
    local orig = original_by_id[id]
    if orig and current_by_id[id] and orig.board_column ~= new_column then
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

  return changes, errors
end

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
    elseif change.type == M.ChangeType.COLUMN_CHANGED then
      table.insert(lines, "  → #" .. change.id .. ": column -> " .. (change.new_column or ""))
    elseif change.type == M.ChangeType.PARENT_CHANGED then
      table.insert(lines, "  ↳ #" .. change.id .. ": parent changed")
    end
  end
  return lines
end

return M
