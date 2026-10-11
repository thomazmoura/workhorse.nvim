-- Encrypted cache files, as paperboy.nvim keeps its contacts: JSON encrypted with AES-256 by
-- openssl in stdpath("cache")/workhorse (mode 0600), with a random key kept in the vault shared
-- with paperboy.nvim (vault.lua: encrypted with a master password asked once per Neovim). The
-- key is read once per session. A key from before the vault, in plaintext in a keyring, is
-- moved into it. Without a key (master password not entered, keyring locked, no openssl)
-- nothing is read or written, and callers keep their data in memory only.
local M = {}

local async = require("workhorse.async")
local vault = require("workhorse.vault")

local KEY_NAME = "workhorse/cache-key"
local LEGACY_ATTRIBUTES = { "workhorse", "cache-key" }

-- The key is passed through the environment, never on the command line
local CIPHER = { "enc", "-aes-256-cbc", "-pbkdf2", "-salt", "-pass", "env:WORKHORSE_CACHE_KEY" }

-- false: not looked up yet; nil after a lookup: no key this session; else the key
local key = false
-- Callbacks of the lookup in flight (concurrent callers share one prompt)
local waiting = nil

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

local function dir()
  return vim.fn.stdpath("cache") .. "/workhorse"
end

local function path(name)
  return dir() .. "/" .. name .. ".enc"
end

--- Write `bytes` to `target` (mode 0600), replacing it atomically
---@return boolean ok, string|nil error
local function write_file(target, bytes)
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p", tonumber("700", 8))
  local tmp = target .. ".tmp"
  vim.loop.fs_unlink(tmp)
  local fd = vim.loop.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then
    return false, "cannot write " .. tmp
  end
  vim.loop.fs_write(fd, bytes, 0)
  vim.loop.fs_close(fd)
  local ok, rename_err = vim.loop.fs_rename(tmp, target)
  return ok == true, not ok and rename_err or nil
end

--- Read (or create) the key in the vault
---@param callback function Callback(key)
local function read_key(callback)
  vault.get(KEY_NAME, function(found, err)
    if err then
      notify(err .. ": the repository cache is kept in memory only", vim.log.levels.WARN)
    elseif found then
      -- The copy of the key wrapped with a cache password, from before the vault
      vim.loop.fs_unlink(path("cache-key"))
    end
    callback(found)
  end, { legacy = LEGACY_ATTRIBUTES, create = vault.random_key })
end

--- The cache key: callback(key), nil when the vault did not give it. Looked up once per
--- session; `retry` looks up again after a failed lookup (asking the master password again)
---@param callback function
---@param retry boolean|nil
function M.get_key(callback, retry)
  if key ~= false and not (retry and key == nil) then
    vim.schedule(function()
      callback(key)
    end)
    return
  end
  if waiting then
    table.insert(waiting, callback)
    return
  end
  waiting = { callback }
  local function done(found)
    key = found
    local callbacks = waiting
    waiting = nil
    for _, cb in ipairs(callbacks) do
      cb(key)
    end
  end
  if retry then
    vault.unlock(function()
      read_key(done)
    end, true)
  else
    read_key(done)
  end
end

--- Read and decrypt a cache file
---@param name string
---@param callback function Callback(data, error): both nil when there is no cache (or no key)
---@param retry boolean|nil Look the key up again when the session's lookup failed
function M.load(name, callback, retry)
  local file = io.open(path(name), "rb")
  if not file then
    vim.schedule(function()
      callback(nil, nil)
    end)
    return
  end
  local encrypted = file:read("*a")
  file:close()

  M.get_key(function(cache_key)
    if not cache_key then
      callback(nil, nil)
      return
    end
    local args = vim.list_extend(vim.deepcopy(CIPHER), { "-d" })
    async.exec("openssl", args, function(stdout, _, code)
      if code ~= 0 then
        callback(nil, "could not decrypt " .. path(name))
        return
      end
      local ok, data = pcall(vim.json.decode, stdout)
      if not ok or type(data) ~= "table" then
        callback(nil, "corrupt cache " .. path(name))
        return
      end
      callback(data, nil)
    end, encrypted, { WORKHORSE_CACHE_KEY = cache_key })
  end, retry)
end

--- Encrypt data (JSON) and write it to a cache file, replacing it atomically
---@param name string
---@param data table
---@param callback function Callback(saved, error): saved false without error when there is no key
---@param retry boolean|nil Look the key up again when the session's lookup failed
function M.save(name, data, callback, retry)
  M.get_key(function(cache_key)
    if not cache_key then
      callback(false, nil)
      return
    end
    async.exec("openssl", CIPHER, function(encrypted, stderr, code)
      if code ~= 0 then
        callback(false, "openssl failed: " .. vim.trim(stderr or ""))
        return
      end
      callback(write_file(path(name), encrypted))
    end, vim.json.encode(data), { WORKHORSE_CACHE_KEY = cache_key })
  end, retry)
end

return M
