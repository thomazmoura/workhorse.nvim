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

--- Open the menu
function M.open()
  require("workhorse.ui.picker").select(ENTRIES, {
    prompt = "Workhorse",
    format_item = function(entry)
      return entry[1]
    end,
  }, function(entry)
    entry[2]()
  end)
end

return M
