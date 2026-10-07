-- Pipelines list (:Workhorse pipelines list): the build definitions as an editable tree of
-- folders (see pipelines/tree.lua). Saving applies the edits in order: moves and renames right
-- away, then each new line through a pre-filled "New pipeline" form, then the deletions after
-- one confirmation. <C-c> on a form or the confirmation stops the rest of the save; what was
-- applied stays, and the buffer is not reloaded (new lines just get their #ID).
local M = {}

local builds_api = require("workhorse.api.builds")
local tree = require("workhorse.pipelines.tree")
local fold = require("workhorse.fold")

-- Created lines being saved, followed across edits
local mark_ns = vim.api.nvim_create_namespace("workhorse_pipelines_marks")

-- Per-buffer state: { originals = { [id] = { name, path } }, loading, saving }
local buffers = {}

local function notify(msg, level)
  vim.notify("Workhorse: " .. msg, level or vim.log.levels.INFO)
end

function M.is_pipelines_buffer(bufnr)
  return buffers[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

local function decorate(bufnr)
  local state = buffers[bufnr]
  if state and not state.loading then
    tree.decorate(bufnr, state.originals)
  end
end

-- Pending changes of the buffer and the errors that block saving them
local function detect(bufnr)
  local items, errors = tree.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local changes, detect_errors = tree.detect(buffers[bufnr].originals, items)
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

-- Fetch the definitions and render them, replacing the buffer content
local function load(bufnr)
  local state = buffers[bufnr]
  state.loading = true
  builds_api.list_definitions(function(definitions, err)
    if not buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    state.loading = false
    if err or not definitions then
      notify("Failed to list the pipelines: " .. tostring(err or "unknown error"), vim.log.levels.ERROR)
      return
    end
    state.originals = {}
    for _, d in ipairs(definitions) do
      state.originals[d.id] = { name = d.name, path = d.path }
    end
    -- The folders the user folded or unfolded stay so across a reload
    local fold_snapshot = state.loaded and fold.snapshot(bufnr) or nil
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, tree.render(definitions))
    vim.bo[bufnr].modified = false
    state.loaded = true
    decorate(bufnr)
    fold.collapse(bufnr, fold_snapshot)
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
  map("<Space>", function()
    fold.toggle(bufnr)
  end, "fold or unfold the folder")
  map("<CR>", function()
    if fold.toggle(bufnr) then
      return
    end
    local pipeline = current_pipeline(bufnr)
    if not pipeline then
      notify("No pipeline on this line", vim.log.levels.WARN)
      return
    end
    require("workhorse.builds").open_runs(pipeline.id, pipeline.name)
  end, "open the runs of the pipeline")
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

--- Open the pipelines list (the existing one when already open)
function M.open()
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
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading pipelines..." })
  vim.bo[bufnr].modified = false
  buffers[bufnr] = { originals = {} }
  setup_keymaps(bufnr)
  setup_autocmds(bufnr)
  fold.attach(bufnr, fold_spec)
  vim.api.nvim_win_set_buf(0, bufnr)
  load(bufnr)
  return bufnr
end

--- Reload the pipelines list from the server (asks first when it has unsaved changes).
--- Returns false when `bufnr` (default: current) is not a pipelines list
function M.refresh(bufnr)
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
  load(bufnr)
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
      each_parallel(changes.deletes, function(d, done)
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
