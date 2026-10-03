local M = {}

-- Pick a pipeline (build definition) using Telescope
function M.pick(opts)
  opts = opts or {}

  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify(
      "Workhorse: Telescope is required for the pipeline picker. Use :Workhorse builds <definitionId> instead.",
      vim.log.levels.WARN
    )
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local builds_api = require("workhorse.api.builds")

  vim.notify("Workhorse: Loading pipelines...", vim.log.levels.INFO)

  builds_api.list_definitions(function(definitions, err)
    if err then
      vim.notify("Workhorse: Failed to load pipelines: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    if #definitions == 0 then
      vim.notify("Workhorse: No pipelines found", vim.log.levels.WARN)
      return
    end

    pickers.new(opts, {
      prompt_title = "Azure DevOps Pipelines",
      finder = finders.new_table({
        results = definitions,
        entry_maker = function(def)
          local folder = def.path:gsub("^\\", "")
          local label = folder ~= "" and (folder .. "\\" .. def.name) or def.name
          return {
            value = def,
            display = label,
            ordinal = label,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            require("workhorse.builds").open_runs(selection.value.id, selection.value.name)
          end
        end)
        return true
      end,
    }):find()
  end)
end

return M
