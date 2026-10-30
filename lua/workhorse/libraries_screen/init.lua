-- Libraries screen (:Workhorse libraries, <leader>wl): the variable groups of the configured
-- project as an editable list, like the repositories screen. A library line is "#id | name";
-- any other line is a new library. Saving applies the edits in order: renames right away, then
-- each deletion after its own confirmation (Keep puts the line back, Stop stops the rest), then
-- each new line opens a draft library screen (its variables are typed there, and its first save
-- creates it). <CR> on a library opens its Variables, Pipelines and Security screen
-- (libraries_screen/library.lua).
local M = {}

local libraries_api = require("workhorse.api.libraries")
local header = require("workhorse.ui.header")

local ns = vim.api.nvim_create_namespace("workhorse_libraries_list")

-- Per-buffer state: { originals = { [id] = group }, loading, loaded, saving }
local buffers = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

-- List --------------------------------------------------------------------------

local function line(id, name)
  return ("#%d | %s"):format(id, name)
end

-- Lines of `originals`, sorted by name
local function render(originals)
  local groups = vim.tbl_values(originals)
  table.sort(groups, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return vim.tbl_map(function(group)
    return line(group.id, group.name)
  end, groups)
end

-- Parse the buffer lines: items { kind = "library"|"new", id, name, lnum }, plus errors
local function parse(lines)
  local items, errors = {}, {}
  for lnum, text in ipairs(lines) do
    text = vim.trim(text)
    if text ~= "" then
      local id, name = text:match("^#(%d+)%s*|%s*(.-)$")
      local item = id and { kind = "library", id = tonumber(id), name = vim.trim(name), lnum = lnum }
        or { kind = "new", name = text, lnum = lnum }
      if item.name == "" then
        table.insert(errors, ("Line %d: library without a name"):format(lnum))
      end
      table.insert(items, item)
    end
  end
  return items, errors
end

-- Header of the list: reloading the libraries
local HEADER = header.new("Libraries", nil, {
  { "\u{f021} Reload", function(bufnr) -- nf-fa-refresh
    M.refresh(bufnr)
  end, "WorkhorseBuildMeta" },
})

-- Changes from `originals` to the buffer: { renames = { { id, group, name } }, creates = { { name,
-- lnum } }, deletes = { { id, group } } }, plus errors
local function detect(bufnr)
  local originals = buffers[bufnr].originals
  local items, errors = parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local header_error = header.check(bufnr)
  if header_error then
    table.insert(errors, 1, header_error)
  end
  local changes = { renames = {}, creates = {}, deletes = {} }
  local seen, names = {}, {}
  for _, item in ipairs(items) do
    local key = item.name:lower()
    if names[key] then
      table.insert(errors, ("Line %d: %s appears more than once"):format(item.lnum, item.name))
    end
    names[key] = true
    if item.kind == "library" then
      local group = originals[item.id]
      if not group then
        table.insert(errors, ("Line %d: #%d is not a library of this list"):format(item.lnum, item.id))
      elseif seen[item.id] then
        table.insert(errors, ("Line %d: #%d appears more than once"):format(item.lnum, item.id))
      else
        seen[item.id] = true
        if item.name ~= group.name then
          table.insert(changes.renames, { id = item.id, group = group, name = item.name })
        end
      end
    else
      table.insert(changes.creates, { name = item.name, lnum = item.lnum })
    end
  end
  for id, group in pairs(originals) do
    if not seen[id] then
      table.insert(changes.deletes, { id = id, group = group })
    end
  end
  table.sort(changes.deletes, function(a, b)
    return a.group.name:lower() < b.group.name:lower()
  end)
  return changes, errors
end

local function count(changes)
  return #changes.renames + #changes.creates + #changes.deletes
end

-- Highlights and hints: how many variables each library has, its description, and the pending
-- renames and creations
local function decorate(bufnr)
  local state = buffers[bufnr]
  if not state or not state.loaded or state.loading then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, item in ipairs((parse(lines))) do
    local row = item.lnum - 1
    if item.kind == "library" then
      local bar = lines[item.lnum]:find("|", 1, true)
      if bar then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { end_col = bar, hl_group = "Comment" })
      end
      local group = state.originals[item.id]
      if group then
        local virt = {}
        if item.name ~= group.name then
          table.insert(virt, { "  [was " .. group.name .. "]", "DiagnosticWarn" })
        end
        local n = vim.tbl_count(group.variables)
        table.insert(virt, { ("  %d variable%s"):format(n, n == 1 and "" or "s"), "WorkhorseBuildBranch" })
        if group.type ~= "Vsts" then
          table.insert(virt, { "  Key Vault", "WorkhorseRepoDisabled" })
        end
        if group.description ~= "" then
          table.insert(virt, { "  " .. group.description, "WorkhorseBuildMeta" })
        end
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = virt })
      end
    else
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, { virt_text = { { "  [new]", "DiagnosticOk" } } })
    end
  end
