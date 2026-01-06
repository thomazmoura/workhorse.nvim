local M = {}

local curl = require("plenary.curl")
local config = require("workhorse.config")

local function get_auth_header()
  local cfg = config.get()
  -- PAT auth uses Basic with empty username
  return "Basic " .. vim.base64.encode(":" .. cfg.pat)
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

function M.request(opts)
  local url = get_base_url() .. opts.path
  local headers = {
    ["Authorization"] = get_auth_header(),
    ["Content-Type"] = opts.content_type or "application/json",
    ["Accept"] = "application/json",
  }

  local request_opts = {
    url = url,
    method = opts.method or "GET",
    headers = headers,
    body = opts.body and vim.json.encode(opts.body) or nil,
    callback = function(response)
      handle_response(response, opts)
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

return M
