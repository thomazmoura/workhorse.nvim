-- Secrets and encrypted caches, in the locksmith.nvim store (namespace "workhorse"), shared with
-- paperboy.nvim and unlocked once per Neovim with its password. The PAT is the secret
-- workhorse/pat; the repository and identity caches are locksmith's disposable caches, sealed
-- with the store's key. Without locksmith (not installed, or missing its crypto libraries)
-- nothing is read or written: the PAT must come from setup() or $AZURE_DEVOPS_PAT, and callers
-- keep their caches in memory only.
local M = {}

M.NAMESPACE = "workhorse"

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

-- Warned once per session that locksmith cannot work
local warned = false

--- The locksmith module, when it can open a store
---@return table|nil locksmith
---@return string|nil error
function M.locksmith()
  local ok, locksmith = pcall(require, "locksmith")
  if not ok then
    return nil, "locksmith.nvim is not installed"
  end
  local status = locksmith.status()
  if not status.backend or status.error then
    return nil, ("locksmith cannot work (%s)"):format(status.error or "no Argon2id implementation, see :Locksmith status")
  end
  return locksmith, nil
end

--- Read a secret of the workhorse namespace, unlocking the store (its password asked) when needed
---@param name string
---@param callback function Callback(value, error): both nil when the store does not have it
function M.get_secret(name, callback)
  local locksmith, err = M.locksmith()
  if not locksmith then
    return vim.schedule(function()
      callback(nil, err)
    end)
  end
  locksmith.get(M.NAMESPACE, name, callback)
end

-- Cache files of the openssl-encrypted cache of older versions (their key was in nvim-vault)
local function remove_legacy(name)
  local dir = vim.fn.stdpath("cache") .. "/workhorse/"
  vim.loop.fs_unlink(dir .. name .. ".enc")
  vim.loop.fs_unlink(dir .. "cache-key.enc")
end

--- Read a cache file
---@param name string
---@param callback function Callback(data, error): both nil when there is no cache
---@param retry boolean|nil Ask the store's password again when it was declined this session
function M.load(name, callback, retry)
  local locksmith, err = M.locksmith()
  if not locksmith then
    if not warned then
      warned = true
      notify(err .. ": caches are kept in memory only", vim.log.levels.WARN)
    end
    return vim.schedule(function()
      callback(nil, nil)
    end)
  end
  local function load()
    locksmith.cache(M.NAMESPACE).load(name, function(data)
      if data ~= nil and type(data) ~= "table" then
        callback(nil, "corrupt cache " .. name)
      else
        callback(data, nil)
      end
    end)
  end
  if retry then
    locksmith.unlock(load)
  else
    load()
  end
end

--- Write data to a cache file
---@param name string
---@param data table JSON-serializable
---@param callback function Callback(saved, error): saved false without error without locksmith
---@param retry boolean|nil Ask the store's password again when it was declined this session
function M.save(name, data, callback, retry)
  local locksmith = M.locksmith()
  if not locksmith then
    return vim.schedule(function()
      callback(false, nil)
    end)
  end
  local function save()
    locksmith.cache(M.NAMESPACE).save(name, data, function(ok, err)
      if ok then
        remove_legacy(name)
      end
      -- Still locked: its prompt was dismissed, nothing to report (kept in memory)
      if not ok and not locksmith.status().unlocked then
        err = nil
      end
      callback(ok == true, err)
    end)
  end
  if retry then
    locksmith.unlock(save)
  else
    save()
  end
end

return M
