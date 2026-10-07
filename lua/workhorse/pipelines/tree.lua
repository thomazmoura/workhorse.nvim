-- Pipeline definitions as an indented tree of folders: rendering, parsing the edited lines
-- back and diffing them against the definitions. A folder line ends with "/" ("Infra/"), a
-- pipeline line is "#ID | name", any other line is a new pipeline. A line belongs to the
-- nearest folder line above it one level less indented.
local M = {}

local tree_parser = require("workhorse.buffer_tree.parser")
local tree_render = require("workhorse.buffer_tree.render")

local ns = vim.api.nvim_create_namespace("workhorse_pipelines")

local function ci_less(a, b)
  return a:lower() < b:lower()
end

-- Folder names of a "\Infra\Web" path ({} for the root)
local function segments(path)
  local result = {}
  for part in (path or ""):gmatch("[^\\/]+") do
    local name = vim.trim(part)
    if name ~= "" then
      table.insert(result, name)
    end
  end
  return result
end

--- Canonical form of a definition path: "\" for the root, "\Infra\Web" otherwise
function M.normalize_path(path)
  return "\\" .. table.concat(segments(path), "\\")
end

--- Lines of the tree of `definitions` ({ id, name, path }): folders first, then pipelines,
--- each sorted by name
function M.render(definitions)
  local root = { folders = {}, pipelines = {} }
  for _, d in ipairs(definitions or {}) do
    local node = root
    for _, name in ipairs(segments(d.path)) do
      node.folders[name] = node.folders[name] or { folders = {}, pipelines = {} }
      node = node.folders[name]
    end
    table.insert(node.pipelines, d)
  end

  local lines = {}
  local function emit(node, level)
    local prefix = tree_render.indent_prefix(level)
    local names = vim.tbl_keys(node.folders)
    table.sort(names, ci_less)
    for _, name in ipairs(names) do
      table.insert(lines, prefix .. name .. "/")
      emit(node.folders[name], level + 1)
    end
    table.sort(node.pipelines, function(a, b)
      return ci_less(a.name, b.name)
    end)
    for _, d in ipairs(node.pipelines) do
      table.insert(lines, ("%s#%d | %s"):format(prefix, d.id, d.name))
    end
  end
  emit(root, 0)
  return lines
end

--- The line of a pipeline at `level` (used to give a created pipeline its id)
function M.pipeline_line(level, id, name)
  return ("%s#%d | %s"):format(tree_render.indent_prefix(level), id, name)
end

