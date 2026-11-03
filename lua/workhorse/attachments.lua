-- Local files to attach to work items (the Attachments section of buffer/details.lua): listed
-- from the attachment folders, shared with paperboy.nvim. The folders are attachments.dirs of
-- setup(); unset, paperboy's compose.attachment_dirs (when paperboy is installed), else
-- $PAPERBOY_ATTACHMENT_DIRS
local M = {}

local config = require("workhorse.config")

--- Folders to list attachments from
---@return table
function M.dirs()
  local dirs = (config.get().attachments or {}).dirs
  if dirs == nil then
    -- paperboy's config already falls back to $PAPERBOY_ATTACHMENT_DIRS, once set up
    local ok, paperboy = pcall(require, "paperboy.config")
    local compose = ok and type(paperboy.get) == "function" and (paperboy.get() or {}).compose
    dirs = type(compose) == "table" and compose.attachment_dirs or nil
  end
  if dirs == nil and (vim.env.PAPERBOY_ATTACHMENT_DIRS or "") ~= "" then
    dirs = vim.split(vim.env.PAPERBOY_ATTACHMENT_DIRS, ":", { trimempty = true })
  end
  if type(dirs) == "string" then
    dirs = { dirs }
  end
  return vim.tbl_map(vim.fs.normalize, type(dirs) == "table" and dirs or {})
end

-- The last listing, reused for a moment: the completion asks for it on every keystroke
local cached, cached_at = nil, 0
local CACHE_MS = 2000

--- Files of the attachment folders (not their subfolders, hidden files left out), newest first
--- (by creation time when the file system records it, or last modification)
---@return table List of { path, name, time, size }
function M.list()
  if cached and vim.uv.now() - cached_at < CACHE_MS then
    return cached
  end
  local files = {}
  for _, dir in ipairs(M.dirs()) do
    local handle = vim.uv.fs_scandir(dir)
    while handle do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if (kind == "file" or kind == "link") and not name:match("^%.") then
        local path = dir .. "/" .. name
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == "file" then
          local birth = stat.birthtime and stat.birthtime.sec or 0
          table.insert(files, { path = path, name = name, time = math.max(birth, stat.mtime.sec), size = stat.size })
        end
      end
    end
  end
  table.sort(files, function(a, b)
    if a.time ~= b.time then
      return a.time > b.time
    end
    return a.path < b.path
  end)
  cached, cached_at = files, vim.uv.now()
  return files
end

--- The file a line of the section names: a path (absolute, ~ or relative to the working
--- directory), or the name of a file in an attachment folder
---@param text string
---@return string|nil path, table|nil stat
function M.resolve(text)
  local candidates = { vim.fn.fnamemodify(vim.fs.normalize(text), ":p") }
  if not text:find("/", 1, true) then
    for _, dir in ipairs(M.dirs()) do
      table.insert(candidates, dir .. "/" .. text)
    end
  end
  for _, path in ipairs(candidates) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      return path, stat
    end
  end
end

--- "12 KB" of a size in bytes
function M.format_size(bytes)
  if not bytes then
    return ""
  end
  for _, unit in ipairs({ "B", "KB", "MB" }) do
    if bytes < 1024 then
      return ((unit == "B" and "%d %s" or "%.1f %s"):format(bytes, unit):gsub("%.0 ", " "))
    end
    bytes = bytes / 1024
  end
  return (("%.1f GB"):format(bytes):gsub("%.0 ", " "))
end

return M
