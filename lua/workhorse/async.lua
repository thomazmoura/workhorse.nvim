-- Asynchronous process execution (git, gdbus, secret-tool, openssl), callbacks on the main loop
local M = {}

--- Execute a command asynchronously using vim.loop
---@param cmd string The command to execute
---@param args table List of arguments
---@param callback function Callback(stdout, stderr, exit_code)
---@param stdin string|nil Optional data written to the process stdin
---@param env table|nil Extra environment variables ({ NAME = value }), added to Neovim's
function M.exec(cmd, args, callback, stdin, env)
  local stdin_pipe = stdin and vim.loop.new_pipe(false) or nil
  local stdout_pipe = vim.loop.new_pipe(false)
  local stderr_pipe = vim.loop.new_pipe(false)
  local stdout_chunks = {}
  local stderr_chunks = {}

  local env_list = nil
  if env then
    env_list = {}
    for name, value in pairs(vim.tbl_extend("force", vim.fn.environ(), env)) do
      table.insert(env_list, name .. "=" .. value)
    end
  end

  local handle
  handle = vim.loop.spawn(cmd, {
    args = args,
    env = env_list,
    stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    hide = true,
  }, function(code, _signal)
    -- Stop reading and close pipes
    if stdin_pipe and not stdin_pipe:is_closing() then
      stdin_pipe:close()
    end
    if stdout_pipe then
      stdout_pipe:read_stop()
      stdout_pipe:close()
    end
    if stderr_pipe then
      stderr_pipe:read_stop()
      stderr_pipe:close()
    end
    if handle then
      handle:close()
    end

    -- Schedule callback on main thread
    vim.schedule(function()
      local stdout_result = table.concat(stdout_chunks)
      local stderr_result = table.concat(stderr_chunks)
      callback(stdout_result, stderr_result, code)
    end)
  end)

  if not handle then
    if stdin_pipe then
      stdin_pipe:close()
    end
    vim.schedule(function()
      callback(nil, "Failed to spawn process: " .. cmd, -1)
    end)
    return
  end

  if stdin_pipe then
    stdin_pipe:write(stdin)
    stdin_pipe:shutdown()
  end

  stdout_pipe:read_start(function(err, data)
    if err then
      return
    end
    if data then
      table.insert(stdout_chunks, data)
    end
  end)

  stderr_pipe:read_start(function(err, data)
    if err then
      return
    end
    if data then
      table.insert(stderr_chunks, data)
    end
  end)
end

return M
