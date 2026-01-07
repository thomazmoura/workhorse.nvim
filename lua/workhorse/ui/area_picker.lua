local M = {}

function M.show(on_select, on_cancel)
  local areas = require("workhorse.api.areas")

  areas.get_all(function(area_list, err)
    if err or not area_list then
      vim.notify("Workhorse: Failed to fetch areas: " .. (err or "unknown error"), vim.log.levels.ERROR)
      if on_cancel then
        on_cancel()
      end
      return
    end

    vim.schedule(function()
      vim.ui.select(area_list, {
        prompt = "Select area for new items:",
      }, function(choice)
        if choice then
          if on_select then
            on_select(choice)
          end
        else
          if on_cancel then
            on_cancel()
          end
        end
      end)
    end)
  end)
end

return M
