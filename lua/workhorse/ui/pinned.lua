-- Frozen headers: every screen starts with its header (title, actions, "───── ◇ ─────"). Once
-- it scrolls out of view, a copy of it is pinned over the top of the window in a non-focusable
-- float, the way nvim-treesitter-context does. The copy holds the header lines and their
-- extmarks (highlights, virtual text, the rule drawn as a virtual line), so it looks like the
-- real header; at the top of the buffer the real (actionable) lines show instead.
--
-- A screen attaches its buffer with the size of its header (M.attach) and refreshes the copy
-- whenever it redraws the header (M.refresh, or M.schedule_refresh while it is being edited).
local M = {}

local copy_ns = vim.api.nvim_create_namespace("workhorse_pinned_copy")

-- Attached buffer -> { size = fn(bufnr) -> header lines, header_buf, height }
local headers = {}
-- Window -> the float pinning its header
local pinned = {}

local function close_pinned(win)
  local float = pinned[win]
  pinned[win] = nil
  if float and vim.api.nvim_win_is_valid(float) then
    vim.api.nvim_win_close(float, true)
  end
end

-- Statuscolumn of a pinned header, filled by M._pinned_number
local PINNED_NUMBER = "%{%v:lua.require'workhorse.ui.pinned'._pinned_number()%}"

-- Give the pinned header the gutter width of the window under it, so its lines stay in the
-- same columns as the real header lines
local function set_pinned_gutter(float, textoff)
  local gutter = textoff > 0
  vim.wo[float].number = gutter
  vim.wo[float].relativenumber = false
  vim.wo[float].numberwidth = math.min(math.max(textoff, 1), 20)
  vim.wo[float].statuscolumn = gutter and PINNED_NUMBER or ""
end

-- Show the pinned header over `win` while its own header is scrolled away
local function pin_header(win)
  local state = headers[vim.api.nvim_win_get_buf(win)]
  local height = state and state.height
  local info = vim.fn.getwininfo(win)[1]
  -- At the top the real (actionable) header lines show; tiny windows keep the content visible
  if not height or height == 0 or info.topline <= 1 or info.height <= height + 1 then
    return close_pinned(win)
  end
  local float_config = {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = info.width,
    height = height,
    focusable = false,
    zindex = 20,
  }
  local float = pinned[win]
  if float and vim.api.nvim_win_is_valid(float) then
    if vim.api.nvim_win_get_buf(float) ~= state.header_buf then
      vim.api.nvim_win_set_buf(float, state.header_buf)
    end
    vim.api.nvim_win_set_config(float, float_config)
    set_pinned_gutter(float, info.textoff)
    return
  end
  float_config.style = "minimal"
  float_config.noautocmd = true
  float = vim.api.nvim_open_win(state.header_buf, false, float_config)
  vim.wo[float].wrap = false
  vim.wo[float].winhighlight = "NormalFloat:Normal"
  -- Opaque even with a global 'winblend': the content behind must not show through
  vim.wo[float].winblend = 0
  set_pinned_gutter(float, info.textoff)
  pinned[win] = float
end

-- Relative numbers change with the cursor of the window, which does not redraw the float
local function redraw_pinned_numbers(win)
  local float = pinned[win]
  if float and vim.api.nvim_win_is_valid(float) and vim.wo[win].relativenumber and vim.api.nvim__redraw then
    vim.api.nvim__redraw({ win = float, statuscolumn = true })
  end
end

-- Pin headers over the windows scrolled past theirs, and drop the floats of windows that were
-- closed or no longer show an attached buffer
local function sync_pinned()
  for win in pairs(pinned) do
    if not (vim.api.nvim_win_is_valid(win) and headers[vim.api.nvim_win_get_buf(win)]) then
      close_pinned(win)
    end
  end
  for bufnr in pairs(headers) do
    for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
      pin_header(win)
    end
  end
end

-- Keep the cursor of `win` off the rows its pinned header covers: `scroll` brings the view down
-- to the cursor (moving up with k), otherwise the cursor moves down into view (scrolling with the
-- wheel or <C-e>)
local function uncover_cursor(win, scroll)
  local float = pinned[win]
  if not (float and vim.api.nvim_win_is_valid(float)) then
    return
  end
  local height = vim.api.nvim_win_get_height(float)
  vim.api.nvim_win_call(win, function()
    -- Step one screen row at a time, so wrapped lines and folds count right
    for _ = 1, height do
      if vim.fn.winline() > height or vim.fn.line("w0") <= 1 then
        return
      end
      vim.cmd(scroll and "normal! \25" or "normal! gj")
    end
  end)
