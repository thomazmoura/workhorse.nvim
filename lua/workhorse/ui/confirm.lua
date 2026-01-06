local M = {}

local changes_mod = require("workhorse.buffer.changes")

-- Show confirmation dialog for pending changes using vim.ui.select
function M.show(changes, on_confirm, on_cancel)
  -- Build description of changes
  local formatted = changes_mod.format_for_display(changes)
  local description = table.concat(formatted, "\n")

  -- Count changes by type
  local created = 0
  local updated = 0
  local deleted = 0
  for _, change in ipairs(changes) do
    if change.type == "created" then
      created = created + 1
    elseif change.type == "updated" then
      updated = updated + 1
    elseif change.type == "deleted" then
      deleted = deleted + 1
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
