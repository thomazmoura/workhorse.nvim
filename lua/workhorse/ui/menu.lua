-- Menu of the Workhorse screens (<leader>w/, :Workhorse menu): a fuzzy picker of the work items,
-- repositories, libraries, builds and pull requests, of the project of the working directory or all
-- of them. Telescope when available, otherwise vim.ui.select (fuzzy with snacks.nvim, fzf-lua or dressing)
local M = {}

local function workhorse()
  return require("workhorse")
end

-- { label, action }, in the order shown
local ENTRIES = {
  { "Work Items", function() workhorse().resume() end },
  { "Work Items Query", function() workhorse().pick_query() end },
  { "Repos of this project", function() workhorse().repo_screen() end },
  { "All Repos", function() workhorse().list_repos() end },
  { "All Repos Picker", function() workhorse().pick_repo() end },
  { "Libraries", function() workhorse().list_libraries() end },
  { "Builds of this project", function() workhorse().repo_builds() end },
  { "Last Build", function() workhorse().resume_build() end },
  { "All Builds", function() workhorse().list_pipelines() end },
  { "Recent Builds", function() workhorse().recent_pipelines() end },
  { "All Builds Picker", function() workhorse().pick_build() end },
  { "Run New Build", function() workhorse().pick_new_build() end },
  { "New Pipeline", function() workhorse().new_pipeline() end },
  { "PRs of this project", function() workhorse().repo_prs() end },
  { "Last PRs", function() workhorse().resume_prs() end },
  { "All PRs", function() workhorse().pick_prs() end },
}

-- Run the entry once the picker is closed (screens open in the window it came from)
local function run(entry)
  if entry then
    vim.schedule(entry[2])
  end
end

local function telescope_pick()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Workhorse",
    finder = finders.new_table({
      results = ENTRIES,
      entry_maker = function(entry)
        return { value = entry, display = entry[1], ordinal = entry[1] }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        run(selection and selection.value)
      end)
      return true
    end,
  }):find()
end

--- Open the menu
function M.open()
  if pcall(require, "telescope") then
    return telescope_pick()
  end
  vim.ui.select(ENTRIES, {
    prompt = "Workhorse",
    format_item = function(entry)
      return entry[1]
    end,
  }, run)
end

return M
