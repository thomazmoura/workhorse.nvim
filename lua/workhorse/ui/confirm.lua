-- Confirmation of the pending changes of a query buffer: a float listing them, answered with
-- y / <CR> (apply) or n / <Esc> (cancel). It always asks.
local M = {}

local changes_mod = require("workhorse.buffer.changes")

function M.show(changes, on_confirm, on_cancel)
  local entries = {}
  for _, line in ipairs(changes_mod.format_for_display(changes)) do
    table.insert(entries, { text = line })
  end
  require("workhorse.ui.list_confirm").show("Apply the changes?", entries, function(confirmed)
    local callback = confirmed and on_confirm or on_cancel
    if callback then
      callback()
    end
  end)
end

return M
