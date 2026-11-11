-- Git commands that may reach a remote (fetch, ls-remote, push), run without ever prompting: a
-- remote that needs credentials fails instead, and access() tells why.
--
-- Spawned by Neovim, git and ssh have no terminal on stdin. With $DISPLAY or $WAYLAND_DISPLAY set,
-- ssh then asks through $SSH_ASKPASS (a desktop popup) for the key's passphrase when the key is
-- not in the agent Neovim knows ($SSH_AUTH_SOCK), and for the account password when the server
-- also takes passwords (answering it empty counts as failed logins). Here:
--   GIT_TERMINAL_PROMPT=0       git asks for no username/password (HTTPS)
--   GCM_INTERACTIVE=never       nor does Git Credential Manager
--   SSH_ASKPASS_REQUIRE=never   ssh never runs the askpass program
--   ssh -o BatchMode=yes        ssh tries no passphrase nor password at all (only when neither
--                               $GIT_SSH_COMMAND, $GIT_SSH nor core.sshCommand picks the command)
--   a new session               no /dev/tty: nothing can prompt on Neovim's terminal either
local M = {}

local async = require("workhorse.async")

local BATCH_SSH = "ssh -o BatchMode=yes"

-- core.sshCommand of each directory (false when unset), read once
local ssh_commands = {}

local function env_for(dir)
  local env = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never", SSH_ASKPASS_REQUIRE = "never" }
  if (vim.env.GIT_SSH_COMMAND or "") ~= "" or (vim.env.GIT_SSH or "") ~= "" then
    return env
  end
  if ssh_commands[dir] == nil then
    local out = vim.fn.systemlist({ "git", "-C", dir, "config", "--get", "core.sshCommand" })
    ssh_commands[dir] = vim.v.shell_error == 0 and out[1] ~= nil and out[1] ~= ""
  end
  if not ssh_commands[dir] then
    env.GIT_SSH_COMMAND = BATCH_SSH
  end
  return env
end

--- Run `git -C dir args...` without prompts
---@param callback function Callback(stdout, stderr, exit_code)
function M.run(dir, args, callback)
  async.exec("git", vim.list_extend({ "-C", dir }, args), callback, nil, env_for(dir), { detached = true })
end

local function first_line(text)
  return vim.trim((text or ""):match("^%s*([^\n]*)") or "")
end

--- Why a remote command failed, as one message for the user: the SSH agent when ssh had no key to
--- use, otherwise the error of git (without ssh's warnings)
---@param remote string The remote's name
---@param stderr string What git wrote
---@param callback function Callback(message)
function M.access(remote, stderr, callback)
  stderr = stderr or ""
  -- ssh's noise: the post-quantum key exchange warning
  local lines = vim.tbl_filter(function(line)
    return not line:match("^%*%*") and line:match("%S")
  end, vim.split(stderr, "\n"))
  local err = vim.trim(table.concat(lines, "\n"))

  if err:match("Host key verification failed") then
    return callback(("Cannot access %s: its SSH host key is not known yet. Connect to it once from a shell "
      .. "(git fetch %s) to accept it, then try again"):format(remote, remote))
  end
  if not err:match("Permission denied %(") then
    return callback(err ~= "" and err or "unknown error")
  end
  local sock = vim.env.SSH_AUTH_SOCK or ""
  if sock == "" then
    return callback(("Cannot access %s: Neovim has no SSH agent ($SSH_AUTH_SOCK is not set), and the key "
      .. "cannot be unlocked without one. Start Neovim where the agent is set, then try again"):format(remote))
  end
  async.exec("ssh-add", { "-l" }, function(_, _, code)
    if code == 1 then
      callback(("Cannot access %s: the SSH key is not added to the agent yet. Add it to the agent Neovim "
        .. "uses and try again:\n  SSH_AUTH_SOCK=%s ssh-add"):format(remote, sock))
    elseif code ~= 0 then
      callback(("Cannot access %s: the SSH agent of Neovim is not running (SSH_AUTH_SOCK=%s). Start it "
        .. "and add the key, or start Neovim where the agent is set, then try again"):format(remote, sock))
    else
      callback(("Cannot access %s: the server refused the keys of the agent (SSH_AUTH_SOCK=%s): %s")
        :format(remote, sock, first_line(err)))
    end
  end)
end

return M
