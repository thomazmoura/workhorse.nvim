-- General section of the repository screen (repos_screen/repo.lua): the repository's settings
-- as "key: value" lines. For now only its default branch, completed from its branches:
--
--   Default branch: main
--
-- The new default branch must already exist on the server. A repository without branches shows
-- an empty value (its first push sets it). Saving (of the whole screen) shows the change, then
-- applies it; the repository table the screen shares (with the Policies section and the
-- repositories list) is updated in place.
local M = {}

local repo_screen = require("workhorse.repos_screen.repo")
local repos_api = require("workhorse.api.repositories")

local ns = vim.api.nvim_create_namespace("workhorse_repo_general")

local notify = repo_screen.notify

local SECTION = "general"
local DEFAULT_BRANCH = "Default branch"

-- Per-buffer state: { repo, branches = { name } (nil when they could not be listed), loading,
-- loaded, saving }
local buffers = {}

-- Lines of the section, the buffer line number before them, and whether the section is there
local function section(bufnr)
  local lines, offset = repo_screen.section_lines(bufnr, SECTION)
  return lines or {}, offset or 0, lines ~= nil
end

local function short(ref)
  return ((ref or ""):gsub("^refs/heads/", ""))
end

local function render(bufnr)
  local state = buffers[bufnr]
  repo_screen.set_section(bufnr, SECTION, { DEFAULT_BRANCH .. ": " .. short(state.repo.default_branch) })
  state.loaded = true
  repo_screen.update_modified(bufnr)
  repo_screen.decorate(bufnr)
end

-- Parsing and changes ---------------------------------------------------------

-- The section's lines (line i being buffer line offset + i): { branch = { value, lnum } }, plus
-- errors
local function parse(lines, offset)
  local result, errors = {}, {}
  for i, line in ipairs(lines) do
    if not line:match("^%s*$") then
      local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
      if key and vim.trim(key):lower() == DEFAULT_BRANCH:lower() and not result.branch then
        result.branch = { value = short(value), lnum = offset + i }
      else
        table.insert(errors, ("Line %d: not a setting: %s"):format(offset + i, vim.trim(line)))
      end
    end
  end
  return result, errors
end

-- The new default branch (nil when unchanged) and the errors that block saving it
local function detect(bufnr)
  local state = buffers[bufnr]
  local lines, offset, present = section(bufnr)
  if not present then
    return nil, { repo_screen.missing_header(SECTION) }
  end
  local parsed, errors = parse(lines, offset)
  local branch = parsed.branch and parsed.branch.value
  -- A missing line keeps it as it is
  if not branch or branch == short(state.repo.default_branch) then
    return nil, errors
  end
  if branch == "" then
    table.insert(errors, "The default branch cannot be emptied")
  elseif state.branches and not vim.tbl_contains(state.branches, branch) then
    table.insert(errors, ("No branch %s on the server (push it first)"):format(branch))
  end
  return #errors == 0 and branch or nil, errors
end

-- Decoration ------------------------------------------------------------------

function M.decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines, offset = section(bufnr)
  local parsed = parse(lines, offset)
  local function mark(lnum, opts)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  end
  local entry = parsed.branch
  if not entry then
    return
  end
  -- Columns of the buffer line, with its indent
  local line = vim.api.nvim_buf_get_lines(bufnr, entry.lnum - 1, entry.lnum, false)[1]
  local colon = line:find(":", 1, true)
  mark(entry.lnum, { col = #line:match("^%s*"), end_col = colon, hl_group = "WorkhorseRunKey" })
  mark(entry.lnum, { col = colon, end_col = #line, hl_group = "WorkhorseBuildBranch" })
  local before = short(state.repo.default_branch)
  local virt
  if entry.value == before then
    if before == "" then
      virt = { "  no branches yet: the first push sets it", "WorkhorseRunHint" }
    end
  elseif entry.value == "" then
    virt = { "  cannot be emptied", "WorkhorseRunRequired" }
  elseif state.branches and not vim.tbl_contains(state.branches, entry.value) then
    virt = { "  no such branch on the server", "WorkhorseRunRequired" }
  else
    virt = { "  [was " .. (before ~= "" and before or "none") .. "]", "DiagnosticWarn" }
  end
  if virt then
    mark(entry.lnum, { virt_text = { virt } })
  end
end

-- Loading ---------------------------------------------------------------------

-- Fetch the repository (its current default branch) and its branches, then render
local function load(bufnr)
  local state = buffers[bufnr]
  state.loading = true
  local pending, failed = 2, nil
  local function joined()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if failed then
      notify("Failed to load the repository " .. state.repo.name .. ": " .. failed, vim.log.levels.ERROR)
      return
    end
    render(bufnr)
  end
  repos_api.get(state.repo.id, function(fresh, err)
    if fresh then
      -- In place: the Policies section and the repositories list share the table
      state.repo.default_branch = fresh.default_branch
    else
      failed = tostring(err)
    end
    joined()
  end)
  repos_api.branches(state.repo.id, function(result)
    -- An empty repository has no refs to list (the Policies section warns about it)
    state.branches = result
    joined()
  end)
end

-- Saving ----------------------------------------------------------------------

--- The changes of the section to save: { entries = { { text, hl } } to confirm, apply(callback) }
--- (nil when there are none), or nil and an error
function M.prepare(bufnr)
  local state = buffers[bufnr]
  if not state or (not state.loaded and not state.loading) then
    return nil
  end
  if state.loading then
    return nil, "The repository is still loading"
  end
  if state.saving then
    return nil, "Already saving the default branch"
  end
  local branch, errors = detect(bufnr)
  if #errors > 0 then
    return nil, table.concat(errors, "\n")
  end
  if not branch then
    return nil
  end
  local before = short(state.repo.default_branch)
  local entries = { {
    text = ("Default branch: set to %s  (was %s)"):format(branch, before ~= "" and before or "none"),
    hl = "DiagnosticWarn",
  } }
  local function apply(callback)
    state.saving = true
    repos_api.set_default_branch(state.repo.id, branch, function(repo, err)
      state.saving = false
      if repo then
        state.repo.default_branch = repo.default_branch or ("refs/heads/" .. branch)
        notify(("Set the default branch of %s to %s"):format(state.repo.name, branch))
      else
        notify("Failed to set the default branch: " .. tostring(err), vim.log.levels.ERROR)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        load(bufnr)
      end
      callback()
    end)
  end
  return { entries = entries, apply = apply }
end

-- Buffer ----------------------------------------------------------------------

--- Whether the section has changes (or errors) to save
function M.pending(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded or state.loading then
    return false
  end
  local branch, errors = detect(bufnr)
  return branch ~= nil or #errors > 0
end

function M.saving(bufnr)
  return buffers[bufnr] ~= nil and buffers[bufnr].saving == true
end

--- Load the repository again, replacing the section
function M.reload(bufnr)
  load(bufnr)
end

-- Completion: the branches on the Default branch line, the key on a line still without its ":"
function M.choices(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if not line:find(":", 1, true) then
    return { DEFAULT_BRANCH .. ": " }
  end
  local state = buffers[bufnr]
  return state and state.branches or {}
end

function M.start(line)
  if not line:find(":", 1, true) then
    return #line:match("^%s*")
  end
end

function M.summary()
  return ""
end

--- Set up the General section of the repository screen `bufnr` (loaded by M.reload)
function M.attach(bufnr, repo)
  buffers[bufnr] = { repo = repo }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

return M
