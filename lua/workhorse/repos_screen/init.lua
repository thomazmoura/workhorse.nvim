-- Repositories screen (:Workhorse repos list, <leader>wG): the repositories of the configured
-- project as an editable list (see repos_screen/list.lua), like the All tab of the pipelines
-- screen. Saving applies the edits in order: renames right away, then each new line through a
-- pre-filled "New repository" form, then each deletion after its own confirmation (Keep puts the
-- line back). <C-c> on a form or Stop on a confirmation stops the rest of the save; what was
-- applied stays. <CR> on a
-- repository opens its General, Security and Policies screen (repos_screen/repo.lua).
local M = {}

local repos_api = require("workhorse.api.repositories")
local list = require("workhorse.repos_screen.list")

-- Created lines being saved, followed across edits
local mark_ns = vim.api.nvim_create_namespace("workhorse_repos_marks")

-- Per-buffer state: { originals = { [short id] = repo }, loading, loaded, saving }
local buffers = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

function M.is_repos_buffer(bufnr)
  return buffers[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

local function decorate(bufnr)
  local state = buffers[bufnr]
  if state and state.loaded and not state.loading then
    list.decorate(bufnr, state.originals)
  end
end

-- Pending changes of the buffer and the errors that block saving them
local function detect(bufnr)
  local items, errors = list.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local changes, detect_errors = list.detect(buffers[bufnr].originals, items)
  vim.list_extend(errors, detect_errors)
  return changes, errors
end

-- Fetch the repositories and render them, replacing the buffer content
local function load(bufnr, hard)
  local state = buffers[bufnr]
  state.loading = true
  if hard then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading repositories..." })
    vim.bo[bufnr].modified = false
  end
  repos_api.list(function(repos, err)
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if not repos then
      notify("Failed to list the repositories: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    state.originals = {}
    for _, repo in ipairs(repos) do
      state.originals[list.short_id(repo.id, state.originals)] = repo
    end
    local cursor = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, list.render(state.originals))
    vim.bo[bufnr].modified = false
    state.loaded = true
    decorate(bufnr)
    if cursor and not hard then
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end
  end)
end

-- The repository on the cursor line
local function current_repo(bufnr)
  local item = list.parse({ vim.api.nvim_get_current_line() })[1]
  if item and item.kind == "repo" then
    return buffers[bufnr].originals[item.id]
  end
end

local function with_repo(bufnr, fn)
  return function()
    local repo = current_repo(bufnr)
    if not repo then
      notify("No repository on this line (save a new one first)", vim.log.levels.WARN)
      return
    end
    fn(repo)
  end
end

local function setup_keymaps(bufnr)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<leader><leader>", function()
    M.save(bufnr)
  end, "apply the changes to the repositories")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the repositories")
  map("<CR>", with_repo(bufnr, function(repo)
    require("workhorse.repos_screen.repo").open(repo)
  end), "open the security and policies of the repository")
  local open_repo = with_repo(bufnr, function(repo)
    vim.ui.open(require("workhorse.api.pullrequests").repo_url(repo))
  end)
  map("gw", open_repo, "open the repository in the browser")
  map("gb", open_repo, "open the repository in the browser")
end

local function setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_repos_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.save(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      decorate(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
  })
end

--- Open the repositories screen in the current window (the existing buffer when already open; on
--- it, reload it)
function M.open()
  local current = vim.api.nvim_get_current_buf()
  if buffers[current] then
    M.refresh(current, { hard = true })
    return current
  end
  for bufnr in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_win_set_buf(0, bufnr)
      return bufnr
    end
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "Workhorse|repos")
  -- acwrite: :w saves (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-repos"
  buffers[bufnr] = { originals = {} }
  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  vim.api.nvim_win_set_buf(0, bufnr)
  load(bufnr, true)
  return bufnr
end

--- Reload the repositories from the server (asks first when there are unsaved changes). Returns
--- false when `bufnr` (default: current) is not the repositories screen
function M.refresh(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return false
  end
  if state.saving then
    notify("Wait for the save to finish", vim.log.levels.WARN)
    return true
  end
  if vim.bo[bufnr].modified and vim.fn.confirm("Discard the pending changes and reload?", "&Reload\n&Cancel", 2) ~= 1 then
    return true
  end
  load(bufnr, opts and opts.hard)
  return true
end

-- Save ------------------------------------------------------------------------

-- Show the repositories list in the current window (forms and confirmations return to it)
local function focus(bufnr)
  if vim.api.nvim_get_current_buf() == bufnr then
    return
  end
  local win = vim.fn.win_findbuf(bufnr)[1]
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.api.nvim_win_set_buf(0, bufnr)
  end
end

-- Give the created line (followed by `mark`) its short id
local function mark_created(bufnr, mark, id, repo)
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, mark_ns, mark, { details = true })
  if not ok or not pos[1] or (pos[3] and pos[3].invalid) then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, pos[1], pos[1] + 1, false, { list.line(id, repo.name) })
