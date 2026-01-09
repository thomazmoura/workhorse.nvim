local M = {}

local defaults = {
  -- Server configuration (falls back to env vars)
  server_url = nil,
  pat = nil,

  -- Required: project name
  project = nil,

  -- Team name (required for board_column grouping mode)
  team = nil,

  -- Grouping mode: "state" (default) or "board_column"
  grouping_mode = "state",

  -- Board name for column configuration (Stories, Epics, Features, etc.)
  default_board = "Stories",

  -- Work item defaults
  default_work_item_type = "User Story",
  work_item_type_hierarchy = { "Epic", "Feature", "User Story", "Task" },
  default_area_path = nil,
  default_iteration_path = nil,

  -- State for soft delete
  deleted_state = "Removed",
  hide_deleted_state = false,

  -- Default state for new items (used in board_column mode)
  default_new_state = "New",

  -- Available states per work item type
  available_states = {
    ["Epic"] = { "New", "Active", "Resolved", "Closed", "Removed" },
    ["Feature"] = { "New", "Active", "Resolved", "Closed", "Removed" },
    ["User Story"] = { "New", "Active", "Resolved", "Closed", "Removed" },
    ["Bug"] = { "New", "Active", "Resolved", "Closed" },
    ["Task"] = { "New", "Active", "Closed" },
  },

  -- State header colors (highlight group names)
  state_colors = {
    ["New"] = "WorkhorseStateNew",
    ["Active"] = "WorkhorseStateActive",
    ["Resolved"] = "WorkhorseStateResolved",
    ["Closed"] = "WorkhorseStateClosed",
    ["Removed"] = "WorkhorseStateRemoved",
  },

  -- Board column colors (highlight group names, used when grouping_mode = "board_column")
  column_colors = {},

  -- Work item type display (text and color independently configurable)
  work_item_type_display = {
    ["Epic"] = { text = "[Epic]", color = "WorkhorseTypeEpic" },
    ["Feature"] = { text = "[Feature]", color = "WorkhorseTypeFeature" },
    ["User Story"] = { text = "[Story]", color = "WorkhorseTypeUserStory" },
    ["Bug"] = { text = "[Bug]", color = "WorkhorseTypeBug" },
    ["Task"] = { text = "[Task]", color = "WorkhorseTypeTask" },
  },

  -- Tag-based title colors (Work Item Type -> Tag -> Highlight Group)
  -- First matching tag wins for items with multiple tags
  -- Example:
  -- tag_title_colors = {
  --   ["Bug"] = {
  --     ["Critical"] = "DiagnosticError",
  --     ["Silly"] = "DiagnosticWarn",
  --   },
  -- },
  tag_title_colors = {},

  -- Tree view indentation prefix per level (up to four entries)
  -- Each level uses its own prefix, and deeper levels reuse the last entry.
  tree_indent = { "└─", "──", "──", "──" },
  tree_indent_hl = "LspCodeLens",

  -- UI options
  confirm_changes = true,

  -- Cache settings
  cache = {
    enabled = true,
    ttl = 300, -- 5 minutes
  },

  -- Lualine integration settings
  lualine = {
    refresh_interval = 60000, -- 1 minute in ms
  },
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Resolve env vars if not explicitly set
  config.server_url = config.server_url or vim.env.AZURE_DEVOPS_URL
  config.pat = config.pat or vim.env.AZURE_DEVOPS_PAT

  M.validate()
end

function M.validate()
  local warnings = {}

  if not config.server_url then
    table.insert(warnings, "server_url not set (use setup() or AZURE_DEVOPS_URL env var)")
  end

  if not config.pat then
    table.insert(warnings, "pat not set (use setup() or AZURE_DEVOPS_PAT env var)")
  end

  if not config.project then
    table.insert(warnings, "project is required in setup()")
  end

  if config.grouping_mode == "board_column" and not config.team then
    table.insert(warnings, "team is required when grouping_mode is 'board_column'")
  end

  if #warnings > 0 then
    vim.schedule(function()
      vim.notify(
        "Workhorse configuration incomplete:\n  - " .. table.concat(warnings, "\n  - "),
        vim.log.levels.WARN
      )
    end)
    return false
  end

  return true
end

-- Check if config is valid (can be called before API operations)
function M.is_valid()
  return config.server_url ~= nil and config.pat ~= nil and config.project ~= nil
end

function M.get()
  return config
end

-- Check if grouping mode is board_column
function M.is_board_column_mode()
  return config.grouping_mode == "board_column"
end

return M
