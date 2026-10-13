-- Repositories of the project as a flat editable list: rendering, parsing the edited lines back
-- and diffing them against the repositories. A repository line is "#id | name", id being the
-- start of the repository's GUID (like a short commit hash: 8 characters, more when two
-- repositories share them); any other line is a new repository.
local M = {}

local ns = vim.api.nvim_create_namespace("workhorse_repos_list")

local SHORT_ID = 8

--- Short id of the repository `repo_id` (a GUID): its first characters, as many as needed to
--- differ from the keys of `taken` ({ [short id] = repo })
function M.short_id(repo_id, taken)
  local id = repo_id:lower():gsub("%-", "")
  local len = SHORT_ID
  while len < #id and taken[id:sub(1, len)] do
    len = len + 1
  end
  return id:sub(1, len)
end

--- Line of the repository with the short id `id`
function M.line(id, name)
  return ("#%s | %s"):format(id, name)
end

--- Lines of `originals` ({ [short id] = repo }), sorted by name
function M.render(originals)
  local keys = vim.tbl_keys(originals)
  table.sort(keys, function(a, b)
    return originals[a].name:lower() < originals[b].name:lower()
  end)
  return vim.tbl_map(function(id)
    return M.line(id, originals[id].name)
  end, keys)
end

--- Parse the buffer lines: items { kind = "repo"|"new", id, name, lnum }, plus a list of errors
function M.parse(lines)
  local items, errors = {}, {}
  for lnum, line in ipairs(lines) do
    local text = vim.trim(line)
    if text ~= "" then
      local id, name = text:match("^#(%x+)%s*|%s*(.-)$")
      local item = id and { kind = "repo", id = id:lower(), name = vim.trim(name), lnum = lnum }
        or { kind = "new", name = text, lnum = lnum }
      if item.name == "" then
        table.insert(errors, ("Line %d: repository without a name"):format(lnum))
      end
      table.insert(items, item)
    end
  end
  return items, errors
end

--- Changes from `originals` ({ [short id] = repo }) to the parsed `items`: { renames = { { id,
--- repo, name } }, creates = { { name, lnum } }, deletes = { { id, repo } } }, plus a list of errors
function M.detect(originals, items)
  local changes = { renames = {}, creates = {}, deletes = {} }
  local errors, seen, names = {}, {}, {}
  for _, item in ipairs(items) do
    local key = item.name:lower()
    if names[key] then
      table.insert(errors, ("Line %d: %s appears more than once"):format(item.lnum, item.name))
    end
    names[key] = true
    if item.kind == "repo" then
      local repo = originals[item.id]
      if not repo then
        table.insert(errors, ("Line %d: #%s is not a repository of this list"):format(item.lnum, item.id))
      elseif seen[item.id] then
        table.insert(errors, ("Line %d: #%s appears more than once"):format(item.lnum, item.id))
      else
        seen[item.id] = true
        if item.name ~= repo.name then
          table.insert(changes.renames, { id = item.id, repo = repo, name = item.name, lnum = item.lnum })
        end
      end
    else
      table.insert(changes.creates, { name = item.name, lnum = item.lnum })
    end
  end
  for id, repo in pairs(originals) do
    if not seen[id] then
      table.insert(changes.deletes, { id = id, repo = repo })
    end
  end
  table.sort(changes.deletes, function(a, b)
    return a.repo.name:lower() < b.repo.name:lower()
  end)
  return changes, errors
end

--- Number of changes of a detect result
function M.count(changes)
  return #changes.renames + #changes.creates + #changes.deletes
end

local function size_text(bytes)
  if not bytes or bytes == 0 then
    return "empty"
  end
  local units, value, unit = { "KB", "MB", "GB" }, bytes, "B"
  for _, u in ipairs(units) do
    if value < 1024 then
      break
    end
    value, unit = value / 1024, u
  end
  return unit == "B" and ("%d B"):format(value) or ("%.1f %s"):format(value, unit)
end

--- Highlights and hints of the buffer: the default branch and size of each repository, and the
--- pending renames and creations
function M.decorate(bufnr, originals)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = M.parse(lines)
  for _, item in ipairs(items) do
    local row, line = item.lnum - 1, lines[item.lnum]
    if item.kind == "repo" then
      local bar = line:find("|", 1, true)
      if bar then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = bar, hl_group = "Comment" })
      end
      local repo = originals[item.id]
      if repo then
        local virt = {}
        if item.name ~= repo.name then
          table.insert(virt, { "  [was " .. repo.name .. "]", "DiagnosticWarn" })
        end
        if repo.disabled then
          table.insert(virt, { "  disabled", "WorkhorseRepoDisabled" })
        end
        local branch = (repo.default_branch or ""):gsub("^refs/heads/", "")
        table.insert(virt, { "  " .. (branch ~= "" and branch or "no branches"), "WorkhorseBuildBranch" })
        table.insert(virt, { "  " .. size_text(repo.size), "WorkhorseBuildMeta" })
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = virt })
      end
    else
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { { "  [new]", "DiagnosticOk" } } })
    end
  end
end

return M
