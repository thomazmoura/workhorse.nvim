local M = {}

local curl = require("plenary.curl")
local config = require("workhorse.config")

-- Base64 encode (fallback for Neovim < 0.10)
local function base64_encode(str)
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(str)
  end
  -- Fallback using base64 command
  local handle = io.popen("echo -n " .. vim.fn.shellescape(str) .. " | base64 -w0 2>/dev/null || echo -n " .. vim.fn.shellescape(str) .. " | base64")
  if handle then
    local result = handle:read("*a"):gsub("%s+$", "")
    handle:close()
    return result
  end
  error("Failed to base64 encode - neither vim.base64 nor base64 command available")
end

local function get_auth_header()
  local cfg = config.get()
  -- PAT auth uses Basic with empty username
  return "Basic " .. base64_encode(":" .. cfg.pat)
end

local function get_base_url()
  local cfg = config.get()
  local url = cfg.server_url
  -- Remove trailing slash if present
  return url:gsub("/$", "")
end

local function handle_response(response, opts)
  vim.schedule(function()
    if response.status >= 200 and response.status < 300 then
      local data = nil
      if response.body and response.body ~= "" then
        local ok, decoded = pcall(vim.json.decode, response.body)
        if ok then
          data = decoded
        else
          vim.notify("Workhorse: Failed to parse response JSON", vim.log.levels.ERROR)
          if opts.on_error then
            opts.on_error("JSON parse error", response)
          end
          return
        end
      end
      if opts.on_success then
        opts.on_success(data)
      end
    else
      local error_msg = "API Error: " .. response.status
      local details = ""

      if response.body and response.body ~= "" then
        local ok, data = pcall(vim.json.decode, response.body)
        if ok and data.message then
          details = data.message
        elseif ok and data.value then
          details = vim.inspect(data.value)
        end
      end

      if details ~= "" then
        error_msg = error_msg .. " - " .. details
      end

      vim.notify("Workhorse: " .. error_msg, vim.log.levels.ERROR)
      if opts.on_error then
        opts.on_error(error_msg, response)
      end
    end
  end)
end

local function handle_transport_error(err, opts)
  local message = err and err.message or "Network error"
  if err and err.exit == 6 then
    message = "Unable to reach server (could not resolve host). Check server_url."
  end

  vim.schedule(function()
    vim.notify("Workhorse: " .. message, vim.log.levels.ERROR)
    if opts.on_error then
      opts.on_error(message, err)
    end
  end)
end

function M.request(opts)
  local url = get_base_url() .. opts.path
  local auth = get_auth_header()

  local headers = {
    authorization = auth,
    content_type = opts.content_type or "application/json",
    accept = "application/json",
  }

  local request_opts = {
    url = url,
    method = opts.method or "GET",
    headers = headers,
    body = opts.body and vim.json.encode(opts.body) or nil,
    callback = function(response)
      handle_response(response, opts)
    end,
    on_error = function(err)
      handle_transport_error(err, opts)
    end,
  }

  -- For raw body (already encoded JSON)
  if opts.raw_body then
    request_opts.body = opts.raw_body
  end

  curl.request(request_opts)
end

function M.get(path, opts)
  opts = opts or {}
  opts.path = path
  opts.method = "GET"
  M.request(opts)
end

function M.post(path, body, opts)
  opts = opts or {}
  opts.path = path
  opts.method = "POST"
  opts.body = body
  M.request(opts)
end

function M.patch(path, body, opts)
  opts = opts or {}
  opts.path = path
  opts.method = "PATCH"
  opts.body = body
  -- JSON Patch requires specific content type
  opts.content_type = "application/json-patch+json"
  M.request(opts)
end

-- Test connection and show debug info
function M.test()
  local cfg = config.get()
  local base_url = get_base_url()
  local test_path = "/" .. cfg.project .. "/_apis/wit/queries?$depth=1&api-version=7.1"
  local full_url = base_url .. test_path

  vim.notify("Workhorse Debug Info:\n" ..
    "  Server URL: " .. (cfg.server_url or "NOT SET") .. "\n" ..
    "  Project: " .. (cfg.project or "NOT SET") .. "\n" ..
    "  PAT: " .. (cfg.pat and (cfg.pat:sub(1, 4) .. "..." .. cfg.pat:sub(-4)) or "NOT SET") .. "\n" ..
    "  Full test URL: " .. full_url,
    vim.log.levels.INFO
  )

  -- Make a test request
  vim.notify("Workhorse: Testing connection...", vim.log.levels.INFO)

  M.get(test_path, {
    on_success = function(data)
      local count = data and data.count or (data and data.value and #data.value) or 0
      vim.notify("Workhorse: Connection successful! Found " .. count .. " queries.", vim.log.levels.INFO)
    end,
    on_error = function(err, response)
      vim.notify("Workhorse: Connection failed!\n  Status: " .. (response and response.status or "unknown") ..
        "\n  URL: " .. full_url ..
        "\n  Error: " .. (err or "unknown"),
        vim.log.levels.ERROR
      )
    end,
  })
end

return M
