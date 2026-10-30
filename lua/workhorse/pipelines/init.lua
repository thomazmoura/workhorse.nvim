-- Pipelines list (:Workhorse pipelines list), All tab: the build definitions as an editable tree
-- of folders (see pipelines/tree.lua; the Recent tab is pipelines/recent.lua, the tabs
-- pipelines/tabs.lua). Saving applies the edits in order: moves and renames right
-- away, then each new line through a pre-filled "New pipeline" form, then the deletions after
-- one confirmation. <C-c> on a form or the confirmation stops the rest of the save; what was
-- applied stays, and the buffer is not reloaded (new lines just get their #ID). Pipelines can be
-- hidden (from the pickers, and from this tab until <leader>w<C-h> shows them); the hidden ones
-- are kept in the repository cache (workhorse.repos). Opening it shows the pipelines of the
-- repository cache right away, then those of the server once they arrive (see load).
local M = {}

local builds_api = require("workhorse.api.builds")
local tree = require("workhorse.pipelines.tree")
local fold = require("workhorse.fold")
local status = require("workhorse.pipelines.status")
local tabs = require("workhorse.pipelines.tabs")
local config = require("workhorse.config")
local header = require("workhorse.ui.header")

-- Created lines being saved, followed across edits
local mark_ns = vim.api.nvim_create_namespace("workhorse_pipelines_marks")

-- Per-buffer state: { originals = { [id] = { name, path } }, hidden = { [id] = true }, loading,
-- syncing (the cached pipelines shown, the server's awaited), saving, generation (of the load) }
local buffers = {}
-- The hidden pipelines are shown too (muted), for the session
local show_hidden = false

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

function M.is_pipelines_buffer(bufnr)
  return buffers[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

-- Pipelines not rendered (hidden while the hidden ones are not shown): their missing lines are not
-- deletions
local function absent(state)
  return show_hidden and {} or state.hidden
end

local function decorate(bufnr)
  local state = buffers[bufnr]
  if state and not state.loading then
    tree.decorate(bufnr, state.originals, state.hidden, absent(state))
    status.render(bufnr)
  end
end

-- Header of the tab: searching the pipelines and reloading them
local HEADER = header.new("All pipelines", nil, {
  { "\u{f002} Search pipelines", function() -- nf-fa-search
    require("workhorse.builds").pick()
  end },
  { "\u{f021} Reload", function(bufnr) -- nf-fa-refresh
    M.refresh(bufnr)
  end, "WorkhorseBuildMeta" },
})

-- Pending changes of the buffer and the errors that block saving them
local function detect(bufnr)
  local items, errors = tree.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local header_error = header.check(bufnr)
  if header_error then
    table.insert(errors, 1, header_error)
  end
  local changes, detect_errors = tree.detect(buffers[bufnr].originals, items, absent(buffers[bufnr]))
  vim.list_extend(errors, detect_errors)
  return changes, errors
end

-- Fold spec (see workhorse/fold.lua): a folded folder counts the pipelines under it, and is
-- named by its path to keep its folding across reloads
local fold_spec = {
  summary = function(bufnr, first, last)
    local count = 0
    for _, item in ipairs((tree.parse(vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)))) do
      if item.kind ~= "folder" then
        count = count + 1
      end
    end
    return ("%d pipeline%s"):format(count, count == 1 and "" or "s")
  end,
  keys = function(bufnr)
    local result = {}
    for _, item in ipairs((tree.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))) do
      if item.kind == "folder" then
        result[item.lnum] = tree.normalize_path(item.path .. "\\" .. table.concat(item.names, "\\"))
      end
    end
    return result
  end,
}

-- Render the pipelines of state.originals (without the hidden ones unless shown), replacing the
-- buffer content. The folders the user folded or unfolded stay so
local function render(bufnr)
  local state = buffers[bufnr]
  local definitions = {}
  for id, original in pairs(state.originals) do
    if show_hidden or not state.hidden[id] then
      table.insert(definitions, { id = id, name = original.name, path = original.path })
    end
  end
  local first = not state.loaded
  local fold_snapshot = state.loaded and fold.snapshot(bufnr) or nil
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header.with(HEADER, tree.render(definitions)))
  vim.bo[bufnr].modified = false
  state.loaded = true
  decorate(bufnr)
  fold.collapse(bufnr, fold_snapshot)
  -- Loaded from scratch: the cursor starts on the first line below the header
  if first then
    header.focus_content(bufnr)
  end
end

-- Whether the server's `definitions` are the pipelines of `originals` (same ids, names and paths)
local function same_definitions(originals, definitions)
  if #definitions ~= vim.tbl_count(originals) then
    return false
  end
  for _, d in ipairs(definitions) do
    local original = originals[d.id]
    if not original or original.name ~= d.name or original.path ~= d.path then
      return false
    end
  end
  return true
end

-- Fetch the definitions (and the hidden ones, from the repository cache) and render them,
-- replacing the buffer content; the repository cache is brought up to date with them. With
-- `from_cache`, the cached pipelines are rendered as soon as the repository cache is read, and
-- replaced by the server's when they differ (unless the buffer was edited meanwhile: the edits
-- stay, and a notification tells); saving waits for the server meanwhile (state.syncing). A hard
-- load starts over like the first opening: the folds all closed, the run statuses fetched again
-- and the cursor on the first line
local function load(bufnr, hard, from_cache)
  local state = buffers[bufnr]
  state.loading, state.syncing = true, false
  state.generation = (state.generation or 0) + 1
  local generation = state.generation
  if hard then
    state.loaded = false
    status.reset()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header.with(HEADER, { "Loading pipelines..." }))
    vim.bo[bufnr].modified = false
  end
  local repos = require("workhorse.repos")
  local definitions, list_err, hidden
  -- The cached pipelines are on screen
  local cached = false
  -- Ends the progress indicator of the server's answer awaited behind them
  local sync_done

  -- A later load (or the buffer's wipe) makes this one moot
  local function current()
    return buffers[bufnr] == state and state.generation == generation and vim.api.nvim_buf_is_valid(bufnr)
  end
  local function show(list)
    state.originals = {}
    for _, d in ipairs(list) do
      state.originals[d.id] = { name = d.name, path = d.path }
    end
    render(bufnr)
  end
  local function place_cursor()
    if hard then
      header.focus_content(bufnr)
    end
  end

  local pending = 2
  local function joined()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if sync_done then
      sync_done(list_err ~= nil or not definitions)
    end
    if not current() then
      return
    end
    state.loading, state.syncing = false, false
    if list_err or not definitions then
      notify("Failed to list the pipelines: " .. tostring(list_err or "unknown error")
        .. (cached and " (showing the cached ones)" or ""), vim.log.levels.ERROR)
      return
    end
    -- Every pipeline of the project: the repository cache learns the new ones
    repos.learn_definitions(definitions, true)
    if not cached then
      state.hidden = hidden
      show(definitions)
      place_cursor()
      return
    end
    if same_definitions(state.originals, definitions) then
      return
    end
    if vim.bo[bufnr].modified then
      notify("The pipelines changed on the server since they were cached: <leader>R reloads them"
        .. " (discarding the pending changes)", vim.log.levels.WARN)
      return
    end
    show(definitions)
  end

  builds_api.list_definitions_full(function(result, err)
    definitions, list_err = result, err
    joined()
  end)
  repos.get(function(cache, err)
    if not cache then
      notify("Could not read the hidden pipelines: " .. tostring(err or "unknown error"), vim.log.levels.WARN)
    end
    hidden = repos.hidden_set(cache)
    -- The server has not answered yet: the cached pipelines show meanwhile
    if from_cache and cache and not definitions and not list_err and current() then
      cached = true
      state.loading, state.syncing = false, true
      state.hidden = hidden
      show(cache.definitions)
      place_cursor()
      sync_done = require("workhorse.progress").start("Fetching the server for pipeline updates")
    end
    joined()
  end)
end

-- The pipeline on the cursor line, as { id, name }
local function current_pipeline(bufnr)
  local line = vim.api.nvim_get_current_line()
  local items = tree.parse({ line })
  local item = items[1]
  if item and item.kind == "pipeline" then
    local original = buffers[bufnr].originals[item.id]
    return { id = item.id, name = original and original.name or item.name }
  end
end

-- Ids of the pipelines on the cursor line (every line of a closed fold) or the visual selection,
-- which it ends
local function selected_ids(bufnr)
  local first, last = vim.fn.line("."), vim.fn.line(".")
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    first = vim.fn.line("v")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  if vim.fn.foldclosed(first) ~= -1 then
    first = vim.fn.foldclosed(first)
  end
  if vim.fn.foldclosedend(last) ~= -1 then
    last = vim.fn.foldclosedend(last)
  end
  local ids = {}
  for _, item in ipairs((tree.parse(vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)))) do
    if item.kind == "pipeline" and buffers[bufnr].originals[item.id] then
      table.insert(ids, item.id)
    end
  end
  return ids
