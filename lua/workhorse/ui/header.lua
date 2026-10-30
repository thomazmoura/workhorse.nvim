-- Header of the list screens (repositories, libraries, pipelines, work item queries), like the
-- build and pull request screens': the screen's name, its actions (one per line,
-- right-aligned), then the "───── ◇ ─────" separator, with the content right below it:
--
--   Repositories
--                                                     Search repositories
--                                                                  Reload
--   ─────────────────────────── ◇ ───────────────────────────
--   #1a2b | my-repo
--
-- These lists are edited as text, so the header lines are empty and all their text is virtual:
-- it never ends up in yanks, searches or the parsed lines (the parsers skip blank lines). A
-- header line that was typed on or deleted blocks saving (M.check). <CR> on a header line runs
-- what it offers (M.action), and the header stays frozen at the top while scrolling
-- (ui/pinned.lua).
local M = {}

local pinned = require("workhorse.ui.pinned")

local ns = vim.api.nvim_create_namespace("workhorse_header")

-- Buffer -> header (see M.new), plus the width it was drawn for
local headers = {}

--- The "───── ◇ ─────" rule across `width` columns, as virtual text chunks
---@param width number
---@return table
function M.rule(width)
  local side = math.max(math.floor((width - 3) / 2), 1)
  return {
    { string.rep("─", side), "WorkhorseBuildSeparator" },
    { " ◇ ", "WorkhorseBuildSeparator" },
    { string.rep("─", math.max(width - 3 - side, 1)), "WorkhorseBuildSeparator" },
  }
end

--- A header: `title`, whose line runs `on_title(bufnr)` on <CR> (if given), then `actions`, a
--- list of { text, fn(bufnr), hl } (hl defaults to WorkhorseBuildRunning)
---@param title string
---@param on_title function|nil
---@param actions table|nil
---@return table header { title, lines, size, separator, run = { [lnum] = fn },
---  actions = { [lnum] = { text, hl } } }
function M.new(title, on_title, actions)
  local header = { title = title, lines = { "" }, run = { on_title }, actions = {} }
  for _, action in ipairs(actions or {}) do
    table.insert(header.lines, "")
    header.run[#header.lines] = action[2]
    header.actions[#header.lines] = { action[1], action[3] or "WorkhorseBuildRunning" }
  end
  table.insert(header.lines, "")
  header.separator = #header.lines
  header.size = #header.lines
  return header
end

--- The header lines followed by `lines`, to set as the buffer's content
---@param header table See M.new
---@param lines table
---@return table
function M.with(header, lines)
  return vim.list_extend(vim.list_slice(header.lines), lines)
end

--- `map` (keyed by line number, e.g. a line map of the rendered lines) keyed by the buffer
--- lines they land on below the header
---@param header table See M.new
---@param map table
---@return table
function M.shift(header, map)
  local shifted = {}
  for lnum, value in pairs(map) do
    shifted[lnum + header.size] = value
  end
  return shifted
end

--- Text width of the narrowest window showing a buffer (minus number/sign columns)
---@param bufnr number
---@return number
function M.width(bufnr)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local info = vim.fn.getwininfo(win)[1]
    local w = info.width - info.textoff
    width = width and math.min(width, w) or w
  end
  return width or vim.o.columns
end

--- Draw the header of a buffer on its first lines (each only while it is still empty: typed
--- text shows as it is, and blocks saving), then refresh its frozen copy
---@param bufnr number
function M.draw(bufnr)
  local header = headers[bufnr]
  if not (header and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  header.width = M.width(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, header.size, false)
  local function draw(lnum, opts)
    if lines[lnum] == "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, opts)
    end
  end
  draw(1, { virt_text = { { header.title, "WorkhorseBuildHeader" } }, virt_text_pos = "overlay" })
  for lnum, action in pairs(header.actions) do
    draw(lnum, { virt_text = { action }, virt_text_pos = "right_align" })
  end
  draw(header.separator, { virt_text = M.rule(header.width), virt_text_pos = "overlay" })
  pinned.refresh(bufnr)
end

--- Show `header` (see M.new) on the first lines of `bufnr`, whose content the screen sets with
--- M.with. Setting another header (e.g. a new title) replaces it.
---@param bufnr number
---@param header table
function M.attach(bufnr, header)
  local attached = headers[bufnr] ~= nil
  -- A copy: buffers sharing a header are drawn for their own width
  headers[bufnr] = vim.tbl_extend("force", {}, header)
  pinned.attach(bufnr, function()
    return headers[bufnr] and headers[bufnr].size or 0
  end)
  if not attached then
    -- Every change (a render or an edit) moves the header's marks: draw it again once it is done
    local pending = false
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function()
        if not headers[bufnr] then
          return true
        end
        if not pending then
          pending = true
          vim.schedule(function()
            pending = false
            M.draw(bufnr)
          end)
        end
      end,
      on_reload = function()
        vim.schedule(function()
          M.draw(bufnr)
        end)
      end,
      on_detach = function()
        headers[bufnr] = nil
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        headers[bufnr] = nil
      end,
    })
  end
  M.draw(bufnr)
end

--- Number of header lines of a buffer (0 without a header)
---@param bufnr number
---@return number
function M.size(bufnr)
  return headers[bufnr] and headers[bufnr].size or 0
end

--- What <CR> on a line runs (called with the buffer), when the line is one of the header's
---@param bufnr number
---@param lnum number
---@return function|nil
function M.action(bufnr, lnum)
  local header = headers[bufnr]
  return header and header.run[lnum]
end

--- Error blocking a save when the header lines were edited (typed on, deleted or added to), nil
--- when they are intact
---@param bufnr number
---@return string|nil
function M.check(bufnr)
  local header = headers[bufnr]
  if not header then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, header.size, false)
  for lnum = 1, header.size do
    if not (lines[lnum] or ""):match("^%s*$") then
      return "The header above the list was edited (line " .. lnum .. "): undo it, or <leader>R reloads"
    end
  end
  return nil
end

--- Put the cursor on the first line below the header, in every window showing the buffer (or
--- the first one to show it, when none does yet)
---@param bufnr number
function M.focus_content(bufnr)
  local function lnum()
    return math.min(M.size(bufnr) + 1, vim.api.nvim_buf_line_count(bufnr))
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    vim.api.nvim_create_autocmd("BufWinEnter", {
      buffer = bufnr,
      once = true,
      callback = function()
        vim.api.nvim_win_set_cursor(0, { lnum(), 0 })
      end,
    })
  end
  for _, win in ipairs(wins) do
    vim.api.nvim_win_set_cursor(win, { lnum(), 0 })
  end
end

-- The rule spans the window: draw it again when the width changes
local resize_events = { "VimResized" }
if vim.fn.exists("##WinResized") == 1 then
  table.insert(resize_events, "WinResized")
end
vim.api.nvim_create_autocmd(resize_events, {
  group = vim.api.nvim_create_augroup("workhorse_header_resize", { clear = true }),
  callback = function()
    for bufnr, header in pairs(headers) do
      if vim.api.nvim_buf_is_valid(bufnr) and M.width(bufnr) ~= header.width then
        M.draw(bufnr)
      end
    end
  end,
})
-- A buffer shown in another (narrower or wider) window
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup("workhorse_header_win", { clear = true }),
  callback = function(args)
    local header = headers[args.buf]
    if header and M.width(args.buf) ~= header.width then
      M.draw(args.buf)
    end
  end,
})

return M
