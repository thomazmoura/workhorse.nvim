local M = {}

-- Pick a Git repository (of any project, from the repository cache) using Telescope, then list
-- its pull requests
function M.pick(opts)
  opts = opts or {}

  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify(
      "Workhorse: Telescope is required for the repository picker. Use :Workhorse PRs here or :Workhorse PRs resume instead.",
      vim.log.levels.WARN
    )
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- From the repository cache: no request once it is loaded
  require("workhorse.repos").get(function(cache, err)
    if not cache then
      vim.notify("Workhorse: Failed to load repositories: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    local repos = cache.repos

    if #repos == 0 then
      vim.notify("Workhorse: No repositories found", vim.log.levels.WARN)
      return
    end

    pickers.new(opts, {
      prompt_title = "Azure DevOps Repositories",
      finder = finders.new_table({
        results = repos,
        entry_maker = function(repo)
          local label = repo.project.name .. "/" .. repo.name
          return {
            value = repo,
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
            require("workhorse.prs").open_list(selection.value)
          end
        end)
        return true
      end,
    }):find()
  end)
end

return M