end

local function busy(state)
  if state.loading or state.saving then
    notify(state.loading and "The pipelines are still loading" or "Wait for the save to finish", vim.log.levels.WARN)
    return true
  end
end

-- Take the lines of the pipelines `ids` off the buffer, keeping its other edits
local function remove_lines(bufnr, ids)
  local set = {}
  for _, id in ipairs(ids) do
    set[id] = true
  end
  local items = tree.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  for i = #items, 1, -1 do
    if items[i].kind == "pipeline" and set[items[i].id] then
      vim.api.nvim_buf_set_lines(bufnr, items[i].lnum - 1, items[i].lnum, false, {})
    end
  end
  vim.bo[bufnr].modified = tree.count((detect(bufnr))) > 0
  decorate(bufnr)
end

-- Hide the selected pipelines (or show them again when `hide` is false) and save that in the
-- repository cache
local function set_hidden(bufnr, hide)
  local state = buffers[bufnr]
  local ids = selected_ids(bufnr)
  if busy(state) then
    return
  end
  if #ids == 0 then
    notify("No pipeline selected", vim.log.levels.WARN)
    return
  end
  require("workhorse.repos").set_hidden(ids, hide, function(set, err)
    if not set then
      notify("Could not update the hidden pipelines: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.hidden = set
    if hide and not show_hidden then
      if vim.bo[bufnr].modified then
        remove_lines(bufnr, ids)
      else
        render(bufnr)
      end
    else
      decorate(bufnr)
    end
    local plural = #ids == 1 and "" or "s"
    notify(hide and ("Hid %d pipeline%s"):format(#ids, plural)
      or ("%d pipeline%s no longer hidden"):format(#ids, plural))
  end)
end

-- Show the hidden pipelines too, or hide them again (asks first when the list has unsaved changes)
local function toggle_hidden(bufnr)
  local state = buffers[bufnr]
  if vim.fn.mode() ~= "n" then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  if busy(state) then
    return
  end
  local action = show_hidden and "hide" or "show"
  if vim.bo[bufnr].modified
    and vim.fn.confirm(("Discard the pending changes and %s the hidden pipelines?"):format(action), "&Discard\n&Cancel", 2) ~= 1 then
    return
  end
  show_hidden = not show_hidden
  render(bufnr)
  local count = vim.tbl_count(state.hidden)
  notify(("%s %d hidden pipeline%s"):format(show_hidden and "Showing" or "Hiding", count, count == 1 and "" or "s"))
end

local function setup_keymaps(bufnr)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map("<leader><leader>", function()
    M.save(bufnr)
  end, "apply the changes to the pipelines")
  map("<leader>R", function()
    M.refresh(bufnr)
  end, "reload the pipelines")
  -- On a folder: fold or unfold it; on a pipeline <CR> opens its runs
  for _, lhs in ipairs(config.space_keys()) do
    map(lhs, function()
      fold.toggle(bufnr)
    end, "fold or unfold the folder")
  end
  map("<CR>", function()
    local action = header.action(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    if action then
      return action(bufnr)
    end
    if fold.toggle(bufnr) then
      return
    end
    local pipeline = current_pipeline(bufnr)
    if not pipeline then
      notify("No pipeline on this line", vim.log.levels.WARN)
      return
    end
    require("workhorse.builds").open_runs(pipeline.id, pipeline.name)
  end, "open the runs of the pipeline (or the header action)")
  -- Hiding works on the cursor line or the visual selection
  local function map_nx(lhs, fn, desc)
    vim.keymap.set({ "n", "x" }, lhs, fn, { buffer = bufnr, silent = true, desc = "Workhorse: " .. desc })
  end
  map_nx("<leader>wh", function()
    set_hidden(bufnr, true)
  end, "hide the pipelines from the pickers")
  map_nx("<leader>wH", function()
    set_hidden(bufnr, false)
  end, "stop hiding the pipelines")
  map_nx("<leader>w<C-h>", function()
    toggle_hidden(bufnr)
  end, "show or hide the hidden pipelines")
  local function open_in_browser()
    local pipeline = current_pipeline(bufnr)
    if not pipeline then
      notify("No pipeline on this line", vim.log.levels.WARN)
      return
    end
    require("workhorse.builds").open_definition_in_browser(pipeline.id)
  end
  map("gw", open_in_browser, "open the pipeline in the browser")
  map("gb", open_in_browser, "open the pipeline in the browser")
  require("workhorse.builds").map_yank(bufnr, open_in_browser, "the pipeline")
  tabs.setup_buffer(bufnr)
end

local function setup_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("workhorse_pipelines_" .. bufnr, { clear = true })
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

--- Open the pipelines screen on its default tab (`pipelines.default_tab`). On one of its tabs, it
--- reloads that tab from scratch instead (see load)
function M.open()
  local current = vim.api.nvim_get_current_buf()
  if M.refresh(current, { hard = true }) then
    return current
  end
  return tabs.show(config.get().pipelines.default_tab)
end

--- Show the All tab (the tree) in the current window: the existing buffer when already open
function M.open_all()
  for bufnr in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_win_set_buf(0, bufnr)
      return bufnr
    end
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "Workhorse|pipelines")
  -- acwrite: :w saves (through BufWriteCmd) instead of writing a file
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "workhorse-pipelines"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, header.with(HEADER, { "Loading pipelines..." }))
  vim.bo[bufnr].modified = false
  buffers[bufnr] = { originals = {}, hidden = {} }
  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  fold.attach(bufnr, fold_spec)
  require("workhorse.buffer_tree.guides").setup_buffer(bufnr)
  status.attach(bufnr)
  vim.api.nvim_win_set_buf(0, bufnr)
  header.attach(bufnr, HEADER)
  header.focus_content(bufnr)
  load(bufnr, false, true)
  return bufnr
end

--- Reload the pipelines list from the server (asks first when it has unsaved changes); opts.hard
--- reloads it from scratch, like the first opening: from the repository cache first (see load).
--- The Recent tab reloads too. Returns false when `bufnr` (default: current) is not a tab of the
--- pipelines screen
function M.refresh(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return require("workhorse.pipelines.recent").refresh(bufnr, opts)
  end
  if state.saving then
    notify("Wait for the save to finish", vim.log.levels.WARN)
    return true
  end
  if vim.bo[bufnr].modified and vim.fn.confirm("Discard the pending changes and reload?", "&Reload\n&Cancel", 2) ~= 1 then
    return true
  end
  local hard = opts and opts.hard
  load(bufnr, hard, hard)
  return true
end

-- Save ------------------------------------------------------------------------

-- Run fn(item, done) for every item at once; then() once all called done
local function each_parallel(items, fn, after)
  local pending = #items
  if pending == 0 then
    return after()
  end
  for _, item in ipairs(items) do
    fn(item, function()
      pending = pending - 1
      if pending == 0 then
        after()
      end
    end)
  end
end

-- Show the pipelines list in the current window (forms and the confirmation return to it)
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

local function describe_move(move)
  local parts = {}
  if move.name ~= move.old_name then
    table.insert(parts, ("Renamed %s to %s"):format(move.old_name, move.name))
  end
  if move.path ~= move.old_path then
    table.insert(parts, ("Moved %s: %s → %s"):format(move.name, move.old_path, move.path))
  end
  return table.concat(parts, "; ")
end

-- Give the created line (followed by `mark`) the id of its pipeline, keeping its indent
local function mark_created(bufnr, mark, definition)
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, mark_ns, mark, { details = true })
  if not ok or not pos[1] or (pos[3] and pos[3].invalid) then
    return
  end
  local row = pos[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local _, rest = require("workhorse.buffer_tree.parser").parse_indent(line)
  local indent = line:sub(1, #(line:gsub("%s+$", "")) - #vim.trim(rest))
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { ("%s#%d | %s"):format(indent, definition.id, definition.name) })
end

--- Apply the changes of the pipelines list (see the top of this file)
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return
  end
  if state.loading then
    notify("The pipelines are still loading", vim.log.levels.WARN)
    return
  end
  if state.syncing then
    notify("The pipelines are still syncing with the server", vim.log.levels.WARN)
    return
  end
  if state.saving then
    notify("Already saving the pipelines", vim.log.levels.WARN)
    return
  end

  local changes, errors = detect(bufnr)
  if #errors > 0 then
    notify("Fix errors before saving:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
    return
  end
  if tree.count(changes) == 0 then
    vim.bo[bufnr].modified = false
    notify("No changes to apply")
    return
  end

  state.saving = true
  vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
  for _, create in ipairs(changes.creates) do
    -- invalidate (Neovim 0.10+): know when the line was deleted meanwhile
    local ok, mark = pcall(vim.api.nvim_buf_set_extmark, bufnr, mark_ns, create.lnum - 1, 0, { invalidate = true })
    create.mark = ok and mark or vim.api.nvim_buf_set_extmark(bufnr, mark_ns, create.lnum - 1, 0, {})
  end

  local function finish(stopped)
    state.saving = false
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
    decorate(bufnr)
    local pending = tree.count((detect(bufnr)))
    vim.bo[bufnr].modified = pending > 0
    if stopped then
      notify(stopped .. (pending > 0 and (" (%d change%s still pending)"):format(pending, pending == 1 and "" or "s") or ""))
    elseif pending > 0 then
      notify(("%d change%s still pending"):format(pending, pending == 1 and "" or "s"), vim.log.levels.WARN)
    end
  end

  local function deletions()
    if #changes.deletes == 0 then
      return finish()
    end
    focus(bufnr)
    require("workhorse.pipelines.confirm").show(changes.deletes, function(confirmed)
      if not confirmed then
        return finish("Deletions cancelled")
      end
      local deleted, failures = 0, {}
      each_parallel(confirmed, function(d, done)
        builds_api.delete_definition(d.id, function(ok, err)
          if ok then
            deleted = deleted + 1
            state.originals[d.id] = nil
          else
            table.insert(failures, ("#%d %s: %s"):format(d.id, d.name, tostring(err)))
          end
          done()
        end)
      end, function()
        if deleted > 0 then
          notify(("Deleted %d pipeline%s"):format(deleted, deleted == 1 and "" or "s"))
        end
        if #failures > 0 then
          notify("Failed to delete:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
        end
        finish()
      end)
    end)
  end

  local function creations(index)
    local create = changes.creates[index]
    if not create then
      return deletions()
    end
    focus(bufnr)
    require("workhorse.builds.new_definition").open({
      name = create.name,
      folder = create.path,
      on_done = function(result, definition)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          state.saving = false
          return
        end
        if result == "cancelled" then
          return finish("Save cancelled")
        end
        if result == "created" then
          state.originals[definition.id] = { name = definition.name, path = definition.path }
          mark_created(bufnr, create.mark, definition)
        end
        creations(index + 1)
      end,
    })
  end

  -- Moves and renames: applied right away, all at once
  local failures = {}
  each_parallel(changes.moves, function(move, done)
    builds_api.update_definition(move.id, { name = move.name, path = move.path }, function(updated, err)
      if updated then
        state.originals[move.id] = { name = updated.name or move.name, path = updated.path or move.path }
        notify(describe_move(move))
      else
        table.insert(failures, ("#%d %s: %s"):format(move.id, move.old_name, tostring(err)))
      end
      done()
    end)
  end, function()
    if #failures > 0 then
      notify("Failed to update:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
    end
    decorate(bufnr)
    creations(1)
  end)
end

return M
