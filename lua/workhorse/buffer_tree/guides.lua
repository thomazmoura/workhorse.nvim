-- Tree guides of the tree buffers (work item trees and the pipelines list). The indentation in
-- the buffer is plain spaces, `width` per level; the guides (├─ └─ │) are drawn over it as
-- overlay virtual text, so they never end up in yanks or searches and follow the indentation as
-- it is edited. Each line's guides are computed from the lines below it: a line gets ├─ when a
-- sibling follows it and └─ otherwise, and │ runs down while an ancestor has a sibling to come.
local M = {}

local config = require("workhorse.config")

local ns = vim.api.nvim_create_namespace("workhorse_tree_guides")

local DEFAULT = { branch = "├─ ", last = "└─ ", vertical = "│  " }

-- The guide strings, each padded to the width of one indent level
local function glyphs()
  local g = vim.tbl_extend("force", DEFAULT, config.get().tree_guides or {})
  local width = math.max(1, vim.fn.strdisplaywidth(g.branch), vim.fn.strdisplaywidth(g.last),
    vim.fn.strdisplaywidth(g.vertical))
  local function pad(text)
    return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
  end
  return { branch = pad(g.branch), last = pad(g.last), vertical = pad(g.vertical), blank = string.rep(" ", width) },
    width
end

--- Columns (spaces) of one indent level
function M.width()
  return select(2, glyphs())
end

--- Indentation of a line at `level`
function M.prefix(level)
  return string.rep(" ", M.width() * math.max(level or 0, 0))
end

--- Guides of `lines`: { [lnum] = text }, for the lines indented with spaces. `boundary(line)`
--- tells the lines that end every tree (section headers); blank lines are skipped
function M.compute(lines, boundary)
  local parse_indent = require("workhorse.buffer_tree.parser").parse_indent
  local g, width = glyphs()
  local result = {}
  -- [level] = a line at that level follows, before any less indented line
  local has_next = {}
  for lnum = #lines, 1, -1 do
    local line = lines[lnum]
    if boundary and boundary(line) then
      has_next = {}
    elseif not line:match("^%s*$") then
      local level = parse_indent(line)
      -- Lines still indented with glyphs (pasted from an older version) are left as they are
      if level > 0 and line:sub(1, level * width):match("^ *$") then
        local parts = {}
        for depth = 1, level - 1 do
          parts[depth] = has_next[depth] and g.vertical or g.blank
        end
        parts[level] = has_next[level] and g.branch or g.last
        result[lnum] = table.concat(parts)
      end
      has_next[level] = true
      for depth in pairs(has_next) do
        if depth > level then
          has_next[depth] = nil
        end
      end
    end
  end
  return result
end

--- Draw the guides of the buffer (opts.boundary as in M.compute)
function M.draw(bufnr, opts)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local hl = config.get().tree_indent_hl
  if not hl or hl == "" then
    hl = "NonText"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for lnum, text in pairs(M.compute(lines, opts and opts.boundary)) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
      virt_text = { { text, hl } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
    })
  end
end

--- Indent options of a tree buffer: >>, <<, <C-t>, <C-d> and <BS> move one level, <Tab> inserts
--- one, and new lines keep the level of the line above
function M.setup_buffer(bufnr)
  local width = M.width()
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = width
  vim.bo[bufnr].softtabstop = width
  vim.bo[bufnr].tabstop = width
  vim.bo[bufnr].autoindent = true
end

return M
