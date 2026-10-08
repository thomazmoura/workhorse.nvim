local M = {}

-- Pick a Git repository (of any project) using Telescope, then list its pull requests
function M.pick(opts)
  opts = opts or {}

  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify(
      "Workhorse: Telescope is required for the repository picker. Use :Workhorse PRs resume instead.",
      vim.log.levels.WARN
    )
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local prs_api = require("workhorse.api.pullrequests")

  vim.notify("Workhorse: Loading repositories...", vim.log.levels.INFO)

  prs_api.list_repositories(function(repos, err)
    if err then
      vim.notify("Workhorse: Failed to load repositories: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

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
