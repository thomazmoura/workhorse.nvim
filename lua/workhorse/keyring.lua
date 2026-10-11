-- Encrypted cache files, as paperboy.nvim keeps its contacts: JSON encrypted with AES-256 by
-- openssl in stdpath("cache")/workhorse (mode 0600), with a random key kept in a GNOME keyring
-- named "workhorse" (create it in Passwords and Keys). The key is read once per session (the
-- first read shows the keyring's unlock prompt) and the keyring is locked again right after.
-- A copy of the key is also kept encrypted with a password (cache-key.enc, asked once the first
-- time the keyring gives the key), so the cache opens where the keyring cannot (e.g. over SSH):
-- the password is asked instead. Without either (or without openssl) there is no key: nothing
-- is read or written, and callers keep their data in memory only.
local M = {}

local async = require("workhorse.async")

local KEYRING = "workhorse"
local CACHE_KEY_ATTRIBUTES = { "workhorse", "cache-key" }
local COLLECTION_PREFIX = "/org/freedesktop/secrets/collection/"
local SECRETS_BUS = { "call", "--session", "--dest", "org.freedesktop.secrets" }

-- The key is passed through the environment, never on the command line
local CIPHER = { "enc", "-aes-256-cbc", "-pbkdf2", "-salt", "-pass", "env:WORKHORSE_CACHE_KEY" }
-- The copy of the key encrypted with the password (more iterations: a password is guessable)
local KEY_FILE = "cache-key"
local WRAP = { "enc", "-aes-256-cbc", "-pbkdf2", "-iter", "600000", "-salt", "-pass", "env:WORKHORSE_PASSWORD" }

-- false: not looked up yet; nil after a lookup: no key this session; else the key
local key = false
-- Callbacks of the lookup in flight (concurrent callers share one unlock prompt)
local waiting = nil
-- Setting a password was skipped this session: not asked again
local password_skipped = false

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

local function dir()
  return vim.fn.stdpath("cache") .. "/workhorse"
end

local function path(name)
  return dir() .. "/" .. name .. ".enc"
end

local function exists(file)
  return vim.loop.fs_stat(file) ~= nil
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

-- Password ----------------------------------------------------------------------

--- Ask a password: nil when left empty (or <C-c>)
local function ask_password(prompt)
  local ok, value = pcall(vim.fn.inputsecret, prompt)
  vim.cmd("redraw")
  if ok and value and value ~= "" then
    return value
  end
end

--- Ask a new password twice: nil when skipped (left empty) or mistyped twice
local function new_password()
  for _ = 1, 2 do
    local password = ask_password("New Workhorse cache password (empty to skip): ")
    if not password then
      return nil
    end
    if ask_password("Repeat the password: ") == password then
      return password
    end
    notify("The passwords do not match", vim.log.levels.WARN)
  end
end

--- Save the copy of `cache_key` encrypted with `password`
---@param callback function Callback(ok, error)
local function wrap_key(cache_key, password, callback)
  async.exec("openssl", WRAP, function(encrypted, stderr, code)
    if code ~= 0 then
      callback(false, "openssl failed: " .. vim.trim(stderr or ""))
      return
    end
    callback(write_file(path(KEY_FILE), encrypted))
  end, cache_key, { WORKHORSE_PASSWORD = password })
end

--- Decrypt the copy of the key with `password`
---@param callback function Callback(key): nil when the password is wrong
local function unwrap_key(password, callback)
  local file = io.open(path(KEY_FILE), "rb")
  if not file then
    vim.schedule(function()
      callback(nil)
    end)
    return
  end
  local encrypted = file:read("*a")
  file:close()
  async.exec("openssl", vim.list_extend(vim.deepcopy(WRAP), { "-d" }), function(stdout, _, code)
    local found = vim.trim(stdout or "")
    -- A wrong password may still decrypt (to garbage) without an error
    callback(code == 0 and #found == 64 and found:match("^%x+$") and found or nil)
  end, encrypted, { WORKHORSE_PASSWORD = password })
end

--- Ask the password until it decrypts the key (3 tries)
---@param callback function Callback(key): nil when left empty or wrong 3 times
local function unlock_with_password(callback, tries)
  tries = tries or 1
  local password = ask_password("Workhorse cache password (empty to skip): ")
  if not password then
    callback(nil)
    return
  end
  unwrap_key(password, function(found)
    if found or tries >= 3 then
      if not found then
        notify("Wrong cache password", vim.log.levels.WARN)
      end
      callback(found)
      return
    end
    notify("Wrong cache password, try again", vim.log.levels.WARN)
    unlock_with_password(callback, tries + 1)
  end)
end

--- Once the keyring gave `cache_key`: ask a password for its copy when there is none yet
---@param callback function Callback(cache_key)
local function offer_password(cache_key, callback)
  if not cache_key or password_skipped or exists(path(KEY_FILE)) then
    callback(cache_key)
    return
  end
  notify("Set a password to open the cache where the keyring cannot (e.g. over SSH)")
  local password = new_password()
  if not password then
    password_skipped = true
    notify("No cache password set: the cache opens with the keyring only", vim.log.levels.WARN)
    callback(cache_key)
    return
  end
  wrap_key(cache_key, password, function(ok, err)
    if ok then
      notify("Cache password set")
    else
      notify("Could not save the cache password: " .. tostring(err), vim.log.levels.WARN)
    end
    callback(cache_key)
  end)
end

local function memory_only(reason)
  notify(reason .. ": the repository cache is kept in memory only", vim.log.levels.WARN)
end

--- Without the keyring: the key from its password copy, or a new key kept only that way when
--- there is no cache yet
---@param callback function Callback(key)
local function password_fallback(callback)
  if exists(path(KEY_FILE)) then
    notify(("The %q keyring could not be opened: enter the cache password"):format(KEYRING))
    unlock_with_password(function(found)
      if not found then
        memory_only("No cache password")
      end
      callback(found)
    end)
    return
  end
  for _, file in ipairs(vim.fn.glob(dir() .. "/*.enc", false, true)) do
    if vim.fn.fnamemodify(file, ":t:r") ~= KEY_FILE then
      memory_only(("The %q keyring could not be opened and the cache has no password (set one where the keyring opens)"):format(KEYRING))
      callback(nil)
      return
    end
  end
  notify(("The %q keyring could not be opened: set a password to keep the repository cache across sessions"):format(KEYRING))
  local password = new_password()
  if not password then
    memory_only("No cache password")
    callback(nil)
    return
  end
  async.exec("openssl", { "rand", "-hex", "32" }, function(stdout, _, code)
    local created = vim.trim(stdout or "")
    if code ~= 0 or #created ~= 64 then
      memory_only("Could not create a cache key")
      callback(nil)
      return
    end
    wrap_key(created, password, function(ok, err)
      if not ok then
        memory_only("Could not save the cache password (" .. tostring(err) .. ")")
      end
      callback(ok and created or nil)
    end)
  end)
end

-- Keyring -----------------------------------------------------------------------

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

--- Store the cache key in the keyring
---@param callback function Callback(key): nil when it could not be stored
local function store_key(collection, cache_key, callback)
  local args = { "store", "--label=Workhorse cache key", "--collection=" .. COLLECTION_PREFIX .. collection }
  async.exec("secret-tool", vim.list_extend(args, vim.deepcopy(CACHE_KEY_ATTRIBUTES)), function(_, _, code)
    callback(code == 0 and cache_key or nil)
  end, cache_key)
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
    store_key(collection, created, callback)
  end)
end

--- Read (or create) the key, then lock the keyring again. Without the keyring (or when it
--- stays locked), the password opens the key instead (see password_fallback)
local function read_key(callback)
  find_collection(KEYRING, function(collection)
    if not collection then
      password_fallback(callback)
      return
    end
    local function done(found)
      async.exec("secret-tool", { "lock", "--collection=" .. collection }, function(_, stderr)
        if vim.trim(stderr or "") ~= "" then
          notify(("Could not lock the %q keyring: %s"):format(KEYRING, vim.trim(stderr)), vim.log.levels.WARN)
        end
        offer_password(found, callback)
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
          password_fallback(callback)
        elseif exists(path(KEY_FILE)) then
          -- A key made without the keyring: the keyring keeps that one from now on
          notify(("The %q keyring has no cache key yet: enter the cache password to store it there"):format(KEYRING))
          unlock_with_password(function(found)
            if not found then
              memory_only("No cache password")
              return done(nil)
            end
            store_key(collection, found, function()
              done(found)
            end)
          end)
        else
          create_key(collection, done)
        end
      end)
    end)
  end)
end

--- The cache key: callback(key), nil when neither the "workhorse" keyring nor the password
--- gave it. Looked up once per session; `retry` looks up again after a failed lookup
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
