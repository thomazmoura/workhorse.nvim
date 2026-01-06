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
  local errors = {}

  if not config.server_url then
    table.insert(errors, "server_url not set (use setup() or AZURE_DEVOPS_URL env var)")
  end

  if not config.pat then
    table.insert(errors, "pat not set (use setup() or AZURE_DEVOPS_PAT env var)")
  end

  if not config.project then
    table.insert(errors, "project is required in setup()")
  end

  if #errors > 0 then
    error("Workhorse configuration errors:\n  - " .. table.concat(errors, "\n  - "))
  end
end

function M.get()
  return config
end

return M
