-- Folding by indentation for the tree buffers (work item trees and the pipelines list). It is
-- only appearance: folds come from 'foldexpr' over the buffer lines, so the folded lines stay in
-- the buffer and are parsed and diffed like any other. A closed fold shows its first line with
-- its highlights and end-of-line hints, plus a summary of what it hides (spec.summary).
--
-- 'foldlevel' stays high so the folds made while editing (a new child line) start open; every
-- parent's fold is closed explicitly when the buffer is (re)loaded (M.collapse).
local M = {}

local parser = require("workhorse.buffer_tree.parser")

-- [bufnr] = spec: {
--   boundary = fn(line) -> true for lines that end every fold (section headers),
--   summary = fn(bufnr, first, last) -> text of the lines first..last hidden by a fold,
--   keys = fn(bufnr) -> { [lnum] = key } naming lines across reloads (M.snapshot),
-- }
local specs = {}
-- [bufnr] = { tick, levels = { [lnum] = level | false (boundary) }, exprs, starts }
local cache = {}
-- [bufnr] = snapshot of a collapse waiting for a window to show the buffer
local pending = {}

local FOLDEXPR = "v:lua.require'workhorse.fold'.expr()"
local FOLDTEXT = "v:lua.require'workhorse.fold'.text()"

-- Fold structure of the buffer, recomputed once per change
local function compute(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cache[bufnr]
  if c and c.tick == tick then
    return c
  end
  local spec = specs[bufnr] or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Level of the indent; false for boundaries, nil for blank lines
  local levels = {}
  for lnum, line in ipairs(lines) do
    if spec.boundary and spec.boundary(line) then
      levels[lnum] = false
    elseif not line:match("^%s*$") then
      levels[lnum] = parser.parse_indent(line)
    end
  end

  -- A line starts a fold when the next non-blank line is more indented. Blank lines take the
  -- lower fold level of their neighbours ("-1"), so they never extend a fold past its last item
  local exprs, starts = {}, {}
  local next_level = nil
  for lnum = #lines, 1, -1 do
    local level = levels[lnum]
    if level == nil then
      exprs[lnum] = "-1"
    elseif level == false then
      exprs[lnum] = "0"
      next_level = false
    else
      if next_level and next_level > level then
        exprs[lnum] = ">" .. (level + 1)
        starts[lnum] = level
      else
        exprs[lnum] = tostring(level)
      end
      next_level = level
    end
  end

  c = { tick = tick, levels = levels, exprs = exprs, starts = starts }
  cache[bufnr] = c
  return c
end

--- 'foldexpr' of the tree buffers
function M.expr()
  local bufnr = vim.api.nvim_get_current_buf()
  return compute(bufnr).exprs[vim.v.lnum] or "0"
end

-- Chunks without their first `count` bytes
local function drop_bytes(chunks, count)
  local result = {}
  for _, chunk in ipairs(chunks) do
    if count >= #chunk[1] then
      count = count - #chunk[1]
    else
      table.insert(result, { chunk[1]:sub(count + 1), chunk[2] })
      count = 0
    end
  end
  return result
end

-- The highlights of `line` (row `row`) as virtual text chunks, with the overlay at its start (the
-- tree guides) and followed by its end-of-line virtual text: what the line looks like when it is
-- not folded
local function line_chunks(bufnr, row, line)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, { row, 0 }, { row, -1 }, { details = true })
  local spans, eol, overlay = {}, {}, {}
  for _, mark in ipairs(marks) do
    local col, details = mark[3], mark[4]
    if details.virt_text and details.virt_text_pos == "overlay" and col == 0 then
      vim.list_extend(overlay, details.virt_text)
    end
    if details.hl_group then
      local stop = (details.end_row and details.end_row > row) and #line or details.end_col or col
      stop = math.min(stop, #line)
      if stop > col then
        table.insert(spans, { col, stop, details.hl_group, details.priority or 4096, #spans })
      end
    end
    if details.virt_text and (details.virt_text_pos or "eol") == "eol" then
      vim.list_extend(eol, details.virt_text)
    end
  end
  -- Stacked like the editor draws them: lower priority first, later marks on top
  table.sort(spans, function(a, b)
    if a[4] ~= b[4] then
      return a[4] < b[4]
    end
    return a[5] < b[5]
  end)

  local chunks = {}
  local start, key, groups = 1, nil, nil
  for i = 1, #line + 1 do
    local here, here_key = {}, nil
    if i <= #line then
      for _, span in ipairs(spans) do
        if i - 1 >= span[1] and i - 1 < span[2] then
          vim.list_extend(here, type(span[3]) == "table" and span[3] or { span[3] })
        end
      end
      here_key = table.concat(here, ",")
    end
    if i > #line or (key ~= nil and here_key ~= key) then
      if i > start then
        table.insert(chunks, { line:sub(start, i - 1), #groups > 0 and groups or nil })
      end
      start = i
    end
    key, groups = here_key, here
  end

  -- The overlay covers the indentation, spaces as wide (in bytes) as it is
  if #overlay > 0 then
    local width = 0
    for _, chunk in ipairs(overlay) do
      width = width + vim.fn.strdisplaywidth(chunk[1])
    end
    chunks = vim.list_extend(vim.deepcopy(overlay), drop_bytes(chunks, width))
  end

  if #eol > 0 then
    table.insert(chunks, { " " })
    vim.list_extend(chunks, eol)
  end
  return chunks
end

--- 'foldtext' of the tree buffers: the first line as it shows unfolded, plus the summary
function M.text()
  local bufnr = vim.api.nvim_get_current_buf()
  local first, last = vim.v.foldstart, vim.v.foldend
  local line = vim.api.nvim_buf_get_lines(bufnr, first - 1, first, false)[1] or ""
  local ok, chunks = pcall(line_chunks, bufnr, first - 1, line)
  if not ok then
    chunks = { { line } }
  end
  local spec = specs[bufnr]
  local summary = spec and spec.summary and spec.summary(bufnr, first + 1, last)
  if summary and summary ~= "" then
    table.insert(chunks, { "  ⋯ " .. summary, "WorkhorseFoldSummary" })
  end
  return chunks
end

--- Whether `lnum` (default: cursor line) has children, i.e. starts a fold
function M.is_parent(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  return specs[bufnr] ~= nil and compute(bufnr).starts[lnum] ~= nil
end

--- Toggle the fold of the cursor line when it is a parent (or inside a closed fold).
--- Returns false, doing nothing, on any other line
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if vim.fn.foldclosed(lnum) ~= -1 then
    vim.cmd("normal! zo")
    return true
  end
  if M.is_parent(bufnr, lnum) then
    vim.cmd("normal! zc")
    return true
  end
  return false
end

-- Fold options of `win` for the buffer it shows (window-local, like :setlocal, so they do not
-- leak to other buffers opened in the window). Only the changed ones are set: setting
-- 'foldmethod' or 'foldexpr' again recreates the folds, opening the ones closed by hand
local function setup_window(win)
  local function set(name, value)
    if vim.api.nvim_get_option_value(name, { win = win }) ~= value then
      vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
    end
  end
  set("foldmethod", "expr")
  set("foldexpr", FOLDEXPR)
  set("foldtext", FOLDTEXT)
  set("foldlevel", 99)
  set("foldenable", true)
  local fillchars = vim.api.nvim_get_option_value("fillchars", { win = win })
  if not fillchars:match("fold: ") then
    fillchars = fillchars:gsub("fold:[^,]*,?", ""):gsub(",$", "")
    set("fillchars", (fillchars ~= "" and fillchars .. "," or "") .. "fold: ")
  end
end

--- Whether each parent is folded ({ [key] = closed }, keys from spec.keys) in a window showing
--- the buffer, to restore them after a reload. nil when no window shows it
function M.snapshot(bufnr)
  local spec = specs[bufnr]
  if not spec or not spec.keys then
    return nil
  end
  if pending[bufnr] then
    return pending[bufnr]
  end
  local win = vim.fn.win_findbuf(bufnr)[1]
  if not win then
    return nil
  end
  local keys = spec.keys(bufnr)
  local closed = {}
  vim.api.nvim_win_call(win, function()
    for lnum in pairs(compute(bufnr).starts) do
      if keys[lnum] ~= nil then
        closed[keys[lnum]] = vim.fn.foldclosed(lnum) ~= -1
      end
    end
  end)
  return closed
end

-- Reset the folds of `win`: every parent closed, but those in `snapshot` (from M.snapshot) as
-- they were
local function collapse_window(bufnr, win, snapshot)
  local spec = specs[bufnr]
  local keys = (snapshot and spec.keys) and spec.keys(bufnr) or {}
  local to_close = {}
  for lnum, level in pairs(compute(bufnr).starts) do
    local closed = true
    if snapshot and keys[lnum] ~= nil and snapshot[keys[lnum]] ~= nil then
      closed = snapshot[keys[lnum]]
    end
    if closed then
      table.insert(to_close, { lnum = lnum, level = level })
    end
  end
  -- Innermost first: :foldclose closes the innermost open fold of the line
  table.sort(to_close, function(a, b)
    return a.level > b.level
  end)
  vim.api.nvim_win_call(win, function()
    setup_window(win)
    -- zX: re-apply 'foldlevel' (everything open), forgetting the folds opened or closed by hand
    vim.cmd("normal! zX")
    local view = vim.fn.winsaveview()
    for _, fold in ipairs(to_close) do
      vim.cmd(fold.lnum .. "foldclose")
    end
    vim.fn.winrestview(view)
  end)
end

--- Close the folds of every parent of the buffer in every window showing it (folding the parents
--- in `snapshot` as they were instead). When no window shows the buffer, the next one does it
function M.collapse(bufnr, snapshot)
  if not specs[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    pending[bufnr] = snapshot or {}
    return
  end
  pending[bufnr] = nil
  for _, win in ipairs(wins) do
    collapse_window(bufnr, win, snapshot)
  end
end

--- Enable folding on a tree buffer (see `specs` above)
function M.attach(bufnr, spec)
  specs[bufnr] = spec
  cache[bufnr] = nil
  local group = vim.api.nvim_create_augroup("workhorse_fold_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if pending[bufnr] then
        local snapshot = pending[bufnr]
        pending[bufnr] = nil
        collapse_window(bufnr, win, snapshot)
      else
        setup_window(win)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      specs[bufnr], cache[bufnr], pending[bufnr] = nil, nil, nil
    end,
  })
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    setup_window(win)
  end
end

return M