end

-- Put back the line of a repository kept at a deletion's confirmation, before the first line of
-- a repository sorting after it
local function restore_line(bufnr, id, repo)
  local row = vim.api.nvim_buf_line_count(bufnr)
  for _, item in ipairs((list.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))) do
    if item.kind == "repo" and item.name:lower() > repo.name:lower() then
      row = item.lnum - 1
      break
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { list.line(id, repo.name) })
end

-- Ask to delete one repository (its line is gone, so the prompt names it): 1 delete, 2 keep it,
-- anything else stops the deletions. Deleting asks to type its name: anything else keeps it.
local function confirm_delete(repo)
  local branch = (repo.default_branch or ""):gsub("^refs/heads/", "")
  local prompt = ("Delete repository %s%s? Its branches, pull requests and history go with it."):format(
    repo.name, branch ~= "" and (" (default branch " .. branch .. ")") or "")
  local choice = vim.fn.confirm(prompt, "&Delete\n&Keep\n&Stop", 2)
  if choice ~= 1 then
    return choice
  end
  if require("workhorse.ui.type_name").ask(("Type %s to delete it: "):format(repo.name), repo.name) then
    return 1
  end
  notify("The name did not match: kept repository " .. repo.name, vim.log.levels.WARN)
  return 2
end

--- Apply the changes of the repositories list (see the top of this file)
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return
  end
  if state.loading then
    notify("The repositories are still loading", vim.log.levels.WARN)
    return
  end
  if state.saving then
    notify("Already saving the repositories", vim.log.levels.WARN)
    return
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    notify("Fix errors before saving:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end
  if list.count(changes) == 0 then
    vim.bo[bufnr].modified = false
    notify("No changes to apply")
    return
  end

  state.saving = true
  local applied = 0
  vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
  for _, create in ipairs(changes.creates) do
    create.mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, create.lnum - 1, 0, { invalidate = true })
  end

  local function finish(stopped)
    state.saving = false
    if applied > 0 then
      -- The pickers and the repository of the working directory see the change
      require("workhorse.repos").update()
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
    decorate(bufnr)
    local pending = list.count((detect(bufnr)))
    vim.bo[bufnr].modified = pending > 0
    local still = ("%d change%s still pending"):format(pending, pending == 1 and "" or "s")
    if stopped then
      notify(stopped .. (pending > 0 and (" (" .. still .. ")") or ""))
    elseif pending > 0 then
      notify(still, vim.log.levels.WARN)
    end
  end

  -- Deletions: one confirmation each
  local function deletions(index)
    local delete = changes.deletes[index]
    if not delete then
      return finish()
    end
    focus(bufnr)
    local choice = confirm_delete(delete.repo)
    if choice == 2 then
      restore_line(bufnr, delete.id, delete.repo)
      return deletions(index + 1)
    elseif choice ~= 1 then
      return finish("Deletions stopped")
    end
    repos_api.delete(delete.repo.id, function(ok, err)
      if ok then
        applied = applied + 1
        state.originals[delete.id] = nil
        notify("Deleted repository " .. delete.repo.name)
      else
        notify("Failed to delete " .. delete.repo.name .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
      deletions(index + 1)
    end)
  end

  local function creations(index)
    local create = changes.creates[index]
    if not create then
      return deletions(1)
    end
    focus(bufnr)
    require("workhorse.repos_screen.new_repo").open(create.name, function(result, repo)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        state.saving = false
        return
      end
      if result == "cancelled" then
        return finish("Save cancelled")
      end
      if result == "created" then
        applied = applied + 1
        local id = list.short_id(repo.id, state.originals)
        state.originals[id] = repo
        mark_created(bufnr, create.mark, id, repo)
      end
      creations(index + 1)
    end)
  end

  -- Renames: applied right away, one after the other
  local function renames(index)
    local rename = changes.renames[index]
    if not rename then
      decorate(bufnr)
      return creations(1)
    end
    repos_api.rename(rename.repo.id, rename.name, function(repo, err)
      if repo then
        applied = applied + 1
        notify(("Renamed %s to %s"):format(rename.repo.name, repo.name or rename.name))
        state.originals[rename.id] = vim.tbl_extend("force", rename.repo, { name = repo.name or rename.name })
      else
        notify(("Failed to rename %s: %s"):format(rename.repo.name, tostring(err)), vim.log.levels.ERROR)
      end
      renames(index + 1)
    end)
  end
  renames(1)
end

return M
