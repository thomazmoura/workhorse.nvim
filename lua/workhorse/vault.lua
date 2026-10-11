-- Secrets of workhorse.nvim and paperboy.nvim (the Azure DevOps PAT, the Exchange password,
-- the keys of the encrypted caches), encrypted with a master password that is never stored.
-- This file is kept identical in both plugins (lua/workhorse/vault.lua, lua/paperboy/vault.lua):
-- the same vault, the same master password, asked once per Neovim for both.
--
-- Each secret is sealed with AES-256-GCM (its name authenticated with it) under a key derived
-- from the master password by PBKDF2-SHA256, 600000 iterations, in this process through
-- libcrypto (LuaJIT FFI): neither the password nor a secret is ever in another process's
-- argv, environment or stdin. Only the sealed text is stored, so the keyrings holding it can
-- be unlocked at login: nothing in them is readable without the master password.
--
-- Where: the Secret Service (GNOME Keyring) through secret-tool, an item "ns/name" in the
-- keyring labelled "ns" (Passwords and Keys) when there is one, the default keyring otherwise.
-- Without a Secret Service (or secret-tool, gdbus), files in $XDG_DATA_HOME/nvim-vault/ns/name
-- (mode 0600). $NVIM_VAULT_BACKEND = "keyring" or "file" forces one. The vault never unlocks a
-- keyring (that prompt may be out of reach, over SSH): a locked one is reported instead.
--
-- The master password is kept in memory, in state shared by both copies of this file through
-- package.loaded. Plaintext items from before the vault (`legacy` attributes) are moved into
-- it on first read. On the command line: bin/nvim-vault (M.main); in Neovim: :NvimVault.
local M = {}

local ffi = require("ffi")

local FORMAT = "nvim-vault:1"
local ITERATIONS = 600000
local NAME_PATTERN = "^[%w._-]+/[%w._-]+$"
local ATTRIBUTE = "nvim-vault"
local ITEM_ATTRIBUTE = "nvim-vault-item"
local LABEL_PREFIX = "nvim-vault "
local COLLECTION_PREFIX = "/org/freedesktop/secrets/collection/"
local DEFAULT_COLLECTION = "/org/freedesktop/secrets/aliases/default"
local SECRETS_BUS = { "gdbus", "call", "--session", "--dest", "org.freedesktop.secrets" }
local EVP_CTRL_GCM_GET_TAG = 0x10
local EVP_CTRL_GCM_SET_TAG = 0x11
local PR_SET_DUMPABLE = 4

-- Shared by both copies of this file: { password, salt, keys = { [salt] = key }, waiting,
-- declined, backend, prompt }
local state = package.loaded["nvim-vault.state"]
if type(state) ~= "table" then
  state = { keys = {} }
  package.loaded["nvim-vault.state"] = state
end

local function notify(message, level)
  if #vim.api.nvim_list_uis() == 0 then
    -- Headless (bin/nvim-vault, the paperboy-unread daemon): a line on the terminal
    io.stderr:write("nvim-vault: " .. message .. "\n")
    return
  end
  vim.notify("Vault: " .. message, level or vim.log.levels.INFO)
end

-- Crypto (libcrypto through LuaJIT FFI) -----------------------------------------------------

local DECLARATIONS = {
  "int PKCS5_PBKDF2_HMAC(const char *, int, const unsigned char *, int, int, const void *, int, unsigned char *);",
  "const void *EVP_sha256(void);",
  "const void *EVP_aes_256_gcm(void);",
  "void *EVP_CIPHER_CTX_new(void);",
  "void EVP_CIPHER_CTX_free(void *);",
  "int EVP_CIPHER_CTX_ctrl(void *, int, int, void *);",
  "int EVP_EncryptInit_ex(void *, const void *, void *, const unsigned char *, const unsigned char *);",
  "int EVP_EncryptUpdate(void *, unsigned char *, int *, const unsigned char *, int);",
  "int EVP_EncryptFinal_ex(void *, unsigned char *, int *);",
  "int EVP_DecryptInit_ex(void *, const void *, void *, const unsigned char *, const unsigned char *);",
  "int EVP_DecryptUpdate(void *, unsigned char *, int *, const unsigned char *, int);",
  "int EVP_DecryptFinal_ex(void *, unsigned char *, int *);",
  "int RAND_bytes(unsigned char *, int);",
  "int prctl(int, unsigned long, unsigned long, unsigned long, unsigned long);",
}