end

-- Fetch the libraries and render them, replacing the buffer content
local function load(bufnr, hard)
  local state = buffers[bufnr]
  state.loading = true
  if hard then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header.with(HEADER, { "Loading libraries..." }))
    vim.bo[bufnr].modified = false
  end
  libraries_api.list(function(groups, err)
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if not groups then
      notify("Failed to list the libraries: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    state.originals = {}
    for _, group in ipairs(groups) do
      state.originals[group.id] = group
    end
    local cursor = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header.with(HEADER, render(state.originals)))
    vim.bo[bufnr].modified = false
    state.loaded = true
    decorate(bufnr)
    if cursor and not hard then
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    elseif hard then
      header.focus_content(bufnr)
    end
  end)
end

-- The library on the cursor line
local function current_group(bufnr)
  local item = parse({ vim.api.nvim_get_current_line() })[1]
  if item and item.kind == "library" then
    return buffers[bufnr].originals[item.id]
  end
end

local function setup_keymaps(bufnr)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<leader><leader>", function()
    M.save(bufnr)
  end, "apply the changes to the libraries")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the libraries")
  map("<CR>", function()
    local action = header.action(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    if action then
      return action(bufnr)
    end
    local group = current_group(bufnr)
    if not group then
      notify("No library on this line (save a new one first)", vim.log.levels.WARN)
      return
    end
    -- A copy: the screen updates its library in place
    require("workhorse.libraries_screen.library").open(vim.deepcopy(group))
  end, "open the variables, pipelines and security of the library (or the header action)")
  local function open_web()
    local group = current_group(bufnr)
    require("workhorse.builds").open_url(libraries_api.web_url(group and group.id))
  end
  map("gw", open_web, "open the library in the browser")
  map("gb", open_web, "open the library in the browser")
  require("workhorse.builds").map_yank(bufnr, open_web, "the library")
end

local function setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_libraries_" .. bufnr, { clear = true })
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

--- Open the libraries screen in the current window (the existing buffer when already open; on
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
  vim.api.nvim_buf_set_name(bufnr, "Workhorse|libraries")
  -- acwrite: :w saves (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-libraries"
  buffers[bufnr] = { originals = {} }
  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  vim.api.nvim_win_set_buf(0, bufnr)
  header.attach(bufnr, HEADER)
  load(bufnr, true)
  return bufnr
end

--- Reload the libraries from the server (asks first when there are unsaved changes). Returns
--- false when `bufnr` (default: current) is not the libraries screen
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

--- A library changed on its screen: reload the list, unless it has pending edits
function M.changed()
  for bufnr, state in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and not state.saving and not vim.bo[bufnr].modified then
      load(bufnr)
    end
  end
end

-- Save ------------------------------------------------------------------------

-- Show the libraries list in the current window (confirmations return to it)
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

-- Put back the line of a library kept at a deletion's confirmation, before the first line of a
-- library sorting after it
local function restore_line(bufnr, group)
  local row = vim.api.nvim_buf_line_count(bufnr)
  for _, item in ipairs((parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))) do
    if item.kind == "library" and item.name:lower() > group.name:lower() then
      row = item.lnum - 1
      break
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { line(group.id, group.name) })
end

-- Ask to delete one library (its line is gone, so the prompt names it): 1 delete, 2 keep it,
-- anything else stops the deletions. Deleting asks to type its name: anything else keeps it.
local function confirm_delete(group)
  local n = vim.tbl_count(group.variables)
  local prompt = ("Delete library %s (%d variable%s)? Pipelines using it will fail."):format(group.name, n,
    n == 1 and "" or "s")
  local choice = vim.fn.confirm(prompt, "&Delete\n&Keep\n&Stop", 2)
  if choice ~= 1 then
    return choice
  end
  if require("workhorse.ui.type_name").ask(("Type %s to delete it: "):format(group.name), group.name) then
    return 1
  end
  notify("The name did not match: kept library " .. group.name, vim.log.levels.WARN)
  return 2
end

--- Apply the changes of the libraries list (see the top of this file)
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return
  end
  if state.loading then
    notify("The libraries are still loading", vim.log.levels.WARN)
    return
  end
  if state.saving then
    notify("Already saving the libraries", vim.log.levels.WARN)
    return
  end
  local changes, errors = detect(bufnr)
  if #errors > 0 then
    notify("Fix errors before saving:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end
  if count(changes) == 0 then
    vim.bo[bufnr].modified = false
    notify("No changes to apply")
    return
  end

  state.saving = true

  local function finish(stopped)
    state.saving = false
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    decorate(bufnr)
    local left = count((detect(bufnr)))
    vim.bo[bufnr].modified = left > 0
    local still = ("%d change%s still pending"):format(left, left == 1 and "" or "s")
    if stopped then
      notify(stopped .. (left > 0 and (" (" .. still .. ")") or ""))
    elseif left > 0 then
      notify(still, vim.log.levels.WARN)
    end
  end

  -- New lines: taken off the list, each opens a draft library screen (the last one shows)
  local function creations()
    if #changes.creates == 0 then
      return finish()
    end
    -- Bottom up, so the line numbers hold
    for i = #changes.creates, 1, -1 do
      local row = changes.creates[i].lnum - 1
      vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, {})
    end
    finish()
    for _, create in ipairs(changes.creates) do
      require("workhorse.libraries_screen.library").open({ name = create.name, description = "", type = "Vsts",
        variables = {} })
    end
    notify(("Type the variables of %s, then save (:w or <leader><leader>) to create it"):format(
      table.concat(vim.tbl_map(function(c)
        return c.name
      end, changes.creates), ", ")))
  end

  -- Deletions: one confirmation each
  local function deletions(index)
    local delete = changes.deletes[index]
    if not delete then
      return creations()
    end
    focus(bufnr)
    local choice = confirm_delete(delete.group)
    if choice == 2 then
      restore_line(bufnr, delete.group)
      return deletions(index + 1)
    elseif choice ~= 1 then
      return finish("Deletions stopped")
    end
    libraries_api.delete(delete.id, function(ok, err)
      if ok then
        state.originals[delete.id] = nil
        notify("Deleted library " .. delete.group.name)
      else
        notify("Failed to delete " .. delete.group.name .. ": " .. tostring(err), vim.log.levels.ERROR)
      end
      deletions(index + 1)
    end)
  end

  -- Renames: applied right away, one after the other (the whole library is sent back, its
  -- secrets without their values, which keeps them)
  local function renames(index)
    local rename = changes.renames[index]
    if not rename then
      decorate(bufnr)
      return deletions(1)
    end
    libraries_api.update(vim.tbl_extend("force", rename.group, { name = rename.name }), function(group, err)
      if group then
        notify(("Renamed %s to %s"):format(rename.group.name, group.name))
        state.originals[rename.id] = group
      else
        notify(("Failed to rename %s: %s"):format(rename.group.name, tostring(err)), vim.log.levels.ERROR)
      end
      renames(index + 1)
    end)
  end
  renames(1)
end

return M
