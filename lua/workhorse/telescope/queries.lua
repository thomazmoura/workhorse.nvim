local M = {}

-- Pick a saved query using Telescope
function M.pick(opts)
  opts = opts or {}

  -- Check if Telescope is available
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("Workhorse: Telescope is required for query picker", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local queries_api = require("workhorse.api.queries")

  vim.notify("Workhorse: Loading queries...", vim.log.levels.INFO)

  -- Fetch queries from Azure DevOps
  queries_api.list(function(query_tree, err)
    if err then
      vim.notify("Workhorse: Failed to load queries: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    -- Flatten the hierarchical structure
    local flat_queries = queries_api.flatten(query_tree)

    if #flat_queries == 0 then
      vim.notify("Workhorse: No queries found", vim.log.levels.WARN)
      return
    end

    -- Create and open the picker
    pickers.new(opts, {
      prompt_title = "Azure DevOps Queries",
      finder = finders.new_table({
        results = flat_queries,
        entry_maker = function(query)
          return {
            value = query,
            display = query.path,
            ordinal = query.path,
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            require("workhorse").open_query(selection.value.id)
          end
        end)
        return true
      end,
    }):find()
  end)
end

-- Register as a Telescope extension
return require("telescope").register_extension({
  exports = {
    queries = M.pick,
  },
})