local crypto = nil

--- libcrypto, nil when it cannot be loaded
local function lib()
  if crypto == nil then
    -- One at a time: a declaration the other copy of this file made already fails alone
    for _, declaration in ipairs(DECLARATIONS) do
      pcall(ffi.cdef, declaration)
    end
    crypto = false
    for _, name in ipairs({ "crypto", "libcrypto.so.3", "libcrypto.so.1.1" }) do
      local ok, loaded = pcall(ffi.load, name)
      if ok then
        crypto = loaded
        break
      end
    end
  end
  return crypto or nil
end

---@return string|nil bytes
local function random(size)
  local buffer = ffi.new("unsigned char[?]", size)
  if lib().RAND_bytes(buffer, size) ~= 1 then
    return nil
  end
  return ffi.string(buffer, size)
end

--- The key for `salt` (bytes): derived from the master password once per salt
local function derive(salt)
  if not state.keys[salt] then
    local key = ffi.new("unsigned char[32]")
    local C = lib()
    if C.PKCS5_PBKDF2_HMAC(state.password, #state.password, salt, #salt, ITERATIONS, C.EVP_sha256(), 32, key) ~= 1 then
      error("PBKDF2 failed")
    end
    state.keys[salt] = ffi.string(key, 32)
  end
  return state.keys[salt]
end

--- Encrypt `plaintext` under the current master password
---@return string sealed text: FORMAT:iterations:salt:iv:ciphertext:tag (base64 fields)
local function seal(name, plaintext)
  local C = lib()
  local key, iv = derive(state.salt), random(12)
  local out = ffi.new("unsigned char[?]", #plaintext + 16)
  local tag = ffi.new("unsigned char[16]")
  local length, final = ffi.new("int[1]"), ffi.new("int[1]")
  local ctx = C.EVP_CIPHER_CTX_new()
  local ok = iv ~= nil
    and C.EVP_EncryptInit_ex(ctx, C.EVP_aes_256_gcm(), nil, key, iv) == 1
    and C.EVP_EncryptUpdate(ctx, nil, length, name, #name) == 1
    and C.EVP_EncryptUpdate(ctx, out, length, plaintext, #plaintext) == 1
    and C.EVP_EncryptFinal_ex(ctx, out + length[0], final) == 1
    and C.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) == 1
  C.EVP_CIPHER_CTX_free(ctx)
  if not ok then
    error("AES-GCM encryption failed")
  end
  local b64 = vim.base64.encode
  return table.concat({
    FORMAT,
    tostring(ITERATIONS),
    b64(state.salt),
    b64(iv),
    b64(ffi.string(out, length[0] + final[0])),
    b64(ffi.string(tag, 16)),
  }, ":")
end

--- Decrypt a sealed text with the master password
---@return string|nil plaintext: nil when the password is wrong (or the text was altered)
---@return string|nil salt of the sealed text
local function open(name, sealed)
  local iterations, salt, iv, ciphertext, tag =
    sealed:match("^" .. vim.pesc(FORMAT) .. ":(%d+):([^:]+):([^:]+):([^:]*):([^:]+)$")
  if tonumber(iterations) ~= ITERATIONS then
    return nil
  end
  local ok, decoded = pcall(function()
    local d = vim.base64.decode
    return { d(salt), d(iv), d(ciphertext), d(tag) }
  end)
  if not ok then
    return nil
  end
  salt, iv, ciphertext, tag = unpack(decoded)
  local C = lib()
  local out = ffi.new("unsigned char[?]", #ciphertext + 16)
  local length, final = ffi.new("int[1]"), ffi.new("int[1]")
  local tag_buffer = ffi.new("unsigned char[16]")
  ffi.copy(tag_buffer, tag, math.min(#tag, 16))
  local ctx = C.EVP_CIPHER_CTX_new()
  local opened = #tag == 16
    and C.EVP_DecryptInit_ex(ctx, C.EVP_aes_256_gcm(), nil, derive(salt), iv) == 1
    and C.EVP_DecryptUpdate(ctx, nil, length, name, #name) == 1
    and C.EVP_DecryptUpdate(ctx, out, length, ciphertext, #ciphertext) == 1
    and C.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag_buffer) == 1
    and C.EVP_DecryptFinal_ex(ctx, out + length[0], final) == 1
  C.EVP_CIPHER_CTX_free(ctx)
  if not opened then
    return nil
  end
  return ffi.string(out, length[0] + final[0]), salt
end

-- Processes ---------------------------------------------------------------------------------

--- Run a command; callback(code, stdout, stderr) on the main loop (code -1: not found)
local function run(cmd, callback, stdin)
  local ok, err = pcall(vim.system, cmd, { stdin = stdin, text = true }, function(result)
    vim.schedule(function()
      callback(result.code, result.stdout or "", result.stderr or "")
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback(-1, "", tostring(err))
    end)
  end
end

-- Keyring backend (Secret Service through secret-tool) -------------------------------------

--- Read a D-Bus property of the Secret Service (never prompts); callback(output or nil)
local function get_property(path, interface, property, callback)
  local cmd = vim.list_extend(vim.deepcopy(SECRETS_BUS), {
    "--object-path",
    path,
    "--method",
    "org.freedesktop.DBus.Properties.Get",
    interface,
    property,
  })
  run(cmd, function(code, stdout)
    callback(code == 0 and stdout or nil)
  end)
end

--- Object path of the keyring labelled `label` (its path may differ: gnome-keyring derives
--- it from a file name that may get a suffix, paperboy_5f1); callback(path or nil)
local function find_collection(label, callback)
  get_property("/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "Collections", function(output)
    local paths = {}
    for id in (output or ""):gmatch(vim.pesc(COLLECTION_PREFIX) .. "([^']+)") do
      table.insert(paths, COLLECTION_PREFIX .. id)
    end
    local pending, found = #paths, nil
    if pending == 0 then
      return callback(nil)
    end
    for _, path in ipairs(paths) do
      get_property(path, "org.freedesktop.Secret.Collection", "Label", function(value)
        if value and value:match("^%(<'(.*)'>,%)") == label then
          found = found or path
        end
        pending = pending - 1
        if pending == 0 then
          callback(found)
        end
      end)
    end
  end)
end

--- Where an item goes: the keyring labelled as its namespace, or the default one.
--- callback(path or nil for the default, error): an error when that keyring is locked
local function target_collection(name, callback)
  local namespace = name:match("^[^/]+")
  find_collection(namespace, function(path)
    get_property(path or DEFAULT_COLLECTION, "org.freedesktop.Secret.Collection", "Locked", function(output)
      if output and output:find("false", 1, true) then
        return callback(path, nil)
      end
      callback(nil, ("the %s keyring is locked: unlock it in Passwords and Keys (or set it to unlock at login)")
        :format(path and ("%q"):format(namespace) or "default"))
    end)
  end)
end

--- Items found by `secret-tool search --all` (never prompts): a list of { label, secret,
--- modified }, secret nil for an item in a locked keyring. callback(items or nil, error)
local function search(attributes, callback)
  local cmd = vim.list_extend({ "secret-tool", "search", "--all" }, attributes)
  run(cmd, function(code, stdout, stderr)
    if code ~= 0 then
      return callback(nil, "secret-tool search failed: " .. vim.trim(stderr))
    end
    local items, item = {}, nil
    for line in stdout:gmatch("[^\n]+") do
      if line:match("^%[") then
        item = {}
        table.insert(items, item)
      elseif item then
        local key, value = line:match("^(%w+) = (.*)$")
        if key then
          item[key] = value
        end
      end
    end
    callback(items, nil)
  end)
end

local keyring = { name = "keyring" }

function keyring.list(callback)
  search({ ATTRIBUTE, "1" }, function(found, err)
    if not found then
      return callback(nil, err)
    end
    -- An item moved to another keyring may leave a copy behind: the newest one wins
    local items = {}
    for _, item in ipairs(found) do
      local name = (item.label or ""):match("^" .. vim.pesc(LABEL_PREFIX) .. "(.+)$")
      if name and (not items[name] or (item.modified or "") > items[name].modified) then
        items[name] = { sealed = item.secret, modified = item.modified or "" }
      end
    end
    callback(items, nil)
  end)
end

function keyring.write(name, sealed, callback)
  target_collection(name, function(path, err)
    if err then
      return callback(err)
    end
    local cmd = { "secret-tool", "store", "--label=" .. LABEL_PREFIX .. name }
    if path then
      table.insert(cmd, "--collection=" .. path)
    end
    vim.list_extend(cmd, { ATTRIBUTE, "1", ITEM_ATTRIBUTE, name })
    run(cmd, function(code, _, stderr)
      callback(code ~= 0 and ("secret-tool store failed: " .. vim.trim(stderr)) or nil)
    end, sealed)
  end)
end

function keyring.remove(name, callback)
  target_collection(name, function(_, err)
    if err then
      return callback(err)
    end
    -- Exit code 1 without a message: there was nothing to delete
    run({ "secret-tool", "clear", ATTRIBUTE, "1", ITEM_ATTRIBUTE, name }, function(code, _, stderr)
      callback(code ~= 0 and vim.trim(stderr) ~= "" and ("secret-tool clear failed: " .. vim.trim(stderr)) or nil)
    end)
  end)
end

--- A plaintext item from before the vault: callback(secret or nil, error), an error when it
--- is in a locked keyring
function keyring.legacy(attributes, callback)
  search(attributes, function(found, err)
    if not found or #found == 0 then
      return callback(nil, err)
    end
    for _, item in ipairs(found) do
      if item.secret then
        return callback(item.secret, nil)
      end
    end
    callback(nil, ("%s is still in plaintext in a locked keyring: unlock it once (Passwords and Keys) "
      .. "to move it into the vault"):format(table.concat(attributes, " ")))
  end)
end

--- Remove the plaintext items (all copies, in every unlocked keyring)
function keyring.clear_legacy(attributes, callback)
  run(vim.list_extend({ "secret-tool", "clear" }, attributes), function(code, _, stderr)
    callback(code ~= 0 and ("secret-tool clear failed: " .. vim.trim(stderr)) or nil)
  end)
end

-- File backend ------------------------------------------------------------------------------

local file = { name = "file" }

function file.dir()
  return (vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")) .. "/nvim-vault"
end

local function file_path(name)
  return file.dir() .. "/" .. name
end

function file.list(callback)
  local items = {}
  for _, path in ipairs(vim.fn.glob(file.dir() .. "/*/*", false, true)) do
    local name = path:sub(#file.dir() + 2)
    local handle = name:match(NAME_PATTERN) and io.open(path, "rb")
    if handle then
      items[name] = { sealed = vim.trim(handle:read("*a") or ""), modified = "" }
      handle:close()
    end
  end
  vim.schedule(function()
    callback(items, nil)
  end)
end

function file.write(name, sealed, callback)
  local target = file_path(name)
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p", tonumber("700", 8))
  local tmp = target .. ".tmp"
  vim.uv.fs_unlink(tmp)
  local fd, err = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
  if fd then
    vim.uv.fs_write(fd, sealed .. "\n", 0)
    vim.uv.fs_close(fd)
    local ok, rename_err = vim.uv.fs_rename(tmp, target)
    err = not ok and rename_err or nil
  end
  vim.schedule(function()
    callback(err and ("cannot write " .. target .. ": " .. err) or nil)
  end)
end

function file.remove(name, callback)
  vim.uv.fs_unlink(file_path(name))
  vim.schedule(function()
    callback(nil)
  end)
end

function file.legacy(_, callback)
  vim.schedule(function()
    callback(nil, nil)
  end)
end

-- Backend choice ----------------------------------------------------------------------------

--- callback(backend): the keyring when the Secret Service answers, files otherwise. Chosen
--- once per process
local function backend(callback)
  if state.backend then
    return vim.schedule(function()
      callback(state.backend)
    end)
  end
  local forced = vim.env.NVIM_VAULT_BACKEND
  if forced == "file" or forced == "keyring" then
    state.backend = forced == "file" and file or keyring
    state.backend_reason = "$NVIM_VAULT_BACKEND"
    return backend(callback)
  end
  if vim.fn.executable("secret-tool") == 0 or vim.fn.executable("gdbus") == 0 then
    state.backend, state.backend_reason = file, "secret-tool or gdbus not installed"
    return backend(callback)
  end
  get_property("/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "Collections", function(output)
    if not state.backend then
      state.backend = output and keyring or file
      state.backend_reason = output and "Secret Service" or "no Secret Service on the session bus"
      if not output then
        notify(("No Secret Service: secrets are kept in %s"):format(file.dir()), vim.log.levels.WARN)
      end
    end
    callback(state.backend)
  end)
end

-- Master password ---------------------------------------------------------------------------

--- Read a line from the terminal without echoing it (no UI: the command line, daemons)
local function tty_prompt(message)
  local tty = io.open("/dev/tty", "r+")
  if not tty then
    return ""
  end
  tty:write(message)
  tty:flush()
  os.execute("stty -echo < /dev/tty")
  local ok, line = pcall(tty.read, tty, "*l")
  os.execute("stty echo < /dev/tty")
  tty:write("\n")
  tty:close()
  return ok and line or ""
end

--- Ask a secret: nil when left empty (or <C-c>)
local function ask(message)
  local prompt = state.prompt
  if not prompt then
    prompt = #vim.api.nvim_list_uis() > 0 and vim.fn.inputsecret or tty_prompt
  end
  local ok, value = pcall(prompt, message)
  if #vim.api.nvim_list_uis() > 0 then
    vim.cmd("redraw")
  end
  if ok and type(value) == "string" and value ~= "" then
    return value
  end
end

--- Ask a new master password twice: nil when left empty or mistyped twice
local function ask_new(message)
  for _ = 1, 2 do
    local password = ask(message)
    if not password then
      return nil
    end
    if ask("Repeat it: ") == password then
      return password
    end
    notify("The passwords do not match", vim.log.levels.WARN)
  end
end

local function use_password(password, salt)
  state.password, state.salt, state.keys = password, salt, {}
end

--- Does the master password in memory open one of `items`? Returns its salt. Any one will
--- do: an item altered (or sealed under another password) does not reject the right password
local function opens_any(items)
  local names = vim.tbl_keys(items)
  table.sort(names)
  for _, name in ipairs(names) do
    if items[name].sealed then
      local _, salt = open(name, items[name].sealed)
      if salt then
        return salt
      end
    end
  end
end

local function finish_unlock(ok, err)
  local callbacks = state.waiting or {}
  state.waiting = nil
  for _, callback in ipairs(callbacks) do
    callback(ok, err)
  end
end

--- Ask the master password (once per process: kept in memory) and check it against the
--- vault, or create it when the vault is empty. callback(ok, error). After the password was
--- not entered, later calls fail without asking, unless `retry`
---@param callback function
---@param retry boolean|nil
function M.unlock(callback, retry)
  if not lib() then
    return vim.schedule(function()
      callback(false, "libcrypto not found (install OpenSSL)")
    end)
  end
  if state.password then
    return vim.schedule(function()
      callback(true, nil)
    end)
  end
  if state.declined and not retry then
    return vim.schedule(function()
      callback(false, "master password not entered (:NvimVault unlock to enter it)")
    end)
  end
  if state.waiting then
    return table.insert(state.waiting, callback)
  end
  state.waiting = { callback }
  state.declined = false

  backend(function(b)
    b.list(function(items, err)
      if not items then
        return finish_unlock(false, err)
      end
      local sealed = {}
      for name, item in pairs(items) do
        sealed[name] = item.sealed and item or nil
      end
      if not next(sealed) then
        if next(items) then
          return finish_unlock(false, "every vault item is in a locked keyring: unlock it (Passwords and Keys)")
        end
        notify(("Create the master password of the Workhorse and Paperboy secrets (kept in %s)")
          :format(b == keyring and "the keyring" or file.dir()))
        local password = ask_new("New master password: ")
        if not password then
          state.declined = true
          return finish_unlock(false, "master password not entered")
        end
        use_password(password, random(16))
        return finish_unlock(true, nil)
      end
      for attempt = 1, 3 do
        local password = ask("Master password (Workhorse and Paperboy secrets): ")
        if not password then
          break
        end
        use_password(password, nil)
        local salt = opens_any(sealed)
        if salt then
          state.salt = salt
          return finish_unlock(true, nil)
        end
        state.password = nil
        notify("Wrong master password" .. (attempt < 3 and ", try again" or ""), vim.log.levels.WARN)
      end
      use_password(nil, nil)
      state.declined = true
      finish_unlock(false, "master password not entered")
    end)
  end)
end

--- Forget the master password (the next secret read asks it again)
function M.lock()
  use_password(nil, nil)
  state.declined = false
end

--- { backend = "keyring"|"file"|nil (not chosen yet), reason, unlocked }
function M.status()
  return {
    backend = state.backend and state.backend.name,
    reason = state.backend_reason,
    unlocked = state.password ~= nil,
  }
end

--- Ask secrets with this function instead of inputsecret() / the terminal
---@param fn function fn(message): the text typed
function M.set_prompt(fn)
  state.prompt = fn
end

-- Secrets -----------------------------------------------------------------------------------

local function check_name(name)
  if type(name) ~= "string" or not name:match(NAME_PATTERN) then
    error(("invalid vault item name %q (expected namespace/name)"):format(tostring(name)))
  end
end

--- Store a secret (encrypted with the master password, asked first when needed)
---@param name string "namespace/name", e.g. "workhorse/pat"
---@param value string
---@param callback function|nil Callback(error)
function M.set(name, value, callback)
  check_name(name)
  callback = callback or function() end
  M.unlock(function(ok, err)
    if not ok then
      return callback(err)
    end
    backend(function(b)
      b.write(name, seal(name, value), callback)
    end)
  end)
end

--- Delete a secret
---@param callback function|nil Callback(error)
function M.delete(name, callback)
  check_name(name)
  backend(function(b)
    b.remove(name, callback or function() end)
  end)
end

--- Names of the secrets in the vault (no password needed)
---@param callback function Callback(names, error): names sorted, nil on error
function M.list(callback)
  backend(function(b)
    b.list(function(items, err)
      if not items then
        return callback(nil, err)
      end
      local names = vim.tbl_keys(items)
      table.sort(names)
      callback(names, nil)
    end)
  end)
end

--- Read a secret, asking the master password first when needed (not when the vault does
--- not have that secret)
---@param name string "namespace/name"
---@param callback function Callback(value, error): both nil when the vault does not have it
---@param opts table|nil { legacy = attributes of a plaintext keyring item to move into the
---vault when it is missing, create = function returning a value to store when it is missing }
function M.get(name, callback, opts)
  check_name(name)
  opts = opts or {}

  local function read(retried)
    backend(function(b)
      b.list(function(items, list_err)
        if not items then
          return callback(nil, list_err)
        end
        local item = items[name]
        if item and not item.sealed then
          return callback(nil, ("%s is in a locked keyring: unlock it (Passwords and Keys)"):format(name))
        end
        if item then
          return M.unlock(function(ok, err)
            if not ok then
              return callback(nil, err)
            end
            local value = open(name, item.sealed)
            if value then
              return callback(value, nil)
            end
            if retried or opens_any(items) then
              return callback(nil, ("%s cannot be decrypted with the master password (altered?)"):format(name))
            end
            -- Changed in another process since it was entered here: asked again
            notify("The master password changed: enter the new one", vim.log.levels.WARN)
            M.lock()
            read(true)
          end)
        end

        local function create()
          if not opts.create then
            return callback(nil, nil)
          end
          local value = opts.create()
          if not value then
            return callback(nil, "could not create " .. name)
          end
          M.set(name, value, function(err)
            callback(not err and value or nil, err)
          end)
        end

        if not opts.legacy then
          return create()
        end
        b.legacy(opts.legacy, function(value, legacy_err)
          if legacy_err then
            return callback(nil, legacy_err)
          end
          if not value then
            return create()
          end
          M.set(name, value, function(err)
            if err then
              return callback(nil, err)
            end
            keyring.clear_legacy(opts.legacy, function(clear_err)
              notify(("Moved %s into the vault%s"):format(name, clear_err and (", but " .. clear_err) or ""))
              callback(value, nil)
            end)
          end)
        end)
      end)
    end)
  end
  read(false)
end

--- A new random key: 64 hex digits (256 bits), for opts.create of M.get
function M.random_key()
  local bytes = lib() and random(32)
  return bytes and (bytes:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end)) or nil
end

--- Change the master password: the current one (asked when not in memory) opens every
--- secret, which is encrypted again with the new one. Nothing changes when one fails.
---@param callback function|nil Callback(error)
function M.change_password(callback)
  callback = callback or function() end
  M.unlock(function(ok, err)
    if not ok then
      return callback(err)
    end
    backend(function(b)
      b.list(function(items, list_err)
        if not items then
          return callback(list_err)
        end
        local names, values = vim.tbl_keys(items), {}
        table.sort(names)
        for _, name in ipairs(names) do
          if not items[name].sealed then
            return callback(name .. " is in a locked keyring: unlock it first (Passwords and Keys)")
          end
          values[name] = open(name, items[name].sealed)
          if not values[name] then
            return callback(name .. " cannot be decrypted with the current master password")
          end
        end

        local password = ask_new("New master password: ")
        if not password then
          return callback("new master password not entered")
        end
        local old_password, old_salt = state.password, state.salt
        use_password(password, random(16))

        -- One at a time; on a failure the ones written already get their old text back
        local function restore(failed, index, write_err)
          use_password(old_password, old_salt)
          local function next_restore(i)
            if i < 1 then
              return callback(("%s: %s (master password not changed)"):format(failed, write_err))
            end
            b.write(names[i], items[names[i]].sealed, function()
              next_restore(i - 1)
            end)
          end
          next_restore(index - 1)
        end
        local function write(index)
          local name = names[index]
          if not name then
            notify(("Master password changed (%d secrets encrypted again)"):format(#names))
            return callback(nil)
          end
          b.write(name, seal(name, values[name]), function(write_err)
            if write_err then
              return restore(name, index, write_err)
            end
            write(index + 1)
          end)
        end
        write(1)
      end)
    end)
  end)
end

-- Commands ----------------------------------------------------------------------------------

local USAGE = [[
Usage: nvim-vault list                 names of the secrets (no password needed)
       nvim-vault set NAME             store a secret, typed (hidden) or piped on stdin
       nvim-vault get NAME             print a secret
       nvim-vault delete NAME          delete a secret
       nvim-vault passwd               change the master password
In Neovim, :NvimVault takes the same commands (but get), plus unlock and lock (forget it).

Secrets of workhorse.nvim and paperboy.nvim, encrypted with a master password that is never
stored. Names: workhorse/pat (Azure DevOps PAT), paperboy/exchange-password, and the cache
keys workhorse/cache-key and paperboy/cache-key. In the keyring labelled after the part
before "/" (or the default one), or in $XDG_DATA_HOME/nvim-vault without a Secret Service.]]

--- Run a vault command: done(error, output)
---@param args table { command, name }
---@param read_value function|nil Returns the value for `set` (default: asked, hidden)
---@param done function
local function command(args, read_value, done)
  local cmd, name = args[1], args[2]
  local needs_name = cmd == "set" or cmd == "get" or cmd == "delete"
  if needs_name and not (name and name:match(NAME_PATTERN)) then
    return done("expected a name like workhorse/pat")
  end
  if cmd == "list" then
    M.list(function(names, err)
      if not names then
        return done(err)
      end
      local status = M.status()
      local where = status.backend == "file" and file.dir() or "the keyring"
      done(nil, (#names > 0 and table.concat(names, "\n") or "(no secrets)") .. ("\n(in %s)"):format(where))
    end)
  elseif cmd == "set" then
    -- The master password first: typing the secret before a wrong one would be wasted
    M.unlock(function(ok, err)
      if not ok then
        return done(err)
      end
      local value = (read_value or function()
        return ask(("Value of %s: "):format(name))
      end)()
      if not value or value == "" then
        return done("no value entered")
      end
      M.set(name, value, function(set_err)
        done(set_err, not set_err and ("Stored " .. name) or nil)
      end)
    end)
  elseif cmd == "get" then
    M.get(name, function(value, err)
      done(err or (not value and (name .. " is not in the vault")) or nil, value)
    end)
  elseif cmd == "delete" then
    M.delete(name, function(err)
      done(err, not err and ("Deleted " .. name) or nil)
    end)
  elseif cmd == "passwd" then
    M.change_password(function(err)
      done(err, not err and "Master password changed" or nil)
    end)
  elseif cmd == "unlock" then
    M.unlock(function(ok, err)
      done(not ok and err or nil, ok and "Unlocked" or nil)
    end, true)
  elseif cmd == "lock" then
    M.lock()
    done(nil, "Master password forgotten")
  else
    done(USAGE)
  end
end

--- :NvimVault list | set NAME | delete NAME | passwd | unlock | lock (defined by both plugins)
function M.create_command()
  vim.api.nvim_create_user_command("NvimVault", function(info)
    -- `get` is left out: a secret has no business in the message history
    if info.fargs[1] == "get" then
      return notify("get is only on the command line (bin/nvim-vault)", vim.log.levels.WARN)
    end
    command(info.fargs, nil, function(err, output)
      if err then
        notify(err, err == USAGE and vim.log.levels.INFO or vim.log.levels.ERROR)
      elseif output then
        notify(output)
      end
    end)
  end, {
    nargs = "*",
    desc = "Master-password vault of Workhorse and Paperboy",
    complete = function(_, line)
      if #vim.split(line, "%s+") <= 2 then
        return { "list", "set", "delete", "passwd", "unlock", "lock" }
      end
      return {}
    end,
  })
end

--- Entry point of bin/nvim-vault (nvim -l): run a command and exit
---@param args table Command line (the `arg` of nvim -l)
function M.main(args)
  local function finish(message, code)
    local out = code == 0 and io.stdout or io.stderr
    if message then
      out:write(message .. "\n")
    end
    out:flush()
    os.exit(code)
  end
  -- Non-dumpable: other processes of the same user can neither ptrace this one nor read
  -- its memory, and there are no core dumps
  if not lib() or lib().prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) ~= 0 then
    finish("nvim-vault: could not load libcrypto or make the process non-dumpable", 1)
  end
  if not args[1] or args[1] == "help" or args[1] == "--help" or args[1] == "-h" then
    finish(USAGE, 0)
  end

  local read_value = nil
  if vim.uv.guess_handle(0) ~= "tty" then
    -- Piped: `pass show x | nvim-vault set y`, a single trailing newline dropped
    read_value = function()
      return (io.read("*a") or ""):gsub("\r?\n$", "")
    end
  end
  local result = nil
  command(args, read_value, function(err, output)
    result = { err, output }
  end)
  vim.wait(24 * 3600 * 1000, function()
    return result ~= nil
  end, 20)
  if result[1] == USAGE then
    finish(USAGE, 2)
  elseif result[1] then
    finish("nvim-vault: " .. result[1], 1)
  end
  finish(result[2], 0)
end

return M