end

local sync_pending = false
local function schedule_sync()
  if not sync_pending then
    sync_pending = true
    vim.schedule(function()
      sync_pending = false
      sync_pinned()
    end)
  end
end

local group = vim.api.nvim_create_augroup("workhorse_pinned_header", { clear = true })
vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinClosed" }, {
  group = group,
  callback = schedule_sync,
})
-- Scrolling updates right away, so the pinned header never lags a redraw behind
vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
  group = group,
  callback = function()
    sync_pinned()
    for win in pairs(pinned) do
      uncover_cursor(win, false)
    end
  end,
})
vim.api.nvim_create_autocmd("CursorMoved", {
  group = group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if pinned[win] then
      uncover_cursor(win, true)
      redraw_pinned_numbers(win)
    end
  end,
})

-- Options of an extmark as returned by nvim_buf_get_extmarks (details), made fit for
-- nvim_buf_set_extmark again, with its end clamped to the header's last line
local function mark_opts(details, size, lines)
  local opts = vim.deepcopy(details)
  opts.ns_id = nil
  if opts.virt_text_pos == "win_col" then
    opts.virt_text_pos = nil
  end
  if opts.end_row and opts.end_row >= size then
    opts.end_row = size - 1
    opts.end_col = #(lines[size] or "")
  end
  return opts
end

--- Copy the header of `bufnr` (its first lines and their extmarks) into the pinned buffer, then
--- pin it over the windows scrolled past it
---@param bufnr number
function M.refresh(bufnr)
  local state = headers[bufnr]
  if not (state and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_valid(state.header_buf)) then
    return
  end
  local size = math.min(state.size(bufnr) or 0, vim.api.nvim_buf_line_count(bufnr))
  local lines = size > 0 and vim.api.nvim_buf_get_lines(bufnr, 0, size, false) or {}
  local header_buf = state.header_buf
  vim.bo[header_buf].modifiable = true
  vim.api.nvim_buf_set_lines(header_buf, 0, -1, false, lines)
  vim.bo[header_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(header_buf, copy_ns, 0, -1)
  local height = size
  if size > 0 then
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, { 0, 0 }, { size - 1, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      local row, col, details = mark[2], mark[3], mark[4]
      if pcall(vim.api.nvim_buf_set_extmark, header_buf, copy_ns, row, col, mark_opts(details, size, lines))
        and details.virt_lines and not (details.virt_lines_above and row == 0) then
        -- Virtual lines (e.g. the rule under a title) take rows of the float too
        height = height + #details.virt_lines
      end
    end
  end
  state.height = height
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    pin_header(win)
  end
end

local refresh_pending = {}
--- M.refresh once the current changes are drawn (e.g. after a screen decorates its edited lines)
---@param bufnr number
function M.schedule_refresh(bufnr)
  if refresh_pending[bufnr] then
    return
  end
  refresh_pending[bufnr] = true
  vim.schedule(function()
    refresh_pending[bufnr] = nil
    M.refresh(bufnr)
  end)
end

--- Freeze the header of `bufnr`: `size(bufnr)` gives the number of lines it takes at the top of
--- the buffer (0 when there is none, e.g. while loading). Attaching again only updates `size`.
---@param bufnr number
---@param size fun(bufnr: number): number
function M.attach(bufnr, size)
  if headers[bufnr] then
    headers[bufnr].size = size
    return
  end
  local header_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[header_buf].modifiable = false
  headers[bufnr] = { size = size, header_buf = header_buf, height = 0 }
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      headers[bufnr] = nil
      schedule_sync()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(header_buf) then
          vim.api.nvim_buf_delete(header_buf, { force = true })
        end
      end)
    end,
  })
end

--- Number column of a pinned header: the numbers the window under it shows on those lines
function M._pinned_number()
  -- The statuscolumn is evaluated with the window being drawn as the current one
  local float = vim.api.nvim_get_current_win()
  for win, f in pairs(pinned) do
    if f == float and vim.api.nvim_win_is_valid(win) then
      local width = vim.wo[float].numberwidth - 1
      -- Virtual lines (the rule under a title) have no number
      if vim.v.virtnum ~= 0 then
        return string.rep(" ", width + 1)
      end
      local lnum = vim.v.lnum
      local number = lnum
      if vim.wo[win].relativenumber then
        local cursor = vim.api.nvim_win_get_cursor(win)[1]
        number = (cursor == lnum and vim.wo[win].number) and lnum or math.abs(cursor - lnum)
      end
      return "%#LineNrAbove#" .. string.format("%" .. width .. "d ", number)
    end
  end
  return ""
end

return M