-- Kind, level and content of a line, nil for blank lines:
-- { kind = "folder", names } | { kind = "pipeline", id, name } | { kind = "new", name }
local function parse_line(line)
  if not line or line:match("^%s*$") then
    return nil
  end
  local level, rest = tree_parser.parse_indent(line)
  rest = vim.trim(rest)
  -- Bytes of the indent (rest is the end of the line, without trailing whitespace)
  local item = { level = level, prefix_len = #(line:gsub("%s+$", "")) - #rest }
  local id, name = rest:match("^#(%d+)%s*|%s*(.-)$")
  if id then
    item.kind, item.id, item.name = "pipeline", tonumber(id), vim.trim(name)
  elseif rest:match("[\\/]$") then
    item.kind, item.names = "folder", segments(rest)
  else
    item.kind, item.name = "new", rest
  end
  return item
end

--- Parse the buffer lines: items { kind, level, lnum, path, id, name } of the pipelines (kind
--- "pipeline" or "new") and folders, plus a list of errors
function M.parse(lines)
  local items, errors = {}, {}
  -- Open folders: { level, names }
  local stack = {}
  for lnum, line in ipairs(lines) do
    local item = parse_line(line)
    if item then
      item.lnum = lnum
      while #stack > 0 and stack[#stack].level >= item.level do
        table.remove(stack)
      end
      if item.level > 0 and (#stack == 0 or stack[#stack].level ~= item.level - 1) then
        table.insert(errors, ("Line %d: indented without a folder line (ending in /) right above"):format(lnum))
      end
      local names = {}
      for _, folder in ipairs(stack) do
        vim.list_extend(names, folder.names)
      end
      item.path = "\\" .. table.concat(names, "\\")
      if item.kind == "folder" then
        if #item.names == 0 then
          table.insert(errors, ("Line %d: folder without a name"):format(lnum))
        end
        table.insert(stack, { level = item.level, names = item.names })
      elseif item.name == "" then
        table.insert(errors, ("Line %d: pipeline without a name"):format(lnum))
      end
      table.insert(items, item)
    end
  end
  return items, errors
end

--- Changes from `originals` ({ [id] = { name, path } }) to the parsed `items`:
--- { moves = { { id, name, path, old_name, old_path } }, creates = { { name, path, lnum, level } },
---   deletes = { { id, name, path } } }, plus a list of errors
function M.detect(originals, items)
  local changes = { moves = {}, creates = {}, deletes = {} }
  local errors, seen = {}, {}
  for _, item in ipairs(items) do
    if item.kind == "pipeline" then
      local original = originals[item.id]
      if not original then
        table.insert(errors, ("Line %d: #%d is not a pipeline of this list"):format(item.lnum, item.id))
      elseif seen[item.id] then
        table.insert(errors, ("Line %d: #%d appears more than once"):format(item.lnum, item.id))
      else
        seen[item.id] = true
        local old_path = M.normalize_path(original.path)
        if item.name ~= original.name or item.path ~= old_path then
          table.insert(changes.moves, {
            id = item.id,
            name = item.name,
            path = item.path,
            old_name = original.name,
            old_path = old_path,
            lnum = item.lnum,
          })
        end
      end
    elseif item.kind == "new" then
      table.insert(changes.creates, { name = item.name, path = item.path, lnum = item.lnum, level = item.level })
    end
  end
  for id, original in pairs(originals) do
    if not seen[id] then
      table.insert(changes.deletes, { id = id, name = original.name, path = M.normalize_path(original.path) })
    end
  end
  table.sort(changes.deletes, function(a, b)
    if a.path ~= b.path then
      return ci_less(a.path, b.path)
    end
    return ci_less(a.name, b.name)
  end)
  return changes, errors
end

--- Number of changes of a detect result
function M.count(changes)
  return #changes.moves + #changes.creates + #changes.deletes
end

--- Highlights of the buffer, plus hints of the pending changes when `originals` is given
function M.decorate(bufnr, originals)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local cfg = require("workhorse.config").get()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = M.parse(lines)
  local moves = {}
  if originals then
    for _, move in ipairs(M.detect(originals, items).moves) do
      moves[move.lnum] = move
    end
  end

  for _, item in ipairs(items) do
    local row, line = item.lnum - 1, lines[item.lnum]
    if item.prefix_len > 0 and cfg.tree_indent_hl and cfg.tree_indent_hl ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = item.prefix_len, hl_group = cfg.tree_indent_hl })
    end
    if item.kind == "folder" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, item.prefix_len, { end_col = #line, hl_group = "Directory" })
    elseif item.kind == "pipeline" then
      local bar = line:find("|", item.prefix_len + 1, true)
      if bar then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, item.prefix_len, { end_col = bar, hl_group = "Comment" })
      end
      local move = moves[item.lnum]
      if move then
        local hints = {}
        if move.path ~= move.old_path then
          table.insert(hints, "from " .. move.old_path)
        end
        if move.name ~= move.old_name then
          table.insert(hints, "was " .. move.old_name)
        end
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
          virt_text = { { "  [" .. table.concat(hints, ", ") .. "]", "DiagnosticWarn" } },
        })
      end
    elseif originals then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { { "  [new]", "DiagnosticOk" } } })
    end
  end
end

return M
