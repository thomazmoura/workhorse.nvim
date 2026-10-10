-- Encrypted cache files, as paperboy.nvim keeps its contacts: JSON encrypted with AES-256 by
-- openssl in stdpath("cache")/workhorse (mode 0600), with a random key kept in a GNOME keyring
-- named "workhorse" (create it in Passwords and Keys). The key is read once per session (the
-- first read shows the keyring's unlock prompt) and the keyring is locked again right after.
-- Without that keyring (or gdbus, secret-tool, openssl) there is no key: nothing is read or
-- written, and callers keep their data in memory only.
local M = {}

local async = require("workhorse.async")

local KEYRING = "workhorse"
local CACHE_KEY_ATTRIBUTES = { "workhorse", "cache-key" }
local COLLECTION_PREFIX = "/org/freedesktop/secrets/collection/"
local SECRETS_BUS = { "call", "--session", "--dest", "org.freedesktop.secrets" }

-- The key is passed through the environment, never on the command line
local CIPHER = { "enc", "-aes-256-cbc", "-pbkdf2", "-salt", "-pass", "env:WORKHORSE_CACHE_KEY" }

-- false: not looked up yet; nil after a lookup: no key this session; else the key
local key = false
-- Callbacks of the lookup in flight (concurrent callers share one unlock prompt)
local waiting = nil

local function path(name)
  return vim.fn.stdpath("cache") .. "/workhorse/" .. name .. ".enc"
end

--- Look up a keyring item (prompts to unlock its keyring when locked)
---@param callback function Callback(value): nil when not found (or prompt dismissed)
local function lookup(attributes, callback)
  async.exec("secret-tool", vim.list_extend({ "lookup" }, vim.deepcopy(attributes)), function(stdout, _, code)
    local value = vim.trim(stdout or "")
    callback(code == 0 and value ~= "" and value or nil)
  end)
end

--- Read a D-Bus property of the Secret Service (never prompts)
---@param callback function Callback(output): gdbus output, nil on error
local function get_property(object_path, interface, property, callback)
  local args = vim.list_extend(vim.deepcopy(SECRETS_BUS), {
    "--object-path",
    object_path,
    "--method",
    "org.freedesktop.DBus.Properties.Get",
    interface,
    property,
  })
  async.exec("gdbus", args, function(stdout, _, code)
    callback(code == 0 and stdout or nil)
  end)
end

--- Find a keyring by its name (the label shown in Passwords and Keys). Its object path may
--- differ: gnome-keyring derives it from a file name that may get a suffix (workhorse_5f1)
---@param callback function Callback(id): last part of the object path, nil when not found
local function find_collection(name, callback)
  get_property("/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "Collections", function(output)
    local ids = {}
    for id in (output or ""):gmatch(vim.pesc(COLLECTION_PREFIX) .. "([^']+)") do
      table.insert(ids, id)
    end
    if #ids == 0 then
      callback(nil)
      return
    end
    local pending, found = #ids, nil
    for _, id in ipairs(ids) do
      get_property(COLLECTION_PREFIX .. id, "org.freedesktop.Secret.Collection", "Label", function(label)
        if id == name or (label and label:match("^%(<'(.*)'>,%)") == name) then
          found = found or id
        end
        pending = pending - 1
        if pending == 0 then
          callback(found)
        end
      end)
    end
  end)
end

--- Is the keyring locked? Reading the property never prompts; unknown counts as locked
local function is_locked(collection, callback)
  get_property(COLLECTION_PREFIX .. collection, "org.freedesktop.Secret.Collection", "Locked", function(output)
    callback(not (output and output:find("false", 1, true)))
  end)
end

--- Create a random cache key (256 bits) and store it in the keyring
---@param callback function Callback(key): nil when it could not be created
local function create_key(collection, callback)
  async.exec("openssl", { "rand", "-hex", "32" }, function(stdout, _, code)
    local created = vim.trim(stdout or "")
    if code ~= 0 or #created ~= 64 then
      callback(nil)
      return
    end
    local args = { "store", "--label=Workhorse cache key", "--collection=" .. COLLECTION_PREFIX .. collection }
    async.exec("secret-tool", vim.list_extend(args, vim.deepcopy(CACHE_KEY_ATTRIBUTES)), function(_, _, store_code)
      callback(store_code == 0 and created or nil)
    end, created)
  end)
end

--- Read (or create) the key, then lock the keyring again
local function read_key(callback)
  find_collection(KEYRING, function(collection)
    if not collection then
      callback(nil)
      return
    end
    local function done(found)
      async.exec("secret-tool", { "lock", "--collection=" .. collection }, function(_, stderr)
        if vim.trim(stderr or "") ~= "" then
          vim.notify(("Workhorse: could not lock the %q keyring: %s"):format(KEYRING, vim.trim(stderr)), vim.log.levels.WARN)
        end
        callback(found)
      end)
    end
    lookup(CACHE_KEY_ATTRIBUTES, function(found)
      if found then
        return done(found)
      end
      -- Nothing read: a key is created only when the keyring is unlocked and really has none.
      -- Still locked means the unlock prompt was dismissed (or could not be shown): creating a
      -- key then would replace the one the cache was encrypted with
      is_locked(collection, function(locked)
        if locked then
          vim.notify(("Workhorse: the %q keyring stayed locked: the repository cache is kept in memory only"):format(KEYRING),
            vim.log.levels.WARN)
          callback(nil)
        else
          create_key(collection, done)
        end
      end)
    end)
  end)
end

--- The cache key: callback(key), nil when there is no "workhorse" keyring (or the unlock prompt
--- was dismissed). Looked up once per session; `retry` looks up again after a failed lookup
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
  read_key(function(found)
    key = found
    local callbacks = waiting
    waiting = nil
    for _, cb in ipairs(callbacks) do
      cb(key)
    end
  end)
end

--- Read and decrypt a cache file
---@param name string
---@param callback function Callback(data, error): both nil when there is no cache (or no key)
function M.load(name, callback)
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
  end)
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
      local target = path(name)
      vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p", tonumber("700", 8))
      local tmp = target .. ".tmp"
      vim.loop.fs_unlink(tmp)
      local fd = vim.loop.fs_open(tmp, "w", tonumber("600", 8))
      if not fd then
        callback(false, "cannot write " .. tmp)
        return
      end
      vim.loop.fs_write(fd, encrypted, 0)
      vim.loop.fs_close(fd)
      local ok, rename_err = vim.loop.fs_rename(tmp, target)
      callback(ok == true, not ok and rename_err or nil)
    end, vim.json.encode(data), { WORKHORSE_CACHE_KEY = cache_key })
  end, retry)
end

return M
