local M = {}

local changes_mod = require("workhorse.buffer.changes")

-- Show confirmation dialog for pending changes using vim.ui.select
function M.show(changes, on_confirm, on_cancel)
  local description_mod = require("workhorse.buffer.description")

  -- Build description of changes
  local formatted = changes_mod.format_for_display(changes)

  -- Add description changes
  local desc_changes = description_mod.get_pending_changes()
  for _, desc_change in ipairs(desc_changes) do
    table.insert(formatted, "  ~ #" .. desc_change.id .. ": description updated")
  end

  local description = table.concat(formatted, "\n")

  -- Count changes by type
  local created = 0
  local updated = 0
  local deleted = 0
  local state_changed = 0
  local column_changed = 0
  local order_changed = 0
  local desc_updated = #desc_changes

  for _, change in ipairs(changes) do
    if change.type == "created" then
      created = created + 1
    elseif change.type == "updated" then
      updated = updated + 1
    elseif change.type == "deleted" then
      deleted = deleted + 1
    elseif change.type == "state_changed" then
      state_changed = state_changed + 1
    elseif change.type == "column_changed" then
      column_changed = column_changed + 1
    elseif change.type == "stack_rank_changed" then
      order_changed = order_changed + 1
    end
  end

  -- Build summary
  local summary_parts = {}
  if created > 0 then
    table.insert(summary_parts, created .. " new")
  end
  if updated > 0 then
    table.insert(summary_parts, updated .. " updated")
  end
  if deleted > 0 then
    table.insert(summary_parts, deleted .. " deleted")
  end
  if state_changed > 0 then
    table.insert(summary_parts, state_changed .. " state changes")
  end
  if column_changed > 0 then
    table.insert(summary_parts, column_changed .. " column changes")
  end
  if order_changed > 0 then
    table.insert(summary_parts, order_changed .. " order changes")
  end
  if desc_updated > 0 then
    table.insert(summary_parts, desc_updated .. " description changes")
  end
  local summary = table.concat(summary_parts, ", ")

  -- Show changes in a notification first
  vim.notify("Pending changes:\n" .. description, vim.log.levels.INFO)

  -- Use vim.ui.select for confirmation
  vim.ui.select({ "Yes - Apply changes", "No - Cancel" }, {
    prompt = "Apply " .. summary .. "?",
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

return M
