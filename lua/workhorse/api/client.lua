local M = {}

local async = require("workhorse.async")
local config = require("workhorse.config")
local store = require("workhorse.store")

local PAT_NAME = "pat"
-- The PAT, once read from the locksmith store
local pat = nil
-- Callbacks waiting for the PAT from the locksmith store (concurrent requests share one prompt)
local pat_waiting = nil

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Base64 encode, in Lua for Neovim < 0.10 (no vim.base64): never through a shell, which would
-- put the PAT on a command line
local function base64_encode(str)
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(str)
  end
  local out = {}
  for i = 1, #str, 3 do
    local a, b, c = str:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local digits = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    for d = 1, 4 do
      digits[d] = B64:sub(digits[d] + 1, digits[d] + 1)
    end
    if not b then
      digits[3] = "="
    end
    if not c then
      digits[4] = "="
    end
    out[#out + 1] = table.concat(digits)
  end
  return table.concat(out)
end

--- The PAT: workhorse/pat from the locksmith store, its only source (its password is asked on
--- the first request), kept in memory once read
---@param callback function Callback(pat, error)
local function get_pat(callback)
  if pat then
    return callback(pat, nil)
  end
  if pat_waiting then
    return table.insert(pat_waiting, callback)
  end
  pat_waiting = { callback }
  store.get_secret(PAT_NAME, function(value, err)
    if not value and not err then
      local name = store.NAMESPACE .. "/" .. PAT_NAME
      err = "no PAT: store it with `:Locksmith set " .. name .. "` (or `locksmith set " .. name .. "`)"
    end
    pat = value
    local callbacks = pat_waiting
    pat_waiting = nil
    for _, cb in ipairs(callbacks) do
      cb(value, err)
    end
  end)
end

local function get_auth_header(pat)
  -- PAT auth uses Basic with empty username
  return "Basic " .. base64_encode(":" .. pat)
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
        -- The response too, for its headers (e.g. continuation tokens)
        opts.on_success(data, response)
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

      if not opts.silent then
        vim.notify("Workhorse: " .. error_msg, vim.log.levels.ERROR)
      end
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
    if not opts.silent then
      vim.notify("Workhorse: " .. message, vim.log.levels.ERROR)
    end
    if opts.on_error then
      opts.on_error(message, err)
    end
  end)
end

function M.request(opts)
  get_pat(function(value, err)
    if not value then
      return handle_transport_error({ message = err }, opts)
    end
    M.request_with(opts, get_auth_header(value))
  end)
end

-- A string quoted for a curl config file (its escapes: \\ \" \n \r \t)
local CONFIG_ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function config_quote(value)
  return '"' .. value:gsub('[\\"\n\r\t]', CONFIG_ESCAPES) .. '"'
end

-- Status, headers ({ "Name: value" }) and body of curl's output with -D -: a header block per
-- response (redirects, proxies), the last one the body's
local function parse_output(output)
  local status, headers, rest = 0, {}, output
  while rest:match("^HTTP/") do
    local block_end = rest:find("\r\n\r\n", 1, true)
    local block = block_end and rest:sub(1, block_end - 1) or rest
    rest = block_end and rest:sub(block_end + 4) or ""
    headers = {}
    for line in block:gmatch("[^\r\n]+") do
      local code = line:match("^HTTP/%S*%s+(%d+)")
      if code then
        status = tonumber(code)
      else
        table.insert(headers, line)
      end
    end
  end
  return status, headers, rest
end

--- Send a request with this Authorization header (opts.base_url replaces the server URL, e.g.
--- for another host of the organization). The header and the body go to curl in a config on
--- its stdin, never on its command line, which other processes can read (ps, /proc)
function M.request_with(opts, auth)
  local url = (opts.base_url or get_base_url()) .. opts.path
  local method = opts.method or "GET"
  local body = opts.raw_body or (opts.body and vim.json.encode(opts.body)) or nil

  local args = {
    "-sSL", "--compressed", "-D", "-", "-X", method,
    "-H", "Content-Type: " .. (opts.content_type or "application/json"),
    "-H", "Accept: application/json",
    "--config", "-",
    url,
  }
  local stdin = { "header = " .. config_quote("Authorization: " .. auth) }
  if body then
    table.insert(stdin, "data-raw = " .. config_quote(body))
  end

  async.exec(vim.g.plenary_curl_bin_path or "curl", args, function(stdout, stderr, code)
    if code ~= 0 then
      return handle_transport_error({
        message = ("%s %s - curl error exit_code=%s stderr=%s"):format(method, url, code, stderr or ""),
        stderr = stderr,
        exit = code,
      }, opts)
    end
    local status, headers, response_body = parse_output(stdout or "")
    handle_response({ status = status, headers = headers, body = response_body, exit = code }, opts)
  end, table.concat(stdin, "\n") .. "\n")
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
    "  PAT: " .. (pat and (pat:sub(1, 4) .. "..." .. pat:sub(-4)) or "not read yet (locksmith)") .. "\n" ..
    "  Full test URL: " .. full_url,
    vim.log.levels.INFO
  )

  -- Make a test request
  local done = require("workhorse.progress").start("Testing connection")

  M.get(test_path, {
    on_success = function(data)
      done()
      local count = data and data.count or (data and data.value and #data.value) or 0
      vim.notify("Workhorse: Connection successful! Found " .. count .. " queries.", vim.log.levels.INFO)
    end,
    on_error = function(err, response)
      done(true)
      vim.notify("Workhorse: Connection failed!\n  Status: " .. (response and response.status or "unknown") ..
        "\n  URL: " .. full_url ..
        "\n  Error: " .. (err or "unknown"),
        vim.log.levels.ERROR
      )
    end,
  })
end

return M
