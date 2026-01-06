local M = {}

local defaults = {
  -- Server configuration (falls back to env vars)
  server_url = nil,
  pat = nil,

  -- Required: project name
  project = nil,

  -- Work item defaults
  default_work_item_type = "User Story",
  default_area_path = nil,
  default_iteration_path = nil,

  -- State for soft delete
  deleted_state = "Removed",

  -- Available states per work item type
  available_states = {
    ["Epic"] = { "New", "Active", "Resolved", "Closed", "Removed" },
    ["Feature"] = { "New", "Active", "Resolved", "Closed", "Removed" },
    ["User Story"] = { "New", "Active", "Resolved", "Closed", "Removed" },
    ["Bug"] = { "New", "Active", "Resolved", "Closed" },
    ["Task"] = { "New", "Active", "Closed" },
  },

  -- UI options
  confirm_changes = true,

  -- Cache settings
  cache = {
    enabled = true,
    ttl = 300, -- 5 minutes
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

return M
